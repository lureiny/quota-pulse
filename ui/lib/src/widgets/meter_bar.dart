import 'package:flutter/material.dart';

import '../format.dart';
import '../models/pulse.dart';
import '../state/settings_store.dart';

/// MeterBar 渲染单个表盘:标签 + 进度条 + 副标。
///
/// 滚动窗口(rolling_window)显示重置(倒计时/绝对);累计配额(cumulative)显示 已用/总额。
/// 两类用同一根进度条,这正是抽象的价值。
class MeterBar extends StatelessWidget {
  const MeterBar(this.meter,
      {super.key,
      this.resetMode = ResetMode.countdown,
      this.onToggleResetMode});

  final Meter meter;
  final ResetMode resetMode; // 重置显示:倒计时 / 绝对(随设置)
  // 单击「重置时间」段的回调:翻转全局 resetMode(持久化,托盘同步)。
  // null 时该段退化为纯展示(仍保留悬停浮窗预览另一种格式)。
  final VoidCallback? onToggleResetMode;

  static const _subStyle = TextStyle(fontSize: 10.5, color: Color(0xFF8E8E93));

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
          if (sub != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: sub,
            ),
        ],
      ),
    );
  }

  /// 副标:重置短语 + 已用/总额 + detail,用 "  ·  " 分隔(与原拼接口径一致)。
  /// 用单段 [Text.rich](软换行不变),把重置短语作为内嵌 [WidgetSpan] 承载交互:
  /// 悬停浮窗预览另一种格式、单击切换全局显示模式。全无内容时返回 null。
  Widget? _subtitle() {
    final absolute = resetMode == ResetMode.absolute;
    final reset = fmtResetPhrase(meter.remainingSecs, meter.resetsAt,
        absolute: absolute);
    // 「另一种格式」:配置绝对→取相对,配置相对→取绝对(悬停浮窗展示它)。
    final other = fmtResetPhrase(meter.remainingSecs, meter.resetsAt,
        absolute: !absolute);

    final spans = <InlineSpan>[];
    void add(InlineSpan span) {
      if (spans.isNotEmpty) spans.add(const TextSpan(text: '  ·  '));
      spans.add(span);
    }

    if (reset.isNotEmpty) {
      add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: _resetChunk(reset, other),
      ));
    }
    if (meter.kind == 'cumulative' && meter.used != null && meter.limit != null) {
      final unit = meter.unit == 'usd' ? '\$' : '';
      add(TextSpan(text: '$unit${meter.used} / $unit${meter.limit}'));
    }
    if (meter.detail.isNotEmpty) {
      add(TextSpan(text: meter.detail));
    }
    if (spans.isEmpty) return null;
    // style 作用于所有 TextSpan;WidgetSpan 内的 reset 段自带同款 _subStyle。
    return Text.rich(TextSpan(children: spans), style: _subStyle);
  }

  /// 「重置时间」段:
  ///   悬停 → Tooltip 展示 [other](另一种时间格式);
  ///   单击 → [onToggleResetMode](翻转全局 resetMode)。
  /// [other] 为空(如只有相对无绝对时刻)则退化为纯文本,不预览也不可切换。
  Widget _resetChunk(String reset, String other) {
    final text = Text(reset, style: _subStyle);
    if (other.isEmpty) return text;
    Widget w = text;
    if (onToggleResetMode != null) {
      w = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: onToggleResetMode, child: w),
      );
    }
    return Tooltip(
      message: other,
      waitDuration: const Duration(milliseconds: 400),
      child: w,
    );
  }
}
