import 'package:flutter/material.dart';

import '../format.dart';
import '../state/pulse_controller.dart';
import '../widgets/account_tile.dart';

/// PopoverPage 是弹层主体:标题栏 + 账户列表 + 底部操作条。
class PopoverPage extends StatelessWidget {
  const PopoverPage({
    super.key,
    required this.controller,
    required this.onRefresh,
    required this.onSettings,
  });

  final PulseController controller;
  final VoidCallback onRefresh;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Column(
          children: [
            _header(),
            const Divider(height: 1),
            Expanded(child: _body()),
            const Divider(height: 1),
            _footer(),
          ],
        );
      },
    );
  }

  Widget _header() {
    final peak = controller.peakUtilization;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Row(
        children: [
          const Text('用量脉搏', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          const Spacer(),
          if (peak != null)
            Text('峰值 ${fmtPct(peak)}',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: meterColor(peak))),
        ],
      ),
    );
  }

  Widget _body() {
    final err = controller.error;
    final pulses = controller.pulses;

    if (err != null && pulses.isEmpty) {
      return _centered('读取失败\n$err', color: const Color(0xFFFF3B30));
    }
    if (pulses.isEmpty) {
      return _centered('加载中…');
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: pulses.length,
      itemBuilder: (_, i) => AccountTile(pulses[i]),
    );
  }

  Widget _footer() {
    final n = controller.pulses.length;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Text('$n 个账户', style: const TextStyle(fontSize: 11, color: Color(0xFF8E8E93))),
          const Spacer(),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: onRefresh,
          ),
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings, size: 18),
            onPressed: onSettings,
          ),
        ],
      ),
    );
  }

  Widget _centered(String text, {Color? color}) => Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: color ?? const Color(0xFF8E8E93)),
          ),
        ),
      );
}
