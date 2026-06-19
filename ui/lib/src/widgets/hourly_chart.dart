import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../format.dart';
import '../models/pulse.dart';

/// HourlyChart:某站点(实例)下所有账户的小时级 token 用量**堆叠柱状图**。
///
/// x 轴 = 小时;每根柱子按账户分段着色,段高 = 该账户该小时的 token 用量
/// (input+output+cache 之和);鼠标悬停某根柱子 → tooltip 列出该小时各账户的
/// in/out/cache 明细与合计。某账户该小时无调用则不堆叠该段。
///
/// 数据来自 AccountPulse.hourly(core 随快照下发,见 provider.TrendFetcher)。
/// 组内账户全部无小时数据时不渲染(返回 SizedBox.shrink)。
class HourlyChart extends StatelessWidget {
  const HourlyChart({
    super.key,
    required this.accounts,
    required this.rangeHours,
  });

  /// 同一实例下的账户(顺序不影响着色:内部按 accountId 稳定排序分配颜色)。
  final List<AccountPulse> accounts;

  /// 显示的回看小时数(与设置一致;实际仅渲染有数据起点至今的连续小时)。
  final int rangeHours;

  static const double _barHeight = 96; // 绘图区高
  static const double _minSlot = 16; // 每根柱子最小占位宽(不足填满父宽,超出横向滚动)

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // 1) 稳定着色顺序:按 accountId 排序,索引→颜色,避免按使用率排序导致颜色乱跳。
    final ordered = [...accounts]
      ..sort((a, b) => a.accountId.compareTo(b.accountId));
    final colorOf = <String, Color>{};
    final nameOf = <String, String>{};
    for (var i = 0; i < ordered.length; i++) {
      final a = ordered[i];
      colorOf[a.accountId] = accountColor(i);
      nameOf[a.accountId] = a.name.isEmpty ? a.accountId : a.name;
    }

    // 2) 收集窗口内的小时桶:[max(now-range, 最早数据), now] 连续逐小时。
    final slots = _buildSlots(ordered, rangeHours);
    if (slots.isEmpty) return const SizedBox.shrink();

    double maxY = 0;
    for (final s in slots) {
      if (s.total > maxY) maxY = s.total.toDouble();
    }
    if (maxY <= 0) return const SizedBox.shrink();

    // 3) 柱组:每个小时一根堆叠柱。
    final groups = <BarChartGroupData>[];
    for (var i = 0; i < slots.length; i++) {
      final s = slots[i];
      final stack = <BarChartRodStackItem>[];
      double from = 0;
      for (final seg in s.segs) {
        final to = from + seg.point.sum.toDouble();
        stack.add(BarChartRodStackItem(from, to, colorOf[seg.accountId]!));
        from = to;
      }
      groups.add(BarChartGroupData(
        x: i,
        barRods: [
          BarChartRodData(
            toY: from,
            width: 9,
            rodStackItems: stack,
            borderRadius: const BorderRadius.all(Radius.circular(1.5)),
          ),
        ],
      ));
    }

    // 底部小时标签:稀疏显示(约 6 个),避免拥挤。
    final labelStep = (slots.length / 6).ceil().clamp(1, slots.length).toInt();

    final chart = BarChart(
      BarChartData(
        maxY: maxY * 1.15,
        alignment: BarChartAlignment.spaceAround,
        barGroups: groups,
        barTouchData: BarTouchData(
          enabled: true,
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => cs.inverseSurface,
            tooltipPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            tooltipMargin: 8,
            fitInsideHorizontally: true,
            fitInsideVertically: true,
            maxContentWidth: 260,
            getTooltipItem: (group, _, __, ___) =>
                _tooltip(slots[group.x], cs, nameOf),
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 18,
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
                    style: TextStyle(
                      fontSize: 9,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: _barHeight,
            child: LayoutBuilder(
              builder: (context, c) {
                final needed = slots.length * _minSlot;
                if (needed <= c.maxWidth) return chart;
                // 柱子太多:横向滚动,保持小时粒度可读。
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(width: needed, child: chart),
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

  // ---- tooltip:某小时各账户明细 ----
  BarTooltipItem _tooltip(
      _Slot slot, ColorScheme cs, Map<String, String> nameOf) {
    final onInv = cs.onInverseSurface;
    final h = slot.hour;
    final head = '${h.month.toString().padLeft(2, '0')}-'
        '${h.day.toString().padLeft(2, '0')} '
        '${h.hour.toString().padLeft(2, '0')}:00';

    final spans = <TextSpan>[];
    for (final seg in slot.segs) {
      final p = seg.point;
      spans.add(TextSpan(
        text: '\n${nameOf[seg.accountId]}  '
            '入${fmtTokens(p.input)}·出${fmtTokens(p.output)}·'
            '缓${fmtTokens(p.cacheCreate + p.cacheRead)} = ${fmtTokens(p.sum)}',
        style: TextStyle(
          color: seg.color,
          fontSize: 10.5,
          fontWeight: FontWeight.w500,
        ),
      ));
    }
    spans.add(TextSpan(
      text: '\n合计 ${fmtTokens(slot.total)} tok',
      style: TextStyle(
        color: onInv.withValues(alpha: 0.75),
        fontSize: 10,
      ),
    ));

    return BarTooltipItem(
      head,
      TextStyle(color: onInv, fontSize: 11, fontWeight: FontWeight.w600),
      children: spans,
      textAlign: TextAlign.left,
    );
  }

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

  /// 把各账户的 hourly 折叠成连续小时桶。起点 = max(now-range, 最早有数据的小时),
  /// 终点 = 当前小时;每桶内按 ordered 顺序排列有量的账户段。
  List<_Slot> _buildSlots(List<AccountPulse> ordered, int hours) {
    final now = DateTime.now();
    final nowHour = DateTime(now.year, now.month, now.day, now.hour);
    final windowStart = nowHour.subtract(Duration(hours: hours));

    // accountId -> (hourEpoch -> HourPoint),并记录窗口内最早数据小时。
    final byAcct = <String, Map<int, HourPoint>>{};
    DateTime? earliest;
    for (final a in ordered) {
      final m = <int, HourPoint>{};
      for (final p in a.hourly) {
        final hb = DateTime(p.hour.year, p.hour.month, p.hour.day, p.hour.hour);
        if (hb.isBefore(windowStart) || hb.isAfter(nowHour)) continue;
        if (p.sum <= 0) continue;
        m[hb.millisecondsSinceEpoch] = p;
        if (earliest == null || hb.isBefore(earliest!)) earliest = hb;
      }
      byAcct[a.accountId] = m;
    }
    if (earliest == null) return const [];

    final slots = <_Slot>[];
    for (var t = earliest!;
        !t.isAfter(nowHour);
        t = t.add(const Duration(hours: 1))) {
      final epoch = t.millisecondsSinceEpoch;
      final segs = <_Seg>[];
      var total = 0;
      for (final a in ordered) {
        final p = byAcct[a.accountId]?[epoch];
        if (p == null) continue;
        segs.add(_Seg(a.accountId, _accountColorFor(ordered, a.accountId), p));
        total += p.sum;
      }
      slots.add(_Slot(t, segs, total));
    }
    return slots;
  }
}

/// 按 ordered 中的位置取账户色(供 _buildSlots 复用同一着色规则)。
Color _accountColorFor(List<AccountPulse> ordered, String accountId) {
  final i = ordered.indexWhere((a) => a.accountId == accountId);
  return accountColor(i < 0 ? 0 : i);
}

class _Slot {
  _Slot(this.hour, this.segs, this.total);
  final DateTime hour;
  final List<_Seg> segs;
  final int total;
}

class _Seg {
  _Seg(this.accountId, this.color, this.point);
  final String accountId;
  final Color color;
  final HourPoint point;
}
