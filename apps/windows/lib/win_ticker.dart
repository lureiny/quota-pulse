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
  // 拖拽浮窗边缘改宽结束 → 持久化新宽(逻辑像素)+ 新位置(左边缘拖会同时移动)。
  static void Function(int w, int x, int y)? onResized;
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
        case 'onResized':
          final m = (call.arguments as Map).cast<String, dynamic>();
          onResized?.call((m['w'] as num).toInt(), (m['x'] as num).toInt(),
              (m['y'] as num).toInt());
          break;
      }
      return null;
    });
    _handlerSet = true;
  }

  /// 推送一次内容/状态。enabled=false 时隐藏浮窗;首次 enabled=true 惰性创建。
  /// [multiline]=false 走单行滚动([segments]),true 走多行铺开([lines])。
  /// [segments] 每项 `{'color': int(ARGB), 'text': String, 'newAccount': bool}`
  ///   (圆点色 + 无 emoji 文本;newAccount=账户起始段,原生在账户之间用更大间隔)。
  /// [lines] 每项 `{'dot': bool, 'color': int(ARGB), 'indent': int, 'text': String}`
  ///   (dot=true 画前导状态圆点;indent 缩进级别)。
  /// scroll=true 且放不下时原生做像素级滚动;pps=点/秒(越大越快),width=可见宽(逻辑像素;
  /// 来自 windowsTickerWidth ?? tickerWidth*9,原生再硬夹到整屏宽,可拖边缘改宽回报 onResized)。
  /// x/y 为已保存的浮窗位置(物理像素);null → 传 -1,原生用默认右下角(仅创建时采用)。
  ///
  /// 返回原生当前实际可见宽(逻辑像素)。用户拖拽浮窗边缘改宽后,原生保留拖出来的宽
  /// (见 win_ticker.cpp 的 lastWidthArg_ 守卫),此返回值会与传入的 [width] 不同;
  /// 壳据此把配置同步过来——这条走 Dart→native 返回值,可靠,不依赖 native→Dart 回调。
  static Future<int?> update({
    required List<Map<String, Object>> segments,
    required List<Map<String, Object>> lines,
    required bool multiline,
    required bool enabled,
    required bool scroll,
    required double pps,
    required double width,
    required bool dark, // 生效后的明暗(跟随 app 主题设置,而非系统)
    required bool hideOnFullscreen,
    int? x,
    int? y,
  }) {
    _ensureHandler();
    return _ch.invokeMethod<int>('update', {
      'segments': segments,
      'lines': lines,
      'multiline': multiline,
      'enabled': enabled,
      'scroll': scroll,
      'pps': pps,
      'width': width,
      'dark': dark,
      'hideOnFullscreen': hideOnFullscreen,
      'x': x ?? -1,
      'y': y ?? -1,
    });
  }

  /// 主面板弹出/收起时调:open=true 把浮窗降到面板之下(仍压住其他程序),false 恢复置顶。
  static Future<void> setPopoverOpen(bool open) =>
      _ch.invokeMethod('setPopoverOpen', open);

  /// 点击浮窗唤起主面板时调:把主面板移到浮窗附近(以浮窗为锚点)。
  static Future<void> positionNearTicker() =>
      _ch.invokeMethod('positionNearTicker');

  /// 把浮窗移回默认位置(设置页「重置位置」用)。
  static Future<void> resetPosition() => _ch.invokeMethod('resetPosition');

  static Future<void> destroy() => _ch.invokeMethod('destroy');
}
