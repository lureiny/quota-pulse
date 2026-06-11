import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

// 共享层:模型 / UI / 状态 / 桥接全部来自 ui 包(与 macOS 同一份)
import 'package:quota_pulse_ui/quota_pulse_ui.dart';

import 'autostart.dart'; // 开机自启动(Windows:注册表 Run 项)

// ── Windows 与 macOS 壳的差异(其余逻辑共用 ui 包) ──
//   · 托盘图标用彩色 .ico(非 macOS 模板图);
//   · Windows 托盘无标题文字 → 峰值走 setToolTip(而非 setTitle);
//   · 托盘在右下角 → 弹层贴 bottomRight(macOS 是 topRight);
//   · 无 LSUIElement/Dock 概念 → 用 skipTaskbar 隐藏任务栏按钮。

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await Window.initialize(); // flutter_acrylic

  final windowOptions = WindowOptions(
    size: const Size(340, 460),
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

  // 毛玻璃:Windows 用 acrylic(Win10+;降级可改 WindowEffect.solid)
  final isDark =
      WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
  await Window.setEffect(effect: WindowEffect.acrylic, dark: isDark);
  // flutter_acrylic 在 Windows 上套 acrylic 后会把标题栏(连带最小化/最大化/关闭三个按钮)加回来。
  // 注:flutter_acrylic 的隐藏按钮 API 仅 macOS 有效;window_manager 的 setTitleBarStyle 在
  // setAsFrameless 之后又会失效(已知问题)。故套完效果后:再断言无边框 + 直接剥掉
  // 最小化/最大化/关闭三个窗口样式位(WS_MINIMIZEBOX/WS_MAXIMIZEBOX/WS_SYSMENU),多管齐下。
  await windowManager.setAsFrameless();
  await windowManager.setMinimizable(false);
  await windowManager.setMaximizable(false);
  await windowManager.setClosable(false);
  await UsageAlerter.setup(); // 通知后端初始化(一次;Windows 会建快捷方式挂 AppUserModelID)

  final settings = await SettingsStore.load();
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

enum _View { list, settings }

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

class _ShellState extends State<Shell> with TrayListener, WindowListener {
  late Settings _settings = widget.initialSettings;
  PulseController? _controller;
  final _alerter = UsageAlerter(); // 用量阈值提醒
  _View _view = _View.list;
  String? _error;
  bool _autostartEnabled = false; // 开机自启动:真值以 OS 为准,启动时查询

  PulseSource get _source => widget.source;

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    windowManager.addListener(this);
    Autostart.isEnabled().then((v) {
      if (mounted) setState(() => _autostartEnabled = v);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _initTray();
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
    _controller?.dispose();
    super.dispose();
  }

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

  Future<void> _showPopover() async {
    await _positionNearTray();
    await windowManager.show();
    await windowManager.focus();
    _source.setForeground(true);
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
      try {
        final d = await screenRetriever.getPrimaryDisplay();
        final maxX = d.size.width - size.width - 6;
        x = x.clamp(6.0, maxX > 6 ? maxX : 6.0).toDouble();
      } catch (_) {}
      if (y < 6) y = 6.0;
      await windowManager.setPosition(Offset(x, y));
    } catch (_) {
      await windowManager.setAlignment(Alignment.bottomRight);
    }
  }

  Future<void> _hidePopover() async {
    _source.setForeground(false);
    await windowManager.hide();
  }

  @override
  void onWindowBlur() {
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
      _controller!.startPolling();
      _error = null;
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() {});
  }

  void _updateTray() {
    // Windows:托盘 tooltip 按设置渲染(默认选中账户的 5h 剩余/重置;
    // 悬停延迟由系统控制,无法调)
    trayManager.setToolTip(
      renderTrayTooltip(
          _controller?.pulses ?? const [], _settings.tray, _settings.resetMode),
    );
  }

  void _onPulse() {
    _alerter.check(_controller?.pulses ?? const <AccountPulse>[], _settings);
    _updateTray();
    if (mounted) setState(() {});
  }

  Future<void> _saveSettings(Settings s) async {
    // 仅当实例配置(toConfigJson)变化才重启核心,避免布局/主题/托盘改动触发全局刷新。
    final coreChanged = _settings.toConfigJson() != s.toConfigJson();
    await SettingsStore.save(s);
    setState(() => _settings = s);
    widget.onThemeModeChanged(s.themeMode.toThemeMode());
    if (coreChanged) {
      _startCore(s);
    }
    setState(() => _view = _View.list);
  }

  void _onThemeChanged(ThemeChoice choice) {
    setState(() => _settings = _settings.copyWith(themeMode: choice));
    widget.onThemeModeChanged(choice.toThemeMode()); // 选中即时生效
    SettingsStore.save(_settings); // 顺手持久化,无需点保存
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
  }

  // 重置显示(倒计时/绝对):主页随 setState 重建,托盘 tooltip 即时重渲染。
  void _onResetModeChanged(ResetMode mode) {
    setState(() => _settings = _settings.copyWith(resetMode: mode));
    SettingsStore.save(_settings);
    _updateTray();
  }

  // 用量提醒(开关/阈值):即时持久化;下一次快照检测即按新设置生效。
  void _onAlertChanged(bool enabled, int threshold) {
    setState(() => _settings =
        _settings.copyWith(alertEnabled: enabled, alertThreshold: threshold));
    SettingsStore.save(_settings);
  }

  Future<void> _quit() async {
    try {
      _source.stop();
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
        onTestNotification: () => _alerter.testNotification(),
        autostartEnabled: _autostartEnabled,
        onAutostartChanged: _onAutostartChanged,
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
      instanceUrls: _settings.instanceUrls(),
      onRefresh: () => _controller?.refreshNow(),
      onSettings: () => setState(() => _view = _View.settings),
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
                onPressed: () => setState(() => _view = _View.settings),
                child: const Text('去设置'),
              ),
            ],
          ),
        ),
      );
}
