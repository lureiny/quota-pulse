import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../format.dart';
import '../models/pulse.dart';
import '../state/pulse_controller.dart';
import '../state/settings_store.dart';
import '../widgets/account_tile.dart';
import '../widgets/heatmap_chart.dart';
import '../widgets/hourly_chart.dart';
import '../widgets/measure_size.dart';
import '../widgets/metric_toggle.dart';

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
    this.onToggleResetMode,
    this.instanceUrls = const {},
    this.chartEnabled = false,
    this.chartRange = ChartRange.h24,
    this.chartType = ChartType.bar,
    this.chartGroupBy = ChartGroupBy.account,
    this.chartMetric = ChartMetric.tokens,
    this.chartHeatmapYear,
    this.chartHeatmapValue,
    this.onChartViewChanged,
    this.onContentHeight,
  });

  final PulseController controller;
  final ListLayout layout;
  final VoidCallback onRefresh;
  final VoidCallback onSettings;
  final ResetMode resetMode; // 重置显示:倒计时 / 绝对(随设置,透传到 MeterBar)
  final VoidCallback? onToggleResetMode; // 单击重置时间:翻转全局 resetMode(透传到 MeterBar)
  final Map<String, String> instanceUrls; // 实例名 → 后台 URL(把实例名做成超链接)
  final bool chartEnabled; // 是否在每个站点分组下显示小时用量图
  final ChartRange chartRange; // 图表时间跨度(主面板视图控件,即时切换)
  final ChartType chartType; // 图表样式:柱状 / 曲线(主面板视图控件,即时切换)
  final ChartGroupBy chartGroupBy; // 分组维度(主面板视图控件,即时切换)
  final ChartMetric chartMetric; // 度量:token 量 / 花费($)(主面板视图控件,即时切换)
  final int? chartHeatmapYear; // 热力图年份(null=最近 6 个月)
  final String? chartHeatmapValue; // 热力图选中维度值(null/''=全部聚合)
  // 主面板「视图控件」变更(维度/样式/跨度/度量 + 热力图年份/值):壳持久化 + 重渲染,不重启核心。
  final void Function(ChartView view)? onChartViewChanged;
  // 内容固有高度上报(测得 body 高 + chrome);壳据此把窗口高度调到刚好容纳,超屏才滚。
  final void Function(double contentHeight)? onContentHeight;

  @override
  State<PopoverPage> createState() => _PopoverPageState();
}

class _PopoverPageState extends State<PopoverPage> {
  // 已折叠的实例名集合(分组模式)。默认全部展开。
  final Set<String> _collapsed = {};

  void _toggle(String instance) => setState(() {
        if (!_collapsed.remove(instance)) _collapsed.add(instance);
      });

  /// 当前图表视图控件打包(改一项即 copyWith 后回调,替代多参位置调用)。
  ChartView get _view => ChartView(
        groupBy: widget.chartGroupBy,
        type: widget.chartType,
        range: widget.chartRange,
        metric: widget.chartMetric,
        heatmapYear: widget.chartHeatmapYear,
        heatmapValue: widget.chartHeatmapValue,
      );

  /// 小时图(柱/线,按 chartType)。每个实例总显示(chartEnabled 时)。
  Widget _hourlyChartFor(String instance) => HourlyChart(
        key: ValueKey('chart-$instance'),
        instance: instance,
        dimension: widget.chartGroupBy.dimension,
        range: widget.chartRange,
        chartType: widget.chartType,
        metric: widget.chartMetric,
        onRangeChanged: (r) =>
            widget.onChartViewChanged?.call(_view.copyWith(range: r)),
        onTypeChanged: (t) =>
            widget.onChartViewChanged?.call(_view.copyWith(type: t)),
        fetchChart: widget.controller.chartData,
        ensureCoverage: widget.controller.ensureCoverage,
      );

  /// 热力图(独立一块,按天)。在小时图下方追加(与小时图同时显示)。
  Widget _heatmapChartFor(String instance) => HeatmapChart(
        key: ValueKey('heatmap-$instance'),
        instance: instance,
        dimension: widget.chartGroupBy.dimension,
        metric: widget.chartMetric,
        heatmapYear: widget.chartHeatmapYear,
        heatmapValue: widget.chartHeatmapValue,
        onHeatmapViewChanged: (year, value) => widget.onChartViewChanged
            ?.call(_view.copyWith(heatmapYear: year, heatmapValue: value)),
        fetchDailyChart: widget.controller.dailyChartData,
        ensureCoverage: widget.controller.ensureCoverage,
        fetchCoverage: widget.controller.coverageData,
      );

  /// 某实例的图表区块:小时图 + 热力图(两块都显示,各带各的控件)。
  List<Widget> _chartsFor(String instance) => [
        if (widget.chartEnabled) ...[
          _hourlyChartFor(instance),
          _heatmapChartFor(instance),
        ],
      ];

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
            // 内容按固有高度渲染:Flexible(loose)+滚动 → 内容 ≤ 可用高就不滚(窗口长到刚好),
            // 超过才滚(仅 body 滚,底栏钉住)。body 与 chrome 各**实测**高度求和上报壳,
            // 不再硬编码 chrome 高(否则窗口偏短会误出滚动条)。
            Flexible(
              fit: FlexFit.loose,
              child: SingleChildScrollView(
                child: MeasureSize(
                  onChange: (s) {
                    _bodyH = s.height;
                    _reportHeight();
                  },
                  child: _body(context, groups),
                ),
              ),
            ),
            MeasureSize(
              onChange: (s) {
                _chromeH = s.height;
                _reportHeight();
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Divider(height: 1),
                  if (showChartBar) ...[
                    _chartViewBar(context),
                    const Divider(height: 1),
                  ],
                  _footer(context),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  // body 与底栏(chrome)各自实测的高度;任一变化即把二者之和上报壳。
  double _bodyH = 0;
  double _chromeH = 0;
  void _reportHeight() => widget.onContentHeight?.call(_bodyH + _chromeH);

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
              resetMode: widget.resetMode,
              onToggleResetMode: widget.onToggleResetMode),
        ));
        children.addAll(_chartsFor(instance));
      }
    });
    // 固有高度 Column(不再 ListView 内滚):滚动交给外层 SingleChildScrollView,
    // 让窗口可按内容高自适应。
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }

  Widget _tabbed(BuildContext context, Map<String, List<AccountPulse>> groups) {
    final entries = groups.entries.toList();
    return DefaultTabController(
      length: entries.length,
      child: Column(
        mainAxisSize: MainAxisSize.min, // 固有高度,供外层测量
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
          // IndexedStack 布局全部 tab、按**最大** tab 定高(切换不跳),只显示当前 index。
          // 代价:失去 TabBarView 的滑动切换动画(可接受)。
          Builder(builder: (ctx) {
            final controller = DefaultTabController.of(ctx);
            return AnimatedBuilder(
              animation: controller,
              builder: (ctx, _) => IndexedStack(
                index: controller.index.clamp(0, entries.length - 1),
                alignment: Alignment.topLeft,
                children: [for (final e in entries) _tabBody(context, e)],
              ),
            );
          }),
        ],
      ),
    );
  }

  // 单个 tab 的内容(固有高度 Column):组头(不重复名字/不折叠)+ 账户 + 可选图表。
  Widget _tabBody(BuildContext context, MapEntry<String, List<AccountPulse>> e) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _groupHeader(context, e.key,
              () => widget.controller.refreshInstance(e.key),
              showName: false, url: widget.instanceUrls[e.key]),
          ...e.value.map((p) => AccountTile(p,
              onRefresh: () => widget.controller.refreshAccount(p.key),
              resetMode: widget.resetMode,
              onToggleResetMode: widget.onToggleResetMode)),
          ..._chartsFor(e.key),
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

  // 主面板「用量图表」共享控件:全局一处(底栏上方独立细条),只放两图**共享**的
  // 聚合维度(控制小时图 + 热力图的归类)。各图专属控件(小时图的跨度/柱线、热力图的
  // 年份/值)在各自图块内。即时切换、持久化,不重启核心、不刷新用量。
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
                widget.onChartViewChanged?.call(_view.copyWith(groupBy: v));
              }
            },
          ),
          const SizedBox(width: 10),
          // 度量(token/花费/次数)也是两图共享的全局配置 → 放这里,不在每张图上各放一个。
          MetricToggle(
            metric: widget.chartMetric,
            onChanged: (m) =>
                widget.onChartViewChanged?.call(_view.copyWith(metric: m)),
          ),
          const Spacer(),
          // 跨度/样式(小时图)、年份/值(热力图)等各图专属控件都在各自图块内 —— 这里
          // 只放两图共享的「聚合维度 + 度量」,不同层级配置不混在一处。
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
