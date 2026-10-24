import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // 录课桥接（设计文档 3.5）：不是 pub 插件，需要手动注册。
    // 注意注册点必须在这里 —— FlutterViewController 实现了
    // FlutterPluginRegistry；FlutterAppDelegate（macOS）没有 registrar。
    ScreenRecorderBridge.register(
      with: flutterViewController.registrar(forPlugin: "ScreenRecorderBridge"))

    super.awakeFromNib()
  }
}
