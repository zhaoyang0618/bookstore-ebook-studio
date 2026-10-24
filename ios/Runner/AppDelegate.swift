import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    // 录课桥接（设计文档 3.5）：不是 pub 插件，需要手动注册。
    // iOS 的 registrar(forPlugin:) 返回可选值（macOS 返回非可选）。
    if let recorderRegistrar = self.registrar(forPlugin: "ReplayKitBridge") {
      ReplayKitBridge.register(with: recorderRegistrar)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
