import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/pulse.dart';
import '../state/config_io.dart';
import '../state/settings_store.dart';
import '../version.dart';

// 后台拉取间隔的下拉预设(秒):被动刷新 / 自动回源。
const List<int> _kPassivePresets = [30, 60, 120, 300];
const List<int> _kActivePresets = [300, 600, 1800, 3600];

/// SettingsPage:管理多个 sub2api 实例 + 列表布局 + 托盘内容。
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.initial,
    required this.accounts, // 当前快照,供「钉住账户」下拉
    required this.onSave, // 仅 sub2api 实例:保存并重连核心
    this.onCancel,
    this.onThemeChanged, // 以下都是改动即时生效(不必保存)
    this.onLayoutChanged,
    this.onTrayChanged,
    this.onResetModeChanged,
    this.onAlertChanged,
    this.onPollChanged, // 后台拉取节奏(改后重启核心生效)
    this.onChartChanged, // 小时图表开关 / 跨度(改后重启核心生效)
    this.onTestNotification,
    this.onResetTickerPosition, // Windows 悬浮窗口「重置位置」
    this.tickerMaxWidth, // Windows 滚动浮窗「宽度」滑块上限(=主屏逻辑宽;null 用兜底)
    this.onImport, // 导入一份完整配置:壳持久化 + 重启核心 + 刷新托盘/浮窗
    this.autostartEnabled = false, // 开机自启动当前状态(由壳查询 OS 得到)
    this.onAutostartChanged,
  });

  final Settings initial;
  final List<AccountPulse> accounts;
  final void Function(Settings) onSave;
  final VoidCallback? onCancel;
  final void Function(ThemeChoice)? onThemeChanged;
  final void Function(ListLayout)? onLayoutChanged;
  final void Function(TraySettings)? onTrayChanged;
  final void Function(ResetMode)? onResetModeChanged; // 重置显示:主页+托盘同时生效
  // 用量提醒:总开关 + 阈值 + 超阈值监听窗口 + 恢复监听窗口
  final void Function(
    bool enabled,
    int threshold,
    Set<String> overWindows,
    Set<String> recoverWindows,
  )? onAlertChanged;
  // 后台拉取:被动刷新间隔(秒) + 自动回源开关 + 自动回源间隔(秒)。改后壳重启核心生效。
  final void Function(
    int passiveSecs,
    bool activeEnabled,
    int activeSecs,
  )? onPollChanged;
  // 小时用量图表:开关 + 跨度。改后壳持久化并重启核心(影响 core 是否取 trend / 取多宽)。
  final void Function(bool enabled, ChartRange range)? onChartChanged;
  final Future<void> Function()? onTestNotification; // 发送测试通知
  final VoidCallback? onResetTickerPosition; // Windows 跑马灯重置到默认位置
  final double? tickerMaxWidth; // Windows 滚动浮窗宽度滑块上限(主屏逻辑宽)
  final void Function(Settings)? onImport; // 导入配置(跨平台)
  final bool autostartEnabled;
  final void Function(bool)? onAutostartChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

/// 单个实例的可编辑草稿(持有控制器)。
class _Draft {
  final String id;
  final TextEditingController name;
  final TextEditingController url;
  final TextEditingController key;
  bool obscure;

  _Draft(this.id, {String name = '', String url = '', String key = ''})
      : name = TextEditingController(text: name),
        url = TextEditingController(text: url),
        key = TextEditingController(text: key),
        obscure = true;

  void dispose() {
    name.dispose();
    url.dispose();
    key.dispose();
  }

  Sub2apiInstance toInstance() => Sub2apiInstance(
        id: id,
        name: name.text.trim(),
        baseUrl: url.text.trim(),
        apiKey: key.text.trim(),
      );
}

class _SettingsPageState extends State<SettingsPage> {
  late List<_Draft> _drafts;
  late ListLayout _layout;
  late ThemeChoice _theme;
  late TrayMode _trayMode;
  late Set<String> _pinnedKeys; // 指定账户(可多选)
  late int _tickerMs; // 滚动速度(ms):macOS 菜单栏 + Windows 跑马灯共用
  late int _tickerWidth; // 滚动窗口宽(字符):仅 macOS 菜单栏
  late int _windowsTickerWidth; // Windows 滚动浮窗宽(逻辑像素;可拖拽/滑块到整屏宽)
  late bool _windowsTickerEnabled; // Windows 悬浮窗口开关
  late bool _windowsTickerMultiline; // Windows 悬浮窗口显示模式:false=滚动,true=多行
  late bool _windowsTickerHideFullscreen; // Windows 跑马灯全屏时隐藏
  late int _windowsTickerIdleTransparency; // Windows 浮窗空闲透明度%(0=关闭)
  late TrayMetric _metric; // 托盘显示量:使用量/剩余量
  late Set<String> _displayWindows; // 显示窗口(5h/7d,可多选;跨平台)
  late ResetMode _resetMode; // 重置显示:倒计时/绝对
  late bool _alertEnabled; // 用量提醒总开关
  late int _alertThreshold; // 用量提醒阈值(%)
  late Set<String> _alertOverWindows; // 超阈值监听窗口
  late Set<String> _alertRecoverWindows; // 额度恢复监听窗口
  late int _pollPassiveSecs; // 被动刷新间隔(秒)
  late bool _pollActiveEnabled; // 自动强制回源开关
  late int _pollActiveSecs; // 自动回源间隔(秒)
  late bool _chartEnabled; // 小时用量图表开关
  late ChartRange _chartRange; // 小时用量图表跨度
  int _idSeq = 0;

  // Windows 滚动浮窗「宽度」滑块上限:主屏逻辑宽(壳传入),缺省兜底 1920,下限保底 240
  // 防滑块退化。原生侧还会把宽度硬夹到整屏宽。
  double get _winWidthSliderMax =>
      ((widget.tickerMaxWidth ?? 1920.0).clamp(240.0, 100000.0)).toDouble();

  @override
  void initState() {
    super.initState();
    _drafts = widget.initial.instances
        .map((i) => _Draft(i.id, name: i.name, url: i.baseUrl, key: i.apiKey))
        .toList();
    if (_drafts.isEmpty) _drafts.add(_newDraft());
    _layout = widget.initial.layout;
    _theme = widget.initial.themeMode;
    _trayMode = widget.initial.tray.mode;
    _pinnedKeys = widget.initial.tray.pinnedKeys.toSet();
    _tickerMs = widget.initial.tray.tickerMs.clamp(30, 300).toInt();
    _tickerWidth = widget.initial.tray.tickerWidth.clamp(8, 40).toInt();
    // Windows 浮窗宽:缺省回退共享 tickerWidth*9(老用户无回归),滑块/拖拽后为具体像素。
    _windowsTickerWidth = widget.initial.tray.windowsTickerWidth ??
        (widget.initial.tray.tickerWidth.clamp(8, 40) * 9).toInt();
    _windowsTickerEnabled = widget.initial.tray.windowsTickerEnabled;
    _windowsTickerMultiline = widget.initial.tray.windowsTickerMultiline;
    _windowsTickerHideFullscreen = widget.initial.tray.windowsTickerHideFullscreen;
    _windowsTickerIdleTransparency =
        widget.initial.tray.windowsTickerIdleTransparency.clamp(0, 90).toInt();
    _metric = widget.initial.tray.metric;
    _displayWindows = widget.initial.tray.displayWindows.toSet();
    _resetMode = widget.initial.resetMode;
    _alertEnabled = widget.initial.alertEnabled;
    _alertThreshold = widget.initial.alertThreshold;
    _alertOverWindows = widget.initial.alertOverWindows.toSet();
    _alertRecoverWindows = widget.initial.alertRecoverWindows.toSet();
    // 吸附到下拉预设值(防御手改 prefs 出现非预设值导致 DropdownButton 断言)。
    _pollPassiveSecs = _kPassivePresets.contains(widget.initial.pollPassiveSecs)
        ? widget.initial.pollPassiveSecs
        : 60;
    _pollActiveEnabled = widget.initial.pollActiveEnabled;
    _pollActiveSecs = _kActivePresets.contains(widget.initial.pollActiveSecs)
        ? widget.initial.pollActiveSecs
        : 600;
    _chartEnabled = widget.initial.chartEnabled;
    _chartRange = widget.initial.chartRange;
  }

  @override
  void didUpdateWidget(SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 浮窗被拖拽改宽后,壳会带新的 initial 重建本页:把宽度滑块同步到新值,
    // 否则设置页仍持旧宽,一旦再 _emitTray 就会把拖出来的宽度覆盖回去(与拖拽不同步)。
    final nw = widget.initial.tray.windowsTickerWidth;
    if (nw != null && nw != oldWidget.initial.tray.windowsTickerWidth) {
      _windowsTickerWidth = nw;
    }
  }

  /// 用量提醒任一项改动即时生效(不必"保存并连接")。
  void _emitAlert() => widget.onAlertChanged?.call(
        _alertEnabled,
        _alertThreshold,
        _alertOverWindows.toSet(),
        _alertRecoverWindows.toSet(),
      );

  /// 后台拉取节奏改动:通知壳重启核心生效(改动较重,非即时)。
  void _emitPoll() => widget.onPollChanged?.call(
        _pollPassiveSecs,
        _pollActiveEnabled,
        _pollActiveSecs,
      );

  /// 小时图表开关/跨度改动:通知壳持久化并重启核心(影响 core 是否取 trend / 取多宽)。
  void _emitChart() => widget.onChartChanged?.call(_chartEnabled, _chartRange);

  _Draft _newDraft() {
    _idSeq++;
    return _Draft('i${DateTime.now().microsecondsSinceEpoch}_$_idSeq');
  }

  @override
  void dispose() {
    for (final d in _drafts) {
      d.dispose();
    }
    super.dispose();
  }

  void _addInstance() => setState(() => _drafts.add(_newDraft()));

  void _removeInstance(int i) => setState(() {
        _drafts[i].dispose();
        _drafts.removeAt(i);
      });

  TraySettings _tray() => TraySettings(
        mode: _trayMode,
        pinnedKeys: _pinnedKeys.toList(),
        tickerMs: _tickerMs,
        tickerWidth: _tickerWidth,
        metric: _metric,
        displayWindows: _displayWindows.toSet(),
        windowsTickerEnabled: _windowsTickerEnabled,
        windowsTickerMultiline: _windowsTickerMultiline,
        windowsTickerHideFullscreen: _windowsTickerHideFullscreen,
        windowsTickerWidth: _windowsTickerWidth,
        windowsTickerIdleTransparency: _windowsTickerIdleTransparency,
        // 保留浮窗位置(拖拽由壳持久化;设置页不持有,故从 initial 透传,避免被置空)。
        windowsTickerX: widget.initial.tray.windowsTickerX,
        windowsTickerY: widget.initial.tray.windowsTickerY,
      );

  /// 托盘相关改动即时生效(不必保存)。
  void _emitTray() => widget.onTrayChanged?.call(_tray());

  /// 由当前表单状态构造一份完整 Settings(保存与导出共用 → 导出 WYSIWYG)。
  Settings _currentSettings() => Settings(
        instances: _drafts.map((d) => d.toInstance()).toList(),
        layout: _layout,
        tray: _tray(),
        themeMode: _theme,
        resetMode: _resetMode,
        alertEnabled: _alertEnabled,
        alertThreshold: _alertThreshold,
        alertOverWindows: _alertOverWindows,
        alertRecoverWindows: _alertRecoverWindows,
        pollPassiveSecs: _pollPassiveSecs,
        pollActiveEnabled: _pollActiveEnabled,
        pollActiveSecs: _pollActiveSecs,
        chartEnabled: _chartEnabled,
        chartRange: _chartRange,
      );

  void _save() => widget.onSave(_currentSettings());

  // ---------- 配置导入 / 导出(YAML) ----------

  Future<void> _showExportDialog() async {
    bool includeKeys = true;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final theme = Theme.of(ctx);
          final yamlText =
              exportConfigYaml(_currentSettings(), includeKeys: includeKeys);
          return AlertDialog(
            title: const Text('导出配置'),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: includeKeys,
                    onChanged: (v) => setLocal(() => includeKeys = v ?? true),
                    title:
                        const Text('包含 API 密钥', style: TextStyle(fontSize: 13)),
                  ),
                  if (includeKeys)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text('⚠️ 含 API 密钥明文,妥善保管、勿外传',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.error)),
                    ),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 240),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(yamlText,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 12)),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: yamlText));
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已复制到剪贴板')));
                  }
                },
                child: const Text('复制'),
              ),
              TextButton(
                onPressed: () => _saveExportToFile(yamlText),
                child: const Text('保存为文件…'),
              ),
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('关闭')),
            ],
          );
        },
      ),
    );
  }

  Future<void> _saveExportToFile(String yamlText) async {
    try {
      final loc = await getSaveLocation(
        suggestedName: 'quota-pulse-config.yaml',
        acceptedTypeGroups: const [
          XTypeGroup(label: 'YAML', extensions: ['yaml', 'yml']),
        ],
      );
      if (loc == null) return; // 用户取消
      await File(loc.path).writeAsString(yamlText);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已导出到 ${loc.path}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导出失败:$e')));
      }
    }
  }

  Future<void> _showImportDialog() async {
    final controller = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入配置'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('粘贴配置(YAML),或从文件选择;导入会覆盖当前配置。',
                  style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                minLines: 6,
                maxLines: 12,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                  hintText: 'app: quota-pulse\nsettings:\n  ...',
                ),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () async {
                    final text = await _pickImportFile();
                    if (text != null) controller.text = text;
                  },
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: const Text('从文件选择…'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消')),
          FilledButton(
            onPressed: () {
              Settings parsed;
              try {
                parsed = importConfigYaml(controller.text);
              } catch (e) {
                final msg = e is FormatException ? e.message : '$e';
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text('导入失败:$msg')));
                return;
              }
              Navigator.of(ctx).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已导入配置')));
              widget.onImport?.call(parsed);
            },
            child: const Text('导入'),
          ),
        ],
      ),
    );
    controller.dispose();
  }

  Future<String?> _pickImportFile() async {
    try {
      final file = await openFile(acceptedTypeGroups: const [
        XTypeGroup(label: 'YAML / JSON', extensions: ['yaml', 'yml', 'json', 'txt']),
      ]);
      if (file == null) return null;
      return await file.readAsString();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('读取失败:$e')));
      }
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 固定顶栏:返回按钮不随内容滚动,设置页任何位置都能返回。
        if (widget.onCancel != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
            child: Row(
              children: [
                IconButton(
                  tooltip: '返回',
                  icon: const Icon(Icons.arrow_back, size: 20),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  onPressed: widget.onCancel,
                ),
                const SizedBox(width: 6),
                Text('设置',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
            children: [
        Text('sub2api 实例', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        for (var i = 0; i < _drafts.length; i++) _instanceCard(i),
        Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _addInstance,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('添加 sub2api'),
                ),
              ),
            ),
            FilledButton(onPressed: _save, child: const Text('保存并连接')),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text('实例改动需点「保存并连接」生效;以下其余设置均改动即时生效。',
              style: theme.textTheme.bodySmall),
        ),
        const Divider(height: 24),

        Text('启动', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('开机自启动', style: TextStyle(fontSize: 13)),
          subtitle: Text('登录系统后自动在后台启动(macOS 下次登录生效)',
              style: theme.textTheme.bodySmall),
          value: widget.autostartEnabled,
          onChanged: widget.onAutostartChanged,
        ),
        const Divider(height: 24),

        Text('列表布局', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        SegmentedButton<ListLayout>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: ListLayout.grouped, label: Text('分组'), icon: Icon(Icons.view_agenda_outlined, size: 15)),
            ButtonSegment(value: ListLayout.tabs, label: Text('标签页'), icon: Icon(Icons.tab_outlined, size: 15)),
          ],
          selected: {_layout},
          onSelectionChanged: (s) {
            setState(() => _layout = s.first);
            widget.onLayoutChanged?.call(_layout); // 即时生效
          },
        ),
        const Divider(height: 24),

        Text('用量图表', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('每站点小时柱状图', style: TextStyle(fontSize: 13)),
          subtitle: Text('主面板每个站点下按账户着色的小时 token 用量;关闭则不额外请求',
              style: theme.textTheme.bodySmall),
          value: _chartEnabled,
          onChanged: (v) {
            setState(() => _chartEnabled = v);
            _emitChart();
          },
        ),
        if (_chartEnabled) ...[
          Row(
            children: [
              const Expanded(child: Text('时间跨度', style: TextStyle(fontSize: 13))),
              _boxed(
                DropdownButton<ChartRange>(
                  value: _chartRange,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final r in ChartRange.values)
                      DropdownMenuItem(value: r, child: Text(r.label)),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _chartRange = v);
                    _emitChart();
                  },
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('鼠标悬停柱子看 in/out/cache 明细;跨度越大数据请求略增',
                style: theme.textTheme.bodySmall),
          ),
        ],
        const Divider(height: 24),

        Text('主题', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        SegmentedButton<ThemeChoice>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: ThemeChoice.system, label: Text('跟随系统')),
            ButtonSegment(value: ThemeChoice.light, label: Text('浅色')),
            ButtonSegment(value: ThemeChoice.dark, label: Text('深色')),
          ],
          selected: {_theme},
          onSelectionChanged: (s) {
            setState(() => _theme = s.first);
            widget.onThemeChanged?.call(s.first); // 即时生效 + 持久化(由壳处理)
          },
        ),
        const Divider(height: 24),

        Text('托盘悬停内容', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        _boxed(
          DropdownButton<TrayMode>(
            value: _trayMode,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(value: TrayMode.allAccounts, child: Text('全部账户(默认)')),
              DropdownMenuItem(value: TrayMode.pinnedAccounts, child: Text('指定账户(可多选)')),
            ],
            onChanged: (v) {
              setState(() => _trayMode = v ?? TrayMode.allAccounts);
              _emitTray(); // 即时生效
            },
          ),
        ),
        const SizedBox(height: 10),
        Text('显示量(悬浮窗/菜单栏)', style: theme.textTheme.bodySmall),
        const SizedBox(height: 4),
        SegmentedButton<TrayMetric>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: TrayMetric.usage, label: Text('使用量')),
            ButtonSegment(value: TrayMetric.remaining, label: Text('剩余量')),
          ],
          selected: {_metric},
          onSelectionChanged: (s) {
            setState(() => _metric = s.first);
            _emitTray(); // 即时生效
          },
        ),
        const SizedBox(height: 10),
        Text('显示窗口(悬浮窗/菜单栏)', style: theme.textTheme.bodySmall),
        const SizedBox(height: 4),
        _displayWindowChips(),
        if (_trayMode == TrayMode.pinnedAccounts) ...[
          const SizedBox(height: 8),
          if (widget.accounts.isEmpty)
            Text('暂无账户;先保存实例、等拉到数据后再来选',
                style: theme.textTheme.bodySmall)
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final a in widget.accounts)
                  FilterChip(
                    label: Text(
                      '${a.instance}·${a.name.isEmpty ? a.accountId : a.name}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    selected: _pinnedKeys.contains(a.key),
                    onSelected: (sel) {
                      setState(() {
                        if (sel) {
                          _pinnedKeys.add(a.key);
                        } else {
                          _pinnedKeys.remove(a.key);
                        }
                      });
                      _emitTray();
                    },
                  ),
              ],
            ),
          if (widget.accounts.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('可多选;不选则默认显示最忙的一个',
                  style: theme.textTheme.bodySmall),
            ),
        ],

        const Divider(height: 24),
        Text('重置时间显示',
            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        SegmentedButton<ResetMode>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: ResetMode.countdown, label: Text('剩余时间')),
            ButtonSegment(value: ResetMode.absolute, label: Text('绝对时间')),
          ],
          selected: {_resetMode},
          onSelectionChanged: (s) {
            setState(() => _resetMode = s.first);
            widget.onResetModeChanged?.call(s.first); // 主页 + 托盘/菜单栏即时生效
          },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('主页与悬浮窗/菜单栏同时生效;倒计时支持到「天」',
              style: theme.textTheme.bodySmall),
        ),

        const Divider(height: 24),
        Text('用量提醒',
            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('启用用量通知', style: TextStyle(fontSize: 13)),
          subtitle: Text('关闭后下列通知都不发送;每个窗口同类通知一个重置周期内只提醒一次',
              style: theme.textTheme.bodySmall),
          value: _alertEnabled,
          onChanged: (v) {
            setState(() => _alertEnabled = v);
            _emitAlert();
          },
        ),
        Row(children: [
          SizedBox(
              width: 76,
              child: Text('阈值 $_alertThreshold%', style: theme.textTheme.bodySmall)),
          Expanded(
            child: Slider(
              min: 50,
              max: 100,
              divisions: 50,
              value: _alertThreshold.toDouble(),
              onChanged: _alertEnabled
                  ? (v) {
                      setState(() => _alertThreshold = v.round());
                      _emitAlert();
                    }
                  : null,
            ),
          ),
        ]),
        const SizedBox(height: 4),
        Text('超阈值提醒 · 用量越过阈值时', style: theme.textTheme.bodySmall),
        const SizedBox(height: 4),
        _windowChips(_alertOverWindows),
        const SizedBox(height: 10),
        Text('额度恢复提醒 · 回落到阈值以下(含窗口重置)时', style: theme.textTheme.bodySmall),
        const SizedBox(height: 4),
        _windowChips(_alertRecoverWindows),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () {
              widget.onTestNotification?.call(); // fire-and-forget
            },
            icon: const Icon(Icons.notifications_active_outlined, size: 16),
            label: const Text('发送测试通知'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Text('依次弹出 🚨 告警 / 🛑 已满 / ✅ 恢复 三种样例',
              style: theme.textTheme.bodySmall),
        ),

        const Divider(height: 24),
        Text('后台拉取',
            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        // 被动刷新:读 sub2api 缓存,始终开,仅周期可配。
        Row(
          children: [
            const Expanded(child: Text('刷新间隔', style: TextStyle(fontSize: 13))),
            _boxed(
              DropdownButton<int>(
                value: _pollPassiveSecs,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 30, child: Text('30 秒')),
                  DropdownMenuItem(value: 60, child: Text('1 分钟(默认)')),
                  DropdownMenuItem(value: 120, child: Text('2 分钟')),
                  DropdownMenuItem(value: 300, child: Text('5 分钟')),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _pollPassiveSecs = v);
                  _emitPoll();
                },
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text('读取 sub2api 缓存的节奏(面板打开自动提速、电池供电降速)',
              style: theme.textTheme.bodySmall),
        ),
        const SizedBox(height: 4),
        // 自动强制回源:有自动化特征,默认关;手动刷新按钮不受影响。
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('自动强制回源', style: TextStyle(fontSize: 13)),
          subtitle: Text('周期性强制 sub2api 回源刷新上游;有明显自动化特征,默认关闭。'
              '启动加载与手动刷新仍会回源一次(加载全部账户),不受此开关影响',
              style: theme.textTheme.bodySmall),
          value: _pollActiveEnabled,
          onChanged: (v) {
            setState(() => _pollActiveEnabled = v);
            _emitPoll();
          },
        ),
        if (_pollActiveEnabled)
          Row(
            children: [
              const Expanded(child: Text('回源间隔', style: TextStyle(fontSize: 13))),
              _boxed(
                DropdownButton<int>(
                  value: _pollActiveSecs,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(value: 300, child: Text('5 分钟')),
                    DropdownMenuItem(value: 600, child: Text('10 分钟(默认)')),
                    DropdownMenuItem(value: 1800, child: Text('30 分钟')),
                    DropdownMenuItem(value: 3600, child: Text('1 小时')),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _pollActiveSecs = v);
                    _emitPoll();
                  },
                ),
              ),
            ],
          ),

        // macOS 专属:菜单栏「全部账户」流水屏滚动调参(拖动即时预览)。
        if (theme.platform == TargetPlatform.macOS) ...[
          const Divider(height: 24),
          Text('菜单栏滚动(macOS)',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          Text('仅「全部账户」模式、且一行放不下时滚动;拖动滑块菜单栏即时预览。',
              style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          Row(children: [
            SizedBox(
                width: 76,
                child: Text('速度 ${_tickerMs}ms', style: theme.textTheme.bodySmall)),
            Expanded(
              child: Slider(
                min: 30,
                max: 300,
                divisions: 27,
                value: _tickerMs.toDouble(),
                onChanged: (v) {
                  setState(() => _tickerMs = v.round());
                  _emitTray();
                },
              ),
            ),
          ]),
          Row(children: [
            SizedBox(
                width: 76,
                child: Text('宽度 $_tickerWidth 字', style: theme.textTheme.bodySmall)),
            Expanded(
              child: Slider(
                min: 8,
                max: 40,
                divisions: 32,
                value: _tickerWidth.toDouble(),
                onChanged: (v) {
                  setState(() => _tickerWidth = v.round());
                  _emitTray();
                },
              ),
            ),
          ]),
          Text('≈ ${(1000 / _tickerMs).round()} 字/秒(间隔越小越顺、也越快)',
              style: theme.textTheme.bodySmall),
        ],

        // Windows 专属:桌面悬浮窗口(原生置顶浮窗,像素级滚动)。
        if (theme.platform == TargetPlatform.windows) ...[
          const Divider(height: 24),
          Text('悬浮窗口',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('启用悬浮窗口', style: TextStyle(fontSize: 13)),
            subtitle: Text('桌面常驻一个可拖拽的用量浮窗(滚动/多行);左键点开主面板',
                style: theme.textTheme.bodySmall),
            value: _windowsTickerEnabled,
            onChanged: (v) {
              setState(() => _windowsTickerEnabled = v);
              _emitTray();
            },
          ),
          if (_windowsTickerEnabled) ...[
            const SizedBox(height: 4),
            Text('显示模式', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('滚动')),
                ButtonSegment(value: true, label: Text('多行')),
              ],
              selected: {_windowsTickerMultiline},
              onSelectionChanged: (s) {
                setState(() => _windowsTickerMultiline = s.first);
                _emitTray();
              },
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 2),
              child: Text(
                _windowsTickerMultiline
                    ? '多行:每账户铺开「基础信息 + 各窗口一行」,不滚动'
                    : '滚动:单行像素级滚动,放不下时自动滚',
                style: theme.textTheme.bodySmall,
              ),
            ),
            // 空闲透明度(滚动/多行均生效):鼠标不在浮窗上时整窗透明度;0=关闭(常亮)。
            Row(children: [
              SizedBox(
                  width: 76,
                  child: Text(
                      _windowsTickerIdleTransparency <= 0
                          ? '空闲透明 关'
                          : '空闲透明 $_windowsTickerIdleTransparency%',
                      style: theme.textTheme.bodySmall)),
              Expanded(
                child: Slider(
                  min: 0,
                  max: 90,
                  divisions: 18,
                  value: _windowsTickerIdleTransparency.toDouble(),
                  onChanged: (v) {
                    setState(() => _windowsTickerIdleTransparency = v.round());
                    _emitTray();
                  },
                ),
              ),
            ]),
            Text('鼠标移开浮窗时变透明(看清背后),移上去变清晰;0=关闭',
                style: theme.textTheme.bodySmall),
            // 速度/宽度仅对滚动模式有意义;多行模式按内容自动排版。
            if (!_windowsTickerMultiline) ...[
              Row(children: [
                SizedBox(
                    width: 76,
                    child:
                        Text('速度 ${_tickerMs}ms', style: theme.textTheme.bodySmall)),
                Expanded(
                  child: Slider(
                    min: 30,
                    max: 300,
                    divisions: 27,
                    value: _tickerMs.toDouble(),
                    onChanged: (v) {
                      setState(() => _tickerMs = v.round());
                      _emitTray();
                    },
                  ),
                ),
              ]),
              Row(children: [
                SizedBox(
                    width: 76,
                    child: Text('宽度 ${_windowsTickerWidth}px',
                        style: theme.textTheme.bodySmall)),
                Expanded(
                  child: Slider(
                    min: 72,
                    max: _winWidthSliderMax,
                    value: _windowsTickerWidth
                        .toDouble()
                        .clamp(72.0, _winWidthSliderMax)
                        .toDouble(),
                    onChanged: (v) {
                      setState(() => _windowsTickerWidth = v.round());
                      _emitTray();
                    },
                  ),
                ),
              ]),
              Text('可拖到整屏宽;也可直接拖拽浮窗左/右边缘改宽',
                  style: theme.textTheme.bodySmall),
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('全屏时自动隐藏', style: TextStyle(fontSize: 13)),
              subtitle: Text('前台应用全屏覆盖整屏时自动藏起,退出再显',
                  style: theme.textTheme.bodySmall),
              value: _windowsTickerHideFullscreen,
              onChanged: (v) {
                setState(() => _windowsTickerHideFullscreen = v);
                _emitTray();
              },
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => widget.onResetTickerPosition?.call(),
                icon: const Icon(Icons.restart_alt, size: 16),
                label: const Text('重置位置'),
              ),
            ),
          ],
        ],

        const SizedBox(height: 12),
        // 配置导入 / 导出(跨平台,YAML;方便迁移到不同机器)。
        const Divider(height: 1),
        const SizedBox(height: 8),
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton.icon(
                onPressed: _showImportDialog,
                icon: const Icon(Icons.file_upload_outlined, size: 16),
                label: const Text('导入配置'),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: _showExportDialog,
                icon: const Icon(Icons.file_download_outlined, size: 16),
                label: const Text('导出配置'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        // MiSans 仅 Windows 打包使用;其许可要求「在软件中特别注明」,故只在 Windows 显示署名。
        if (theme.platform == TargetPlatform.windows) ...[
          const SizedBox(height: 14),
          Center(
            child: Text(
              '界面字体 MiSans · 版权归小米所有',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.55),
              ),
            ),
          ),
        ],
        const SizedBox(height: 14),
        Center(
          child: Text(
            '版本 $appVersion',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _instanceCard(int i) {
    final d = _drafts[i];
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: d.name,
                  decoration: _dec('实例名(如 主力 / 备用)'),
                  // 不设 fontWeight:Windows 雅黑只有 Regular/Bold,w500/w600 会被
                  // 就近映射成 Bold,导致这一项看起来「莫名加粗」而其它字段正常。
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              if (_drafts.length > 1)
                IconButton(
                  tooltip: '删除',
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () => _removeInstance(i),
                ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: d.url,
            decoration: _dec('Base URL,如 https://host'),
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: d.key,
            obscureText: d.obscure,
            decoration: _dec('Admin API Key (x-api-key)').copyWith(
              suffixIcon: IconButton(
                icon: Icon(d.obscure ? Icons.visibility_off : Icons.visibility, size: 16),
                onPressed: () => setState(() => d.obscure = !d.obscure),
              ),
            ),
            style: const TextStyle(fontSize: 13),
          ),
        ],
      ),
    );
  }

  /// 显示窗口多选 chips(5h / 7d);跨平台生效,至少保留一个(禁止删到空)。
  Widget _displayWindowChips() => Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final e in kAlertWindows.entries)
            FilterChip(
              label: Text(e.value, style: const TextStyle(fontSize: 12)),
              selected: _displayWindows.contains(e.key),
              onSelected: (sel) {
                if (!sel && _displayWindows.length <= 1) return; // 至少保留一个
                setState(() {
                  if (sel) {
                    _displayWindows.add(e.key);
                  } else {
                    _displayWindows.remove(e.key);
                  }
                });
                _emitTray();
              },
            ),
        ],
      );

  /// 通知监听窗口多选 chips(5h / 7d);总开关关闭时禁用。
  Widget _windowChips(Set<String> selected) => Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final e in kAlertWindows.entries)
            FilterChip(
              label: Text(e.value, style: const TextStyle(fontSize: 12)),
              selected: selected.contains(e.key),
              onSelected: _alertEnabled
                  ? (sel) {
                      setState(() {
                        if (sel) {
                          selected.add(e.key);
                        } else {
                          selected.remove(e.key);
                        }
                      });
                      _emitAlert();
                    }
                  : null,
            ),
        ],
      );

  InputDecoration _dec(String? hint) => InputDecoration(
        isDense: true,
        hintText: hint,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: const OutlineInputBorder(),
      );

  /// 给 DropdownButton 套一个与输入框一致的描边盒。
  Widget _boxed(Widget child) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5),
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: child,
      );
}
