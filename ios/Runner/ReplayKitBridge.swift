//
//  iOS 录制桥接（设计文档 3.5：iPad 端录课）—— **仅录制本应用窗口**。
//
//  为什么不用 ReplayKit：
//  - ReplayKit（startCapture / 预览保存）只能录**整个屏幕**，
//    系统没有「只录自己窗口」的 API；
//  - 需要屏幕录制权限，且录进来的内容（其它 app、状态栏）不是用户想要的。
//
//  这里的做法：CADisplayLink 定时（默认 30fps）用 `drawHierarchy` 把本应用
//  的窗口渲染进 CVPixelBuffer，AVAssetWriter 编码 H.264 —— 录制的是
//  **应用自己的内容**，且不需要屏幕录制权限（只要麦克风权限）。
//
//  麦克风：AVAudioRecorder 单独录一路 m4a，停止后用 AVMutableComposition
//  （passthrough 导出）与视频合成。这比手动构造 CMSampleBuffer 的音频
//  管线简单一个数量级，且导出失败时还能退回纯视频。
//
//  限制：切后台 / 息屏时 CADisplayLink 暂停，画面定格（时间轴继续）；
//  系统弹窗、键盘等不在窗口层级内的内容不会被录进去。
//
//  Dart 侧见 lib/features/recorder/record_page.dart（channel: ebook_studio/recorder）。
//

import AVFoundation
import Flutter
import UIKit

public class ReplayKitBridge: NSObject, FlutterPlugin {
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var pixelPool: CVPixelBufferPool?
    private var displayLink: CADisplayLink?

    private weak var targetWindow: UIWindow?
    private var cropRect: CGRect = .zero
    private var pixelWidth = 0
    private var pixelHeight = 0

    private var outputURL: URL?
    private var micURL: URL?
    private var micRecorder: AVAudioRecorder?
    private var sessionStartTime: CMTime?
    private var startedAt: Date?
    private var fps = 30

    // FlutterResult 只能在主线程调用；导出完成后的回调先存这里
    private var pendingStop: FlutterResult?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "ebook_studio/recorder", binaryMessenger: registrar.messenger())
        let instance = ReplayKitBridge()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
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
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else {
            result(FlutterError(code: "UNAVAILABLE", message: "找不到应用窗口", details: nil))
            return
        }
        targetWindow = window

        // 裁剪区域（窗口内容逻辑坐标，Dart 传内容区矩形）；缺省 = 整个窗口
        if let crop = args?["crop"] as? [String: Any],
           let x = crop["x"] as? Double, let y = crop["y"] as? Double,
           let w = crop["w"] as? Double, let h = crop["h"] as? Double, w >= 2, h >= 2 {
            cropRect = CGRect(x: x, y: y, width: w, height: h)
        } else {
            cropRect = window.bounds
        }

        // 输出分辨率（像素）：Dart 按 720p / 1080p / 跟随窗口算好传来
        let scale = window.screen.scale
        let outArgs = args?["out"] as? [String: Any]
        var width = (outArgs?["w"] as? Int) ?? Int((cropRect.width * scale).rounded(.down))
        var height = (outArgs?["h"] as? Int) ?? Int((cropRect.height * scale).rounded(.down))
        width -= width % 2  // 编码器要求偶数
        height -= height % 2
        guard width >= 16, height >= 16 else {
            result(FlutterError(code: "UNAVAILABLE", message: "内容区尺寸过小，无法录制", details: nil))
            return
        }
        pixelWidth = width
        pixelHeight = height

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = documents.appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(formatter.string(from: Date())).mp4")
        outputURL = url

        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            result(FlutterError(code: "START_FAILED", message: "无法创建视频文件：\(error.localizedDescription)", details: nil))
            return
        }

        // 视频轨 + 像素缓冲池（自己建池，避免 adaptor.pixelBufferPool 尚为 nil 的时序问题）
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

        // 麦克风：单独录一路 m4a（失败则退化为纯视频，不阻塞录制）
        if args?["audio"] as? Bool ?? false {
            startMicRecording()
        }

        fps = max(1, min(60, args?["fps"] as? Int ?? 30))
        let link = CADisplayLink(target: self, selector: #selector(captureFrame))
        link.preferredFramesPerSecond = fps
        link.add(to: .main, forMode: .common)
        displayLink = link
        result(nil)
    }

    private func startMicRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("mic-\(formatter.string(from: Date())).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record() else {
                return
            }
            micRecorder = recorder
            micURL = url
        } catch {
            // 麦克风不可用：纯视频继续
        }
    }

    // ---------- 逐帧渲染（主线程） ----------

    @objc private func captureFrame() {
        guard let writer, writer.status == .writing,
              let videoInput, videoInput.isReadyForMoreMediaData,
              let adaptor, let pool = pixelPool,
              let window = targetWindow else {
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

        // drawHierarchy 画在左上原点，CVPixelBuffer 是左下原点 → 翻转 y
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: 1, y: -1)
        // 窗口坐标 → 裁剪区域 → 目标分辨率（裁剪外自动落在画布之外）
        let scaleX = CGFloat(pixelWidth) / cropRect.width
        let scaleY = CGFloat(pixelHeight) / cropRect.height
        context.scaleBy(x: scaleX, y: scaleY)
        context.translateBy(x: -cropRect.minX, y: -cropRect.minY)
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)

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
        guard let writer else {
            result(FlutterError(code: "NOT_RECORDING", message: "当前没有正在进行的录制", details: nil))
            return
        }
        pendingStop = result
        displayLink?.invalidate()
        displayLink = nil
        micRecorder?.stop()
        micRecorder = nil
        videoInput?.markAsFinished()
        writer.finishWriting { [weak self] in
            DispatchQueue.main.async {
                self?.mergeMicAudioIfNeeded()
            }
        }
    }

    /// 把麦克风 m4a 合成进视频（passthrough 不重编码）。
    /// 任何一步失败都退回纯视频 —— 有画面总比没结果好。
    private func mergeMicAudioIfNeeded() {
        guard let writer, let videoURL = outputURL else { return }
        let duration = startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0

        guard writer.status == .completed else {
            let stop = pendingStop
            let message = "视频写入失败（录制时间过短或磁盘空间不足）"
            reset()
            stop?(FlutterError(code: "STOP_FAILED", message: message, details: nil))
            return
        }

        guard let micURL else {
            finish(result: pendingStop, path: videoURL.path, duration: duration, micURL: nil)
            return
        }

        let micAsset = AVURLAsset(url: micURL)
        let videoAsset = AVURLAsset(url: videoURL)
        let composition = AVMutableComposition()
        guard
            let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            let sourceVideo = videoAsset.tracks(withMediaType: .video).first
        else {
            // 一帧都没画出来（比如立刻停止）—— 视频轨为空，返回错误而不是坏文件
            let stop = pendingStop
            reset()
            stop?(FlutterError(code: "STOP_FAILED", message: "没有录到有效画面（录制时间过短）", details: nil))
            return
        }
        try? videoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoAsset.duration),
            of: sourceVideo, at: .zero)

        if let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
           let sourceAudio = micAsset.tracks(withMediaType: .audio).first {
            let micDuration = min(micAsset.duration, videoAsset.duration)
            if micDuration.seconds > 0.5 {
                try? audioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: micDuration),
                    of: sourceAudio, at: .zero)
            } else {
                composition.removeTrack(audioTrack)
            }
        }

        // 导出到临时文件再顶替原视频（导出目标不能是输入文件）
        let mergedURL = videoURL.deletingLastPathComponent()
            .appendingPathComponent(videoURL.deletingPathExtension().lastPathComponent + "+merged.mp4")
        try? FileManager.default.removeItem(at: mergedURL)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            finish(result: pendingStop, path: videoURL.path, duration: duration, micURL: micURL)
            return
        }
        export.outputURL = mergedURL
        export.outputFileType = .mp4
        export.exportAsynchronously { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if export.status == .completed {
                    // 顶替原视频
                    try? FileManager.default.removeItem(at: videoURL)
                    try? FileManager.default.moveItem(at: mergedURL, to: videoURL)
                }
                self.finish(result: self.pendingStop, path: videoURL.path, duration: duration, micURL: micURL)
            }
        }
    }

    private func finish(result: FlutterResult?, path: String, duration: Int, micURL: URL?) {
        if let micURL {
            try? FileManager.default.removeItem(at: micURL)
        }
        self.micURL = nil
        let stop = result
        reset()
        stop?(["path": path, "duration_seconds": duration])
    }

    private func reset() {
        writer = nil
        videoInput = nil
        adaptor = nil
        // CVPixelBufferPool 是 Core Foundation 桥接对象，Swift/ARC 自动管理，
        // 不能（也不需要）手动 Release
        pixelPool = nil
        displayLink?.invalidate()
        displayLink = nil
        targetWindow = nil
        cropRect = .zero
        outputURL = nil
        micURL = nil
        micRecorder = nil
        sessionStartTime = nil
        startedAt = nil
        pendingStop = nil
    }
}
