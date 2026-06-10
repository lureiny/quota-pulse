import 'package:flutter/material.dart';
import 'package:system_theme/system_theme.dart';

/// 读 accent 失败时的回退种子色。
const Color _fallbackSeed = Color(0xFF3478F6);

/// 读取系统强调色(macOS / Windows accent;读不到则回退)。
/// 需在 runApp 前调用(main 里已有 WidgetsFlutterBinding.ensureInitialized)。
Future<Color> loadAccentColor({Color fallback = _fallbackSeed}) async {
  SystemTheme.fallbackColor = fallback;
  try {
    await SystemTheme.accentColor.load();
    return SystemTheme.accentColor.accent;
  } catch (_) {
    return fallback;
  }
}

/// 统一主题:布局 / 组件 / 间距 / 密度跨平台一致;字体走系统默认(贴近原生);
/// 配色由 seed(系统强调色)+ 明暗派生。两端及未来平台共用这一份。
ThemeData buildAppTheme({required Color seed, required Brightness brightness}) {
  final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    // 钉死密度,不随平台变(否则桌面各平台默认间距不同)
    visualDensity: VisualDensity.standard,
    // 不设 fontFamily → 用系统默认字体(macOS=SF / Windows=雅黑)
    scrollbarTheme: const ScrollbarThemeData(
      thickness: WidgetStatePropertyAll<double>(6.0),
      radius: Radius.circular(3),
    ),
  );
}
