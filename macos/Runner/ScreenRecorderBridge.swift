//
//  屏幕录制桥接（设计文档 3.5：macOS 桌面端录课）—— **只录内容区**。
//
//  用 CGWindowListCreateImage 抓**本应用窗口**（windowNumber → CGWindowID），
//  按 Dart 传来的内容区矩形裁剪、缩放到目标分辨率，
//  经 AVAssetWriter（H.264）落盘；麦克风用 AVCaptureAudioDataOutput 的
//  采样缓冲喂给同一条 writer 的音频轨。
//
//  权限：窗口抓取在 macOS 10.15+ 仍需 TCC「屏幕录制」授权（首次弹窗，
//  授权后需重启应用）；麦克风需 TCC + 沙箱 audio-input entitlement。
//
//  说明：CGWindowListCreateImage 自 10.15 起标记 deprecated 但仍是唯一
//  无需 ScreenCaptureKit 复杂管线的同步抓帧 API（SCK 需要 weak-link 与
//  独立音频管线，见 README「为什么 macOS 还是全屏」的后续计划）。
//
//  Dart 侧见 lib/features/recorder/record_page.dart（channel: ebook_studio/recorder）。
//

import AVFoundation
import CoreGraphics
import FlutterMacOS

class ScreenRecorderBridge: NSObject, FlutterPlugin {
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var pixelPool: CVPixelBufferPool?
    private var outputURL: URL?

    private var captureTimer: DispatchSourceTimer?
    private let writerQueue = DispatchQueue(label: "ebook_studio.recorder")

    private var captureSession: AVCaptureSession?
    private var windowID: CGWindowID = 0
    private var screenCropRect = CGRect.zero
    private var pixelWidth = 0
    private var pixelHeight = 0
    private var sessionStartTime: CMTime?
    private var startedAt: Date?
    private var fps = 30

    private var pendingStop: FlutterResult?

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "ebook_studio/recorder", binaryMessenger: registrar.messenger)
        let instance = ScreenRecorderBridge()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startRecording":
            startRecording(args: call.arguments as? [String: Any], result: result)
        case "stopRecording":
            stopRecording(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // ---------- 开始 ----------

    private func startRecording(args: [String: Any]?, result: @escaping FlutterResult) {
        guard writer == nil else {
            result(FlutterError(code: "ALREADY_RECORDING", message: "已经在录制中", details: nil))
            return
        }
        if #available(macOS 10.15, *) {
            if !CGPreflightScreenCaptureAccess() {
                // 触发系统弹窗；本轮内拿不到授权，让用户开完后重试
                CGRequestScreenCaptureAccess()
                result(FlutterError(
                    code: "SCREEN_PERMISSION",
                    message: "需要在「系统设置 → 隐私与安全性 → 屏幕录制」中允许 ebook studio，然后重启应用再试",
                    details: nil))
                return
            }
        }
        guard let window = NSApplication.shared.keyWindow else {
            result(FlutterError(code: "UNAVAILABLE", message: "找不到应用窗口", details: nil))
            return
        }

        // Dart 传来的内容区矩形是「窗口内容（Flutter 视图）逻辑坐标、左上原点」；
        // 转成屏幕全局坐标（左下原点）给 CGWindowListCreateImage
        let contentBounds = window.contentView?.bounds ?? .zero
        let contentHeight = contentBounds.height
        let crop = cropRect(from: args) ?? CGRect(x: 0, y: 0, width: contentBounds.width, height: contentHeight)
        let viewRect = NSRect(x: crop.minX, y: contentHeight - crop.maxY, width: crop.width, height: crop.height)
        screenCropRect = window.convertToScreen(viewRect)
        windowID = CGWindowID(window.windowNumber)

        let outArgs = args?["out"] as? [String: Any]
        var width = (outArgs?["w"] as? Int) ?? Int(crop.width)
        var height = (outArgs?["h"] as? Int) ?? Int(crop.height)
        width = max(16, width - (width % 2))
        height = max(16, height - (height % 2))
        pixelWidth = width
        pixelHeight = height

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(formatter.string(from: Date())).mp4")
        outputURL = url

        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            result(FlutterError(code: "START_FAILED", message: "无法创建视频文件：\(error.localizedDescription)", details: nil))
            return
        }

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer!.canAdd(videoInput) else {
            reset()
            result(FlutterError(code: "START_FAILED", message: "无法添加视频轨道", details: nil))
            return
        }
        writer!.add(videoInput)
        self.videoInput = videoInput

        let poolAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput,
                                                       sourcePixelBufferAttributes: poolAttributes)
        CVPixelBufferPoolCreate(nil, poolAttributes as CFDictionary, nil, &pixelPool)

        if writer!.startWriting() {
            startedAt = Date()
        } else {
            reset()
            result(FlutterError(code: "START_FAILED", message: "视频写入器启动失败", details: nil))
            return
        }

        // 麦克风：AVCaptureAudioDataOutput 采样缓冲（失败则纯视频）
        if args?["audio"] as? Bool ?? false {
            startMicCapture()
        }

        fps = max(1, min(60, args?["fps"] as? Int ?? 30))
        startCaptureTimer()
        result(nil)
    }

    private func cropRect(from args: [String: Any]?) -> NSRect? {
        guard let crop = args?["crop"] as? [String: Any],
              let x = crop["x"] as? Double, let y = crop["y"] as? Double,
              let w = crop["w"] as? Double, let h = crop["h"] as? Double,
              w >= 2, h >= 2 else {
            return nil
        }
        return NSRect(x: x, y: y, width: w, height: h)
    }

    private func startMicCapture() {
        guard let mic = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: mic) else {
            return
        }
        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: writerQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
        captureSession = session

        // 音频轨：AAC 输出（writer 负责把 PCM 转码）
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ])
        audio.expectsMediaDataInRealTime = true
        if writer!.canAdd(audio) {
            writer!.add(audio)
            audioInput = audio
        }
    }

    private func startCaptureTimer() {
        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now(), repeating: Double(1_000) / Double(fps) / 1_000.0)
        timer.setEventHandler { [weak self] in
            self?.captureFrame()
        }
        timer.resume()
        captureTimer = timer
    }

    // ---------- 逐帧抓取（writerQueue） ----------

    private func captureFrame() {
        guard let writer, writer.status == .writing,
              let videoInput, videoInput.isReadyForMoreMediaData,
              let adaptor, let pool = pixelPool else {
            return
        }
        // 抓取失败（窗口最小化 / 权限被收回）就跳过这一帧，时间轴继续
        guard let cgImage = CGWindowListCreateImage(
            screenCropRect,
            .optionIncludingWindow,
            windowID,
            [.bestResolution, .boundsIgnoreFraming]) else {
            return
        }

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let buffer = pixelBuffer else { return }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        // CGImage 是左上原点，CVPixelBuffer 内存行 0 在顶部：翻转后画满画布
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if sessionStartTime == nil {
            sessionStartTime = now
            writer.startSession(atSourceTime: now)
        }
        let pts = CMTimeSubtract(now, sessionStartTime!)
        adaptor.append(buffer, withPresentationTime: pts)
    }

    // ---------- 停止 ----------

    private func stopRecording(result: @escaping FlutterResult) {
        guard writer != nil else {
            result(FlutterError(code: "NOT_RECORDING", message: "当前没有正在进行的录制", details: nil))
            return
        }
        pendingStop = result
        captureTimer?.cancel()
        captureTimer = nil
        captureSession?.stopRunning()
        captureSession = nil
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writer?.finishWriting { [weak self] in
            DispatchQueue.main.async {
                self?.finish(result: result)
            }
        }
    }

    private func finish(result: @escaping FlutterResult) {
        guard let writer else { return }
        let url = outputURL
        let duration = startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        let success = writer.status == .completed
        reset()
        if success, let url {
            result(["path": url.path, "duration_seconds": duration])
        } else {
            result(FlutterError(code: "STOP_FAILED", message: "视频写入失败（可能录制时间过短）", details: nil))
        }
    }

    private func reset() {
        captureTimer?.cancel()
        captureTimer = nil
        captureSession?.stopRunning()
        captureSession = nil
        writer = nil
        videoInput = nil
        adaptor = nil
        audioInput = nil
        pixelPool = nil
        outputURL = nil
        windowID = 0
        screenCropRect = .zero
        sessionStartTime = nil
        startedAt = nil
        pendingStop = nil
    }
}

// MARK: - 麦克风采样缓冲

extension ScreenRecorderBridge: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let writer, writer.status == .writing, sessionStartTime != nil,
              let audioInput, audioInput.isReadyForMoreMediaData else {
            return
        }
        audioInput.append(sampleBuffer)
    }
}
