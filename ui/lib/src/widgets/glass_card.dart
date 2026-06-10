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
    final isLight = theme.brightness == Brightness.light;
    // 浅色:M3 的 surface 偏灰 + 半透明会让整页发灰发暗 → 底色拉向纯白且高不透明,
    // 保证够亮、文字对比足;深色仍保留较透的玻璃感。
    final base = isLight ? Color.lerp(scheme.surface, Colors.white, 0.7)! : scheme.surface;
    final alpha = isLight ? 0.94 : 0.45;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: base.withValues(alpha: alpha),
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
