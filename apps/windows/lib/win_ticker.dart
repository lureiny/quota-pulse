import 'package:flutter/services.dart';

/// Windows 桌面悬浮跑马灯(原生 Win32 浮层 + Direct2D 像素级滚动)。
/// 原生侧见 apps/windows/runner_patches/win_ticker.{h,cpp};通道在 runner 启动时挂好。
///
/// 与 macOS 的 [MacMenuBar] 对应:macOS 把滚动文字塞进菜单栏状态项,Windows 没有
/// 这个承载面,故用一个可拖拽的置顶浮窗自绘同样的滚动文字。
class WinTicker {
  static const _ch = MethodChannel('quota_pulse/ticker');
  static void Function()? onClick; // 左键单击浮窗 → 弹主面板
  static void Function(int x, int y)? onMoved; // 拖拽结束 → 持久化新位置(物理像素)
  static bool _handlerSet = false;

  static void _ensureHandler() {
    if (_handlerSet) return;
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onClick':
          onClick?.call();
          break;
        case 'onMoved':
          final m = (call.arguments as Map).cast<String, dynamic>();
          onMoved?.call((m['x'] as num).toInt(), (m['y'] as num).toInt());
          break;
      }
      return null;
    });
    _handlerSet = true;
  }

  /// 推送一次内容/状态。enabled=false 时隐藏浮窗;首次 enabled=true 惰性创建。
  /// [segments] 每项 `{'color': int(ARGB), 'text': String}`(状态色 + 无 emoji 文本)。
  /// scroll=true 且放不下时原生做像素级滚动;pps=点/秒(越大越快),width=可见宽(逻辑像素)。
  /// x/y 为已保存的浮窗位置(物理像素);null → 传 -1,原生用默认右下角(仅创建时采用)。
  static Future<void> update({
    required List<Map<String, Object>> segments,
    required bool enabled,
    required bool scroll,
    required double pps,
    required double width,
    required bool hideOnFullscreen,
    int? x,
    int? y,
  }) {
    _ensureHandler();
    return _ch.invokeMethod('update', {
      'segments': segments,
      'enabled': enabled,
      'scroll': scroll,
      'pps': pps,
      'width': width,
      'hideOnFullscreen': hideOnFullscreen,
      'x': x ?? -1,
      'y': y ?? -1,
    });
  }

  /// 把浮窗移回默认位置(设置页「重置位置」用)。
  static Future<void> resetPosition() => _ch.invokeMethod('resetPosition');

  static Future<void> destroy() => _ch.invokeMethod('destroy');
}
