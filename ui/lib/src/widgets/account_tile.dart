import 'package:flutter/material.dart';

import '../format.dart';
import '../models/pulse.dart';
import '../state/settings_store.dart';
import 'account_status_badges.dart';
import 'meter_bar.dart';
import 'status_dot.dart';

/// AccountTile 渲染一个账户:状态 + 名称 + 全部窗口 + 详情(始终展开,不折叠)。
/// 桌面端 hover 高亮,并出现「刷新此账户」按钮。
class AccountTile extends StatefulWidget {
  const AccountTile(this.pulse,
      {super.key,
      this.onRefresh,
      this.resetMode = ResetMode.countdown,
      this.onToggleResetMode});

  final AccountPulse pulse;
  final VoidCallback? onRefresh; // 只刷新此账户
  final ResetMode resetMode; // 重置显示:倒计时 / 绝对(随设置)
  final VoidCallback? onToggleResetMode; // 单击重置时间:翻转全局 resetMode

  @override
  State<AccountTile> createState() => _AccountTileState();
}

class _AccountTileState extends State<AccountTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.pulse;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.fromLTRB(12, 9, 10, 10),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest
                .withValues(alpha: _hover ? 0.45 : 0.22),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _headerRow(theme, scheme, p),
              if (p.state != null) AccountStatusBadges(p.state!),
              if (p.error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    p.error,
                    maxLines: 3,
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
              ...p.meters.map((m) => MeterBar(m,
                  resetMode: widget.resetMode,
                  onToggleResetMode: widget.onToggleResetMode)),
              _detail(theme, scheme, p),
            ],
          ),
        ),
      ),
    );
  }

  Widget _headerRow(ThemeData theme, ColorScheme scheme, AccountPulse p) {
    return Row(
      children: [
        // 有「管理状态」时,状态点改用其严重度色,与下方状态徽章一致。
        StatusDot(p.status,
            color: p.state != null ? severityColor(p.state!.severity) : null),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            p.name.isEmpty ? p.accountId : p.name,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall,
          ),
        ),
        if (p.tier.isNotEmpty) _chip(scheme, p.tier),
        if (widget.onRefresh != null)
          Opacity(
            opacity: _hover ? 1 : 0, // 预留位避免抖动;hover 才可点
            child: IconButton(
              tooltip: p.autoRefresh ? '刷新此账户' : '此账户不会自动更新,点此手动回源',
              icon: const Icon(Icons.refresh, size: 15),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              onPressed: _hover ? widget.onRefresh : null,
            ),
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
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            children: [
              Text(meta, style: theme.textTheme.bodySmall),
              if (!p.autoRefresh) _manualOnlyHint(theme, scheme),
            ],
          ),
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

  // 非 Anthropic OAuth/SetupToken 账户:sub2api 不支持被动读取,面板稳态轮询取不到它的用量,
  // 只能手动刷新(或设置→高级开启「自动强制回源」)。给个带说明的角标,别让人以为卡住了。
  Widget _manualOnlyHint(ThemeData theme, ColorScheme scheme) => Tooltip(
        message: '此平台不支持被动(自动)刷新\n'
            '用量需手动点刷新,或在设置→高级开启「自动强制回源」',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.touch_app_outlined,
                size: 11, color: scheme.onSurfaceVariant),
            const SizedBox(width: 2),
            Text('需手动刷新',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      );

  Widget _chip(ColorScheme scheme, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.12), // 跟随系统强调色
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text, style: TextStyle(fontSize: 10, color: scheme.primary)),
      );
}
