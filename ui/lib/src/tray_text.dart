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

/// Windows 悬浮跑马灯的一段:一个账户 = 状态色 + 不含 emoji 的文本。
/// 原生侧把 [color] 画成圆点(规避 Windows 彩色 emoji 的渲染复杂度)、[text] 用主题色绘制。
class TickerSeg {
  final int color; // 状态色 ARGB(0xFFRRGGBB)
  final String text;
  const TickerSeg(this.color, this.text);
}

String _tickerLine(AccountPulse a,
    {required TrayMetric metric, required ResetMode resetMode}) {
  final m = _fiveHour(a);
  final reset = _reset(m, resetMode);
  final tail = reset.isEmpty ? '' : ' · $reset';
  return '${_accountName(a)} ${_metricText(m, metric)}$tail';
}

/// Windows 跑马灯内容:按 [trayAccounts] 选集,逐账户给 (状态色, 文本)。
/// 与 macOS 菜单栏同源(同一选集 / 同样的 5h 用量+重置),只是去掉 emoji、状态走原生圆点。
List<TickerSeg> tickerSegments(
  List<AccountPulse> pulses,
  TraySettings tray,
  ResetMode resetMode,
) =>
    [
      for (final a in trayAccounts(pulses, tray))
        TickerSeg(
          statusColor(a.status).value,
          _tickerLine(a, metric: tray.metric, resetMode: resetMode),
        ),
    ];

/// Windows 托盘 tooltip:每个账户占两行——
///   行1:状态emoji + 实例·账户名;行2(缩进):5h 用量/剩余 · ⏳重置。
/// 比例字体(Segoe UI,app 改不了)下多账户的"列"无法用空格对齐(空格宽 ≠ 字宽),
/// 故改用每账户独立两行块:块结构一致即视觉整齐。按 [trayAccounts] 选集渲染;
/// tooltip 约 128 字上限,放不下折叠为"…还有 N 个"。
String renderTrayTooltip(
    List<AccountPulse> pulses, TraySettings tray, ResetMode resetMode) {
  final accounts = trayAccounts(pulses, tray);
  if (accounts.isEmpty) return 'quota-pulse';
  final lines = <String>[];
  var total = 0;
  for (var i = 0; i < accounts.length; i++) {
    final a = accounts[i];
    final m = _fiveHour(a);
    final reset = _reset(m, resetMode);
    final l1 = '${_statusEmoji(a.status)} ${a.instance}·${_accountName(a)}';
    final l2 = reset.isEmpty
        ? '    ${_metricText(m, tray.metric)}'
        : '    ${_metricText(m, tray.metric)} · ⏳$reset';
    final cost = l1.length + l2.length + 2; // 两行各含一个换行
    if (total + cost > 118 && lines.isNotEmpty) {
      lines.add('…还有 ${accounts.length - i} 个');
      break;
    }
    lines.add(l1);
    lines.add(l2);
    total += cost;
  }
  return lines.join('\n');
}
