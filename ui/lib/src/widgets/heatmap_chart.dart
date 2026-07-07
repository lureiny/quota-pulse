import 'dart:async';

import 'package:flutter/material.dart';

import '../format.dart';
import '../models/pulse.dart';
import '../state/settings_store.dart' show ChartMetric;

/// HeatmapChart:某站点(实例)的 GitHub 贡献图式**按天**用量热力图。
///
/// 一天一个强度格子、列=周(7 行=星期几,周日在上)、顶部标月份、左侧标星期。
/// - 数据按 `dimension` 从 core 即时聚合(本地 SQLite 原始事件 GROUP BY day_local)。
///   `heatmapValue` 为空=聚合(跨所有维度值求和),否则只看该维度值一条序列。
/// - 强度随度量(token/花费/次数)着色;单色系 4 档(见 format.heatCell)。
/// - 默认「最近 12 个月」;可下拉选某一整年。悬停格子 → 浮层显示日期 + 值。
/// - 历史需拉全量:core 已 keep-all(不淘汰),这里按需触发补拉并显示「补齐中 %」。
class HeatmapChart extends StatefulWidget {
  const HeatmapChart({
    super.key,
    required this.instance,
    required this.dimension,
    required this.metric,
    required this.onMetricChanged,
    required this.heatmapYear,
    required this.heatmapValue,
    required this.onHeatmapViewChanged,
    required this.fetchDailyChart,
    required this.ensureCoverage,
    required this.fetchCoverage,
  });

  final String instance;
  final String dimension; // account / api_key / model / user / group
  final ChartMetric metric;
  final ValueChanged<ChartMetric> onMetricChanged;
  final int? heatmapYear; // null=最近 12 个月;否则某一整年
  final String? heatmapValue; // null/''=全部(聚合);否则某维度值(series.key)
  final void Function(int? year, String? value) onHeatmapViewChanged;

  /// (instance, dimension, days) → 按天 ChartData(本地查询,便宜)。
  final ChartData Function(String instance, String dimension, int days)
      fetchDailyChart;

  /// (instance, hours) → 触发按需回填(异步)。
  final void Function(String instance, int hours) ensureCoverage;

  /// (instance) → 覆盖状态(水位 + 最早事件),供进度/年份列表。
  final Coverage Function(String instance) fetchCoverage;

  @override
  State<HeatmapChart> createState() => _HeatmapChartState();
}

class _HeatmapChartState extends State<HeatmapChart> {
  static const double _gap = 2; // 格子间距
  static const double _cellMin = 4;
  static const double _cellMax = 13;
  static const double _labelW = 16; // 左侧星期标签列宽
  static const double _monthRowH = 13; // 顶部月份标签行高

  ChartData _data = const ChartData();
  Coverage _coverage = Coverage.empty;
  DateTime? _backfillStarted;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _data = _load();
    _coverage = _loadCoverage();
    _maybeBackfill();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
  }

  @override
  void didUpdateWidget(HeatmapChart old) {
    super.didUpdateWidget(old);
    // 实例/维度/年份变 → 查询窗口变,需重取;度量/值是纯客户端(重建即可)。
    if (old.instance != widget.instance ||
        old.dimension != widget.dimension ||
        old.heatmapYear != widget.heatmapYear) {
      _backfillStarted = null;
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
      return widget.fetchDailyChart(
          widget.instance, widget.dimension, _daysToRequest());
    } catch (_) {
      return ChartData.failed;
    }
  }

  Coverage _loadCoverage() {
    try {
      return widget.fetchCoverage(widget.instance);
    } catch (_) {
      return Coverage.empty;
    }
  }

  void _refresh() {
    final d = _load();
    final c = _loadCoverage();
    if (!mounted) return;
    setState(() {
      _data = d;
      _coverage = c;
    });
    _maybeBackfill();
  }

  void _maybeBackfill() {
    if (_data.ok && !_data.fullyCovered) {
      _backfillStarted ??= DateTime.now();
      widget.ensureCoverage(widget.instance, _daysToRequest() * 24);
    } else {
      _backfillStarted = null;
    }
  }

  // ---- 时间窗口 ----

  DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  /// 该日所在周的周日(GitHub 周从周日起)。Dart weekday: Mon=1..Sun=7。
  DateTime _weekStartSunday(DateTime d) =>
      _dayOnly(d).subtract(Duration(days: d.weekday % 7));

  /// 有效年份:落在 [earliest, now] 内才用,否则回退最近 12 个月(null)。
  int? _effectiveYear() {
    final y = widget.heatmapYear;
    if (y == null) return null;
    final curY = DateTime.now().year;
    final earliestY = _coverage.earliestEvent?.year ?? curY;
    return (y >= earliestY && y <= curY) ? y : null;
  }

  /// 网格左界(周日):最近 12 个月=当前周往前 52 周;某年=该年 1/1 所在周。
  DateTime _gridStartWeek() {
    final y = _effectiveYear();
    if (y == null) {
      return _weekStartSunday(DateTime.now())
          .subtract(const Duration(days: 52 * 7));
    }
    return _weekStartSunday(DateTime(y, 1, 1));
  }

  /// 窗口右界(含):最近 12 个月=今天;某年=min(该年 12/31, 今天)。
  DateTime _displayEnd() {
    final y = _effectiveYear();
    final today = _dayOnly(DateTime.now());
    if (y == null) return today;
    final yEnd = DateTime(y, 12, 31);
    return yEnd.isAfter(today) ? today : yEnd;
  }

  /// 窗口左界(含):最近 12 个月=网格左界;某年=该年 1/1。
  DateTime _displayStart() {
    final y = _effectiveYear();
    return y == null ? _gridStartWeek() : DateTime(y, 1, 1);
  }

  /// 要向 core 请求的天数:从网格左界一路覆盖到今天(core 返回 [today-days, today])。
  int _daysToRequest() {
    final today = _dayOnly(DateTime.now());
    final days = today.difference(_gridStartWeek()).inDays + 1;
    return days < 1 ? 1 : days;
  }

  int _weekCount() {
    final start = _gridStartWeek();
    final lastWeek = _weekStartSunday(_displayEnd());
    return (lastWeek.difference(start).inDays ~/ 7) + 1;
  }

  // ---- 取值 ----

  /// 每天的度量合计(按 heatmapValue 过滤或聚合)。key=当天零点。
  Map<DateTime, double> _valueByDay(String? effectiveValue) {
    final out = <DateTime, double>{};
    for (final s in _data.series) {
      if (effectiveValue != null && s.key != effectiveValue) continue;
      for (final p in s.points) {
        final day = _dayOnly(p.hour);
        out[day] = (out[day] ?? 0.0) + metricValue(p, widget.metric);
      }
    }
    return out;
  }

  /// 着色分母:窗口内非零日值的 p95(抗单日暴量冲淡刻度)。<=0 时返回 1(全空格)。
  double _maxValue(Map<DateTime, double> byDay) {
    final vals = byDay.values.where((v) => v > 0).toList()..sort();
    if (vals.isEmpty) return 1;
    final idx = ((vals.length - 1) * 0.95).round().clamp(0, vals.length - 1);
    final m = vals[idx];
    return m > 0 ? m : 1;
  }

  String _fmtVal(double v) {
    if (v <= 0) return '无';
    return switch (widget.metric) {
      ChartMetric.tokens => '${fmtTokens(v.round())} tok',
      ChartMetric.cost => fmtCost(v),
      ChartMetric.count => '${fmtCount(v.round())} 次',
    };
  }

  String _ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 补齐进度(0~1);未知(缺水位/最早事件)返回 null。
  double? _progress() {
    final cov = _coverage.coverageFrom, earliest = _coverage.earliestEvent;
    if (cov == null || earliest == null) return null;
    final now = DateTime.now();
    final total = now.difference(earliest).inSeconds;
    if (total <= 0) return 1;
    return (now.difference(cov).inSeconds / total).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (!_data.ok) {
      return _placeholder(cs,
          icon: Icons.error_outline, text: '数据获取异常,点按重试', onTap: _refresh);
    }

    final effectiveValue = _effectiveValue();
    final byDay = _valueByDay(effectiveValue);
    final maxV = _maxValue(byDay);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _controls(cs, effectiveValue),
          _progressChip(cs),
          const SizedBox(height: 4),
          LayoutBuilder(
            builder: (context, c) => _grid(c.maxWidth, byDay, maxV, cs),
          ),
          const SizedBox(height: 6),
          _legend(cs),
        ],
      ),
    );
  }

  String? _effectiveValue() {
    final v = widget.heatmapValue;
    if (v == null || v.isEmpty) return null;
    return _data.series.any((s) => s.key == v) ? v : null;
  }

  // ---- 网格 ----

  Widget _grid(double availWidth, Map<DateTime, double> byDay, double maxV,
      ColorScheme cs) {
    final weeks = _weekCount();
    final gridStart = _gridStartWeek();
    final displayStart = _displayStart();
    final displayEnd = _displayEnd();
    final today = _dayOnly(DateTime.now());
    final covDay = _coverage.coverageFrom != null
        ? _dayOnly(_coverage.coverageFrom!)
        : null;
    final earliestDay =
        _coverage.earliestEvent != null ? _dayOnly(_coverage.earliestEvent!) : null;

    // 单元占位边长:填满可用宽度,夹到 [min,max]。放不下则横向滚动。
    final rawCell = (availWidth - _labelW) / weeks - _gap;
    final cell = rawCell.clamp(_cellMin, _cellMax).toDouble();
    final slot = cell + _gap;

    Color colorFor(DateTime date) {
      // 覆盖水位之前(且在最早事件之后)= 尚未补齐;之前无数据 = 空格。
      if (covDay != null && date.isBefore(covDay)) {
        if (earliestDay != null && date.isBefore(earliestDay)) {
          return heatEmptyCell(cs);
        }
        return cs.onSurface.withValues(alpha: 0.16); // 未采集/补齐中
      }
      return heatCell(byDay[date] ?? 0.0, maxV, cs);
    }

    String tipFor(DateTime date) {
      if (covDay != null && date.isBefore(covDay)) {
        if (earliestDay != null && date.isBefore(earliestDay)) {
          return '${_ymd(date)} · 无';
        }
        return '${_ymd(date)} · 未采集';
      }
      return '${_ymd(date)} · ${_fmtVal(byDay[date] ?? 0.0)}';
    }

    Widget dayCell(int w, int r) {
      final date = gridStart.add(Duration(days: w * 7 + r));
      final inWindow = !date.isBefore(displayStart) &&
          !date.isAfter(displayEnd) &&
          !date.isAfter(today);
      if (!inWindow) {
        return SizedBox(width: slot, height: slot); // 未来/窗口外:透明占位
      }
      return Padding(
        padding: const EdgeInsets.all(_gap / 2),
        child: Tooltip(
          message: tipFor(date),
          waitDuration: const Duration(milliseconds: 300),
          child: Container(
            width: cell,
            height: cell,
            decoration: BoxDecoration(
              color: colorFor(date),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      );
    }

    // 月份标签行:某列的周里含某月 1 号 → 在该列上方标「N月」。
    String? monthLabel(int w) {
      final colSunday = gridStart.add(Duration(days: w * 7));
      for (var r = 0; r < 7; r++) {
        final d = colSunday.add(Duration(days: r));
        if (d.day == 1 && !d.isAfter(displayEnd) && !d.isBefore(displayStart)) {
          return '${d.month}月';
        }
      }
      return null;
    }

    final monthRow = Row(
      children: [
        for (var w = 0; w < weeks; w++)
          SizedBox(
            width: slot,
            height: _monthRowH,
            child: monthLabel(w) == null
                ? null
                : Align(
                    alignment: Alignment.centerLeft,
                    child: Text(monthLabel(w)!,
                        style: TextStyle(
                            fontSize: 9, color: cs.onSurfaceVariant)),
                  ),
          ),
      ],
    );

    // 左侧星期标签(周一/三/五)。
    const weekdayLabels = {1: '一', 3: '三', 5: '五'};
    final weekdayCol = Column(
      children: [
        for (var r = 0; r < 7; r++)
          SizedBox(
            width: _labelW,
            height: slot,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(weekdayLabels[r] ?? '',
                  style: TextStyle(fontSize: 8, color: cs.onSurfaceVariant)),
            ),
          ),
      ],
    );

    final gridRow = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var w = 0; w < weeks; w++)
          Column(
            children: [for (var r = 0; r < 7; r++) dayCell(w, r)],
          ),
      ],
    );

    final needed = _labelW + weeks * slot;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [SizedBox(width: _labelW), monthRow]),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [weekdayCol, gridRow],
        ),
      ],
    );

    // 放不下(格子已到下限仍溢出)→ 横向滚动;否则直接铺开。
    if (needed > availWidth + 0.5) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: body,
      );
    }
    return body;
  }

  // ---- 控件行:度量切换 + 年份下拉 + 值下拉 ----

  Widget _controls(ColorScheme cs, String? effectiveValue) {
    return Row(
      children: [
        _metricToggle(cs),
        const SizedBox(width: 10),
        _yearDropdown(cs),
        const SizedBox(width: 8),
        Flexible(child: _valueDropdown(cs, effectiveValue)),
      ],
    );
  }

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
          cell('次', ChartMetric.count),
        ],
      ),
    );
  }

  Widget _yearDropdown(ColorScheme cs) {
    final curY = DateTime.now().year;
    final earliestY = _coverage.earliestEvent?.year ?? curY;
    final years = <int?>[null, for (var y = curY; y >= earliestY; y--) y];
    final value = _effectiveYear();
    final style = TextStyle(fontSize: 11, color: cs.onSurface);
    return DropdownButton<int?>(
      value: value,
      isDense: true,
      underline: const SizedBox.shrink(),
      style: style,
      items: [
        for (final y in years)
          DropdownMenuItem<int?>(
            value: y,
            child: Text(y == null ? '最近 12 个月' : '$y 年', style: style),
          ),
      ],
      onChanged: (y) => widget.onHeatmapViewChanged(y, widget.heatmapValue),
    );
  }

  Widget _valueDropdown(ColorScheme cs, String? effectiveValue) {
    final style = TextStyle(fontSize: 11, color: cs.onSurface);
    final ordered = [..._data.series]..sort((a, b) => a.key.compareTo(b.key));
    return DropdownButton<String?>(
      value: effectiveValue,
      isDense: true,
      isExpanded: true,
      underline: const SizedBox.shrink(),
      style: style,
      items: [
        DropdownMenuItem<String?>(
            value: null, child: Text('全部(聚合)', style: style)),
        for (final s in ordered)
          DropdownMenuItem<String?>(
            value: s.key,
            child: Text(s.name.isEmpty ? s.key : s.name,
                overflow: TextOverflow.ellipsis, style: style),
          ),
      ],
      onChanged: (v) => widget.onHeatmapViewChanged(widget.heatmapYear, v),
    );
  }

  // ---- 补齐进度条 ----

  Widget _progressChip(ColorScheme cs) {
    if (_data.fullyCovered) return const SizedBox.shrink();
    final p = _progress();
    final label = p == null ? '补齐历史中…' : '补齐历史中 ${(p * 100).round()}%';
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
              width: 9,
              height: 9,
              child: CircularProgressIndicator(
                  strokeWidth: 1.6, color: cs.onSurfaceVariant)),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(fontSize: 9, color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  // ---- 图例:少 [空][档1..4] 多 ----

  Widget _legend(ColorScheme cs) {
    Widget sw(Color c) => Container(
          width: 9,
          height: 9,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration:
              BoxDecoration(color: c, borderRadius: BorderRadius.circular(2)),
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('少', style: TextStyle(fontSize: 9, color: cs.onSurfaceVariant)),
        const SizedBox(width: 3),
        sw(heatEmptyCell(cs)),
        for (final a in kHeatLevelAlphas) sw(cs.primary.withValues(alpha: a)),
        const SizedBox(width: 3),
        Text('多', style: TextStyle(fontSize: 9, color: cs.onSurfaceVariant)),
      ],
    );
  }

  // ---- 占位(取数异常) ----

  Widget _placeholder(ColorScheme cs,
      {IconData? icon, required String text, VoidCallback? onTap}) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) Icon(icon, size: 14, color: cs.onSurfaceVariant),
        const SizedBox(width: 6),
        Text(text, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Center(
        child: onTap == null
            ? row
            : InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: onTap,
                child: Padding(padding: const EdgeInsets.all(6), child: row)),
      ),
    );
  }
}
