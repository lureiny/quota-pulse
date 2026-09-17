import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

// 共享层:模型 / UI / 状态 / 桥接全部来自 ui 包(与 macOS 同一份)
import 'package:quota_pulse_ui/quota_pulse_ui.dart';

import 'autostart.dart'; // 开机自启动(Windows:注册表 Run 项)
import 'win_ticker.dart'; // 桌面悬浮跑马灯(原生 Win32 浮层 + D2D 像素级滚动)

// ── Windows 与 macOS 壳的差异(其余逻辑共用 ui 包) ──
//   · 托盘图标用彩色 .ico(非 macOS 模板图);
//   · Windows 托盘无标题文字 → 峰值走 setToolTip(而非 setTitle);
//   · 托盘在右下角 → 弹层贴 bottomRight(macOS 是 topRight);
//   · 无 LSUIElement/Dock 概念 → 用 skipTaskbar 隐藏任务栏按钮。

/// 弹层固定宽(WindowOptions 与定位共用)。高度由内容动态自适应(见 _onContentHeight)。
const double kPanelWidth = 460.0;

/// App 生效明暗:跟随「主题」设置(system 时解析系统平台明暗)。
bool effectiveDark(ThemeChoice mode) => switch (mode) {
      ThemeChoice.light => false,
      ThemeChoice.dark => true,
      ThemeChoice.system =>
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark,
    };

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await Window.initialize(); // flutter_acrylic

  final windowOptions = WindowOptions(
    size: const Size(kPanelWidth, 600),
    backgroundColor: Colors.transparent, // 透出毛玻璃
    skipTaskbar: true,
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
    alwaysOnTop: true,
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setAsFrameless();
    await windowManager.setBackgroundColor(Colors.transparent);
    await windowManager.setSkipTaskbar(true);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.hide(); // 托盘应用:启动即隐藏,点托盘才弹出
  });

  // 毛玻璃:Windows 用 acrylic(Win10+;降级可改 WindowEffect.solid)。
  // dark 跟随 App 生效明暗(主题设置,而非启动瞬间的系统明暗);之后由 Shell 在主题 /
  // 系统明暗变化时重套。否则浅色主题会叠在深色 acrylic 上,半透 GlassCard 被压暗。
  final settings = await SettingsStore.load();
  await Window.setEffect(
      effect: WindowEffect.acrylic, dark: effectiveDark(settings.themeMode));
  // flutter_acrylic 在 Windows 上套 acrylic 后会把标题栏(连带最小化/最大化/关闭三个按钮)加回来。
  // 注:flutter_acrylic 的隐藏按钮 API 仅 macOS 有效;window_manager 的 setTitleBarStyle 在
  // setAsFrameless 之后又会失效(已知问题)。故套完效果后:再断言无边框 + 直接剥掉
  // 最小化/最大化/关闭三个窗口样式位(WS_MINIMIZEBOX/WS_MAXIMIZEBOX/WS_SYSMENU),多管齐下。
  await windowManager.setAsFrameless();
  await windowManager.setMinimizable(false);
  await windowManager.setMaximizable(false);
  await windowManager.setClosable(false);
  await UsageAlerter.setup(); // 通知后端初始化(一次;Windows 会建快捷方式挂 AppUserModelID)

  final seed = await loadAccentColor(); // 跟随系统强调色
  runApp(QuotaPulseApp(source: FfiPulseSource(), settings: settings, seed: seed));
}

class QuotaPulseApp extends StatefulWidget {
  const QuotaPulseApp({
    super.key,
    required this.source,
    required this.settings,
    required this.seed,
  });

  final PulseSource source;
  final Settings settings;
  final Color seed;

  @override
  State<QuotaPulseApp> createState() => _QuotaPulseAppState();
}

class _QuotaPulseAppState extends State<QuotaPulseApp> {
  late ThemeMode _themeMode = widget.settings.themeMode.toThemeMode();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      // Windows:打包 MiSans 修正雅黑缺失的中间字重(macOS 壳不传,用系统 SF)
      theme: buildAppTheme(
          seed: widget.seed, brightness: Brightness.light, fontFamily: 'MiSans'),
      darkTheme: buildAppTheme(
          seed: widget.seed, brightness: Brightness.dark, fontFamily: 'MiSans'),
      themeMode: _themeMode, // 可设置;默认跟随系统
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: MediaQuery.textScalerOf(context)
              .clamp(minScaleFactor: 1.0, maxScaleFactor: 1.3),
        ),
        child: child!,
      ),
      home: Shell(
        source: widget.source,
        initialSettings: widget.settings,
        onThemeModeChanged: (m) => setState(() => _themeMode = m),
      ),
    );
  }
}

enum _View { list, settings, debug }

class Shell extends StatefulWidget {
  const Shell({
    super.key,
    required this.source,
    required this.initialSettings,
    required this.onThemeModeChanged,
  });

  final PulseSource source;
  final Settings initialSettings;
  final void Function(ThemeMode) onThemeModeChanged;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell>
    with TrayListener, WindowListener, WidgetsBindingObserver {
  late Settings _settings = widget.initialSettings;
  PulseController? _controller;
  final _alerter = UsageAlerter(); // 用量阈值提醒
  _View _view = _View.list;
  // 面板当前是否真的在屏上。启动时两个壳都先 windowManager.hide(),所以初值是 false。
  // 不能靠 PulseController 的默认值 —— controller 是 _startCore 里才创建的,
  // 而图表 widget 从第一帧起就挂着定时器了。
  bool _popoverVisible = false;
  String? _error;
  bool _autostartEnabled = false; // 开机自启动:真值以 OS 为准,启动时查询
  bool _debugOpen = false; // 调试面板打开时:窗口放大 + 失焦不自动收起

  PulseSource get _source => widget.source;

  // 悬浮跑马灯滚动参数:速度仍与 macOS 菜单栏同源(tickerMs→pps 点/秒);
  // 宽度改用 Windows 浮窗独立字段 windowsTickerWidth(逻辑像素),缺省回退共享 tickerWidth*9
  // 兜底(老用户无回归)。原生再把宽度硬夹到整屏宽。可拖拽浮窗边缘改宽,经 onResized 回写。
  double get _scrollPps => 8000.0 / _settings.tray.tickerMs.clamp(20, 1000);
  double get _scrollWidth =>
      (_settings.tray.windowsTickerWidth ??
              (_settings.tray.tickerWidth.clamp(8, 40) * 9))
          .toDouble();

  double? _screenWidth; // 主屏逻辑宽(异步查询回填);供设置页宽度滑块上限=整屏宽

  // ---- 弹层高度随内容自适应(底锚向上生长,超工作区高才封顶滚动) ----
  double? _cachedVisibleH;
  double _lastPanelH = 0; // 上次 setSize 的高(防抖)
  int _heightSeq = 0; // 内容高度上报序号(丢弃乱序完成的过期上报)
  double _lastContentH = 0; // 最近一次上报的内容固有高(兜底重应用用)

  Future<double>? _capInFlight; // 并发去重:多次上报撞在一起时只发一个平台请求

  Future<double> _capHeight() {
    if (_cachedVisibleH != null) {
      final vh = _cachedVisibleH!;
      return Future<double>.value((vh - 60).clamp(300.0, vh));
    }
    return _capInFlight ??= () async {
      try {
        final d = await screenRetriever.getPrimaryDisplay();
        _cachedVisibleH = d.visibleSize?.height ?? d.size.height;
      } catch (_) {
        // 取不到就这次先用兜底值,不写缓存 → 下次还会再试
      } finally {
        _capInFlight = null;
      }
      final vh = _cachedVisibleH ?? 900.0;
      return (vh - 60).clamp(300.0, vh);
    }();
  }

  /// PopoverPage 上报内容固有高 → 窗口高 = clamp(h, 260, cap),仅列表视图生效、防抖。
  /// 切到设置页,并顺带重新定位一次窗口。
  ///
  /// 设置页不参与 [_onContentHeight](它不上报内容固有高),几何完全继承列表页留下的那份 ——
  /// 万一那份是错的,设置页自己没有任何纠正机会,只能等用户退回列表才恢复。
  /// 这里补一次定位,让它能自愈。
  Future<void> _gotoSettings() async {
    setState(() => _view = _View.settings);
    await _positionNearTray();
  }

  Future<void> _onContentHeight(double h) async {
    _lastContentH = h; // 记住最近一次上报,供显示面板时兜底重应用
    if (_view != _View.list) return;
    // 序号守卫:本方法是 async 的(要先拿工作区高),而内容高度会在短时间内上报**多次** ——
    // 图表从「加载中…」占位换成真图表、每个实例各换一轮。多个并发调用的 await 完成顺序
    // 不保证与上报顺序一致,一旦「占位那一次」最后落地,窗口就被钉死在矮尺寸上;
    // 而 MeasureSize 只在尺寸**变化**时才回调,此后内容高度稳定,再没有人来纠正它 ——
    // 表现就是「窗口一直矮、等多久都不长高,必须滚动才能看全」。
    final seq = ++_heightSeq;
    final cap = await _capHeight();
    if (seq != _heightSeq) return; // 已被更新的上报取代,这次作废
    final target = (h + 2).clamp(260.0, cap); // +2 余量防亚像素溢出误出滚动条
    if ((target - _lastPanelH).abs() < 2) return;
    _lastPanelH = target;
    await windowManager.setSize(Size(kPanelWidth, target));
    // **resize 之后必须无条件重新定位**,哪怕这一发已经被更新的上报取代。
    // 窗口是「底部贴托盘、向上生长」的,尺寸变了不重新定位,几何就错位
    // (表现:顶部那一行渲染不出来,但控件其实还在、点得到)。
    // 曾经想当然地交给抢占者去定位,但抢占者的目标高度若落在下面那个 <2 的防抖区间,
    // 它会在定位之前就 return —— 那次 setSize 就永远没有配套定位了。
    await _positionNearTray();
  }

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    windowManager.addListener(this);
    WidgetsBinding.instance.addObserver(this); // 跟随系统明暗(themeMode=system 时)
    WinTicker.onClick = () => _showPopover(fromTicker: true); // 左键点浮窗 → 以浮窗为锚点弹主面板
    WinTicker.onMoved = _onTickerMoved; // 拖拽结束 → 持久化位置
    WinTicker.onResized = _onTickerResized; // 拖拽边缘改宽结束 → 持久化新宽(+位置)
    Autostart.isEnabled().then((v) {
      if (mounted) setState(() => _autostartEnabled = v);
    });
    // 主屏逻辑宽:供设置页「宽度」滑块上限=整屏宽(异步回填,失败则设置页用兜底值)。
    screenRetriever.getPrimaryDisplay().then((d) {
      if (mounted) setState(() => _screenWidth = d.size.width);
    }).catchError((_) {});
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _initTray();
      _updateTicker(); // 启动即按设置建/隐浮窗(数据未到时显示占位)
      if (_settings.configured) {
        _startCore(_settings);
      } else {
        setState(() => _view = _View.settings);
        await _showPopover(); // 首次运行:弹出让用户填连接信息
      }
    });
  }

  @override
  void dispose() {
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  // 系统明暗变化(themeMode=system 时):重渲染浮窗 + 重套窗材质以跟随。
  @override
  void didChangePlatformBrightness() {
    _updateTicker();
    _applyWindowEffect();
  }

  // 窗口材质(acrylic)的明暗跟随 App 生效明暗:启动时 main 已套过一次,
  // 之后主题设置 / 系统明暗变化都要重套,否则浅色主题叠在深色 acrylic 上被压暗。
  Future<void> _applyWindowEffect() =>
      Window.setEffect(effect: WindowEffect.acrylic, dark: _effectiveDark());

  // ---------- 托盘 ----------

  Future<void> _initTray() async {
    await trayManager.setIcon('assets/tray_icon.ico'); // Windows 用 .ico
    await trayManager.setToolTip('quota-pulse 用量');    // Windows 无标题,用 tooltip
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'refresh', label: '刷新'),
      MenuItem.separator(),
      MenuItem(key: 'settings', label: '设置…'),
      MenuItem(key: 'quit', label: '退出 quota-pulse'),
    ]));
  }

  @override
  void onTrayIconMouseDown() async {
    if (await windowManager.isVisible()) {
      await _hidePopover();
    } else {
      await _showPopover();
    }
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'refresh':
        _controller?.refreshNow();
        break;
      case 'settings':
        setState(() => _view = _View.settings);
        await _showPopover();
        break;
      case 'quit':
        await _quit();
        break;
    }
  }

  // ---------- 窗口(弹层) ----------

  // fromTicker=true:点击悬浮窗唤起 → 以悬浮窗为锚点定位;否则(托盘图标唤起)贴托盘。
  Future<void> _showPopover({bool fromTicker = false}) async {
    _updateTicker(); // 顺带回拉原生实际宽,把可能被拖拽改过的宽度同步到配置/设置页滑块
    WinTicker.setPopoverOpen(true); // 面板弹出时把浮窗降到面板之下(仍压住其他程序)
    // 兜底:用最近一次上报的内容高度重新应用一次窗口高。
    // MeasureSize 只在尺寸**变化**时回调,所以万一某次 setSize 落错了(或被乱序覆盖),
    // 内容稳定之后就再没有人来纠正 —— 用户会永久看到一个矮窗口且无法自愈。
    // 这里每次显示都重算一遍,把「不可恢复」降级成「打开一次就好」。
    // 走 _onContentHeight 本身,自然领到新序号,与在途的上报正确排序。
    if (_lastContentH > 0) await _onContentHeight(_lastContentH);
    if (fromTicker) {
      await WinTicker.positionNearTicker(); // 以悬浮窗为锚点
    } else {
      await _positionNearTray(); // 以托盘图标为锚点
    }
    await windowManager.show();
    await windowManager.focus();
    _source.setForeground(true); // 喂给 Go poller 的调度信号(提高回源频率)
    _popoverVisible = true;
    _controller?.setVisible(true); // 喂给 UI 侧:恢复 2s 快照 + 允许图表查询
  }

  /// 把弹层贴到托盘图标正上方、水平居中(图标落在弹层下沿中点);
  /// 拿不到图标位置则回退到右下角。
  Future<void> _positionNearTray() async {
    try {
      final icon = await trayManager.getBounds();
      if (icon == null) {
        await windowManager.setAlignment(Alignment.bottomRight);
        return;
      }
      final size = await windowManager.getSize();
      var x = icon.center.dx - size.width / 2;
      var y = icon.top - size.height - 6; // 托盘上方留一点缝
      var top = 6.0;
      try {
        final d = await screenRetriever.getPrimaryDisplay();
        final maxX = d.size.width - size.width - 6;
        x = x.clamp(6.0, maxX > 6 ? maxX : 6.0).toDouble();
        top = (d.visiblePosition?.dy ?? 0) + 6; // 工作区顶(窗口变高时避免被顶出屏)
      } catch (_) {}
      if (y < top) y = top;
      await windowManager.setPosition(Offset(x, y));
    } catch (_) {
      await windowManager.setAlignment(Alignment.bottomRight);
    }
  }

  Future<void> _hidePopover() async {
    _source.setForeground(false);
    // 面板看不见了:快照降频到 10s,图表只读缓存、不再发起几秒的聚合。
    // 注意**不是停表** —— 托盘 tooltip / 跑马灯都挂在快照通知上,停了就不再更新。
    _popoverVisible = false;
    _controller?.setVisible(false);
    await windowManager.hide();
    WinTicker.setPopoverOpen(false); // 面板收起 → 浮窗恢复置顶
  }

  @override
  void onWindowBlur() {
    if (_debugOpen) return; // 调试面板是独立视图,失焦不收起
    _hidePopover(); // 点击弹层外即收起
  }

  // ---------- 核心生命周期 ----------

  void _startCore(Settings s) {
    try {
      _source.stop();
    } catch (_) {}
    try {
      _source.init(s.toConfigJson());
      _source.start();
      if (_controller == null) {
        _controller = PulseController(_source);
        _controller!.addListener(_onPulse);
      }
      // 核心被重建了:新引擎的图表版本号从 0 重新计数,会和旧缓存里的版本号撞车,
      // 不清就会永久命中过期缓存(改实例名同理 —— 它也走这条路径)。
      // 以壳的真实可见态为准,别依赖 controller 的默认值。
      // 必须在 startPolling() 之前:此时 _timer 还是 null,不会白重排一次定时器。
      _controller!.setVisible(_popoverVisible);
      _controller!.invalidateCharts();
      _controller!.startPolling();
      _applyDebug(); // 重启核心后按持久化配置重挂调试采样
      _error = null;
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() {});
  }

  // 调试:客户端读流量采样。开关/上限改动即持久化并调 FFI;开关或上限变化都以新配置重开采样。
  void _onDebugChanged(bool enabled, int maxSamples, int maxMemMB) {
    final s = _settings.copyWith(
      debugSampling: enabled,
      debugMaxSamples: maxSamples,
      debugMaxMemMB: maxMemMB,
    );
    SettingsStore.save(s);
    setState(() => _settings = s);
    _applyDebug();
  }

  void _applyDebug() {
    try {
      _source.debugSet(
        enabled: _settings.debugSampling,
        maxSamples: _settings.debugMaxSamples,
        maxMemBytes: _settings.debugMaxMemMB * 1024 * 1024,
      );
    } catch (_) {}
  }

  // 打开调试面板:放大窗口居中、标记独立视图(失焦不收起)。
  Future<void> _openDebug() async {
    setState(() {
      _debugOpen = true;
      _view = _View.debug;
    });
    WinTicker.setPopoverOpen(true);
    await windowManager.setSize(const Size(760, 560));
    await windowManager.setAlignment(Alignment.center);
    await windowManager.show();
    await windowManager.focus();
    _source.setForeground(true);
  }

  // 关闭调试面板:恢复弹层尺寸并贴回托盘附近,回到设置页。
  Future<void> _closeDebug() async {
    setState(() {
      _debugOpen = false;
      _view = _View.settings;
    });
    _lastPanelH = 0; // 回列表后重新按内容量高
    await windowManager.setSize(const Size(kPanelWidth, 600));
    await _positionNearTray();
  }

  void _updateTray() {
    // Windows:托盘 tooltip 按设置渲染(默认选中账户的 5h 剩余/重置;
    // 悬停延迟由系统控制,无法调)
    trayManager.setToolTip(
      renderTrayTooltip(
          _controller?.pulses ?? const [], _settings.tray, _settings.resetMode),
    );
  }

  // 浮窗明暗:跟随 app 的「主题」设置(system 时解析系统明暗),而非直接读系统。
  bool _effectiveDark() => effectiveDark(_settings.themeMode);

  // 悬浮窗口:内容与 macOS 菜单栏同源(同一选集 + 选中窗口用量/重置),状态走原生圆点。
  // 单行滚动用 segments;多行铺开用 lines(每账户 base + 各窗口一行)。两份都构造,
  // 原生按 multiline 选用哪份,切换模式无需重建数据。
  Future<void> _updateTicker() async {
    final tray = _settings.tray;
    final pulses = _controller?.pulses ?? const <AccountPulse>[];
    final segs = tickerSegments(pulses, tray, _settings.resetMode)
        .map((s) => <String, Object>{
              'color': s.color,
              'text': s.text,
              'newAccount': s.newAccount,
            })
        .toList();
    final lines = tickerLines(pulses, tray, _settings.resetMode)
        .map((l) => <String, Object>{
              'dot': l.dot,
              'color': l.color,
              'indent': l.indent,
              'text': l.text,
            })
        .toList();
    // 是否滚动完全交给原生按"放不放得下"判定(contentWidth > width):哪怕只有
    // 一个账户,只要单行超出可见宽也要滚,否则会一直只露出半截信息(同 macOS)。
    const scroll = true;
    // 空闲透明度%(0=关闭)→ 整窗 alpha(0-255):t=0 → 255(不透明=关闭),t 越大越透。
    // t 已夹到 [0,95],(255*(100-t)/100).round() 必落 [13,255],无需再夹。
    final t = tray.windowsTickerIdleTransparency.clamp(0, 95);
    final idleAlpha = (255 * (100 - t) / 100).round();
    final pushed = _scrollWidth.round();
    final nativeW = await WinTicker.update(
      segments: segs,
      lines: lines,
      multiline: tray.windowsTickerMultiline,
      enabled: tray.windowsTickerEnabled,
      scroll: scroll,
      pps: _scrollPps,
      width: _scrollWidth,
      dark: _effectiveDark(),
      hideOnFullscreen: tray.windowsTickerHideFullscreen,
      idleAlpha: idleAlpha,
      x: tray.windowsTickerX,
      y: tray.windowsTickerY,
    );
    // 原生回报的实际宽与我们推下去的不同 → 用户拖过浮窗边缘:采纳进配置并刷新设置页滑块。
    //
    // 注意:这条曾经是「可靠的那条」—— 因为 _onPulse 每 2 秒无条件跑一次,它等于一条定频兜底。
    // 快照脏检查之后 _updateTicker 只在快照真变时才跑(账号静止时可能很久一次),
    // 所以现在**主路径是 native→Dart 的 onResized 回调**(initState 里挂的 _onTickerResized,
    // drag-end 时直接触发),这里的返回值只是机会性采纳。改动这块时别再按旧注释判断。
    if (nativeW != null && nativeW != pushed) {
      _settings = _settings.copyWith(
          tray: _settings.tray.copyWith(windowsTickerWidth: nativeW));
      SettingsStore.save(_settings);
      if (mounted) setState(() {});
    }
  }

  void _onPulse() {
    _alerter.check(_controller?.pulses ?? const <AccountPulse>[], _settings);
    _updateTray();
    _updateTicker();
    if (mounted) setState(() {});
  }

  Future<void> _saveSettings(Settings s) async {
    // 仅当实例配置(toConfigJson)变化才重启核心,避免布局/主题/托盘改动触发全局刷新。
    final coreChanged = _settings.toConfigJson() != s.toConfigJson();
    await SettingsStore.save(s);
    setState(() => _settings = s);
    widget.onThemeModeChanged(s.themeMode.toThemeMode());
    _applyWindowEffect(); // 主题可能随保存/导入变化,窗材质同步
    if (coreChanged) {
      _startCore(s);
    }
    setState(() => _view = _View.list);
  }

  // 导入一份完整配置:走 _saveSettings(持久化 + 主题回传 + 按需重启核心 + 切回 list),
  // 再刷新托盘 tooltip 与浮窗以反映显示窗口/透明度/显示模式等非核心改动。
  Future<void> _onImportConfig(Settings s) async {
    await _saveSettings(s);
    _updateTray();
    _updateTicker();
  }

  void _onThemeChanged(ThemeChoice choice) {
    setState(() => _settings = _settings.copyWith(themeMode: choice));
    widget.onThemeModeChanged(choice.toThemeMode()); // 选中即时生效
    SettingsStore.save(_settings); // 顺手持久化,无需点保存
    _updateTicker(); // 浮窗即时跟随新主题
    _applyWindowEffect(); // 窗材质即时跟随
  }

  Future<void> _onAutostartChanged(bool enable) async {
    try {
      await Autostart.setEnabled(enable);
    } catch (_) {}
    final now = await Autostart.isEnabled(); // 以 OS 实际状态回填开关
    if (mounted) setState(() => _autostartEnabled = now);
  }

  // 布局 / 托盘:改动即时生效 + 持久化(无需"保存并连接")。
  void _onLayoutChanged(ListLayout layout) {
    setState(() => _settings = _settings.copyWith(layout: layout));
    SettingsStore.save(_settings);
  }

  void _onTrayChanged(TraySettings tray) {
    setState(() => _settings = _settings.copyWith(tray: tray));
    SettingsStore.save(_settings);
    _updateTray(); // 立刻按新设置重渲染托盘
    _updateTicker(); // 跑马灯开关/速度/宽度/全屏隐藏即时生效
  }

  // 浮窗拖拽后:持久化新位置(物理像素)。setState 让打开着的设置页拿到新 initial,
  // 避免设置页用旧位置(其 _tray() 从 initial 透传 X/Y)把刚拖好的位置覆盖回去。
  void _onTickerMoved(int x, int y) {
    _settings = _settings.copyWith(
        tray: _settings.tray.copyWith(windowsTickerX: x, windowsTickerY: y));
    SettingsStore.save(_settings);
    if (mounted) setState(() {});
  }

  // 拖拽浮窗边缘改宽结束:持久化新宽(逻辑像素)+ 新位置(左边缘拖会同时移动浮窗)。
  // ① setState → 打开着的设置页据新 initial 重建,didUpdateWidget 把宽度滑块同步过去,
  //   否则设置页仍持旧宽,下次 _emitTray 会把拖出来的宽度覆盖回去;
  // ② 立刻 _updateTicker 按新宽重推一次 —— Apply 每个 tick 都用 width 参数重置 width_,
  //   不重推的话下一拍(轮询/前台)就会用旧宽把浮窗弹回原状。
  void _onTickerResized(int w, int x, int y) {
    _settings = _settings.copyWith(
        tray: _settings.tray.copyWith(
            windowsTickerWidth: w, windowsTickerX: x, windowsTickerY: y));
    SettingsStore.save(_settings);
    if (mounted) setState(() {});
    _updateTicker();
  }

  // 设置页「重置位置」:原生移回默认位置(其 onMoved 回调会顺带持久化新坐标)。
  void _onResetTickerPosition() => WinTicker.resetPosition();

  // 重置显示(倒计时/绝对):主页随 setState 重建,托盘 tooltip 即时重渲染。
  void _onResetModeChanged(ResetMode mode) {
    setState(() => _settings = _settings.copyWith(resetMode: mode));
    SettingsStore.save(_settings);
    _updateTray();
    _updateTicker();
  }

  // 用量提醒(总开关/阈值/各类监听窗口):即时持久化;下一次快照检测即按新设置生效。
  void _onAlertChanged(
      bool enabled, int threshold, Set<String> over, Set<String> recover) {
    setState(() => _settings = _settings.copyWith(
          alertEnabled: enabled,
          alertThreshold: threshold,
          alertOverWindows: over,
          alertRecoverWindows: recover,
        ));
    SettingsStore.save(_settings);
    // 快照脏检查之后 _onPulse 只在快照**真变**时才跑,而 _alerter.check 是唯一的告警入口。
    // 不在这里立刻按当前快照重判一次的话:改阈值/改监听窗口要等到下一次快照变化才生效,
    // 而且刚开启告警时,那一拍会被 alerter 当成 seed 静默吞掉 —— 真告警直接丢失。
    _alerter.check(_controller?.pulses ?? const <AccountPulse>[], _settings);
  }

  // 后台拉取节奏改动:持久化并重启核心(poll 配置进 toConfigJson,只能重新 init 生效)。
  void _onPollChanged(int passiveSecs, bool activeEnabled, int activeSecs) {
    final s = _settings.copyWith(
      pollPassiveSecs: passiveSecs,
      pollActiveEnabled: activeEnabled,
      pollActiveSecs: activeSecs,
    );
    SettingsStore.save(s);
    setState(() => _settings = s);
    if (s.configured) _startCore(s); // 已配置才有核心可重启
  }

  // 设置页:图表开关。仅它进 toConfigJson,变化才重启核心(跨度/维度/样式纯 UI)。
  void _onChartChanged(bool enabled) {
    final enabledChanged = enabled != _settings.chartEnabled;
    final s = _settings.copyWith(chartEnabled: enabled);
    SettingsStore.save(s);
    setState(() => _settings = s);
    if (enabledChanged && s.configured) _startCore(s);
  }

  // 实例启用/禁用即时生效:持久化 + 仅当核心配置变化时重启(不导航,留在设置页)。
  // 不卡 configured 门槛 —— 禁用最后一个实例时也要重启成空 providers,真正停掉其轮询。
  void _onInstancesChanged(Settings s) {
    final coreChanged = _settings.toConfigJson() != s.toConfigJson();
    SettingsStore.save(s);
    setState(() => _settings = s);
    if (coreChanged) _startCore(s);
    _updateTray(); // 账户集变了,刷新托盘
    _updateTicker(); // 同步桌面悬浮窗口
  }

  // 主面板视图控件:维度 + 样式(柱/线/热力图)+ 跨度 + 度量 + 热力图年份/值。
  // 纯 UI,持久化 + 重渲染,不重启核心(这些字段不进 toConfigJson)。
  void _onChartViewChanged(ChartView v) {
    final s = _settings.withChartView(v);
    SettingsStore.save(s);
    setState(() => _settings = s);
  }

  Future<void> _quit() async {
    try {
      _source.stop();
    } catch (_) {}
    try {
      _source.shutdown(); // 停掉图表查询用的后台 isolate
    } catch (_) {}
    await trayManager.destroy();
    exit(0);
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent, // 透出毛玻璃,卡片自绘圆角
      body: GlassCard(child: _content()),
    );
  }

  Widget _content() {
    if (_view == _View.debug) {
      return DebugPanel(
        enabled: _settings.debugSampling,
        maxSamples: _settings.debugMaxSamples,
        maxMemMB: _settings.debugMaxMemMB,
        onChanged: _onDebugChanged,
        fetchReport: () => _source.debugReportJson(),
        onReset: () => _source.debugReset(),
        onClose: _closeDebug,
      );
    }
    if (_view == _View.settings || !_settings.configured) {
      return SettingsPage(
        initial: _settings,
        accounts: _controller?.pulses ?? const [],
        onSave: _saveSettings,
        onThemeChanged: _onThemeChanged,
        onLayoutChanged: _onLayoutChanged,
        onTrayChanged: _onTrayChanged,
        onResetModeChanged: _onResetModeChanged,
        onAlertChanged: _onAlertChanged,
        onPollChanged: _onPollChanged,
        onChartChanged: _onChartChanged,
        onTestNotification: () => _alerter.testNotification(),
        onResetTickerPosition: _onResetTickerPosition,
        tickerMaxWidth: _screenWidth, // 宽度滑块上限=整屏宽(null 时设置页用兜底)
        onImport: _onImportConfig,
        onInstancesChanged: _onInstancesChanged,
        autostartEnabled: _autostartEnabled,
        onAutostartChanged: _onAutostartChanged,
        debugSampling: _settings.debugSampling,
        debugMaxSamples: _settings.debugMaxSamples,
        debugMaxMemMB: _settings.debugMaxMemMB,
        onDebugChanged: _onDebugChanged,
        onOpenDebug: _openDebug,
        onCancel: _settings.configured ? () => setState(() => _view = _View.list) : null,
      );
    }
    if (_controller == null) {
      return _errorView(_error ?? '核心未启动');
    }
    return PopoverPage(
      controller: _controller!,
      layout: _settings.layout,
      resetMode: _settings.resetMode,
      // 单击主页「重置时间」→ 翻转全局 resetMode(等同设置里的开关,持久化 + 托盘同步)。
      onToggleResetMode: () => _onResetModeChanged(
          _settings.resetMode == ResetMode.absolute
              ? ResetMode.countdown
              : ResetMode.absolute),
      instanceUrls: _settings.instanceUrls(),
      chartEnabled: _settings.chartEnabled,
      chartRange: _settings.chartRange,
      chartType: _settings.chartType,
      chartGroupBy: _settings.chartGroupBy,
      chartMetric: _settings.chartMetric,
      chartHeatmapYear: _settings.chartHeatmapYear,
      chartHeatmapValue: _settings.chartHeatmapValue,
      onChartViewChanged: _onChartViewChanged,
      onContentHeight: _onContentHeight,
      onRefresh: () => _controller?.refreshNow(),
      onSettings: _gotoSettings,
    );
  }

  Widget _errorView(String msg) => Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(msg, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: Color(0xFFFF3B30))),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _gotoSettings,
                child: const Text('去设置'),
              ),
            ],
          ),
        ),
      );
}
