import 'package:flutter/material.dart';

import '../format.dart';
import '../models/pulse.dart';
import 'meter_bar.dart';
import 'status_dot.dart';

/// AccountTile 渲染一个账户。点击行内展开:折叠态只显示最满的一条表盘,
/// 展开态显示全部表盘 + 平台/类型/账户号/更新时间/申诉链接。桌面端 hover 高亮。
class AccountTile extends StatefulWidget {
  const AccountTile(this.pulse, {super.key, this.onRefresh});

  final AccountPulse pulse;
  final VoidCallback? onRefresh; // 只刷新此账户

  @override
  State<AccountTile> createState() => _AccountTileState();
}

class _AccountTileState extends State<AccountTile> {
  bool _expanded = true; // 默认展开(点击可折叠)
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.pulse;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // 折叠态显示使用率最高的一条;展开态显示全部。
    final sorted = [...p.meters]
      ..sort((a, b) => (b.utilization ?? -1).compareTo(a.utilization ?? -1));
    final shown = _expanded ? p.meters : sorted.take(1).toList();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _expanded = !_expanded),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.fromLTRB(12, 9, 10, 10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest
                  .withValues(alpha: _hover ? 0.55 : 0.22),
              borderRadius: BorderRadius.circular(8),
            ),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 150),
              alignment: Alignment.topCenter,
              curve: Curves.easeOut,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _headerRow(theme, scheme, p),
                  if (p.error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        p.error,
                        maxLines: _expanded ? 4 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: statusColor(PulseStatus.error)),
                      ),
                    ),
                  if (p.meters.isEmpty && p.error.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('无窗口数据', style: theme.textTheme.bodySmall),
                    ),
                  ...shown.map((m) => MeterBar(m)),
                  if (_expanded) _detail(theme, scheme, p),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _headerRow(ThemeData theme, ColorScheme scheme, AccountPulse p) {
    final peak = p.peakUtilization;
    return Row(
      children: [
        StatusDot(p.status),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            p.name.isEmpty ? p.accountId : p.name,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall,
          ),
        ),
        if (p.tier.isNotEmpty) _chip(scheme, p.tier),
        const SizedBox(width: 6),
        Text(
          fmtPct(peak),
          style: theme.textTheme.labelMedium?.copyWith(
            color: meterColor(peak),
            fontWeight: FontWeight.w700,
          ),
        ),
        if (widget.onRefresh != null && _hover)
          IconButton(
            tooltip: '刷新此账户',
            icon: const Icon(Icons.refresh, size: 15),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            onPressed: widget.onRefresh,
          ),
        Icon(
          _expanded ? Icons.expand_less : Icons.expand_more,
          size: 16,
          color: scheme.onSurfaceVariant,
        ),
      ],
    );
  }

  Widget _detail(ThemeData theme, ColorScheme scheme, AccountPulse p) {
    final meta = <String>[
      if (p.platform.isNotEmpty) p.platform,
      '#${p.accountId}',
      if (p.updatedAt != null) '更新 ${fmtClock(p.updatedAt)}',
    ].join('  ·  ');
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(meta, style: theme.textTheme.bodySmall),
          if (p.actionUrl.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                p.actionUrl,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.primary),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chip(ColorScheme scheme, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.12), // 跟随系统强调色
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text, style: TextStyle(fontSize: 10, color: scheme.primary)),
      );
}
