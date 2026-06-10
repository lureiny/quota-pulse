import 'package:flutter/material.dart';

import '../format.dart';
import '../models/pulse.dart';

/// 账户状态色点。
class StatusDot extends StatelessWidget {
  const StatusDot(this.status, {super.key, this.size = 8});

  final PulseStatus status;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: statusColor(status),
        shape: BoxShape.circle,
      ),
    );
  }
}
