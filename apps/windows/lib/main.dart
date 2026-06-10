import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

// 共享层:模型 / UI / 状态 / 桥接全部来自 ui 包(与 macOS 同一份)
import 'package:quota_pulse_ui/quota_pulse_ui.dart';

// ── Windows 与 macOS 壳的差异(其余逻辑共用 ui 包) ──
//   · 托盘图标用彩色 .ico(非 macOS 模板图);
//   · Windows 托盘无标题文字 → 峰值走 setToolTip(而非 setTitle);
//   · 托盘在右下角 → 弹层贴 bottomRight(macOS 是 topRight);
//   · 无 LSUIElement/Dock 概念 → 用 skipTaskbar 隐藏任务栏按钮。

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  final windowOptions = WindowOptions(
    size: const Size(340, 460),
    skipTaskbar: true,
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
    alwaysOnTop: true,
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setAsFrameless();
    await windowManager.setSkipTaskbar(true);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.hide(); // 托盘应用:启动即隐藏,点托盘才弹出
  });

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
  _View _view = _View.list;
  String? _error;

  PulseSource get _source => widget.source;

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    windowManager.addListener(this);
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
    await windowManager.setAlignment(Alignment.bottomRight); // 托盘在右下
    await windowManager.show();
    await windowManager.focus();
    _source.setForeground(true);
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

  void _onPulse() {
    // Windows:托盘 tooltip 显示尽量全的多行汇总(悬停延迟由系统控制,无法调)
    trayManager.setToolTip(renderTrayTooltip(_controller?.pulses ?? const []));
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
    // Windows 暂用不透明窗口(毛玻璃待定:flutter_acrylic 会挂 Windows 构建)
    return Scaffold(body: _content());
  }

  Widget _content() {
    if (_view == _View.settings || !_settings.configured) {
      return SettingsPage(
        initial: _settings,
        accounts: _controller?.pulses ?? const [],
        onSave: _saveSettings,
        onCancel: _settings.configured ? () => setState(() => _view = _View.list) : null,
      );
    }
    if (_controller == null) {
      return _errorView(_error ?? '核心未启动');
    }
    return PopoverPage(
      controller: _controller!,
      layout: _settings.layout,
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
