import 'package:local_notifier/local_notifier.dart';

import '../models/pulse.dart';
import '../state/settings_store.dart';

/// 用量阈值提醒:某滚动窗口用量越过阈值时发系统通知。
///
/// 去重:同一窗口在同一个重置周期内只提醒一次——以 [Meter.resetsAt] 作"周期指纹",
/// 窗口重置(resetsAt 变化)后可再次提醒;无 resetsAt 的窗口退化为"上穿沿"触发。
/// 首次喂入只 seed 状态、不提醒(避免启动时一堆已超阈值账户同时刷屏);关闭后再开启亦然。
class UsageAlerter {
  static bool _setupDone = false;

  /// 初始化通知后端(Windows 需创建快捷方式挂 AppUserModelID 才能弹 toast)。只需调一次。
  static Future<void> setup() async {
    if (_setupDone) return;
    _setupDone = true;
    await localNotifier.setup(
      appName: 'quota-pulse',
      shortcutPolicy: ShortcutPolicy.requireCreate,
    );
  }

  bool _seeded = false;
  final Map<String, DateTime?> _alertedReset = {}; // key -> 已提醒过的该周期 resetsAt
  final Map<String, bool> _wasAbove = {}; // key -> 上次是否越线(无 resetsAt 时退化用)

  /// 每次拿到新快照时调用:按设置阈值检测各滚动窗口越线,去重后发通知。
  void check(List<AccountPulse> pulses, Settings settings) {
    if (!settings.alertEnabled) {
      _seeded = false; // 关闭即清"已就绪":下次开启会静默 seed,避免开启瞬间刷屏
      return;
    }
    final threshold = settings.alertThreshold / 100.0;
    final firstTime = !_seeded;
    for (final p in pulses) {
      for (final m in p.meters) {
        if (m.kind != 'rolling_window') continue; // 只盯滚动窗口(5h / 7d …)
        final u = m.utilization;
        if (u == null) continue;
        final key = '${p.key}|${m.id}';
        final above = u >= threshold;
        final reset = m.resetsAt;
        if (above) {
          final fresh = reset != null
              ? _alertedReset[key] != reset // 本周期还没提醒过
              : _wasAbove[key] != true; // 无周期信息 → 上穿沿
          if (fresh) {
            _alertedReset[key] = reset; // 标记本周期已处理(首次也标,只是不弹)
            if (!firstTime) _fire(p, m, u);
          }
        }
        _wasAbove[key] = above;
      }
    }
    _seeded = true;
  }

  void _fire(AccountPulse p, Meter m, double u) {
    final name = p.name.isEmpty ? p.accountId : p.name;
    final label = m.label.isEmpty ? m.id : m.label;
    final full = u >= 1.0; // 已用满(通常已限流)→ 升级更醒目的标题
    LocalNotification(
      title: full ? '🛑 用量已满' : '🚨 用量告警',
      body: '${p.instance}·$name 的 $label 已用 ${(u * 100).round()}%',
      silent: false, // 播放系统提示音,更易察觉
    ).show();
  }

  /// 设置页"发送测试通知"按钮用:立即发一条,绕过阈值与去重,便于快速验证通知是否真弹。
  Future<void> testNotification() async {
    await setup();
    await LocalNotification(
      title: '🚨 测试通知',
      body: 'quota-pulse 通知工作正常',
      silent: false, // 与真实告警一致:带提示音
    ).show();
  }
}
