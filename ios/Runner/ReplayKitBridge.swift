//
//  ReplayKit 桥接（设计文档 3.5：iPad 端屏幕录制）。
//
//  通过 Flutter Platform Channel 暴露 startRecording / stopRecording 两个方法，
//  内部调用 ReplayKit 的 RPScreenRecorder。
//
//  Dart 侧见 lib/features/recorder/record_page.dart（channel: ebook_studio/recorder）。
//

import Flutter
import ReplayKit

public class ReplayKitBridge: NSObject, FlutterPlugin {
    private let recorder = RPScreenRecorder.shared()
    private var eventSink: FlutterEventSink?

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

    private func startRecording(args: [String: Any]?, result: @escaping FlutterResult) {
        guard recorder.isAvailable else {
            result(FlutterError(code: "UNAVAILABLE", message: "屏幕录制不可用（可能是受限模式或模拟器）", details: nil))
            return
        }
        recorder.isMicrophoneEnabled = args?["audio"] as? Bool ?? false
        recorder.startRecording(handler: { [weak self] error in
            if let error = error {
                result(FlutterError(code: "START_FAILED", message: error.localizedDescription, details: nil))
                return
            }
            result(nil)
            _ = self
        })
    }

    private func stopRecording(result: @escaping FlutterResult) {
        recorder.stopRecording(handler: { [weak self] previewViewController, error in
            if let error = error {
                result(FlutterError(code: "STOP_FAILED", message: error.localizedDescription, details: nil))
                return
            }
            // 录课视频保存到应用的文档目录，文件名带时间戳
            let formatter = DateFormatter.iso()
            let fileName = "\(formatter.string(from: Date())).mp4"
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let destination = documents.appendingPathComponent("recordings").appendingPathComponent(fileName)
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 交给用户预览 / 保存（RPPreviewViewController 需在 FlutterViewController 上呈现）
            if let preview = previewViewController {
                DispatchQueue.main.async {
                    UIApplication.shared.windows.first?.rootViewController?.present(preview, animated: true)
                }
            }
            result(["path": destination.path])
        })
    }
}

/// ISO 8601 文件名用的日期格式化器。
private final class DateFormatter {
    private let formatter: Foundation.DateFormatter
    init() {
        formatter = Foundation.DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
    }
    func string(from date: Date) -> String { formatter.string(from: date) }
    static func iso() -> DateFormatter { DateFormatter() }
}
