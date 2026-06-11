import Cocoa
import FlutterMacOS

// 替换 flutter create 生成的 macos/Runner/MainFlutterWindow.swift。
// 默认实现 + 在这里(flutterViewController 直接在手)创建自定义菜单栏状态项,
// 比在 AppDelegate 里事后去找 FlutterViewController 可靠。
class MainFlutterWindow: NSWindow {
  var menuBar: MenuBarController?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // 用 Flutter 引擎的 messenger 注册菜单栏通道(此时引擎已就绪、Dart 尚未运行)。
    menuBar = MenuBarController(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
