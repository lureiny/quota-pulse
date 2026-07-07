import 'package:flutter/material.dart';

import '../state/settings_store.dart' show ChartMetric;

/// 度量小开关:Tk / $ / 次 三格,点未选中的一格即切换。
/// 图表度量(token / 花费 / 请求次数)是**全局**配置(两图共用),统一放全局控件条一处,
/// 不在每张图上各放一个。
class MetricToggle extends StatelessWidget {
  const MetricToggle({super.key, required this.metric, required this.onChanged});

  final ChartMetric metric;
  final ValueChanged<ChartMetric> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget cell(String label, ChartMetric m) {
      final on = metric == m;
      return InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: on ? null : () => onChanged(m),
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
}
