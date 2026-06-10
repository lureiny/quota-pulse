import 'package:flutter/material.dart';

import '../models/pulse.dart';
import '../state/settings_store.dart';

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
  String? _pinnedKey;
  late TextEditingController _template;
  int _idSeq = 0;

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
    _pinnedKey = widget.initial.tray.pinnedKey;
    _template = TextEditingController(text: widget.initial.tray.template ?? '{name} {peak}%');
  }

  _Draft _newDraft() {
    _idSeq++;
    return _Draft('i${DateTime.now().microsecondsSinceEpoch}_$_idSeq');
  }

  @override
  void dispose() {
    for (final d in _drafts) {
      d.dispose();
    }
    _template.dispose();
    super.dispose();
  }

  void _addInstance() => setState(() => _drafts.add(_newDraft()));

  void _removeInstance(int i) => setState(() {
        _drafts[i].dispose();
        _drafts.removeAt(i);
      });

  TraySettings _tray() => TraySettings(
        mode: _trayMode,
        pinnedKey: _pinnedKey,
        template: _template.text.trim().isEmpty ? null : _template.text.trim(),
      );

  /// 托盘相关改动即时生效(不必保存)。
  void _emitTray() => widget.onTrayChanged?.call(_tray());

  void _save() {
    final instances = _drafts.map((d) => d.toInstance()).toList();
    widget.onSave(Settings(
      instances: instances,
      layout: _layout,
      tray: _tray(),
      themeMode: _theme,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accountKeys = widget.accounts.map((a) => a.key).toSet();
    final pinnedValue =
        (_pinnedKey != null && accountKeys.contains(_pinnedKey)) ? _pinnedKey : null;

    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        if (widget.onCancel != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
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
              DropdownMenuItem(value: TrayMode.pinnedAccount, child: Text('指定账户·5h 剩余/重置(默认)')),
              DropdownMenuItem(value: TrayMode.allAccounts, child: Text('全部账户')),
              DropdownMenuItem(value: TrayMode.custom, child: Text('自定义模板')),
            ],
            onChanged: (v) {
              setState(() => _trayMode = v ?? TrayMode.pinnedAccount);
              _emitTray(); // 即时生效
            },
          ),
        ),
        if (_trayMode == TrayMode.pinnedAccount) ...[
          const SizedBox(height: 8),
          _boxed(
            DropdownButton<String>(
              value: pinnedValue,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              hint: const Text('选择要钉住的账户'),
              items: [
                for (final a in widget.accounts)
                  DropdownMenuItem(
                    value: a.key,
                    child: Text('${a.instance} · ${a.name.isEmpty ? a.accountId : a.name}',
                        overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) {
                setState(() => _pinnedKey = v);
                _emitTray();
              },
            ),
          ),
          if (widget.accounts.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('暂无账户;先保存实例、等拉到数据后再来选', style: theme.textTheme.bodySmall),
            ),
        ],
        if (_trayMode == TrayMode.custom) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _template,
            decoration: _dec('模板,如 {name} {peak}%'),
            style: const TextStyle(fontSize: 13),
            onChanged: (_) => _emitTray(), // 即时生效
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('变量:{name} {peak} {count}', style: theme.textTheme.bodySmall),
          ),
        ],

        const SizedBox(height: 12),
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
