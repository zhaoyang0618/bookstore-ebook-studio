import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // 录课桥接（设计文档 3.5）：不是 pub 插件，需要手动注册
    let recorderRegistrar = self.registrar(forPlugin: "ScreenRecorderBridge")
    ScreenRecorderBridge.register(with: recorderRegistrar)
    super.applicationDidFinishLaunching(notification)
  }
}
