import 'package:flutter/material.dart';

import 'models/pulse.dart';

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

/// 把剩余秒数格式化为 "2h13m" / "45m" / "30s"。
String fmtDuration(int secs) {
  if (secs <= 0) return '';
  final h = secs ~/ 3600;
  final m = (secs % 3600) ~/ 60;
  if (h > 0) return '${h}h${m}m';
  if (m > 0) return '${m}m';
  return '${secs}s';
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
