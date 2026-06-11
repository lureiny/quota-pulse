import 'format.dart';
import 'models/pulse.dart';
import 'state/settings_store.dart';

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

/// 状态 emoji(托盘/菜单栏一眼看出账户健康度)。
String _statusEmoji(PulseStatus s) => switch (s) {
      PulseStatus.ok => '🟢',
      PulseStatus.warning => '🟡',
      PulseStatus.rateLimited => '🔴',
      PulseStatus.forbidden => '⛔',
      PulseStatus.banned => '🚫',
      PulseStatus.needsReauth => '🔑',
      PulseStatus.error => '⚪',
      PulseStatus.unknown => '⚪',
    };

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

/// 全部账户按账户序排序(供 macOS 菜单栏流水屏取序)。
List<AccountPulse> sortedByAccount(List<AccountPulse> pulses) =>
    [...pulses]..sort(_byAccount);

/// 托盘要展示的账户集合(按账户序):
///   全部账户 → 全部;指定账户(多选)→ 命中的子集;都没命中 → 兜底最忙的一个。
List<AccountPulse> trayAccounts(List<AccountPulse> pulses, TraySettings tray) {
  final sorted = sortedByAccount(pulses);
  if (tray.mode == TrayMode.allAccounts) return sorted;
  final keys = tray.pinnedKeys.toSet();
  final pinned = sorted.where((a) => keys.contains(a.key)).toList();
  if (pinned.isNotEmpty) return pinned;
  final top = _topAccount(pulses);
  return top == null ? const [] : [top];
}

/// 单个账户的菜单栏单行(无实例前缀,更短):emoji 名称 用量 · ⏳重置。
/// 供 macOS「全部账户/指定账户」流水屏拼接复用(单行滚动,无需列对齐)。
String renderTrayAccountLine(
  AccountPulse a, {
  required TrayMetric metric,
  required ResetMode resetMode,
}) {
  final m = _fiveHour(a);
  final reset = _reset(m, resetMode);
  final tail = reset.isEmpty ? '' : ' · ⏳$reset';
  return '${_statusEmoji(a.status)} ${_accountName(a)} ${_metricText(m, metric)}$tail';
}

// ---- Windows tooltip 三列对齐(账户 / 用量 / 重置)----
// 比例字体(Segoe UI)下空格补齐只能按"字符显示宽度"近似对齐:CJK/emoji 记 2、其余 1。

bool _isWide(int r) =>
    (r >= 0x1100 && r <= 0x115F) || // Hangul Jamo
    (r >= 0x2300 && r <= 0x27BF) || // 杂项技术/符号(含 ⏳⛔⚪ 等)
    (r >= 0x2E80 && r <= 0xA4CF) || // CJK 部首…彝文
    (r >= 0xAC00 && r <= 0xD7A3) || // Hangul 音节
    (r >= 0xF900 && r <= 0xFAFF) || // CJK 兼容
    (r >= 0xFE30 && r <= 0xFE4F) || // CJK 兼容形式
    (r >= 0xFF00 && r <= 0xFF60) || // 全角
    (r >= 0xFFE0 && r <= 0xFFE6) ||
    (r >= 0x1F300 && r <= 0x1FAFF); // emoji(🟢🔴🔑…)

int _dispWidth(String s) {
  var w = 0;
  for (final r in s.runes) {
    w += _isWide(r) ? 2 : 1;
  }
  return w;
}

String _padRight(String s, int width) {
  final pad = width - _dispWidth(s);
  return pad > 0 ? s + ' ' * pad : s;
}

/// Windows 托盘 tooltip:每账户一行,分「账户 / 用量 / 重置」三列,
/// 各列按最大显示宽度用空格补齐对齐(账户在前)。按 [trayAccounts] 选集渲染。
/// 注:tooltip 总长约 128 字符上限;放不下折叠为"…还有 N 个"。
String renderTrayTooltip(
    List<AccountPulse> pulses, TraySettings tray, ResetMode resetMode) {
  final accounts = trayAccounts(pulses, tray);
  if (accounts.isEmpty) return 'quota-pulse';

  // 先生成三列内容,再求各列最大显示宽度。
  final rows = <List<String>>[];
  for (final a in accounts) {
    final m = _fiveHour(a);
    final reset = _reset(m, resetMode);
    rows.add([
      '${_statusEmoji(a.status)} ${a.instance}·${_accountName(a)}', // 账户列(在前)
      _metricText(m, tray.metric), // 用量列
      reset.isEmpty ? '' : '⏳$reset', // 重置列(末列,不补齐)
    ]);
  }
  var wAcct = 0, wUse = 0;
  for (final r in rows) {
    final a0 = _dispWidth(r[0]), a1 = _dispWidth(r[1]);
    if (a0 > wAcct) wAcct = a0;
    if (a1 > wUse) wUse = a1;
  }

  final lines = <String>[];
  var total = 0;
  for (var i = 0; i < rows.length; i++) {
    final r = rows[i];
    final resetCol = r[2].isEmpty ? '' : '  ${r[2]}';
    final line = '${_padRight(r[0], wAcct)}  ${_padRight(r[1], wUse)}$resetCol';
    if (total + line.length + 1 > 118 && lines.isNotEmpty) {
      lines.add('…还有 ${rows.length - i} 个');
      break;
    }
    lines.add(line);
    total += line.length + 1;
  }
  return lines.join('\n');
}
