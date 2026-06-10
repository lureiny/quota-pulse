import 'models/pulse.dart';
import 'state/settings_store.dart';

/// 计算托盘要显示的文字(跨平台共用;Windows=tooltip,macOS=菜单栏标题)。
/// 由 [TraySettings] 决定模式;[pinnedAccount] 找不到时回退全局峰值。
String renderTrayText(List<AccountPulse> pulses, TraySettings tray) {
  String pct(double? u) => u == null ? '—' : '${(u * 100).round()}%';

  double? globalPeak() {
    double? p;
    for (final a in pulses) {
      final u = a.peakUtilization;
      if (u == null) continue;
      if (p == null || u > p) p = u;
    }
    return p;
  }

  AccountPulse? topAccount() {
    AccountPulse? top;
    for (final a in pulses) {
      if (top == null || (a.peakUtilization ?? -1) > (top.peakUtilization ?? -1)) {
        top = a;
      }
    }
    return top;
  }

  String globalText() {
    final gp = globalPeak();
    return gp == null ? 'quota-pulse' : 'quota-pulse · 峰值 ${pct(gp)}';
  }

  switch (tray.mode) {
    case TrayMode.pinnedAccount:
      if (tray.pinnedKey != null) {
        for (final a in pulses) {
          if (a.key == tray.pinnedKey) {
            final name = a.name.isEmpty ? a.accountId : a.name;
            return '$name ${pct(a.peakUtilization)}';
          }
        }
      }
      return globalText(); // 没钉住或找不到 → 回退

    case TrayMode.globalPeak:
      return globalText();

    case TrayMode.countPeak:
      return '${pulses.length} 账户 · 峰值 ${pct(globalPeak())}';

    case TrayMode.custom:
      final top = topAccount();
      final name = top == null ? '' : (top.name.isEmpty ? top.accountId : top.name);
      final gp = globalPeak();
      final peakNum = gp == null ? '' : '${(gp * 100).round()}';
      return (tray.template ?? '{name} {peak}%')
          .replaceAll('{name}', name)
          .replaceAll('{peak}', peakNum)
          .replaceAll('{count}', '${pulses.length}');
  }
}
