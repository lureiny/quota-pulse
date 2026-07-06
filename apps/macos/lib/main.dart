import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

// 共享层:模型 / UI / 状态 / 桥接全部来自 ui 包
import 'package:quota_pulse_ui/quota_pulse_ui.dart';

import 'autostart.dart'; // 开机自启动(macOS:LaunchAgent)
import 'menu_bar.dart'; // 自定义菜单栏状态项(替代 tray_manager,支持丝滑滚动)

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
    await windowManager.hide(); // 菜单栏应用:启动即隐藏,点图标才弹出
  });

  // 毛玻璃:macOS 用 popover 弹层材质(降级可改 WindowEffect.solid)
  final isDark =
      WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
  await Window.setEffect(effect: WindowEffect.popover, dark: isDark);
  await UsageAlerter.setup(); // 通知后端初始化(一次)

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
      theme: buildAppTheme(seed: widget.seed, brightness: Brightness.light),
      darkTheme: buildAppTheme(seed: widget.seed, brightness: Brightness.dark),
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

class _ShellState extends State<Shell> with WindowListener {
  late Settings _settings = widget.initialSettings;
  PulseController? _controller;
  final _alerter = UsageAlerter(); // 用量阈值提醒
  _View _view = _View.list;
  String? _error;
  bool _autostartEnabled = false; // 开机自启动:真值以 OS 为准,启动时查询
  bool _debugOpen = false; // 调试面板打开时:窗口放大 + 失焦不自动收起

  // 菜单栏滚动参数由设置映射(macOS 专属、可在设置页实时调):
  //   速度 tickerMs(ms/字,20-1000)→ pps(点/秒);宽度 tickerWidth(字,8-40)→ 点。
  double get _scrollPps => 8000.0 / _settings.tray.tickerMs.clamp(20, 1000);
  double get _scrollWidth => _settings.tray.tickerWidth.clamp(8, 40) * 9.0;

  PulseSource get _source => widget.source;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    Autostart.isEnabled().then((v) {
      if (mounted) setState(() => _autostartEnabled = v);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _initMenuBar();
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
    windowManager.removeListener(this);
    _controller?.dispose();
    super.dispose();
  }

  // ---------- 菜单栏(自定义状态项) ----------

  Future<void> _initMenuBar() async {
    MacMenuBar.onClick = _toggle;
    MacMenuBar.onMenu = _onMenu;
    final icon = (await rootBundle.load('assets/tray_icon.png')).buffer.asUint8List();
    final menu = <Map<String, dynamic>>[
      {'key': 'refresh', 'label': '刷新'},
      {'separator': true},
      {'key': 'settings', 'label': '设置…'},
      {'key': 'quit', 'label': '退出 quota-pulse'},
    ];
    // 通道偶发未就绪 → 重试几次,直到原生把状态项建出来。
    for (var i = 0; i < 20; i++) {
      try {
        await MacMenuBar.setup(icon: icon, menu: menu);
        _updateTray();
        return;
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 150));
      }
    }
  }

  Future<void> _toggle() async {
    if (await windowManager.isVisible()) {
      await _hidePopover();
    } else {
      await _showPopover();
    }
  }

  Future<void> _onMenu(String key) async {
    switch (key) {
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
    await _positionUnderTray();
    await windowManager.show();
    await windowManager.focus();
    _source.setForeground(true);
  }

  /// 贴到菜单栏图标正下方、水平居中(图标落在弹层上沿中点);拿不到位置则回退右上角。
  Future<void> _positionUnderTray() async {
    try {
      final icon = await MacMenuBar.getFrame();
      if (icon == null) {
        await windowManager.setAlignment(Alignment.topRight);
        return;
      }
      const w = 340.0; // = WindowOptions.size.width
      var x = icon.center.dx - w / 2;
      final y = icon.bottom + 6;
      final sw = await _screenWidth();
      if (sw != null) {
        final maxX = sw - w - 6;
        x = x.clamp(6.0, maxX > 6 ? maxX : 6.0).toDouble();
      }
      await windowManager.setPosition(Offset(x, y));
    } catch (_) {
      await windowManager.setAlignment(Alignment.topRight);
    }
  }

  double? _cachedScreenW;
  Future<double?> _screenWidth() async {
    if (_cachedScreenW != null) return _cachedScreenW;
    try {
      _cachedScreenW = (await screenRetriever.getPrimaryDisplay()).size.width;
    } catch (_) {}
    return _cachedScreenW;
  }

  Future<void> _hidePopover() async {
    _source.setForeground(false);
    await windowManager.hide();
  }

  @override
  void onWindowBlur() {
    if (_debugOpen) return; // 调试面板是独立视图,失焦不收起
    _hidePopover(); // 点击弹层外即收起(popover 行为)
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
      _applyDebug(); // 重启核心后按持久化配置重挂调试采样
      _error = null;
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() {});
  }

  // 菜单栏内容:全部账户 → 拼一行交给原生做流水屏滚动;否则静态显示。
  // 滚不滚由原生按"放不放得下"决定;速度/宽度来自设置(实时)。
  void _updateTray() {
    final pulses = _controller?.pulses ?? const <AccountPulse>[];
    final tray = _settings.tray;
    final rm = _settings.resetMode;
    // 全部账户 / 指定账户(多选)统一取展示集合,拼成一行交给原生。
    final accounts = trayAccounts(pulses, tray);
    final windows = displayWindowIds(tray); // 按设置显示 5h / 7d(可多选)
    final text = accounts.isEmpty
        ? 'quota-pulse'
        : accounts
            .map((a) => renderTrayAccountLine(a,
                metric: tray.metric, resetMode: rm, windows: windows))
            .join('   ·   ');
    // 是否滚动完全交给原生按"放不放得下"判定(contentWidth > width):哪怕只有
    // 一个账户,只要单行超出可见宽也要滚,否则会一直只露出半截信息。
    const scroll = true;
    MacMenuBar.setTicker(text, scroll: scroll, pps: _scrollPps, width: _scrollWidth);
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

  // 导入一份完整配置:走 _saveSettings(持久化 + 主题回传 + 按需重启核心 + 切回 list),
  // 再刷新菜单栏文案以反映显示窗口/重置显示等非核心改动。
  Future<void> _onImportConfig(Settings s) async {
    await _saveSettings(s);
    _updateTray();
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
    _updateTray(); // 即时把新文字/速度/宽度发给原生菜单栏
  }

  // 重置显示(倒计时/绝对):主页随 setState 重建,托盘/菜单栏即时重渲染。
  void _onResetModeChanged(ResetMode mode) {
    setState(() => _settings = _settings.copyWith(resetMode: mode));
    SettingsStore.save(_settings);
    _updateTray();
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
    _updateTray(); // 账户集变了,刷新菜单栏
  }

  // 主面板视图控件:时间跨度 + 分组维度 + 柱/线 + 度量。纯 UI,持久化 + 重渲染,不重启核心。
  void _onChartViewChanged(ChartGroupBy groupBy, ChartType type,
      ChartRange range, ChartMetric metric) {
    final s = _settings.copyWith(
        chartGroupBy: groupBy,
        chartType: type,
        chartRange: range,
        chartMetric: metric);
    SettingsStore.save(s);
    setState(() => _settings = s);
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

  // 把当前调试采样配置下发到核心(壳持久化的开关/上限 → FFI)。
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
    await windowManager.setSize(const Size(760, 560));
    await windowManager.setAlignment(Alignment.center);
    await windowManager.show();
    await windowManager.focus();
    _source.setForeground(true);
  }

  // 关闭调试面板:恢复弹层尺寸并贴回菜单栏下方,回到设置页。
  Future<void> _closeDebug() async {
    setState(() {
      _debugOpen = false;
      _view = _View.settings;
    });
    await windowManager.setSize(const Size(340, 460));
    await _positionUnderTray();
  }

  Future<void> _quit() async {
    try {
      _source.stop();
    } catch (_) {}
    await MacMenuBar.destroy();
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
      onChartViewChanged: _onChartViewChanged,
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
