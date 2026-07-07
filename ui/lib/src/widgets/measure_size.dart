import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// MeasureSize 在子组件布局后把其尺寸回调出来 —— 尺寸变化才回调,且在 post-frame 内触发
/// (回调里可安全 setState / 调 window_manager)。用于让弹层按内容**固有高度**调整窗口大小。
///
/// 注意:child 须能自行确定尺寸(如 Column / 内容);外层给它无界高度(SingleChildScrollView)
/// 时量到的就是固有高度,与窗口高无关 → 不会与「按内容调窗口高」形成尺寸抖动死循环。
class MeasureSize extends SingleChildRenderObjectWidget {
  const MeasureSize({
    super.key,
    required this.onChange,
    required Widget child,
  }) : super(child: child);

  final ValueChanged<Size> onChange;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _MeasureSizeRenderObject(onChange);

  @override
  void updateRenderObject(
      BuildContext context, _MeasureSizeRenderObject renderObject) {
    renderObject.onChange = onChange;
  }
}

class _MeasureSizeRenderObject extends RenderProxyBox {
  _MeasureSizeRenderObject(this.onChange);

  ValueChanged<Size> onChange;
  Size? _old;

  @override
  void performLayout() {
    super.performLayout();
    final size = child?.size ?? Size.zero;
    if (size != _old) {
      _old = size;
      WidgetsBinding.instance.addPostFrameCallback((_) => onChange(size));
    }
  }
}
