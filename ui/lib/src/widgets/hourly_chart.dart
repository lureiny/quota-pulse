import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../format.dart';
import '../models/pulse.dart';
import '../state/settings_store.dart' show ChartType;

/// HourlyChart:某站点(实例)的小时级 token 用量图(柱状 / 曲线可切换)。
///
/// 数据按 `dimension`(account/api_key/model/user/group)从 core 即时聚合而来
/// (本地 SQLite 原始事件 GROUP BY),每个维度值 = 一条「系列」,按系列着色。
/// - 柱状:每小时一根堆叠柱,按系列分段;曲线:每系列一条线。
/// - x 轴覆盖整个选定窗口的每一小时,无数据的小时也留空列;全空也渲染坐标框。
/// - 鼠标悬停 → 半透明、随主题 tooltip,列出该小时各系列的 in/out/cache 与合计。
class HourlyChart extends StatefulWidget {
  const HourlyChart({
    super.key,
    required this.instance,
    required this.dimension,
    required this.rangeHours,
    required this.chartType,
    required this.fetchSeriesJson,
  });

  final String instance;
  final String dimension; // account / api_key / model / user / group
  final int rangeHours;
  final ChartType chartType;

  /// (instance, dimension, hours) → []Series 的 JSON(本地查询,便宜)。
  final String Function(String instance, String dimension, int hours)
      fetchSeriesJson;

  @override
  State<HourlyChart> createState() => _HourlyChartState();
}

class _HourlyChartState extends State<HourlyChart> {
  static const double _areaHeight = 96;
  static const double _minSlot = 13;
  static const double _maxBarWidth = 26;

  List<UsageSeries> _series = const [];
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _series = _load(); // 直接赋值(initState 里不 setState),build 紧随其后。
    // 随新事件同步,定时刷新图表(与快照 tick 解耦,避免每次重建都打 FFI)。
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
  }

  @override
  void didUpdateWidget(HourlyChart old) {
    super.didUpdateWidget(old);
    // 维度/实例/跨度变了立即重取(切样式 chartType 不必重取,build 直接换渲染)。
    if (old.instance != widget.instance ||
        old.dimension != widget.dimension ||
        old.rangeHours != widget.rangeHours) {
      _refresh();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  List<UsageSeries> _load() {
    try {
      return UsageSeries.listFromJson(widget.fetchSeriesJson(
          widget.instance, widget.dimension, widget.rangeHours));
    } catch (_) {
      return const [];
    }
  }

  void _refresh() {
    final s = _load();
    if (mounted) setState(() => _series = s);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 注意:_series 为空(该窗口无用量)也照常渲染空坐标框(留位),不隐藏。

    // 稳定着色:按系列 key 排序 → 索引 → 颜色。
    final ordered = [..._series]..sort((a, b) => a.key.compareTo(b.key));
    final colorOf = <String, Color>{};
    final nameOf = <String, String>{};
    for (var i = 0; i < ordered.length; i++) {
      final s = ordered[i];
      colorOf[s.key] = accountColor(i);
      nameOf[s.key] = s.name.isEmpty ? s.key : s.name;
    }

    final slots = _buildSlots(ordered, widget.rangeHours);

    var barMax = 0, lineMax = 0;
    for (final s in slots) {
      if (s.total > barMax) barMax = s.total;
      for (final p in s.points.values) {
        if (p.sum > lineMax) lineMax = p.sum;
      }
    }
    final rawMax =
        (widget.chartType == ChartType.line ? lineMax : barMax).toDouble();
    final maxY = rawMax > 0 ? rawMax * 1.18 : 1.0;

    final labelStep = (slots.length / 6).ceil().clamp(1, slots.length).toInt();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: _areaHeight,
            child: LayoutBuilder(
              builder: (context, c) {
                final n = slots.length;
                final fits = n * _minSlot <= c.maxWidth;
                final slotW = fits ? c.maxWidth / n : _minSlot;
                final totalW = fits ? c.maxWidth : n * _minSlot;
                final barWidth =
                    (slotW * 0.6).clamp(2.0, _maxBarWidth).toDouble();
                final chart = widget.chartType == ChartType.line
                    ? _lineChart(slots, ordered, colorOf, nameOf, maxY, labelStep, cs)
                    : _barChart(slots, ordered, colorOf, nameOf, maxY, labelStep,
                        barWidth, cs);
                if (fits) return chart;
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(width: totalW, child: chart),
                );
              },
            ),
          ),
          const SizedBox(height: 6),
          _legend(context, ordered, colorOf, nameOf),
        ],
      ),
    );
  }

  // ---- 柱状图 ----
  Widget _barChart(
      List<_Slot> slots,
      List<UsageSeries> ordered,
      Map<String, Color> colorOf,
      Map<String, String> nameOf,
      double maxY,
      int labelStep,
      double barWidth,
      ColorScheme cs) {
    final groups = <BarChartGroupData>[];
    for (var i = 0; i < slots.length; i++) {
      final s = slots[i];
      final stack = <BarChartRodStackItem>[];
      double from = 0;
      for (final ser in ordered) {
        final p = s.points[ser.key];
        if (p == null) continue;
        final to = from + p.sum.toDouble();
        stack.add(BarChartRodStackItem(from, to, colorOf[ser.key]!));
        from = to;
      }
      groups.add(BarChartGroupData(
        x: i,
        barRods: [
          BarChartRodData(
            toY: from,
            width: barWidth,
            rodStackItems: stack,
            borderRadius: const BorderRadius.all(Radius.circular(1.5)),
          ),
        ],
      ));
    }

    return BarChart(
      BarChartData(
        maxY: maxY,
        alignment: BarChartAlignment.spaceAround,
        barGroups: groups,
        barTouchData: BarTouchData(
          enabled: true,
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => _tooltipBg(cs),
            tooltipBorder: _tooltipBorder(cs),
            tooltipPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            tooltipMargin: 8,
            fitInsideHorizontally: true,
            fitInsideVertically: true,
            maxContentWidth: 280,
            getTooltipItem: (group, groupIndex, rod, rodIndex) =>
                _barTooltip(slots[groupIndex], ordered, colorOf, nameOf, cs),
          ),
        ),
        titlesData: _titles(slots, labelStep, cs),
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
      ),
    );
  }

  // ---- 曲线图 ----
  Widget _lineChart(
      List<_Slot> slots,
      List<UsageSeries> ordered,
      Map<String, Color> colorOf,
      Map<String, String> nameOf,
      double maxY,
      int labelStep,
      ColorScheme cs) {
    final bars = <LineChartBarData>[];
    for (final ser in ordered) {
      final spots = <FlSpot>[
        for (var i = 0; i < slots.length; i++)
          FlSpot(i.toDouble(), (slots[i].points[ser.key]?.sum ?? 0).toDouble()),
      ];
      bars.add(LineChartBarData(
        spots: spots,
        isCurved: true,
        curveSmoothness: 0.25,
        preventCurveOverShooting: true,
        color: colorOf[ser.key],
        barWidth: 2.2,
        dotData: const FlDotData(show: false),
        belowBarData: BarAreaData(show: false),
      ));
    }

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: (slots.length - 1).toDouble(),
        minY: 0,
        maxY: maxY,
        lineBarsData: bars,
        lineTouchData: LineTouchData(
          enabled: true,
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => _tooltipBg(cs),
            tooltipBorder: _tooltipBorder(cs),
            tooltipPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            maxContentWidth: 280,
            fitInsideHorizontally: true,
            fitInsideVertically: true,
            getTooltipItems: (spots) =>
                _lineTooltip(spots, slots, ordered, colorOf, nameOf, cs),
          ),
        ),
        titlesData: _titles(slots, labelStep, cs),
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
      ),
    );
  }

  // ---- 共用:底部小时标签(稀疏) ----
  FlTitlesData _titles(List<_Slot> slots, int labelStep, ColorScheme cs) =>
      FlTitlesData(
        leftTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 18,
            interval: 1,
            getTitlesWidget: (value, meta) {
              final i = value.round();
              if (i < 0 || i >= slots.length || i % labelStep != 0) {
                return const SizedBox.shrink();
              }
              final h = slots[i].hour;
              return Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '${h.hour.toString().padLeft(2, '0')}:00',
                  style: TextStyle(fontSize: 9, color: cs.onSurfaceVariant),
                ),
              );
            },
          ),
        ),
      );

  // 半透明、随主题的 tooltip 背景 + 细描边:看得见背后内容。
  Color _tooltipBg(ColorScheme cs) =>
      cs.surfaceContainerHighest.withValues(alpha: 0.6);
  BorderSide _tooltipBorder(ColorScheme cs) =>
      BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5), width: 0.6);

  // ---- tooltip:柱(整小时各系列明细) ----
  BarTooltipItem? _barTooltip(_Slot slot, List<UsageSeries> ordered,
      Map<String, Color> colorOf, Map<String, String> nameOf, ColorScheme cs) {
    if (slot.points.isEmpty) return null;
    final onText = cs.onSurface;
    final spans = <TextSpan>[];
    for (final ser in ordered) {
      final p = slot.points[ser.key];
      if (p == null) continue;
      spans.add(TextSpan(
        text: '\n${nameOf[ser.key]}  ${_detail(p)}',
        style: TextStyle(
            color: colorOf[ser.key],
            fontSize: 10.5,
            fontWeight: FontWeight.w500),
      ));
    }
    spans.add(TextSpan(
      text: '\n合计 ${fmtTokens(slot.total)} tok',
      style: TextStyle(color: onText.withValues(alpha: 0.7), fontSize: 10),
    ));
    return BarTooltipItem(
      _head(slot.hour),
      TextStyle(color: onText, fontSize: 11, fontWeight: FontWeight.w600),
      children: spans,
      textAlign: TextAlign.left,
    );
  }

  // ---- tooltip:线(被命中的各系列;首条带小时表头) ----
  List<LineTooltipItem?> _lineTooltip(
      List<LineBarSpot> spots,
      List<_Slot> slots,
      List<UsageSeries> ordered,
      Map<String, Color> colorOf,
      Map<String, String> nameOf,
      ColorScheme cs) {
    final onText = cs.onSurface;
    final out = <LineTooltipItem?>[];
    var headerPlaced = false;
    for (final sp in spots) {
      final i = sp.x.round();
      final ser = (sp.barIndex >= 0 && sp.barIndex < ordered.length)
          ? ordered[sp.barIndex]
          : null;
      final p = (ser != null && i >= 0 && i < slots.length)
          ? slots[i].points[ser.key]
          : null;
      if (ser == null || p == null) {
        out.add(null);
        continue;
      }
      final line = '${nameOf[ser.key]}  ${_detail(p)}';
      final color = colorOf[ser.key];
      if (!headerPlaced) {
        headerPlaced = true;
        out.add(LineTooltipItem(
          _head(slots[i].hour),
          TextStyle(color: onText, fontSize: 11, fontWeight: FontWeight.w600),
          textAlign: TextAlign.left,
          children: [
            TextSpan(
                text: '\n$line',
                style: TextStyle(
                    color: color, fontSize: 10.5, fontWeight: FontWeight.w500)),
          ],
        ));
      } else {
        out.add(LineTooltipItem(
          line,
          TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.w500),
          textAlign: TextAlign.left,
        ));
      }
    }
    return out;
  }

  String _detail(HourPoint p) =>
      '入${fmtTokens(p.input)}·出${fmtTokens(p.output)}·'
      '缓${fmtTokens(p.cacheCreate + p.cacheRead)} = ${fmtTokens(p.sum)}';

  String _head(DateTime h) =>
      '${h.month.toString().padLeft(2, '0')}-${h.day.toString().padLeft(2, '0')} '
      '${h.hour.toString().padLeft(2, '0')}:00';

  // ---- 图例:系列色点 + 名字 ----
  Widget _legend(BuildContext context, List<UsageSeries> ordered,
      Map<String, Color> colorOf, Map<String, String> nameOf) {
    final style = Theme.of(context).textTheme.labelSmall;
    return Wrap(
      spacing: 10,
      runSpacing: 2,
      children: [
        for (final ser in ordered)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: colorOf[ser.key],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 3),
              Text(nameOf[ser.key]!, style: style),
            ],
          ),
      ],
    );
  }

  /// 连续小时桶:从 nowHour-(hours-1) 到 nowHour 共 hours 个,逐小时;空桶也保留。
  /// 每个系列在每小时至多一个点(core 已按小时聚合),据此填入 slot.points[seriesKey]。
  List<_Slot> _buildSlots(List<UsageSeries> ordered, int hours) {
    final now = DateTime.now();
    final nowHour = DateTime(now.year, now.month, now.day, now.hour);
    final windowStart = nowHour.subtract(Duration(hours: hours - 1));

    // seriesKey -> (hourEpoch -> HourPoint)
    final byKey = <String, Map<int, HourPoint>>{};
    for (final ser in ordered) {
      final m = <int, HourPoint>{};
      for (final p in ser.points) {
        final hb = DateTime(p.hour.year, p.hour.month, p.hour.day, p.hour.hour);
        if (hb.isBefore(windowStart) || hb.isAfter(nowHour)) continue;
        if (p.sum <= 0) continue;
        m[hb.millisecondsSinceEpoch] = p;
      }
      byKey[ser.key] = m;
    }

    final slots = <_Slot>[];
    for (var k = hours - 1; k >= 0; k--) {
      final t = nowHour.subtract(Duration(hours: k));
      final epoch = t.millisecondsSinceEpoch;
      final points = <String, HourPoint>{};
      var total = 0;
      for (final ser in ordered) {
        final p = byKey[ser.key]?[epoch];
        if (p == null) continue;
        points[ser.key] = p;
        total += p.sum;
      }
      slots.add(_Slot(t, points, total));
    }
    return slots;
  }
}

class _Slot {
  _Slot(this.hour, this.points, this.total);
  final DateTime hour;
  final Map<String, HourPoint> points; // seriesKey -> 该小时有量的系列用量
  final int total;
}
