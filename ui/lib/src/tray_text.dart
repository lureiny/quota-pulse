import 'models/pulse.dart';
import 'state/settings_store.dart';

/// Windows 托盘 tooltip:尽量全的多行汇总(所有账户按峰值降序,~118 字符上限)。
/// 注:悬停延迟由 Windows 系统控制、app 无法调整;要即时看全部请左键点托盘打开弹层。
String renderTrayTooltip(List<AccountPulse> pulses) {
  if (pulses.isEmpty) return 'quota-pulse';
  final sorted = [...pulses]
    ..sort((a, b) => (b.peakUtilization ?? -1).compareTo(a.peakUtilization ?? -1));
  final lines = <String>[];
  var total = 0;
  for (var i = 0; i < sorted.length; i++) {
    final a = sorted[i];
    final name = a.name.isEmpty ? a.accountId : a.name;
    final pk = a.peakUtilization == null ? '—' : '${(a.peakUtilization! * 100).round()}%';
    final line = '${a.instance}·$name  $pk';
    if (total + line.length + 1 > 118 && lines.isNotEmpty) {
      lines.add('…还有 ${sorted.length - i} 个');
      break;
    }
    lines.add(line);
    total += line.length + 1;
  }
  return lines.join('\n');
}

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
