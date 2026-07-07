import 'package:flutter/material.dart';

import 'models/pulse.dart';
import 'state/settings_store.dart' show ChartMetric;

// macOS 系统色
const _green = Color(0xFF34C759);
const _amber = Color(0xFFFF9F0A);
const _red = Color(0xFFFF3B30);
const _orange = Color(0xFFFF9500);
const _purple = Color(0xFFAF52DE);
const _grey = Color(0xFF8E8E93);

Color statusColor(PulseStatus s) => switch (s) {
      PulseStatus.ok => _green,
      PulseStatus.warning => _amber,
      PulseStatus.rateLimited => _red,
      PulseStatus.forbidden => _red,
      PulseStatus.banned => _purple,
      PulseStatus.needsReauth => _orange,
      PulseStatus.error => _grey,
      PulseStatus.unknown => _grey,
    };

String statusLabel(PulseStatus s) => switch (s) {
      PulseStatus.ok => '正常',
      PulseStatus.warning => '接近上限',
      PulseStatus.rateLimited => '已限流',
      PulseStatus.forbidden => '受限',
      PulseStatus.banned => '已封禁',
      PulseStatus.needsReauth => '需重新授权',
      PulseStatus.error => '错误',
      PulseStatus.unknown => '—',
    };

/// 进度条颜色:按使用率分档。
Color meterColor(double? u) {
  if (u == null) return _grey;
  if (u >= 1.0) return _red;
  if (u >= 0.8) return _amber;
  return _green;
}

/// 账户着色调色板(小时图表按账户分色)。~12 色去重,头部沿用 macOS 系统色,
/// 其后补一组色相/明度分散的色,深浅主题下都够清晰;账户超过 12 个则循环复用。
const List<Color> _chartPalette = [
  Color(0xFF34C759), // green
  Color(0xFF0A84FF), // blue
  Color(0xFFFF9F0A), // amber
  Color(0xFFAF52DE), // purple
  Color(0xFFFF375F), // pink
  Color(0xFF64D2FF), // cyan
  Color(0xFFFFD60A), // yellow
  Color(0xFF30D158), // light green
  Color(0xFFBF5AF2), // light purple
  Color(0xFFFF6482), // rose
  Color(0xFF5E5CE6), // indigo
  Color(0xFFAC8E68), // tan
];

/// 取第 i 个账户的稳定颜色(循环复用调色板)。
Color accountColor(int i) => _chartPalette[i % _chartPalette.length];

/// 某小时/日桶在所选度量下的取值(token 之和 / 花费 / 请求次数)。三者正交,
/// 小时图与热力图共用此提取器,单一口径。
double metricValue(HourPoint p, ChartMetric m) => switch (m) {
      ChartMetric.tokens => p.sum.toDouble(),
      ChartMetric.cost => p.cost,
      ChartMetric.count => p.count.toDouble(),
    };

/// 热力图 GitHub 式绿色强度阶梯(4 档,由浅到深),按明暗主题各一套 —— 固定绿色
/// 保证浅色模式也清晰可辨(不再用浅底上的淡色 alpha)。
const List<Color> _heatGreenLight = [
  Color(0xFF9BE9A8),
  Color(0xFF40C463),
  Color(0xFF30A14E),
  Color(0xFF216E39),
];
const List<Color> _heatGreenDark = [
  Color(0xFF0E4429),
  Color(0xFF006D32),
  Color(0xFF26A641),
  Color(0xFF39D353),
];

/// 当前主题的热力图 4 档绿色(格子与图例共用同一阶梯)。
List<Color> heatRamp(ColorScheme cs) =>
    cs.brightness == Brightness.dark ? _heatGreenDark : _heatGreenLight;

/// 空格(0 值)填充色:中性灰,浅色模式下也要清晰可辨(别太淡看不清格子)。
Color heatEmptyCell(ColorScheme cs) => cs.onSurface
    .withValues(alpha: cs.brightness == Brightness.dark ? 0.11 : 0.16);

/// 热力图格子色:GitHub 式绿色强度阶梯。value<=0 或 maxValue<=0 → 空格色;
/// 否则按 value/maxValue 分 4 档取绿。
Color heatCell(double value, double maxValue, ColorScheme cs) {
  if (value <= 0 || maxValue <= 0) return heatEmptyCell(cs);
  final r = (value / maxValue).clamp(0.0, 1.0);
  final i = r <= 0.25
      ? 0
      : r <= 0.5
          ? 1
          : r <= 0.75
              ? 2
              : 3;
  return heatRamp(cs)[i];
}

/// 紧凑整数 → "1.2K" / "3.4M" / "1.2B"(千/百万/十亿;与 core mapper 的 humanInt 口径一致)。
/// token 与请求次数同量级、共用此口径(见 fmtCount)。
String fmtTokens(int n) {
  if (n >= 1000000000) return '${(n / 1e9).toStringAsFixed(1)}B';
  if (n >= 1000000) return '${(n / 1e6).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1e3).toStringAsFixed(1)}K';
  return '$n';
}

/// 请求次数 → 复用 token 的 K/M/B 紧凑格式(整数同量级,口径统一)。
String fmtCount(int n) => fmtTokens(n);

/// 花费(USD)→ "$12.34" / "$1.2K" / "$3.4M" / "$1.2B"。小额自适应加精度(单条请求可能只几厘)。
String fmtCost(double v) {
  if (v <= 0) return r'$0';
  if (v >= 1e9) return '\$${(v / 1e9).toStringAsFixed(1)}B';
  if (v >= 1e6) return '\$${(v / 1e6).toStringAsFixed(1)}M';
  if (v >= 1000) return '\$${(v / 1e3).toStringAsFixed(1)}K';
  if (v >= 1) return '\$${v.toStringAsFixed(2)}';
  if (v >= 0.01) return '\$${v.toStringAsFixed(3)}';
  return '\$${v.toStringAsFixed(4)}';
}

/// 字节数 → "1.2 KB" / "3.4 MB"(1024 进制,调试面板用)。
String fmtBytes(num n) {
  final v = n.toDouble();
  if (v < 1024) return '${v.toStringAsFixed(0)} B';
  if (v < 1024 * 1024) return '${(v / 1024).toStringAsFixed(1)} KB';
  if (v < 1024 * 1024 * 1024) return '${(v / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(v / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// 把剩余秒数格式化为 "2天3h" / "3h13m" / "45m" / "30s"。0 天不显示天。
String fmtDuration(int secs) {
  if (secs <= 0) return '';
  final d = secs ~/ 86400;
  final h = (secs % 86400) ~/ 3600;
  final m = (secs % 3600) ~/ 60;
  if (d > 0) return h > 0 ? '$d天${h}h' : '$d天';
  if (h > 0) return '${h}h${m}m';
  if (m > 0) return '${m}m';
  return '${secs}s';
}

/// 绝对重置时刻(本地)"MM-dd HH:mm"。
String fmtResetAt(DateTime t) {
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

/// 统一的"重置"短语,供主页 MeterBar 与托盘/菜单栏共用:
///   倒计时 → "2天3h后重置";绝对 → "06-13 15:42 重置"。无可用数据返回空串。
String fmtResetPhrase(int? remainingSecs, DateTime? resetsAt,
    {required bool absolute}) {
  if (absolute) {
    return resetsAt == null ? '' : '${fmtResetAt(resetsAt)} 重置';
  }
  if (remainingSecs == null || remainingSecs <= 0) return '';
  return '${fmtDuration(remainingSecs)}后重置';
}

/// 把 0~1 的使用率格式化为百分比文本。
String fmtPct(double? u) => u == null ? '—' : '${(u * 100).round()}%';

/// 本地时钟 HH:mm:ss(用于"更新时间")。
String fmtClock(DateTime? t) {
  if (t == null) return '';
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
}
