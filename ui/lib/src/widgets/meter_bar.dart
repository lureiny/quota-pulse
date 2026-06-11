import 'package:flutter/material.dart';

import '../format.dart';
import '../models/pulse.dart';
import '../state/settings_store.dart';

/// MeterBar 渲染单个表盘:标签 + 进度条 + 副标。
///
/// 滚动窗口(rolling_window)显示重置(倒计时/绝对);累计配额(cumulative)显示 已用/总额。
/// 两类用同一根进度条,这正是抽象的价值。
class MeterBar extends StatelessWidget {
  const MeterBar(this.meter, {super.key, this.resetMode = ResetMode.countdown});

  final Meter meter;
  final ResetMode resetMode; // 重置显示:倒计时 / 绝对(随设置)

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
                  fontWeight: FontWeight.w700,
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
    final reset = fmtResetPhrase(meter.remainingSecs, meter.resetsAt,
        absolute: resetMode == ResetMode.absolute);
    if (reset.isNotEmpty) parts.add(reset);
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
