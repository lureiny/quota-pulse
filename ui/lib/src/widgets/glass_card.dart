import 'package:flutter/material.dart';

/// 弹层根容器:半透明圆角卡片(+ 1px 描边)。
/// 配合壳层 flutter_acrylic 的窗口毛玻璃,在 Win/macOS 呈现一致的「悬浮卡片」。
/// 透出底层模糊靠 surface 的半透明;明暗跟随系统(颜色从主题取)。
class GlassCard extends StatelessWidget {
  const GlassCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 浅色模式下太透会让文字与亮背景对比不足、看不清 → 提高不透明度保证可读;深色仍更透。
    final alpha = theme.brightness == Brightness.light ? 0.78 : 0.45;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: alpha),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.4),
            width: 1,
          ),
        ),
        child: child,
      ),
    );
  }
}
