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

/// 选中(钉住)的账户;找不到则退回使用率最高的那个,保证总有内容。
AccountPulse? _selected(List<AccountPulse> pulses, TraySettings tray) {
  for (final a in pulses) {
    if (a.key == tray.pinnedKey) return a;
  }
  return _topAccount(pulses);
}

/// 取"5 小时"窗口表盘:优先 id=five_hour;兜底标签含 5、再兜底第一个滚动窗口/第一个表盘。
Meter? _fiveHour(AccountPulse a) {
  for (final m in a.meters) {
    if (m.id == 'five_hour') return m;
  }
  for (final m in a.meters) {
    if (m.label.contains('5')) return m;
  }
  for (final m in a.meters) {
    if (m.kind == 'rolling_window') return m;
  }
  return a.meters.isEmpty ? null : a.meters.first;
}

/// 剩余量 = 1 - 使用率(剩余百分比)。
String _remain(Meter? m) {
  final u = m?.utilization;
  if (u == null) return '—';
  final r = (1 - u).clamp(0.0, 1.0);
  return '${(r * 100).round()}%';
}

/// 重置倒计时 "2h13m" / "45m" / "30s"(无则空)。
String _dur(int? secs) {
  if (secs == null || secs <= 0) return '';
  final h = secs ~/ 3600, m = (secs % 3600) ~/ 60;
  if (h > 0) return '${h}h${m}m';
  if (m > 0) return '${m}m';
  return '${secs}s';
}

String _meterLabel(Meter? m) =>
    (m != null && m.label.isNotEmpty) ? m.label : '5h';

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

/// Windows 托盘 tooltip:多行,按 [TraySettings] 模式渲染。
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
      // 选中账户的 5 小时窗口:剩余量 + 重置倒计时(与 macOS 菜单栏一致)。
      final a = _selected(pulses, tray);
      if (a == null) return 'quota-pulse';
      final m = _fiveHour(a);
      final reset = _dur(m?.remainingSecs);
      final line2 = reset.isEmpty
          ? '${_meterLabel(m)} 剩 ${_remain(m)}'
          : '${_meterLabel(m)} 剩 ${_remain(m)}  ·  $reset 后重置';
      return '${_accountName(a)}\n$line2';

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
      // 选中账户的 5 小时窗口:剩余量 + 重置倒计时。
      final a = _selected(pulses, tray);
      if (a == null) return 'quota-pulse';
      final m = _fiveHour(a);
      final reset = _dur(m?.remainingSecs);
      final tail = reset.isEmpty ? '' : ' · $reset';
      return '${_accountName(a)} 剩${_remain(m)}$tail';

    case TrayMode.globalPeak:
      final gp = _globalPeak(pulses);
      return gp == null ? 'quota-pulse' : 'quota-pulse · 峰值 ${_pct(gp)}';

    case TrayMode.custom:
      return _custom(pulses, tray);
  }
}
