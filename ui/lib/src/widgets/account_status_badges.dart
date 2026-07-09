import 'package:flutter/material.dart';

import '../format.dart';
import '../models/pulse.dart';

// macOS 系统色(与 format.dart 同源;模型级徽章需要紫色,故本地再声明一份)。
const _amber = Color(0xFFFF9F0A);
const _red = Color(0xFFFF3B30);
const _purple = Color(0xFFAF52DE);

/// AccountStatusBadges 把账户的「管理状态」渲染成一排徽章,
/// **与 sub2api 网页「账户管理→状态」列同款同逻辑**:
///   - 主状态徽章(限流中/过载中/临时不可调度/错误/配额超限/暂停/停用),
///     429/529 带「解除倒计时」,错误/临时不可调度带 tooltip 详情;
///   - 模型级徽章(普通模型限流 / 积分已用尽 / 走积分),各带解除倒计时。
///
/// 主状态为「正常」时不画徽章(交给行首状态点),避免每行都挂一个「正常」。
/// 弹层每 ~2s 拉快照重建,倒计时随之刷新。
class AccountStatusBadges extends StatelessWidget {
  const AccountStatusBadges(this.state, {super.key});

  final AccountState state;

  @override
  Widget build(BuildContext context) {
    final badges = <Widget>[];

    // 主状态(正常则跳过)。
    if (!state.isOk) {
      badges.add(_primaryBadge());
    }
    // 模型级徽章。
    for (final m in state.models) {
      badges.add(_modelBadge(m));
    }

    if (badges.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Wrap(spacing: 6, runSpacing: 4, children: badges),
    );
  }

  Widget _primaryBadge() {
    final color = severityColor(state.severity);
    var text = _primaryLabel(state.code);

    // 429/529:主徽章后接「解除倒计时」。
    final left = _remaining(state.resetsAt);
    if (left.isNotEmpty &&
        (state.code == 'rate_limited' || state.code == 'overloaded')) {
      final suffix = state.code == 'rate_limited' ? '$left 自动恢复' : left;
      text = '$text · $suffix';
    }

    // 错误 / 临时不可调度:tooltip 给出详情。
    final tip = switch (state.code) {
      'rate_limited' => state.resetsAt == null
          ? '限流中,当前不参与调度'
          : '限流中,当前不参与调度,预计 ${fmtResetAt(state.resetsAt!)} 自动恢复',
      'overloaded' =>
        state.resetsAt == null ? '负载过重' : '负载过重,重置时间:${fmtResetAt(state.resetsAt!)}',
      'temp_unschedulable' =>
        state.reason.isNotEmpty ? state.reason : '临时不可调度',
      'error' => state.reason.isNotEmpty ? state.reason : '错误',
      _ => '',
    };
    return _pill(text, color, tooltip: tip);
  }

  Widget _modelBadge(ModelState m) {
    final (label, color) = switch (m.kind) {
      'credits_exhausted' => ('积分已用尽', _red),
      'credits_active' => ('${_scopeAlias(m.model)} 走积分', _amber),
      _ => ('${_scopeAlias(m.model)} 限流', _purple),
    };
    final left = _remaining(m.resetsAt);
    final text = left.isEmpty ? label : '$label · $left';
    final tip = m.resetsAt == null ? '' : '解除时间:${fmtResetAt(m.resetsAt!)}';
    return _pill(text, color, tooltip: tip);
  }

  Widget _pill(String text, Color color, {String tooltip = ''}) {
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, height: 1.1, color: color, fontWeight: FontWeight.w500),
      ),
    );
    return tooltip.isEmpty ? pill : Tooltip(message: tooltip, child: pill);
  }
}

/// 主状态机器码 → 网页同款中文文案。
String _primaryLabel(String code) => switch (code) {
      'rate_limited' => '限流中',
      'overloaded' => '过载中',
      'temp_unschedulable' => '临时不可调度',
      'error' => '错误',
      'quota_exceeded' => '配额超限',
      'paused' => '暂停',
      'inactive' => '停用',
      'ok' => '正常',
      _ => '—',
    };

/// [resetsAt] 距今剩余的紧凑时长("2天3h"/"3h13m"/…);已过或缺失返回空串。
String _remaining(DateTime? resetsAt) {
  if (resetsAt == null) return '';
  final secs = resetsAt.difference(DateTime.now()).inSeconds;
  if (secs <= 0) return '';
  return fmtDuration(secs);
}

/// 模型/scope 短名别名(照抄 sub2api 前端 formatScopeName,让展示与网页一致;未命中回退原名)。
String _scopeAlias(String scope) => _scopeAliases[scope] ?? scope;

const Map<String, String> _scopeAliases = {
  // Claude 系列
  'claude-fable-5': 'CFable5',
  'claude-opus-4-6': 'COpus46',
  'claude-opus-4-6-thinking': 'COpus46T',
  'claude-opus-4-7': 'COpus47',
  'claude-opus-4-8': 'COpus48',
  'claude-sonnet-4-6': 'CSon46',
  'claude-sonnet-4-5': 'CSon45',
  'claude-sonnet-4-5-thinking': 'CSon45T',
  // Gemini 2.5 系列
  'gemini-2.5-flash': 'G25F',
  'gemini-2.5-flash-lite': 'G25FL',
  'gemini-2.5-flash-thinking': 'G25FT',
  'gemini-2.5-pro': 'G25P',
  'gemini-2.5-flash-image': 'G25I',
  // Gemini 3.5 / 3 系列
  'gemini-3.5-flash': 'G35F',
  'gemini-3-flash': 'G3F',
  'gemini-3.1-pro-high': 'G3PH',
  'gemini-3.1-pro-low': 'G3PL',
  'gemini-3-pro-image': 'G3PI',
  'gemini-3.1-flash-image': 'G31FI',
  // 其他
  'gpt-oss-120b-medium': 'GPT120',
  'tab_flash_lite_preview': 'TabFL',
  // 旧版 scope 别名(兼容)
  'claude': 'Claude',
  'claude_sonnet': 'CSon',
  'claude_opus': 'COpus',
  'claude_haiku': 'CHaiku',
  'gemini_text': 'Gemini',
  'gemini_image': 'GImg',
  'gemini_flash': 'GFlash',
  'gemini_pro': 'GPro',
};
