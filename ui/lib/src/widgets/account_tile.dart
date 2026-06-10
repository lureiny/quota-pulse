import 'package:flutter/material.dart';

import '../format.dart';
import '../models/pulse.dart';
import 'meter_bar.dart';
import 'status_dot.dart';

/// AccountTile 渲染一个账户:状态点 + 名称 + 等级 + 一组表盘。
class AccountTile extends StatelessWidget {
  const AccountTile(this.pulse, {super.key});

  final AccountPulse pulse;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: const Color(0x0A8E8E93),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusDot(pulse.status),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  pulse.name.isEmpty ? pulse.accountId : pulse.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              if (pulse.tier.isNotEmpty) _chip(pulse.tier),
              const SizedBox(width: 6),
              Text(
                statusLabel(pulse.status),
                style: TextStyle(fontSize: 11, color: statusColor(pulse.status)),
              ),
            ],
          ),
          if (pulse.error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                pulse.error,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Color(0xFFFF3B30)),
              ),
            ),
          if (pulse.meters.isEmpty && pulse.error.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('无窗口数据', style: TextStyle(fontSize: 11, color: Color(0xFF8E8E93))),
            ),
          ...pulse.meters.map((m) => MeterBar(m)),
        ],
      ),
    );
  }

  Widget _chip(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: const Color(0x1F007AFF),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text, style: const TextStyle(fontSize: 10, color: Color(0xFF007AFF))),
      );
}
