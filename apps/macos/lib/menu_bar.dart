import 'package:flutter/services.dart';

/// macOS 自定义菜单栏状态项(替代 tray_manager):
/// 固定宽 = 图标区 + 文字区,图标不动,右侧文字像素级平滑滚动(流水屏)。
/// 原生侧见 apps/macos/runner_patches/AppDelegate.swift。
class MacMenuBar {
  static const _ch = MethodChannel('quota_pulse/menubar');
  static void Function()? onClick; // 左键点击图标
  static void Function(String key)? onMenu; // 右键菜单项
  static bool _handlerSet = false;

  static void _ensureHandler() {
    if (_handlerSet) return;
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onClick':
          onClick?.call();
          break;
        case 'onMenu':
          onMenu?.call(call.arguments as String);
          break;
      }
      return null;
    });
    _handlerSet = true;
  }

  /// 创建状态项。icon = PNG 字节;menu = [{key,label} 或 {separator:true}]。
  static Future<void> setup({
    required Uint8List icon,
    required List<Map<String, dynamic>> menu,
  }) {
    _ensureHandler();
    return _ch.invokeMethod('setup', {'icon': icon, 'menu': menu});
  }

  /// 设置右侧文字。scroll=true 且放不下时原生做像素级滚动;
  /// pps=点/秒(越大越快),width=文字区宽(点)。
  static Future<void> setTicker(
    String text, {
    required bool scroll,
    required double pps,
    required double width,
  }) {
    return _ch.invokeMethod('setTicker', {
      'text': text,
      'scroll': scroll,
      'pps': pps,
      'width': width,
    });
  }

  /// 状态项屏幕坐标(左上原点),给弹层定位(替代 tray_manager.getBounds)。
  static Future<Rect?> getFrame() async {
    final m = await _ch.invokeMapMethod<String, dynamic>('getFrame');
    if (m == null) return null;
    return Rect.fromLTWH(
      (m['x'] as num).toDouble(),
      (m['y'] as num).toDouble(),
      (m['width'] as num).toDouble(),
      (m['height'] as num).toDouble(),
    );
  }

  static Future<void> destroy() => _ch.invokeMethod('destroy');
}
