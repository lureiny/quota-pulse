import Cocoa
import FlutterMacOS

// 替换 flutter create 生成的 macos/Runner/AppDelegate.swift。
// 菜单栏(accessory)应用:隐藏窗口时不退出整个 App。
@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // 关键:窗口隐藏 ≠ 退出。退出走托盘菜单"退出"。
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
