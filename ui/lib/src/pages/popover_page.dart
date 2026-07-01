import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../format.dart';
import '../models/pulse.dart';
import '../state/pulse_controller.dart';
import '../state/settings_store.dart';
import '../widgets/account_tile.dart';
import '../widgets/hourly_chart.dart';

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
    this.instanceUrls = const {},
    this.chartEnabled = false,
    this.chartRange = ChartRange.h24,
    this.chartType = ChartType.bar,
    this.chartGroupBy = ChartGroupBy.account,
    this.chartMetric = ChartMetric.tokens,
    this.onChartViewChanged,
  });

  final PulseController controller;
  final ListLayout layout;
  final VoidCallback onRefresh;
  final VoidCallback onSettings;
  final ResetMode resetMode; // 重置显示:倒计时 / 绝对(随设置,透传到 MeterBar)
  final Map<String, String> instanceUrls; // 实例名 → 后台 URL(把实例名做成超链接)
  final bool chartEnabled; // 是否在每个站点分组下显示小时用量图
  final ChartRange chartRange; // 图表时间跨度(主面板视图控件,即时切换)
  final ChartType chartType; // 图表样式:柱状 / 曲线(主面板视图控件,即时切换)
  final ChartGroupBy chartGroupBy; // 分组维度(主面板视图控件,即时切换)
  final ChartMetric chartMetric; // 度量:token 量 / 花费($)(主面板视图控件,即时切换)
  // 主面板「视图控件」变更(跨度/维度/样式/度量):壳持久化 + 重渲染,不重启核心。
  final void Function(ChartGroupBy groupBy, ChartType type, ChartRange range,
      ChartMetric metric)? onChartViewChanged;

  @override
  State<PopoverPage> createState() => _PopoverPageState();
}

class _PopoverPageState extends State<PopoverPage> {
  // 已折叠的实例名集合(分组模式)。默认全部展开。
  final Set<String> _collapsed = {};

  void _toggle(String instance) => setState(() {
        if (!_collapsed.remove(instance)) _collapsed.add(instance);
      });

  // 系统默认浏览器打开实例后台(macOS=NSWorkspace / Windows=ShellExecute,共用 url_launcher)。
  // 收 String?:调用点的 url 经 hasUrl 守卫但 Dart 不据此提升为非空,这里统一判空。
  Future<void> _open(String? url) async {
    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final groups = _groupByInstance(widget.controller.pulses);
        // 图表视图控件:全局一处,放在底栏上方一条独立细条(控制所有实例)。
        final showChartBar =
            widget.chartEnabled && widget.controller.pulses.isNotEmpty;
        return Column(
          children: [
            Expanded(child: _body(context, groups)),
            const Divider(height: 1),
            if (showChartBar) ...[
              _chartViewBar(context),
              const Divider(height: 1),
            ],
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
        () => widget.controller.refreshInstance(instance),
        collapsible: true,
        collapsed: collapsed,
        onToggle: () => _toggle(instance),
        url: widget.instanceUrls[instance],
      ));
      if (!collapsed) {
        // 先列账户(5h/7d 用量),图表放在其下方(#1)。
        children.addAll(list.map(
          (p) => AccountTile(p,
              onRefresh: () => widget.controller.refreshAccount(p.key),
              resetMode: widget.resetMode),
        ));
        if (widget.chartEnabled) {
          children.add(HourlyChart(
            key: ValueKey('chart-$instance'),
            instance: instance,
            dimension: widget.chartGroupBy.dimension,
            rangeHours: widget.chartRange.hours,
            chartType: widget.chartType,
            metric: widget.chartMetric,
            fetchChart: widget.controller.chartData,
            ensureCoverage: widget.controller.ensureCoverage,
          ));
        }
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
                      _groupHeader(context, e.key,
                          () => widget.controller.refreshInstance(e.key),
                          showName: false, url: widget.instanceUrls[e.key]),
                      ...e.value.map((p) => AccountTile(p,
                          onRefresh: () => widget.controller.refreshAccount(p.key),
                          resetMode: widget.resetMode)),
                      if (widget.chartEnabled)
                        HourlyChart(
                          key: ValueKey('chart-${e.key}'),
                          instance: e.key,
                          dimension: widget.chartGroupBy.dimension,
                          rangeHours: widget.chartRange.hours,
                          chartType: widget.chartType,
                          metric: widget.chartMetric,
                          fetchChart: widget.controller.chartData,
                          ensureCoverage: widget.controller.ensureCoverage,
                        ),
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
    VoidCallback onRefresh, {
    bool showName = true, // 标签页里 Tab 已显示名字,这里不再重复
    bool collapsible = false, // 分组模式可折叠
    bool collapsed = false,
    VoidCallback? onToggle,
    String? url, // 实例后台 URL:有则把实例名做成超链接(分组)/ 加打开图标(标签页)
  }) {
    final theme = Theme.of(context);
    final hasUrl = url != null && url.isNotEmpty;
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
              child: hasUrl
                  ? MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () => _open(url),
                        child: Text(instance.toUpperCase(),
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.primary,
                              letterSpacing: 0.5,
                              decoration: TextDecoration.underline,
                              decorationColor: theme.colorScheme.primary,
                            )),
                      ),
                    )
                  : Text(instance.toUpperCase(),
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        letterSpacing: 0.5,
                      )),
            ),
          const Spacer(),
          if (!showName && hasUrl)
            IconButton(
              tooltip: '打开后台',
              icon: const Icon(Icons.open_in_new, size: 14),
              padding: const EdgeInsets.only(left: 6),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              onPressed: () => _open(url),
            ),
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

  // 主面板「用量图表」视图控件:全局一处(底栏上方独立细条),控制所有实例的
  // 时间跨度 + 分组维度 + 柱/线样式。即时切换、持久化(由壳保存),不重启核心、不刷新用量。
  Widget _chartViewBar(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 5, 8, 5),
      child: Row(
        children: [
          Icon(Icons.insights_outlined,
              size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 5),
          DropdownButton<ChartGroupBy>(
            value: widget.chartGroupBy,
            isDense: true,
            underline: const SizedBox.shrink(),
            items: [
              for (final g in ChartGroupBy.values)
                DropdownMenuItem(
                    value: g,
                    child:
                        Text(g.label, style: const TextStyle(fontSize: 12))),
            ],
            onChanged: (v) {
              if (v != null) {
                widget.onChartViewChanged?.call(
                    v, widget.chartType, widget.chartRange, widget.chartMetric);
              }
            },
          ),
          const SizedBox(width: 10),
          // 时间跨度(紧凑短标签,省横向空间)。
          DropdownButton<ChartRange>(
            value: widget.chartRange,
            isDense: true,
            underline: const SizedBox.shrink(),
            items: [
              for (final r in ChartRange.values)
                DropdownMenuItem(
                    value: r,
                    child: Text(r.shortLabel,
                        style: const TextStyle(fontSize: 12))),
            ],
            onChanged: (v) {
              if (v != null) {
                widget.onChartViewChanged?.call(
                    widget.chartGroupBy, widget.chartType, v, widget.chartMetric);
              }
            },
          ),
          const Spacer(),
          // 度量:按 token 量 / 按花费($)。花费视图下堆叠柱即各维度花费占比。
          SegmentedButton<ChartMetric>(
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            segments: const [
              ButtonSegment(
                  value: ChartMetric.tokens,
                  icon: Icon(Icons.toll_outlined, size: 15),
                  tooltip: 'Token 量'),
              ButtonSegment(
                  value: ChartMetric.cost,
                  icon: Icon(Icons.attach_money, size: 15),
                  tooltip: '花费($)'),
            ],
            selected: {widget.chartMetric},
            onSelectionChanged: (s) => widget.onChartViewChanged?.call(
                widget.chartGroupBy, widget.chartType, widget.chartRange, s.first),
          ),
          const SizedBox(width: 8),
          SegmentedButton<ChartType>(
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            segments: const [
              ButtonSegment(
                  value: ChartType.bar, icon: Icon(Icons.bar_chart, size: 15)),
              ButtonSegment(
                  value: ChartType.line, icon: Icon(Icons.show_chart, size: 15)),
            ],
            selected: {widget.chartType},
            onSelectionChanged: (s) => widget.onChartViewChanged
                ?.call(widget.chartGroupBy, s.first, widget.chartRange,
                    widget.chartMetric),
          ),
        ],
      ),
    );
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
