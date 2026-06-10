import 'models/pulse.dart';
import 'state/settings_store.dart';

String _pct(double? u) => u == null ? '—' : '${(u * 100).round()}%';

double? _globalPeak(List<AccountPulse> pulses) {
  double? p;
  for (final a in pulses) {
    final u = a.peakUtilization;
    if (u == null) continue;
    if (p == null || u > p) p = u;
  }
  return p;
}

String _accountName(AccountPulse a) => a.name.isEmpty ? a.accountId : a.name;

/// 按账户稳定排序:实例 → 名称 → id(不随使用率跳动)。
int _byAccount(AccountPulse a, AccountPulse b) {
  final c = a.instance.compareTo(b.instance);
  if (c != 0) return c;
  final c2 = _accountName(a).compareTo(_accountName(b));
  if (c2 != 0) return c2;
  return a.accountId.compareTo(b.accountId);
}

AccountPulse? _topAccount(List<AccountPulse> pulses) {
  AccountPulse? top;
  for (final a in pulses) {
    if (top == null || (a.peakUtilization ?? -1) > (top.peakUtilization ?? -1)) {
      top = a;
    }
  }
  return top;
}

String _custom(List<AccountPulse> pulses, TraySettings tray) {
  final top = _topAccount(pulses);
  final name = top == null ? '' : _accountName(top);
  final gp = _globalPeak(pulses);
  final peakNum = gp == null ? '' : '${(gp * 100).round()}';
  return (tray.template ?? '{name} {peak}%')
      .replaceAll('{name}', name)
      .replaceAll('{peak}', peakNum)
      .replaceAll('{count}', '${pulses.length}');
}

/// Windows 托盘 tooltip:多行,按 [TraySettings] 模式渲染(默认 allAccounts,按账户排序)。
/// 注:悬停延迟由 Windows 系统控制、app 无法调整;要即时看全部请左键点托盘。
String renderTrayTooltip(List<AccountPulse> pulses, TraySettings tray) {
  if (pulses.isEmpty) return 'quota-pulse';
  switch (tray.mode) {
    case TrayMode.allAccounts:
      final sorted = [...pulses]..sort(_byAccount);
      final lines = <String>[];
      var total = 0;
      for (var i = 0; i < sorted.length; i++) {
        final a = sorted[i];
        final line = '${a.instance}·${_accountName(a)}  ${_pct(a.peakUtilization)}';
        if (total + line.length + 1 > 118 && lines.isNotEmpty) {
          lines.add('…还有 ${sorted.length - i} 个');
          break;
        }
        lines.add(line);
        total += line.length + 1;
      }
      return lines.join('\n');

    case TrayMode.pinnedAccount:
      for (final a in pulses) {
        if (a.key == tray.pinnedKey) {
          final meters =
              a.meters.map((m) => '${m.label} ${_pct(m.utilization)}').join('   ');
          return meters.isEmpty
              ? '${_accountName(a)}  ${_pct(a.peakUtilization)}'
              : '${_accountName(a)}\n$meters';
        }
      }
      // 没钉住或找不到 → 退回全部
      return renderTrayTooltip(pulses, const TraySettings(mode: TrayMode.allAccounts));

    case TrayMode.globalPeak:
      return '峰值 ${_pct(_globalPeak(pulses))}';

    case TrayMode.countPeak:
      return '${pulses.length} 账户 · 峰值 ${_pct(_globalPeak(pulses))}';

    case TrayMode.custom:
      return _custom(pulses, tray);
  }
}

/// macOS 菜单栏标题(单行,空间有限)。
String renderTrayText(List<AccountPulse> pulses, TraySettings tray) {
  if (pulses.isEmpty) return 'quota-pulse';
  switch (tray.mode) {
    case TrayMode.allAccounts:
    case TrayMode.countPeak:
      return '${pulses.length} 账户 · 峰值 ${_pct(_globalPeak(pulses))}';

    case TrayMode.pinnedAccount:
      for (final a in pulses) {
        if (a.key == tray.pinnedKey) {
          return '${_accountName(a)} ${_pct(a.peakUtilization)}';
        }
      }
      final gp = _globalPeak(pulses);
      return gp == null ? 'quota-pulse' : 'quota-pulse · 峰值 ${_pct(gp)}';

    case TrayMode.globalPeak:
      final gp = _globalPeak(pulses);
      return gp == null ? 'quota-pulse' : 'quota-pulse · 峰值 ${_pct(gp)}';

    case TrayMode.custom:
      return _custom(pulses, tray);
  }
}
