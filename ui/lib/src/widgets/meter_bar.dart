import 'package:flutter/material.dart';

import '../format.dart';
import '../models/pulse.dart';

/// MeterBar 渲染单个表盘:标签 + 进度条 + 副标。
///
/// 滚动窗口(rolling_window)显示重置倒计时;累计配额(cumulative)显示 已用/总额。
/// 两类用同一根进度条,这正是抽象的价值。
class MeterBar extends StatelessWidget {
  const MeterBar(this.meter, {super.key});

  final Meter meter;

  @override
  Widget build(BuildContext context) {
    final u = meter.utilization;
    final frac = (u ?? 0).clamp(0.0, 1.0).toDouble();
    final sub = _subtitle();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  meter.label,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                ),
              ),
              Text(
                fmtPct(u),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: meterColor(u),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: frac,
              minHeight: 5,
              backgroundColor: const Color(0x1F8E8E93),
              valueColor: AlwaysStoppedAnimation<Color>(meterColor(u)),
            ),
          ),
          if (sub.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                sub,
                style: const TextStyle(fontSize: 10.5, color: Color(0xFF8E8E93)),
              ),
            ),
        ],
      ),
    );
  }

  String _subtitle() {
    final parts = <String>[];
    final secs = meter.remainingSecs;
    if (secs != null && secs > 0) {
      parts.add('${fmtDuration(secs)}后重置');
    }
    if (meter.kind == 'cumulative' && meter.used != null && meter.limit != null) {
      final unit = meter.unit == 'usd' ? '\$' : '';
      parts.add('$unit${meter.used} / $unit${meter.limit}');
    }
    if (meter.detail.isNotEmpty) {
      parts.add(meter.detail);
    }
    return parts.join('  ·  ');
  }
}
