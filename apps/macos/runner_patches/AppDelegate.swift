import Cocoa
import FlutterMacOS

// 替换 flutter create 生成的 macos/Runner/AppDelegate.swift。
//
// 自管菜单栏状态项(不再用 tray_manager):固定宽 = 图标区 + 文字区,
// 图标钉死在左、永不被挤动;右侧文字区裁剪后做像素级平滑横向滚动(流水屏)。
// 与 Flutter 通过 MethodChannel "quota_pulse/menubar" 通信。

// AppKit(左下原点)↔ Flutter(左上原点)坐标换算,与 window_manager 一致。
extension NSRect {
  var qpTopLeft: CGPoint {
    let h = NSScreen.main?.frame.height ?? 0
    return CGPoint(x: origin.x, y: h - origin.y - size.height)
  }
}

// 菜单栏状态项在 MainFlutterWindow.awakeFromNib 创建(那里直接拿得到 FlutterViewController)。
@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // 关键:窗口隐藏 ≠ 退出。退出走菜单栏右键"退出"。
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

// 菜单栏状态项控制器:固定长度;左键→通知 Flutter 弹层,右键→上下文菜单。
class MenuBarController: NSObject {
  private let channel: FlutterMethodChannel
  private var statusItem: NSStatusItem?
  private var view: MenuBarView?
  private var menuItems: [[String: Any]] = []

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "quota_pulse/menubar", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "setup": setup(args); result(nil)
    case "setTicker": setTicker(args); result(nil)
    case "getFrame": result(frameDict())
    case "destroy": destroy(); result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func ensureItem() {
    guard statusItem == nil else { return }
    let total = MenuBarView.iconArea + 150
    let item = NSStatusBar.system.statusItem(withLength: total)
    if let button = item.button {
      // 关键:显式给定非零 frame。statusItem 刚创建时 button.bounds 可能仍是 0,
      // 用 0 frame + autoresizing 会一直保持 0 → 视图既不可见也收不到点击。
      let v = MenuBarView(frame: NSRect(x: 0, y: 0, width: total, height: NSStatusBar.system.thickness))
      v.onLeftClick = { [weak self] in self?.channel.invokeMethod("onClick", arguments: nil) }
      v.onRightClick = { [weak self] in self?.showMenu() }
      button.addSubview(v)
      view = v
    }
    statusItem = item
  }

  private func setup(_ args: [String: Any]) {
    ensureItem()
    // 图标自绘到子视图左侧固定区,不走 button.image:
    // 按钮无 title 时 AppKit 会把 image 居中到整条状态项 → 正好压在文字上(重叠)。
    if let icon = args["icon"] as? FlutterStandardTypedData, let img = NSImage(data: icon.data) {
      img.isTemplate = true
      img.size = NSSize(width: 18, height: 18)
      view?.setIcon(img)
    }
    menuItems = args["menu"] as? [[String: Any]] ?? []
  }

  private func setTicker(_ args: [String: Any]) {
    ensureItem()
    let text = args["text"] as? String ?? ""
    let scroll = args["scroll"] as? Bool ?? false
    let pps = CGFloat((args["pps"] as? NSNumber)?.doubleValue ?? 100)
    let width = CGFloat((args["width"] as? NSNumber)?.doubleValue ?? 150)
    let total = MenuBarView.iconArea + width
    statusItem?.length = total
    view?.frame = NSRect(x: 0, y: 0, width: total, height: NSStatusBar.system.thickness)
    view?.setContent(text, scroll: scroll, pps: pps, textWidth: width)
  }

  // 状态项按钮的屏幕坐标(左上原点),供 Flutter 给弹层定位。
  private func frameDict() -> [String: Any]? {
    guard let wf = statusItem?.button?.window?.frame else { return nil }
    let tl = wf.qpTopLeft
    return ["x": tl.x, "y": tl.y, "width": wf.size.width, "height": wf.size.height]
  }

  private func destroy() {
    if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
    statusItem = nil
    view = nil
  }

  // 右键:临时挂菜单 → performClick 弹出 → 立刻摘掉(避免左键也弹菜单)。
  private func showMenu() {
    guard let item = statusItem else { return }
    item.menu = buildMenu()
    item.button?.performClick(nil)
    item.menu = nil
  }

  private func buildMenu() -> NSMenu {
    let menu = NSMenu()
    for item in menuItems {
      if (item["separator"] as? Bool) == true {
        menu.addItem(.separator())
        continue
      }
      let mi = NSMenuItem(
        title: item["label"] as? String ?? "",
        action: #selector(onMenuItem(_:)), keyEquivalent: "")
      mi.target = self
      mi.representedObject = item["key"]
      menu.addItem(mi)
    }
    return menu
  }

  @objc private func onMenuItem(_ sender: NSMenuItem) {
    if let key = sender.representedObject as? String {
      channel.invokeMethod("onMenu", arguments: key)
    }
  }
}

// 自定义绘制 + 鼠标处理(参照 tray_manager 的 TrayIcon 子视图方式)。
// 左侧固定图标(模板色随明暗适配)+ 右侧裁剪区内逐像素横向滚动文字。
// 翻转坐标(左上原点)便于排版;滚动用 60fps 定时器推进偏移。
class MenuBarView: NSView {
  static let iconArea: CGFloat = 26
  private let font = NSFont.systemFont(ofSize: 13)
  private let gap: CGFloat = 44 // 一圈文字尾到头的空隙

  var onLeftClick: (() -> Void)?
  var onRightClick: (() -> Void)?

  private var iconRaw: NSImage?    // 原始模板图(随明暗重新着色)
  private var iconTinted: NSImage? // 按当前外观着成 labelColor 的缓存

  private var text: String = ""
  private var scrolling = false
  private var pps: CGFloat = 100
  private var textWidth: CGFloat = 150
  private var contentWidth: CGFloat = 0
  private var offset: CGFloat = 0
  private var timer: Timer?

  override var isFlipped: Bool { true }

  // 图标自绘:模板图按当前外观着色后缓存,避免每帧重算。
  func setIcon(_ img: NSImage?) {
    iconRaw = img
    retintIcon()
    needsDisplay = true
  }

  private func retintIcon() {
    guard let raw = iconRaw else { iconTinted = nil; return }
    let out = NSImage(size: raw.size)
    out.lockFocus()
    let saved = NSAppearance.current
    NSAppearance.current = effectiveAppearance     // 让 labelColor 解析到当前明暗
    NSColor.labelColor.set()
    let rect = NSRect(origin: .zero, size: raw.size)
    raw.draw(in: rect)
    rect.fill(using: .sourceAtop)                   // 用 labelColor 染模板图的不透明像素
    NSAppearance.current = saved
    out.unlockFocus()
    iconTinted = out
  }

  // 每次数据轮询都会调用(文字常有微变,如倒计时)。已在滚动时只换文字、保留进度,
  // 避免每轮跳回开头;速度/宽度变化即时生效(定时器闭包每帧读 self.pps)。
  func setContent(_ s: String, scroll: Bool, pps: CGFloat, textWidth: CGFloat) {
    self.pps = pps
    self.textWidth = textWidth
    self.text = s
    contentWidth = (s as NSString).size(withAttributes: [.font: font]).width
    let shouldScroll = scroll && contentWidth > textWidth
    let wasScrolling = scrolling
    scrolling = shouldScroll
    if shouldScroll {
      if !wasScrolling || timer == nil {
        offset = 0
        startTimer()
      }
      // 已在滚 → 保留 offset 与定时器,仅换文字
    } else {
      timer?.invalidate()
      timer = nil
      offset = 0
    }
    needsDisplay = true
  }

  private func startTimer() {
    timer?.invalidate()
    let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      guard let self = self else { return }
      self.offset += self.pps / 60.0
      let loop = self.contentWidth + self.gap
      if loop > 0, self.offset >= loop { self.offset -= loop }
      self.needsDisplay = true
    }
    RunLoop.main.add(t, forMode: .common) // .common:菜单/拖动时也继续滚
    timer = t
  }

  override func draw(_ dirtyRect: NSRect) {
    let h = bounds.height
    // 左侧图标:自绘,水平居中于 iconArea、垂直居中(钉死,绝不与文字区重叠)。
    if let icon = iconTinted {
      let s = icon.size
      icon.draw(in: NSRect(x: (MenuBarView.iconArea - s.width) / 2,
                           y: (h - s.height) / 2,
                           width: s.width, height: s.height))
    }
    // 右侧文字区:裁剪后绘制,滚动时画多遍接成无缝循环。
    // 用 textWidth(不依赖 bounds 时序)。
    let tx = MenuBarView.iconArea
    let tw = textWidth
    if tw <= 0 || text.isEmpty { return }
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
    let ns = text as NSString
    let size = ns.size(withAttributes: attrs)
    let ty = (h - size.height) / 2
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: NSRect(x: tx, y: 0, width: tw, height: h)).addClip()
    if scrolling {
      let loop = contentWidth + gap
      var x = tx - offset
      while x < tx + tw {
        ns.draw(at: NSPoint(x: x, y: ty), withAttributes: attrs)
        x += loop
      }
    } else {
      ns.draw(at: NSPoint(x: tx, y: ty), withAttributes: attrs)
    }
    NSGraphicsContext.restoreGraphicsState()
  }

  // 明暗切换:文字用 labelColor 自动更新;图标需按新外观重新着色。
  override func viewDidChangeEffectiveAppearance() {
    retintIcon()
    needsDisplay = true
  }

  // ---- 鼠标:自己处理,不走 button.action ----
  override func mouseDown(with event: NSEvent) {
    (superview as? NSStatusBarButton)?.highlight(true)
  }

  override func mouseUp(with event: NSEvent) {
    (superview as? NSStatusBarButton)?.highlight(false)
    onLeftClick?()
  }

  override func rightMouseDown(with event: NSEvent) {
    onRightClick?()
  }

  deinit { timer?.invalidate() }
}
