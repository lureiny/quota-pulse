import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

// 共享层:模型 / UI / 状态 / 桥接全部来自 ui 包
import 'package:quota_pulse_ui/quota_pulse_ui.dart';

import 'autostart.dart'; // 开机自启动(macOS:LaunchAgent)

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
    await windowManager.hide(); // 菜单栏应用:启动即隐藏,点托盘才弹出
  });

  // 毛玻璃:macOS 用 popover 弹层材质(降级可改 WindowEffect.solid)
  final isDark =
      WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
  await Window.setEffect(effect: WindowEffect.popover, dark: isDark);

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

class _ShellState extends State<Shell>
    with TrayListener, WindowListener, SingleTickerProviderStateMixin {
  late Settings _settings = widget.initialSettings;
  PulseController? _controller;
  _View _view = _View.list;
  String? _error;
  bool _autostartEnabled = false; // 开机自启动:真值以 OS 为准,启动时查询

  // 弹层"从菜单栏放大出现"的入场动画。
  late final AnimationController _popAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 190),
  );

  // 「全部账户」模式:把所有账户拼成一行,在菜单栏里循环横向滚动(类似流水屏)。
  Timer? _tickerTimer;
  List<int> _tickerRunes = const []; // 整条文本的码点
  int _tickerPos = 0;
  static const int _tickerWindow = 18; // 菜单栏可见字符数(窗口宽)
  static const String _tickerGap = '      '; // 一圈结束到重新开始的空隙

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
    _tickerTimer?.cancel();
    _popAnim.dispose();
    _controller?.dispose();
    super.dispose();
  }

  // ---------- 托盘 ----------

  Future<void> _initTray() async {
    await trayManager.setIcon('assets/tray_icon.png', isTemplate: true);
    await trayManager.setTitle('用量');
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
    await _positionUnderTray();
    // 关键:显示前先把动画归零(内容缩到起始态),否则窗口会先以上次的满屏态出现、
    // forward 再把它缩回 0.92 又放大 → 看着像"弹两次"。再等一帧确保以起始态画好后再显示。
    _popAnim.value = 0;
    await WidgetsBinding.instance.endOfFrame;
    await windowManager.show();
    await windowManager.focus();
    _source.setForeground(true);
    _popAnim.forward(); // 从 0 平滑放大到 1
  }

  /// 把弹层贴到菜单栏图标正下方、水平居中(图标落在弹层上沿中点);
  /// 拿不到图标位置则回退到右上角。
  Future<void> _positionUnderTray() async {
    try {
      final icon = await trayManager.getBounds();
      if (icon == null) {
        await windowManager.setAlignment(Alignment.topRight);
        return;
      }
      final size = await windowManager.getSize();
      var x = icon.center.dx - size.width / 2;
      final y = icon.bottom + 6; // 菜单栏下方留一点缝
      try {
        final d = await screenRetriever.getPrimaryDisplay();
        final maxX = d.size.width - size.width - 6;
        x = x.clamp(6.0, maxX > 6 ? maxX : 6.0).toDouble(); // 别越出屏幕右沿
      } catch (_) {}
      await windowManager.setPosition(Offset(x, y));
    } catch (_) {
      await windowManager.setAlignment(Alignment.topRight);
    }
  }

  Future<void> _hidePopover() async {
    _source.setForeground(false);
    await windowManager.hide();
  }

  @override
  void onWindowBlur() {
    // 点击弹层外即收起(popover 行为)
    _hidePopover();
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
    // macOS 菜单栏单行。「全部账户」→ 拼成一整行做流水屏滚动;否则按模式静态渲染。
    final pulses = _controller?.pulses ?? const <AccountPulse>[];
    if (_settings.tray.mode == TrayMode.allAccounts && pulses.isNotEmpty) {
      final full = sortedByAccount(pulses).map(renderTrayAccountLine).join('   ·   ');
      _tickerRunes = full.runes.toList();
      _renderTicker();
      _syncTicker(_tickerRunes.length > _tickerWindow); // 放得下就不必滚
    } else {
      _syncTicker(false);
      trayManager.setTitle(renderTrayText(pulses, _settings.tray));
    }
  }

  // 始终输出固定 _tickerWindow 个字符(窗口宽不随内容变);从当前位置起取一段环形文本。
  void _renderTicker() {
    if (_tickerRunes.isEmpty) {
      trayManager.setTitle('');
      return;
    }
    var loop = [..._tickerRunes, ..._tickerGap.runes];
    // 一圈比窗口还短 → 用空格补齐,避免同一内容在窗口里立刻重复出现。
    if (loop.length < _tickerWindow) {
      loop = [...loop, ...List<int>.filled(_tickerWindow - loop.length, 0x20)];
    }
    final n = loop.length;
    final out = List<int>.generate(_tickerWindow, (k) => loop[(_tickerPos + k) % n]);
    trayManager.setTitle(String.fromCharCodes(out));
  }

  // 「全部账户」且放不下 → 高频小步前移(更丝滑);否则停表、固定宽静态显示。
  void _syncTicker(bool active) {
    if (active && _tickerTimer == null) {
      // 间隔越小越顺、但滚得也越快(一步=一个字符,二者绑死)。70ms ≈ 14 字/秒。
      _tickerTimer = Timer.periodic(const Duration(milliseconds: 70), (_) {
        _tickerPos++;
        _renderTicker();
      });
    } else if (!active && _tickerTimer != null) {
      _tickerTimer!.cancel();
      _tickerTimer = null;
      _tickerPos = 0;
      _renderTicker(); // 停下时也按固定宽渲染一次
    }
  }

  void _onPulse() {
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
      body: AnimatedBuilder(
        animation: _popAnim,
        builder: (context, child) {
          // 只做缩放、不淡入:否则毛玻璃材质先满屏出现、内容再淡入,看着像"弹两次"。
          final t = Curves.easeOutCubic.transform(_popAnim.value);
          return Transform.scale(
            scale: 0.92 + 0.08 * t,
            alignment: Alignment.topCenter, // 从上沿(菜单栏处)展开
            child: child,
          );
        },
        child: GlassCard(child: _content()),
      ),
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
