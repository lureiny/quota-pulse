import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../format.dart';
import '../models/pulse.dart';
import '../state/settings_store.dart' show ChartType, ChartMetric;

/// HourlyChart:某站点(实例)的小时级 token 用量图(柱状 / 曲线可切换)。
///
/// 数据按 `dimension`(account/api_key/model/user/group)从 core 即时聚合而来
/// (本地 SQLite 原始事件 GROUP BY),每个维度值 = 一条「系列」,按系列着色。
/// - 柱状:每桶一根堆叠柱,按系列分段;曲线:每系列一条线。
/// - x 轴覆盖整个选定窗口;跨度大于可容纳柱数时按「整数小时」合并成桶(每桶=K 小时
///   累计,降精度但不丢准确度);无数据的桶也留位。
/// - 图例可点击开关单个系列;鼠标悬停 → 半透明、随主题 tooltip,列出该桶各系列明细与合计。
/// - 三态可辨:取数异常 / 该维度真无请求 / 本地尚未覆盖到该区间(灰色「未采集」带 + 按需补齐)。
class HourlyChart extends StatefulWidget {
  const HourlyChart({
    super.key,
    required this.instance,
    required this.dimension,
    required this.rangeHours,
    required this.chartType,
    required this.metric,
    required this.onMetricChanged,
    required this.fetchChart,
    required this.ensureCoverage,
  });

  final String instance;
  final String dimension; // account / api_key / model / user / group
  final int rangeHours;
  final ChartType chartType;
  final ChartMetric metric; // 度量:token 量 / 花费($)
  final ValueChanged<ChartMetric> onMetricChanged; // 图右上角小开关切度量(全局持久化)

  /// (instance, dimension, hours) → ChartData(本地查询,便宜)。
  final ChartData Function(String instance, String dimension, int hours)
      fetchChart;

  /// (instance, hours) → 触发按需回填,确保本地覆盖延伸到 now-hours(异步)。
  final void Function(String instance, int hours) ensureCoverage;

  @override
  State<HourlyChart> createState() => _HourlyChartState();
}

class _HourlyChartState extends State<HourlyChart> {
  static const double _areaHeight = 96;
  static const double _minSlot = 14; // 每根柱/桶的最小水平占位,据此定可容纳桶数
  static const double _maxBarWidth = 26;
  static const double _labelReserve = 18; // 底部小时标签预留高

  ChartData _data = const ChartData();
  final Set<String> _hidden = {}; // 被图例关掉的系列 key
  DateTime? _backfillStarted; // 本次未覆盖触发补齐的时刻(用于「补齐中」短时态)
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _data = _load(); // 直接赋值(initState 里不 setState),build 紧随其后。
    _maybeBackfill();
    // 随新事件 / 补齐进度,定时刷新(与快照 tick 解耦,避免每次重建都打 FFI)。
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
  }

  @override
  void didUpdateWidget(HourlyChart old) {
    super.didUpdateWidget(old);
    final dimOrInst =
        old.instance != widget.instance || old.dimension != widget.dimension;
    if (dimOrInst) {
      _hidden.clear(); // 维度/实例变 → 系列键变,清隐藏集
    }
    if (dimOrInst || old.rangeHours != widget.rangeHours) {
      _backfillStarted = null; // 新跨度 → 重置「补齐中」短时态
      _refresh();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  ChartData _load() {
    try {
      return widget.fetchChart(
          widget.instance, widget.dimension, widget.rangeHours);
    } catch (_) {
      return ChartData.failed;
    }
  }

  void _refresh() {
    final d = _load();
    if (!mounted) return;
    setState(() => _data = d);
    _maybeBackfill();
  }

  /// 区间未被本地覆盖 → 触发按需回填(Go 侧已对「已覆盖 / 在途」做幂等保护)。
  void _maybeBackfill() {
    if (_data.ok && !_data.fullyCovered) {
      _backfillStarted ??= DateTime.now();
      widget.ensureCoverage(widget.instance, widget.rangeHours);
    } else {
      _backfillStarted = null;
    }
  }

  // ---- 度量取值(token 量 / 花费):柱高、曲线、占比分母统一走这里,fl_chart 用 double ----
  double _val(HourPoint p) =>
      widget.metric == ChartMetric.cost ? p.cost : p.sum.toDouble();
  double _valOrZero(HourPoint? p) => p == null ? 0 : _val(p);
  double _slotVal(_Slot s) =>
      widget.metric == ChartMetric.cost ? s.costTotal : s.total.toDouble();

  /// tooltip 尾行「桶合计」:随度量显示花费或 token。
  String _totalLine(_Slot s) => widget.metric == ChartMetric.cost
      ? '桶合计 ${fmtCost(s.costTotal)}'
      : '合计 ${fmtTokens(s.total)} tok';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // 取数/解析异常:明确区别于「真无数据」,可点按重试。
    if (!_data.ok) {
      return _placeholder(cs,
          icon: Icons.error_outline,
          text: '数据获取异常,点按重试',
          onTap: _refresh);
    }

    final allSeries = _data.series;
    if (allSeries.isEmpty) {
      // 空:已覆盖整段 = 真没有请求;未覆盖 = 本地还没采到这么早,正在补齐。
      if (_data.fullyCovered) {
        return _placeholder(cs,
            icon: Icons.inbox_outlined, text: '该维度在所选区间暂无请求');
      }
      return _placeholder(cs, text: '本地尚未采集到该区间,正在补齐…', spinner: true);
    }

    // 稳定着色:按系列 key 排序 → 索引 → 颜色(对全部系列固定,隐藏不改色)。
    final ordered = [...allSeries]..sort((a, b) => a.key.compareTo(b.key));
    final colorOf = <String, Color>{};
    final nameOf = <String, String>{};
    for (var i = 0; i < ordered.length; i++) {
      final s = ordered[i];
      colorOf[s.key] = accountColor(i);
      nameOf[s.key] = s.name.isEmpty ? s.key : s.name;
    }
    final visible =
        ordered.where((s) => !_hidden.contains(s.key)).toList(growable: false);

    final now = DateTime.now();
    final nowHour = DateTime(now.year, now.month, now.day, now.hour);
    final windowStart = nowHour.subtract(Duration(hours: widget.rangeHours - 1));

    // 未采集带:落在覆盖水位之前的窗口时间比例(approximate 横向比例)。
    final uncoveredFrac = _uncoveredFraction(windowStart, nowHour);
    final fresh = _backfillStarted != null &&
        now.difference(_backfillStarted!) < const Duration(seconds: 90);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: _areaHeight,
            child: LayoutBuilder(
              builder: (context, c) {
                // 按可用宽度定桶:容纳不下逐小时就按整数小时合并(降精度不丢准确度)。
                final maxBars = (c.maxWidth / _minSlot)
                    .floor()
                    .clamp(1, widget.rangeHours);
                final bucketHours = (widget.rangeHours / maxBars).ceil();
                final slots =
                    _buildSlots(visible, windowStart, nowHour, bucketHours);

                var barMax = 0.0, lineMax = 0.0;
                for (final s in slots) {
                  final sv = _slotVal(s); // 堆叠柱高 = 桶内各系列度量之和
                  if (sv > barMax) barMax = sv;
                  for (final p in s.points.values) {
                    final pv = _val(p); // 曲线高 = 单系列度量
                    if (pv > lineMax) lineMax = pv;
                  }
                }
                final rawMax =
                    widget.chartType == ChartType.line ? lineMax : barMax;
                final maxY = rawMax > 0 ? rawMax * 1.18 : 1.0;
                final labelStep =
                    (slots.length / 6).ceil().clamp(1, slots.length).toInt();
                final slotW = c.maxWidth / slots.length;
                final barWidth =
                    (slotW * 0.6).clamp(2.0, _maxBarWidth).toDouble();

                // 只渲染可见系列(隐藏的从堆叠/曲线里彻底去掉,而非画成全 0 线)。
                final chart = widget.chartType == ChartType.line
                    ? _lineChart(
                        slots, visible, colorOf, nameOf, maxY, labelStep, cs)
                    : _barChart(slots, visible, colorOf, nameOf, maxY, labelStep,
                        barWidth, cs);

                return Stack(
                  children: [
                    chart,
                    if (uncoveredFrac > 0)
                      _uncoveredBand(c.maxWidth, uncoveredFrac, fresh, cs),
                    // 度量切换:小开关叠在图右上角(不占控件条),点选 token / 花费。
                    Positioned(top: 0, right: 0, child: _metricToggle(cs)),
                  ],
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

  // ---- 度量小开关(图右上角):Tk / $ 两格,点未选中的一格即切换(全局持久化)----
  Widget _metricToggle(ColorScheme cs) {
    Widget cell(String label, ChartMetric m) {
      final on = widget.metric == m;
      return InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: on ? null : () => widget.onMetricChanged(m),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: on ? cs.primary.withValues(alpha: 0.9) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(label,
              style: TextStyle(
                fontSize: 9,
                height: 1.3,
                color: on ? cs.onPrimary : cs.onSurfaceVariant,
                fontWeight: on ? FontWeight.w700 : FontWeight.w400,
              )),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
            color: cs.outlineVariant.withValues(alpha: 0.5), width: 0.6),
      ),
      padding: const EdgeInsets.all(1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          cell('Tk', ChartMetric.tokens),
          cell('\$', ChartMetric.cost),
        ],
      ),
    );
  }

  // ---- 占位(异常 / 空 / 补齐中) ----
  Widget _placeholder(ColorScheme cs,
      {IconData? icon, required String text, VoidCallback? onTap, bool spinner = false}) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (spinner)
          const SizedBox(
              width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
        else if (icon != null)
          Icon(icon, size: 14, color: cs.onSurfaceVariant),
        const SizedBox(width: 6),
        Text(text, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: SizedBox(
        height: _areaHeight,
        child: Center(
          child: onTap == null
              ? row
              : InkWell(borderRadius: BorderRadius.circular(6), onTap: onTap, child: Padding(padding: const EdgeInsets.all(6), child: row)),
        ),
      ),
    );
  }

  // ---- 未采集带:覆盖窗口左侧 frac 比例,半透明灰 + 右边界 + 标签 ----
  Widget _uncoveredBand(
      double width, double frac, bool fresh, ColorScheme cs) {
    return Positioned(
      left: 0,
      top: 0,
      bottom: _labelReserve,
      width: (width * frac).clamp(0.0, width),
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            color: cs.onSurface.withValues(alpha: 0.06),
            border: Border(
                right: BorderSide(
                    color: cs.outlineVariant.withValues(alpha: 0.7),
                    width: 1)),
          ),
          alignment: Alignment.topLeft,
          padding: const EdgeInsets.only(left: 4, top: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (fresh) ...[
                SizedBox(
                    width: 9,
                    height: 9,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.6, color: cs.onSurfaceVariant)),
                const SizedBox(width: 4),
              ],
              Text(fresh ? '补齐中…' : '未采集',
                  style: TextStyle(fontSize: 9, color: cs.onSurfaceVariant)),
            ],
          ),
        ),
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
        final to = from + _val(p);
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
          FlSpot(i.toDouble(), _valOrZero(slots[i].points[ser.key])),
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

  // ---- 共用:底部桶起始小时标签(稀疏) ----
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
            reservedSize: _labelReserve,
            interval: 1,
            getTitlesWidget: (value, meta) {
              final i = value.round();
              if (i < 0 || i >= slots.length || i % labelStep != 0) {
                return const SizedBox.shrink();
              }
              final h = slots[i].start;
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

  // ---- tooltip:柱(整桶各系列明细 + 桶区间) ----
  BarTooltipItem? _barTooltip(_Slot slot, List<UsageSeries> ordered,
      Map<String, Color> colorOf, Map<String, String> nameOf, ColorScheme cs) {
    if (slot.points.isEmpty) return null;
    final onText = cs.onSurface;
    final slotTotal = _slotVal(slot);
    final spans = <TextSpan>[];
    for (final ser in ordered) {
      final p = slot.points[ser.key];
      if (p == null) continue;
      spans.add(TextSpan(
        text: '\n${nameOf[ser.key]}  ${_detail(p, slotTotal)}',
        style: TextStyle(
            color: colorOf[ser.key],
            fontSize: 10.5,
            fontWeight: FontWeight.w500),
      ));
    }
    spans.add(TextSpan(
      text: '\n${_totalLine(slot)}',
      style: TextStyle(color: onText.withValues(alpha: 0.7), fontSize: 10),
    ));
    return BarTooltipItem(
      _head(slot),
      TextStyle(color: onText, fontSize: 11, fontWeight: FontWeight.w600),
      children: spans,
      textAlign: TextAlign.left,
    );
  }

  // ---- tooltip:线(被命中的各系列;首条带桶区间表头) ----
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
      final line = '${nameOf[ser.key]}  ${_detail(p, _slotVal(slots[i]))}';
      final color = colorOf[ser.key];
      if (!headerPlaced) {
        headerPlaced = true;
        out.add(LineTooltipItem(
          _head(slots[i]),
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

  /// 单系列明细:token 度量维持「入·出·缓 = 合计」;花费度量显示「$x.xx (占比%)」。
  /// slotTotal 为该桶当前度量的合计,用于算占比(为 0 时占比按 0,避免除零)。
  String _detail(HourPoint p, double slotTotal) {
    if (widget.metric == ChartMetric.cost) {
      final share = slotTotal > 0 ? (p.cost / slotTotal * 100).round() : 0;
      return '${fmtCost(p.cost)} ($share%)';
    }
    return '入${fmtTokens(p.input)}·出${fmtTokens(p.output)}·'
        '缓${fmtTokens(p.cacheCreate + p.cacheRead)} = ${fmtTokens(p.sum)}';
  }

  /// 桶表头:单小时桶显示 "MM-DD HH:00";多小时桶显示 "MM-DD HH:00–HH:00 · Nh累计"。
  String _head(_Slot s) {
    final a = s.start;
    final base =
        '${a.month.toString().padLeft(2, '0')}-${a.day.toString().padLeft(2, '0')} '
        '${a.hour.toString().padLeft(2, '0')}:00';
    if (s.spanHours <= 1) return base;
    final e = s.end;
    return '$base–${e.hour.toString().padLeft(2, '0')}:00 · ${s.spanHours}h累计';
  }

  // ---- 图例:系列色点 + 名字;点击开关该系列(隐藏置灰划线) ----
  Widget _legend(BuildContext context, List<UsageSeries> ordered,
      Map<String, Color> colorOf, Map<String, String> nameOf) {
    final style = Theme.of(context).textTheme.labelSmall;
    return Wrap(
      spacing: 10,
      runSpacing: 2,
      children: [
        for (final ser in ordered)
          _legendItem(ser, colorOf, nameOf, style),
      ],
    );
  }

  Widget _legendItem(UsageSeries ser, Map<String, Color> colorOf,
      Map<String, String> nameOf, TextStyle? style) {
    final hidden = _hidden.contains(ser.key);
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () => setState(() {
        if (!_hidden.remove(ser.key)) _hidden.add(ser.key);
      }),
      child: Opacity(
        opacity: hidden ? 0.4 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 1),
          child: Row(
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
              Text(
                nameOf[ser.key]!,
                style: style?.copyWith(
                    decoration:
                        hidden ? TextDecoration.lineThrough : TextDecoration.none),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 落在覆盖水位之前的窗口时间比例(0=全覆盖;>0=左侧该比例尚未采集)。
  double _uncoveredFraction(DateTime windowStart, DateTime nowHour) {
    final cov = _data.coverageFrom;
    if (cov == null || _data.fullyCovered) return 0;
    final windowEnd = nowHour.add(const Duration(hours: 1));
    final spanMin = windowEnd.difference(windowStart).inMinutes;
    if (spanMin <= 0) return 0;
    final uncoveredMin = cov.difference(windowStart).inMinutes;
    return (uncoveredMin / spanMin).clamp(0.0, 1.0);
  }

  /// 把窗口按 bucketHours 合并成桶:从 windowStart 起每 K 小时一桶,逐桶累加各系列;
  /// 空桶也保留(留位)。每桶值 = 该 K 小时内各系列的累计(降精度不丢准确度)。
  List<_Slot> _buildSlots(List<UsageSeries> series, DateTime windowStart,
      DateTime nowHour, int bucketHours) {
    final k = bucketHours < 1 ? 1 : bucketHours;
    final hours = nowHour.difference(windowStart).inHours + 1;
    final nB = (hours / k).ceil();
    final lastHour = nowHour.add(const Duration(hours: 1));

    // bucketIndex -> seriesKey -> [in,out,cacheCreate,cacheRead];cost 走并行的 double 累加器。
    final acc = List.generate(nB, (_) => <String, List<int>>{});
    final costAcc = List.generate(nB, (_) => <String, double>{});
    for (final ser in series) {
      for (final p in ser.points) {
        final hb = DateTime(p.hour.year, p.hour.month, p.hour.day, p.hour.hour);
        if (hb.isBefore(windowStart) || hb.isAfter(nowHour)) continue;
        if (p.sum <= 0 && p.cost <= 0) continue; // 两个度量都空才跳过
        final offset = hb.difference(windowStart).inHours;
        final bi = (offset ~/ k).clamp(0, nB - 1);
        final v = acc[bi].putIfAbsent(ser.key, () => [0, 0, 0, 0]);
        v[0] += p.input;
        v[1] += p.output;
        v[2] += p.cacheCreate;
        v[3] += p.cacheRead;
        costAcc[bi][ser.key] = (costAcc[bi][ser.key] ?? 0) + p.cost;
      }
    }

    final slots = <_Slot>[];
    for (var bi = 0; bi < nB; bi++) {
      final start = windowStart.add(Duration(hours: bi * k));
      var end = start.add(Duration(hours: k));
      if (end.isAfter(lastHour)) end = lastHour;
      final points = <String, HourPoint>{};
      var total = 0;
      var costTotal = 0.0;
      for (final ser in series) {
        final v = acc[bi][ser.key];
        if (v == null) continue;
        final sum = v[0] + v[1] + v[2] + v[3];
        final cost = costAcc[bi][ser.key] ?? 0;
        if (sum <= 0 && cost <= 0) continue;
        points[ser.key] = HourPoint(
          hour: start,
          input: v[0],
          output: v[1],
          cacheCreate: v[2],
          cacheRead: v[3],
          total: sum,
          cost: cost,
        );
        total += sum;
        costTotal += cost;
      }
      slots.add(_Slot(start, end, points, total, costTotal));
    }
    return slots;
  }
}

class _Slot {
  _Slot(this.start, this.end, this.points, this.total, this.costTotal);
  final DateTime start; // 桶起始小时
  final DateTime end; // 桶结束(exclusive,clamp 到 now+1h)
  final Map<String, HourPoint> points; // seriesKey -> 该桶累计(有量的系列)
  final int total; // 桶内 token 合计
  final double costTotal; // 桶内花费合计(USD)
  int get spanHours => end.difference(start).inHours;
}
