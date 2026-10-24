//
//  ReplayKit 桥接（设计文档 3.5：iPad 端屏幕录制）。
//
//  通过 Flutter Platform Channel 暴露 startRecording / stopRecording，
//  内部用 RPScreenRecorder 的**采样缓冲模式**（startCapture），
//  把视频 / 麦克风 CMSampleBuffer 写进 AVAssetWriter，直接产出 MP4。
//
//  为什么不用 stopRecording 的 RPPreviewViewController：
//  预览界面只让用户「存到相册」，我们拿不到文件路径，元数据
//  （设计文档 1.7）也就无从写起。采样缓冲模式由我们控制输出路径，
//  停止后立即得到可用的 MP4。
//
//  Dart 侧见 lib/features/recorder/record_page.dart（channel: ebook_studio/recorder）。
//

import AVFoundation
import Flutter
import ReplayKit

public class ReplayKitBridge: NSObject, FlutterPlugin {
    private let recorder = RPScreenRecorder.shared()
    private let queue = DispatchQueue(label: "ebook_studio.recorder")

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var startedSession = false
    private var startedAt: Date?

    // FlutterResult 不能跨线程调用，停止完成后的回调先存这里，回主线程再取
    private var pendingStopResult: FlutterResult?

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
        guard recorder.isAvailable else {
            result(FlutterError(code: "UNAVAILABLE", message: "屏幕录制不可用（可能是受限模式或模拟器）", details: nil))
            return
        }
        guard writer == nil else {
            result(FlutterError(code: "ALREADY_RECORDING", message: "已经在录制中", details: nil))
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let fileName = "\(formatter.string(from: Date())).mp4"

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let recordingsDir = documents.appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        let url = recordingsDir.appendingPathComponent(fileName)
        outputURL = url

        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            result(FlutterError(code: "START_FAILED", message: "无法创建视频文件：\(error.localizedDescription)", details: nil))
            return
        }

        startedSession = false
        startedAt = Date()
        recorder.isMicrophoneEnabled = args?["audio"] as? Bool ?? false

        recorder.startCapture(handler: { [weak self] sampleBuffer, sampleBufferType, error in
            guard let self else { return }
            if error != nil { return }
            switch sampleBufferType {
            case .video:
                self.appendVideo(sampleBuffer)
            case .audioApp, .audioMic:
                // audioApp 是系统声音（iPad 上多为空），麦克风音频走 audioMic
                self.appendAudio(sampleBuffer)
            @unknown default:
                break
            }
        }, completionHandler: { [weak self] error in
            guard let self else { return }
            if let error {
                self.reset()
                result(FlutterError(code: "START_FAILED", message: error.localizedDescription, details: nil))
            } else {
                result(nil)
            }
        })
    }

    // ---------- 采样缓冲 → AVAssetWriter ----------

    /// 首个视频缓冲到达时才创建输入：屏幕尺寸要从缓冲的格式描述里拿，
    /// 提前猜会写错分辨率。
    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let writer, writer.status == .writing else { return }
        if videoInput == nil {
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)

            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(dimensions.width),
                AVVideoHeightKey: Int(dimensions.height),
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { return }
            writer.add(input)
            videoInput = input

            if audioInput == nil {
                let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 2,
                    AVSampleRateKey: 44100,
                    AVEncoderBitRateKey: 128_000,
                ])
                audio.expectsMediaDataInRealTime = true
                if writer.canAdd(audio) {
                    writer.add(audio)
                    audioInput = audio
                }
            }

            if writer.startWriting() {
                // sessionStartTime 在首个缓冲到来时确定，保证两条轨道时间轴一致
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                startedSession = true
            }
        }
        guard startedSession, let videoInput else { return }
        // 实时录制：编码器来不及就丢帧，不能阻塞回调队列
        if videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let writer, writer.status == .writing, startedSession, let audioInput else { return }
        if audioInput.isReadyForMoreMediaData {
            audioInput.append(sampleBuffer)
        }
    }

    // ---------- 停止 ----------

    private func stopRecording(result: @escaping FlutterResult) {
        guard writer != nil else {
            result(FlutterError(code: "NOT_RECORDING", message: "当前没有正在进行的录制", details: nil))
            return
        }
        pendingStopResult = result
        recorder.stopCapture { [weak self] _ in
            DispatchQueue.main.async {
                self?.finishWriting()
            }
        }
    }

    private func finishWriting() {
        guard let writer else { return }
        let url = outputURL
        let duration = startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        // 先标记两条轨道不再收数据，finishWriting 才会正常收尾
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self else { return }
            let success = writer.status == .completed
            let result = self.pendingStopResult
            self.reset()
            guard let result else { return }
            if success, let url {
                result(["path": url.path, "duration_seconds": duration])
            } else {
                result(FlutterError(code: "STOP_FAILED", message: "视频写入失败", details: nil))
            }
        }
    }

    private func reset() {
        writer = nil
        videoInput = nil
        audioInput = nil
        outputURL = nil
        startedSession = false
        startedAt = nil
        pendingStopResult = nil
    }
}
