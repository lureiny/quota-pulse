/// quota-pulse 跨平台共享层(平台无关 + 桌面 FFI)。
///
/// `apps/<platform>` 依赖本包,只需各自实现「薄外壳」(托盘 / 窗口 / 打包)。
/// 公开 API 全部从这里导出;实现细节在 `src/`。
library;

// 数据模型 + 展示工具
export 'src/models/pulse.dart';
export 'src/format.dart';
export 'src/version.dart';

// 统一主题(跨平台共用:布局/组件/密度一致;字体走系统;配色由系统 accent + 明暗派生)
export 'src/theme.dart';

// 托盘文字渲染(跨平台共用)
export 'src/tray_text.dart';

// UI 组件
export 'src/widgets/meter_bar.dart';
export 'src/widgets/account_tile.dart';
export 'src/widgets/status_dot.dart';
export 'src/widgets/glass_card.dart';
export 'src/widgets/hourly_chart.dart';

// 页面
export 'src/pages/popover_page.dart';
export 'src/pages/settings_page.dart';

// 状态
export 'src/state/pulse_controller.dart';
export 'src/state/settings_store.dart';
export 'src/state/config_io.dart';

// 用量阈值提醒(系统通知)
export 'src/alert/usage_alerter.dart';

// 桥接(用量来源抽象 + 桌面 FFI 实现)
export 'src/bridge/pulse_source.dart';
export 'src/bridge/ffi_pulse_source.dart';
