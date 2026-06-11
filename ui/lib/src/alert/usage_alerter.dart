import 'package:local_notifier/local_notifier.dart';

import '../models/pulse.dart';
import '../state/settings_store.dart';

/// 用量阈值提醒:按设置对各滚动窗口发系统通知。支持两类通知,各自可配监听窗口(5h/7d):
///   · 超阈值(over):用量上穿阈值 → 提醒;
///   · 额度恢复(recover):曾在阈值之上、现回落到阈值之下(含窗口重置)→ 提醒。
///
/// 去重:每类通知在同一个重置周期内只发一次——以 [Meter.resetsAt] 作"周期指纹",
/// 窗口重置(resetsAt 变化)后可再次提醒;无 resetsAt 的窗口退化为"穿越沿"触发。
/// 首次喂入只 seed 状态、不提醒(避免启动时一堆已超阈值账户同时刷屏);关闭后再开启亦然。
/// 通知范围只覆盖 [kAlertWindows](当前 5h / 7d),其余窗口不打扰。
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
  final Map<String, DateTime?> _overReset = {}; // key -> 已发"超阈值"的该周期 resetsAt
  final Map<String, DateTime?> _recoverReset = {}; // key -> 已发"恢复"的该周期 resetsAt
  final Map<String, bool> _wasAbove = {}; // key -> 上次是否在阈值之上(判穿越沿)

  /// 每次拿到新快照时调用:按设置检测各窗口的超阈值/恢复,去重后发通知。
  void check(List<AccountPulse> pulses, Settings settings) {
    final over = settings.alertOverWindows;
    final recover = settings.alertRecoverWindows;
    // 总开关关、或两类都没选窗口 → 不发;并清"已就绪",下次启用时静默 seed 避免刷屏。
    if (!settings.alertEnabled || (over.isEmpty && recover.isEmpty)) {
      _seeded = false;
      return;
    }
    final threshold = settings.alertThreshold / 100.0;
    final firstTime = !_seeded;
    for (final p in pulses) {
      for (final m in p.meters) {
        if (m.kind != 'rolling_window') continue;
        if (!kAlertWindows.containsKey(m.id)) continue; // 只盯 5h / 7d
        final u = m.utilization;
        if (u == null) continue;
        final key = '${p.key}|${m.id}';
        final reset = m.resetsAt;
        final above = u >= threshold;
        final wasAbove = _wasAbove[key];

        // 超阈值:在阈值之上 + 本周期未发过(无周期信息则取上穿沿)。
        if (over.contains(m.id) && above) {
          final fresh =
              reset != null ? _overReset[key] != reset : wasAbove != true;
          if (fresh) {
            _overReset[key] = reset; // 首次也标(只是不弹)
            if (!firstTime) _fireOver(p, m, u);
          }
        }

        // 额度恢复:曾在阈值之上、现回落到阈值之下 + 本周期未发过。
        if (recover.contains(m.id) && wasAbove == true && !above) {
          final fresh = reset == null || _recoverReset[key] != reset;
          if (fresh) {
            _recoverReset[key] = reset;
            if (!firstTime) _fireRecover(p, m, u);
          }
        }

        _wasAbove[key] = above;
      }
    }
    _seeded = true;
  }

  void _fireOver(AccountPulse p, Meter m, double u) => _showOver(_who(p, m), u);
  void _fireRecover(AccountPulse p, Meter m, double u) =>
      _showRecover(_who(p, m), u);

  // 真实告警与测试样例共用同一渲染,确保"测到的就是真实长相"。
  void _showOver(String who, double u) {
    final full = u >= 1.0; // 已用满(通常已限流)→ 升级更醒目的标题
    LocalNotification(
      title: full ? '🛑 用量已满' : '🚨 用量告警',
      body: '$who 已用 ${(u * 100).round()}%',
      silent: false, // 播放系统提示音,更易察觉
    ).show();
  }

  void _showRecover(String who, double u) {
    LocalNotification(
      title: '✅ 额度恢复',
      body: '$who 已回落到 ${(u * 100).round()}%',
      silent: false,
    ).show();
  }

  String _who(AccountPulse p, Meter m) {
    final name = p.name.isEmpty ? p.accountId : p.name;
    final label = m.label.isEmpty ? m.id : m.label;
    return '${p.instance}·$name 的 $label';
  }

  /// 设置页"发送测试通知"按钮用:依次弹出全部三种通知样例(🚨 告警 / 🛑 已满 / ✅ 恢复),
  /// 绕过阈值与去重,便于一次性核验每种通知是否真弹、长什么样。间隔 600ms 让三条清晰分开。
  Future<void> testNotification() async {
    await setup();
    const who = '演示·测试账户 的 5h';
    _showOver(who, 0.9); // 🚨 用量告警
    await Future.delayed(const Duration(milliseconds: 600));
    _showOver(who, 1.0); // 🛑 用量已满
    await Future.delayed(const Duration(milliseconds: 600));
    _showRecover(who, 0.12); // ✅ 额度恢复
  }
}
