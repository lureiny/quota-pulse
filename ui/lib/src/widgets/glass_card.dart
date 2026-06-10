import 'package:flutter/material.dart';

/// 弹层根容器:半透明圆角卡片(+ 1px 描边)。
/// 配合壳层 flutter_acrylic 的窗口毛玻璃,在 Win/macOS 呈现一致的「悬浮卡片」。
/// 透出底层模糊靠 surface 的半透明;明暗跟随系统(颜色从主题取)。
class GlassCard extends StatelessWidget {
  const GlassCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: 0.45), // 更透:让背后毛玻璃更明显
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
