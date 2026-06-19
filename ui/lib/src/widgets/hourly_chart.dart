import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../format.dart';
import '../models/pulse.dart';
import '../state/settings_store.dart' show ChartType;

/// HourlyChart:某站点(实例)下所有账户的小时级 token 用量图(柱状 / 曲线可切换)。
///
/// - 柱状:每小时一根堆叠柱,按账户分段着色,段高=该账户该小时 token(in+out+cache)。
/// - 曲线:每账户一条线(同色),y=该账户该小时 token。
/// - x 轴覆盖**整个选定窗口的每一小时**,无数据的小时也**留出空列/横坐标位置**;
///   即便整窗口无任何数据也渲染空图(只画坐标框)。
/// - 鼠标悬停 → **半透明** tooltip 展示该小时各账户 in/out/cache 明细与合计。
///
/// 数据来自 AccountPulse.hourly(core 固定下发最近 7d 小时序;本组件按 rangeHours 裁剪)。
class HourlyChart extends StatelessWidget {
  const HourlyChart({
    super.key,
    required this.accounts,
    required this.rangeHours,
    this.chartType = ChartType.bar,
  });

  /// 同一实例下的账户(顺序不影响着色:内部按 accountId 稳定排序分配颜色)。
  final List<AccountPulse> accounts;

  /// 显示的回看小时数(UI 裁剪;core 始终下发更大的窗口,改这个不触发刷新)。
  final int rangeHours;

  /// 图表样式:柱状 / 曲线。
  final ChartType chartType;

  static const double _areaHeight = 96; // 绘图区高
  static const double _minSlot = 13; // 每小时最小占位宽(不足则填满父宽,超出横向滚动)
  static const double _maxBarWidth = 26; // 柱宽上限(防小跨度时柱子过胖)

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (accounts.isEmpty) return const SizedBox.shrink();

    // 稳定着色:按 accountId 排序 → 索引 → 颜色。
    final ordered = [...accounts]
      ..sort((a, b) => a.accountId.compareTo(b.accountId));
    final colorOf = <String, Color>{};
    final nameOf = <String, String>{};
    for (var i = 0; i < ordered.length; i++) {
      final a = ordered[i];
      colorOf[a.accountId] = accountColor(i);
      nameOf[a.accountId] = a.name.isEmpty ? a.accountId : a.name;
    }

    // 连续小时桶(覆盖整个窗口,含空桶 → 留位;即使全空也渲染框)。
    final slots = _buildSlots(ordered, rangeHours);

    var barMax = 0, lineMax = 0;
    for (final s in slots) {
      if (s.total > barMax) barMax = s.total;
      for (final p in s.points.values) {
        if (p.sum > lineMax) lineMax = p.sum;
      }
    }
    final rawMax = (chartType == ChartType.line ? lineMax : barMax).toDouble();
    final maxY = rawMax > 0 ? rawMax * 1.18 : 1.0; // 全空也给个高度,画出坐标框

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
                // 动态柱宽:占位宽的 ~60%(留缝),封顶防过胖 → 小跨度也填满、不稀疏。
                final barWidth =
                    (slotW * 0.6).clamp(2.0, _maxBarWidth).toDouble();
                final chart = chartType == ChartType.line
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
      List<AccountPulse> ordered,
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
      for (final a in ordered) {
        final p = s.points[a.accountId];
        if (p == null) continue; // 该账户该小时无量 → 不堆叠该段
        final to = from + p.sum.toDouble();
        stack.add(BarChartRodStackItem(from, to, colorOf[a.accountId]!));
        from = to;
      }
      groups.add(BarChartGroupData(
        x: i,
        barRods: [
          BarChartRodData(
            toY: from, // 空桶 toY=0:不画柱但 x 位置仍保留
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
            getTooltipColor: (_) => cs.inverseSurface.withValues(alpha: 0.78),
            tooltipPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            tooltipMargin: 8,
            fitInsideHorizontally: true,
            fitInsideVertically: true,
            maxContentWidth: 280,
            // 用 groupIndex(确定为 int,且与 slots 顺序一致)做下标,
            // 避免 group.x 的数值类型当 List 下标。
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
      List<AccountPulse> ordered,
      Map<String, Color> colorOf,
      Map<String, String> nameOf,
      double maxY,
      int labelStep,
      ColorScheme cs) {
    final bars = <LineChartBarData>[];
    for (final a in ordered) {
      final spots = <FlSpot>[
        for (var i = 0; i < slots.length; i++)
          FlSpot(i.toDouble(), (slots[i].points[a.accountId]?.sum ?? 0).toDouble()),
      ];
      bars.add(LineChartBarData(
        spots: spots,
        isCurved: true,
        curveSmoothness: 0.25,
        color: colorOf[a.accountId],
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
        clipData: const FlClipData.all(), // 裁掉曲线在 0 附近的过冲
        lineBarsData: bars,
        lineTouchData: LineTouchData(
          enabled: true,
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => cs.inverseSurface.withValues(alpha: 0.78),
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

  // ---- 共用:底部小时标签(稀疏显示) ----
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

  // ---- tooltip:柱(整小时各账户明细) ----
  BarTooltipItem? _barTooltip(_Slot slot, List<AccountPulse> ordered,
      Map<String, Color> colorOf, Map<String, String> nameOf, ColorScheme cs) {
    if (slot.points.isEmpty) return null; // 空桶不弹
    final onInv = cs.onInverseSurface;
    final spans = <TextSpan>[];
    for (final a in ordered) {
      final p = slot.points[a.accountId];
      if (p == null) continue;
      spans.add(TextSpan(
        text: '\n${nameOf[a.accountId]}  ${_detail(p)}',
        style: TextStyle(
            color: colorOf[a.accountId],
            fontSize: 10.5,
            fontWeight: FontWeight.w500),
      ));
    }
    spans.add(TextSpan(
      text: '\n合计 ${fmtTokens(slot.total)} tok',
      style: TextStyle(color: onInv.withValues(alpha: 0.75), fontSize: 10),
    ));
    return BarTooltipItem(
      _head(slot.hour),
      TextStyle(color: onInv, fontSize: 11, fontWeight: FontWeight.w600),
      children: spans,
      textAlign: TextAlign.left,
    );
  }

  // ---- tooltip:线(被命中的各账户;首条带小时表头) ----
  List<LineTooltipItem?> _lineTooltip(
      List<LineBarSpot> spots,
      List<_Slot> slots,
      List<AccountPulse> ordered,
      Map<String, Color> colorOf,
      Map<String, String> nameOf,
      ColorScheme cs) {
    final onInv = cs.onInverseSurface;
    final out = <LineTooltipItem?>[];
    var headerPlaced = false;
    for (final s in spots) {
      final i = s.x.round();
      final acct = (s.barIndex >= 0 && s.barIndex < ordered.length)
          ? ordered[s.barIndex]
          : null;
      final p = (acct != null && i >= 0 && i < slots.length)
          ? slots[i].points[acct.accountId]
          : null;
      if (acct == null || p == null) {
        out.add(null); // 该账户该小时无量 → 不显示这条
        continue;
      }
      final line = '${nameOf[acct.accountId]}  ${_detail(p)}';
      final color = colorOf[acct.accountId];
      if (!headerPlaced) {
        headerPlaced = true;
        out.add(LineTooltipItem(
          _head(slots[i].hour),
          TextStyle(color: onInv, fontSize: 11, fontWeight: FontWeight.w600),
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

  // ---- 图例:账户色点 + 名字 ----
  Widget _legend(BuildContext context, List<AccountPulse> ordered,
      Map<String, Color> colorOf, Map<String, String> nameOf) {
    final style = Theme.of(context).textTheme.labelSmall;
    return Wrap(
      spacing: 10,
      runSpacing: 2,
      children: [
        for (final a in ordered)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: colorOf[a.accountId],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 3),
              Text(nameOf[a.accountId]!, style: style),
            ],
          ),
      ],
    );
  }

  /// 连续小时桶:从 nowHour-(hours-1) 到 nowHour 共 hours 个,逐小时;空桶也保留。
  List<_Slot> _buildSlots(List<AccountPulse> ordered, int hours) {
    final now = DateTime.now();
    final nowHour = DateTime(now.year, now.month, now.day, now.hour);
    final windowStart = nowHour.subtract(Duration(hours: hours - 1));

    // accountId -> (hourEpoch -> HourPoint),仅窗口内、有量的桶。
    final byAcct = <String, Map<int, HourPoint>>{};
    for (final a in ordered) {
      final m = <int, HourPoint>{};
      for (final p in a.hourly) {
        final hb = DateTime(p.hour.year, p.hour.month, p.hour.day, p.hour.hour);
        if (hb.isBefore(windowStart) || hb.isAfter(nowHour)) continue;
        if (p.sum <= 0) continue;
        m[hb.millisecondsSinceEpoch] = p;
      }
      byAcct[a.accountId] = m;
    }

    final slots = <_Slot>[];
    for (var k = hours - 1; k >= 0; k--) {
      final t = nowHour.subtract(Duration(hours: k));
      final epoch = t.millisecondsSinceEpoch;
      final points = <String, HourPoint>{};
      var total = 0;
      for (final a in ordered) {
        final p = byAcct[a.accountId]?[epoch];
        if (p == null) continue;
        points[a.accountId] = p;
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
  final Map<String, HourPoint> points; // accountId -> 该小时有量的账户用量
  final int total;
}
