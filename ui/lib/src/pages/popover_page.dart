import 'package:flutter/material.dart';

import '../format.dart';
import '../models/pulse.dart';
import '../state/pulse_controller.dart';
import '../state/settings_store.dart';
import '../widgets/account_tile.dart';

/// PopoverPage:标题(含醒目峰值)+ 账户列表(按实例分组 / 标签页)+ 底部操作条。
class PopoverPage extends StatelessWidget {
  const PopoverPage({
    super.key,
    required this.controller,
    required this.layout,
    required this.onRefresh,
    required this.onSettings,
  });

  final PulseController controller;
  final ListLayout layout;
  final VoidCallback onRefresh;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final groups = _groupByInstance(controller.pulses);
        return Column(
          children: [
            _header(context),
            const Divider(height: 1),
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

  // ---- 标题 ----
  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Text('用量脉搏',
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
    );
  }

  Widget _body(BuildContext context, Map<String, List<AccountPulse>> groups) {
    final err = controller.error;
    if (err != null && controller.pulses.isEmpty) {
      return _state(context, '读取失败\n$err', color: statusColor(PulseStatus.error));
    }
    if (controller.pulses.isEmpty) {
      return _state(context, '加载中…');
    }
    if (layout == ListLayout.tabs && groups.length > 1) {
      return _tabbed(context, groups);
    }
    return _grouped(context, groups);
  }

  Widget _grouped(BuildContext context, Map<String, List<AccountPulse>> groups) {
    final children = <Widget>[];
    groups.forEach((instance, list) {
      children.add(_groupHeader(context, instance, _groupPeak(list),
          () => controller.refreshInstance(instance)));
      children.addAll(list.map(
        (p) => AccountTile(p, onRefresh: () => controller.refreshAccount(p.key)),
      ));
    });
    return ListView(padding: const EdgeInsets.only(top: 4, bottom: 8), children: children);
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
                      _groupHeader(context, e.key, _groupPeak(e.value),
                          () => controller.refreshInstance(e.key),
                          showName: false),
                      ...e.value.map((p) => AccountTile(p,
                          onRefresh: () => controller.refreshAccount(p.key))),
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
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 4),
      child: Row(
        children: [
          if (showName)
            Text(instance.toUpperCase(),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  letterSpacing: 0.5,
                )),
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
  }

  Widget _footer(BuildContext context) {
    final n = controller.pulses.length;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Text('$n 个账户', style: Theme.of(context).textTheme.bodySmall),
          const Spacer(),
          IconButton(tooltip: '刷新', icon: const Icon(Icons.refresh, size: 18), onPressed: onRefresh),
          IconButton(tooltip: '设置', icon: const Icon(Icons.settings, size: 18), onPressed: onSettings),
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
