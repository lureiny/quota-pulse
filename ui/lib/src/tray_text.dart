import 'format.dart';
import 'models/pulse.dart';
import 'state/settings_store.dart';

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

/// 按设置显示"使用量"或"剩余量":使用量=利用率(可 >100% 即超额),剩余量=1-利用率。
String _metricText(Meter? m, TrayMetric metric) {
  final u = m?.utilization;
  if (u == null) return '—';
  if (metric == TrayMetric.usage) {
    return '用 ${(u * 100).round()}%';
  }
  final r = (1 - u).clamp(0.0, 1.0);
  return '剩 ${(r * 100).round()}%';
}

/// 该 meter 的重置短语(倒计时 / 绝对),无数据返回空串。
String _reset(Meter? m, ResetMode mode) => fmtResetPhrase(
      m?.remainingSecs,
      m?.resetsAt,
      absolute: mode == ResetMode.absolute,
    );

String _meterLabel(Meter? m) => (m != null && m.label.isNotEmpty) ? m.label : '5h';

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

/// 单个账户的菜单栏/单行表示:名称 + 5h 使用/剩余 + 重置(倒计时或绝对)。
/// 供「指定账户」模式与 macOS「全部账户」流水屏复用。
String renderTrayAccountLine(
  AccountPulse a, {
  required TrayMetric metric,
  required ResetMode resetMode,
}) {
  final m = _fiveHour(a);
  final reset = _reset(m, resetMode);
  final tail = reset.isEmpty ? '' : ' · $reset';
  return '${_accountName(a)} ${_metricText(m, metric)}$tail';
}

/// 全部账户按账户序排序(供 macOS 菜单栏流水屏取序)。
List<AccountPulse> sortedByAccount(List<AccountPulse> pulses) =>
    [...pulses]..sort(_byAccount);

/// Windows 托盘 tooltip:多行,按 [TraySettings] 模式渲染。
/// 注:Windows tooltip 总长约 128 字符上限;放不下的账户折叠为"…还有 N 个"。
/// 要即时看全部请左键点托盘。
String renderTrayTooltip(
    List<AccountPulse> pulses, TraySettings tray, ResetMode resetMode) {
  if (pulses.isEmpty) return 'quota-pulse';
  switch (tray.mode) {
    case TrayMode.allAccounts:
      // 每个账户一行,统一展示 5h 使用/剩余 + 重置(与 macOS 菜单栏一致)。
      final sorted = sortedByAccount(pulses);
      final lines = <String>[];
      var total = 0;
      for (var i = 0; i < sorted.length; i++) {
        final a = sorted[i];
        final m = _fiveHour(a);
        final reset = _reset(m, resetMode);
        final tail = reset.isEmpty ? '' : ' · $reset';
        final line =
            '${a.instance}·${_accountName(a)}  ${_metricText(m, tray.metric)}$tail';
        if (total + line.length + 1 > 118 && lines.isNotEmpty) {
          lines.add('…还有 ${sorted.length - i} 个');
          break;
        }
        lines.add(line);
        total += line.length + 1;
      }
      return lines.join('\n');

    case TrayMode.pinnedAccount:
      // 选中账户的 5 小时窗口:使用/剩余 + 重置(与 macOS 菜单栏一致)。
      final a = _selected(pulses, tray);
      if (a == null) return 'quota-pulse';
      final m = _fiveHour(a);
      final reset = _reset(m, resetMode);
      final line2 = reset.isEmpty
          ? '${_meterLabel(m)} ${_metricText(m, tray.metric)}'
          : '${_meterLabel(m)} ${_metricText(m, tray.metric)}  ·  $reset';
      return '${_accountName(a)}\n$line2';

    case TrayMode.custom:
      return _custom(pulses, tray);
  }
}

/// macOS 菜单栏标题(单行,空间有限)。
/// 「全部账户」多个时由壳层用 [renderTrayAccountLine] + [sortedByAccount] 拼成流水屏;
/// 这里只兜底单个/直接调用的情况。
String renderTrayText(
    List<AccountPulse> pulses, TraySettings tray, ResetMode resetMode) {
  if (pulses.isEmpty) return 'quota-pulse';
  switch (tray.mode) {
    case TrayMode.allAccounts:
      return renderTrayAccountLine(sortedByAccount(pulses).first,
          metric: tray.metric, resetMode: resetMode);

    case TrayMode.pinnedAccount:
      final a = _selected(pulses, tray);
      return a == null
          ? 'quota-pulse'
          : renderTrayAccountLine(a, metric: tray.metric, resetMode: resetMode);

    case TrayMode.custom:
      return _custom(pulses, tray);
  }
}
