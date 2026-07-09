import 'package:flutter/material.dart';

import '../format.dart';
import '../models/pulse.dart';

/// 账户状态色点。默认按用量态([status])上色;传 [color] 可覆盖
/// (账户有「管理状态」时改用其严重度色,让点与状态徽章一致)。
class StatusDot extends StatelessWidget {
  const StatusDot(this.status, {super.key, this.size = 8, this.color});

  final PulseStatus status;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color ?? statusColor(status),
        shape: BoxShape.circle,
      ),
    );
  }
}
