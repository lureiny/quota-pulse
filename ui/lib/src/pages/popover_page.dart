import 'package:flutter/material.dart';

import '../format.dart';
import '../models/pulse.dart';
import '../state/pulse_controller.dart';
import '../state/settings_store.dart';
import '../widgets/account_tile.dart';

/// PopoverPage:账户列表(按实例分组 / 标签页)+ 底部操作条。
/// 分组模式下每个分组可点击折叠/展开。
class PopoverPage extends StatefulWidget {
  const PopoverPage({
    super.key,
    required this.controller,
    required this.layout,
    required this.onRefresh,
    required this.onSettings,
    this.resetMode = ResetMode.countdown,
  });

  final PulseController controller;
  final ListLayout layout;
  final VoidCallback onRefresh;
  final VoidCallback onSettings;
  final ResetMode resetMode; // 重置显示:倒计时 / 绝对(随设置,透传到 MeterBar)

  @override
  State<PopoverPage> createState() => _PopoverPageState();
}

class _PopoverPageState extends State<PopoverPage> {
  // 已折叠的实例名集合(分组模式)。默认全部展开。
  final Set<String> _collapsed = {};

  void _toggle(String instance) => setState(() {
        if (!_collapsed.remove(instance)) _collapsed.add(instance);
      });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final groups = _groupByInstance(widget.controller.pulses);
        return Column(
          children: [
            Expanded(child: _body(context, groups)),
            const Divider(height: 1),
            _footer(context),
          ],
        );
      },
    );
  }

  // ---- 分组 + 组内按使用率降序 ----
  Map<String, List<AccountPulse>> _groupByInstance(List<AccountPulse> pulses) {
    final map = <String, List<AccountPulse>>{};
    for (final p in pulses) {
      (map[p.instance] ??= []).add(p);
    }
    final out = <String, List<AccountPulse>>{};
    for (final k in map.keys.toList()..sort()) {
      out[k] = map[k]!
        ..sort((a, b) => (b.peakUtilization ?? -1).compareTo(a.peakUtilization ?? -1));
    }
    return out;
  }

  double? _groupPeak(List<AccountPulse> list) {
    double? peak;
    for (final p in list) {
      final u = p.peakUtilization;
      if (u == null) continue;
      if (peak == null || u > peak) peak = u;
    }
    return peak;
  }

  Widget _body(BuildContext context, Map<String, List<AccountPulse>> groups) {
    final err = widget.controller.error;
    if (err != null && widget.controller.pulses.isEmpty) {
      return _state(context, '读取失败\n$err', color: statusColor(PulseStatus.error));
    }
    if (widget.controller.pulses.isEmpty) {
      return _state(context, '加载中…');
    }
    if (widget.layout == ListLayout.tabs && groups.length > 1) {
      return _tabbed(context, groups);
    }
    return _grouped(context, groups);
  }

  Widget _grouped(BuildContext context, Map<String, List<AccountPulse>> groups) {
    final children = <Widget>[];
    groups.forEach((instance, list) {
      final collapsed = _collapsed.contains(instance);
      children.add(_groupHeader(
        context,
        instance,
        _groupPeak(list),
        () => widget.controller.refreshInstance(instance),
        collapsible: true,
        collapsed: collapsed,
        onToggle: () => _toggle(instance),
      ));
      if (!collapsed) {
        children.addAll(list.map(
          (p) => AccountTile(p,
              onRefresh: () => widget.controller.refreshAccount(p.key),
              resetMode: widget.resetMode),
        ));
      }
    });
    return ListView(padding: const EdgeInsets.only(top: 6, bottom: 8), children: children);
  }

  Widget _tabbed(BuildContext context, Map<String, List<AccountPulse>> groups) {
    final entries = groups.entries.toList();
    return DefaultTabController(
      length: entries.length,
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelStyle: Theme.of(context).textTheme.labelLarge,
              tabs: [for (final e in entries) Tab(height: 36, text: e.key)],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                for (final e in entries)
                  ListView(
                    padding: const EdgeInsets.only(top: 4, bottom: 8),
                    children: [
                      // 标签页里 Tab 已显示名字,这里不再重复;也不提供折叠。
                      _groupHeader(context, e.key, _groupPeak(e.value),
                          () => widget.controller.refreshInstance(e.key),
                          showName: false),
                      ...e.value.map((p) => AccountTile(p,
                          onRefresh: () => widget.controller.refreshAccount(p.key),
                          resetMode: widget.resetMode)),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _groupHeader(
    BuildContext context,
    String instance,
    double? peak,
    VoidCallback onRefresh, {
    bool showName = true, // 标签页里 Tab 已显示名字,这里不再重复
    bool collapsible = false, // 分组模式可折叠
    bool collapsed = false,
    VoidCallback? onToggle,
  }) {
    final theme = Theme.of(context);
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
      child: Row(
        children: [
          if (collapsible) ...[
            AnimatedRotation(
              duration: const Duration(milliseconds: 150),
              turns: collapsed ? -0.25 : 0, // 展开 ▼ / 折叠 ▶
              child: Icon(Icons.expand_more,
                  size: 18, color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: 2),
          ],
          if (showName)
            Flexible(
              child: Text(instance.toUpperCase(),
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    letterSpacing: 0.5,
                  )),
            ),
          const Spacer(),
          if (peak != null)
            Text(fmtPct(peak),
                style: theme.textTheme.labelSmall?.copyWith(color: meterColor(peak))),
          IconButton(
            tooltip: '刷新本实例',
            icon: const Icon(Icons.refresh, size: 15),
            padding: const EdgeInsets.only(left: 6),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            onPressed: onRefresh,
          ),
        ],
      ),
    );
    if (!collapsible) return row;
    // 整行可点折叠;刷新按钮在手势竞技场里仍优先响应自己的点击。
    return InkWell(onTap: onToggle, child: row);
  }

  Widget _footer(BuildContext context) {
    final n = widget.controller.pulses.length;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Text('$n 个账户', style: Theme.of(context).textTheme.bodySmall),
          const Spacer(),
          IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: widget.onRefresh),
          IconButton(
              tooltip: '设置',
              icon: const Icon(Icons.settings, size: 18),
              onPressed: widget.onSettings),
        ],
      ),
    );
  }

  Widget _state(BuildContext context, String text, {Color? color}) => Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
      );
}
