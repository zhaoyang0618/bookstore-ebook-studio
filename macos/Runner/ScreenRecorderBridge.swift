//
//  屏幕录制桥接（设计文档 3.5：macOS 桌面端录课）。
//
//  用 AVFoundation 的 AVCaptureScreenInput + AVCaptureMovieFileOutput，
//  整条流水线系统自带，输出 H.264 + AAC 的 MP4，无需第三方依赖。
//
//  权限：
//  - 屏幕录制（TCC）：macOS 10.15+ 首次录制会触发系统弹窗，授权后
//    **需要重启应用**才生效（系统行为）。
//  - 麦克风（TCC）+ 沙箱 `com.apple.security.device.audio-input`。
//
//  Dart 侧见 lib/features/recorder/record_page.dart（channel: ebook_studio/recorder）。
//

import AVFoundation
import CoreGraphics
import FlutterMacOS

class ScreenRecorderBridge: NSObject, FlutterPlugin {
    private let session = AVCaptureSession()
    private var screenInput: AVCaptureScreenInput?
    private var micInput: AVCaptureDeviceInput?
    private var movieOutput: AVCaptureMovieFileOutput?
    private var outputPath: String?
    private var startedAt: Date?
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
        guard movieOutput == nil else {
            result(FlutterError(code: "ALREADY_RECORDING", message: "已经在录制中", details: nil))
            return
        }
        // .inputPriority：不裁剪分辨率，按屏幕原生尺寸录（须在添加输入前设置）
        session.sessionPreset = .inputPriority
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
        guard let input = AVCaptureScreenInput(displayID: CGMainDisplayID()) else {
            result(FlutterError(code: "UNAVAILABLE", message: "没有可录制的显示器", details: nil))
            return
        }
        // 30fps 足够录课，文件也更小
        input.minFrameDuration = CMTime(value: 1, timescale: 30)
        screenInput = input

        let audio = args?["audio"] as? Bool ?? false
        if audio, let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
            self.micInput = micInput
        }

        let output = AVCaptureMovieFileOutput()
        guard session.canAddOutput(output) else {
            result(FlutterError(code: "START_FAILED", message: "无法创建录制输出", details: nil))
            return
        }
        session.addOutput(output)
        movieOutput = output

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let url = dir.appendingPathComponent("\(formatter.string(from: Date())).mp4")
        outputPath = url.path

        session.startRunning()
        startedAt = Date()
        output.startRecording(to: url, recordingDelegate: self)
        result(nil)
    }

    // ---------- 停止 ----------

    private func stopRecording(result: @escaping FlutterResult) {
        guard let output = movieOutput else {
            result(FlutterError(code: "NOT_RECORDING", message: "当前没有正在进行的录制", details: nil))
            return
        }
        pendingStop = result
        output.stopRecording()
    }

    private func teardown() {
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        screenInput = nil
        micInput = nil
        movieOutput = nil
        startedAt = nil
        pendingStop = nil
        if session.isRunning {
            DispatchQueue.global(qos: .utility).async { [session] in
                session.stopRunning()
            }
        }
    }
}

extension ScreenRecorderBridge: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let path = outputPath
        let duration = startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        let stop = pendingStop
        DispatchQueue.main.async { [weak self] in
            self?.teardown()
            guard let stop else { return }
            if let error {
                stop(FlutterError(code: "STOP_FAILED", message: "视频写入失败：\(error.localizedDescription)", details: nil))
            } else if let path {
                stop(["path": path, "duration_seconds": duration])
            } else {
                stop(FlutterError(code: "STOP_FAILED", message: "视频文件路径丢失", details: nil))
            }
        }
    }
}
