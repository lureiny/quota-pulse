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

/// 取指定窗口表盘(id=five_hour / seven_day):
///   精确 id 优先;再按标签兜底(5h→含"5";7d→含"7"/"周"/"week")。
///   5h 再兜底第一个滚动窗口/第一个表盘;7d 取不到返回 null(不回退到 5h 表盘,
///   以免两个窗口取到同一个 meter)。
Meter? _windowMeter(AccountPulse a, String id) {
  for (final m in a.meters) {
    if (m.id == id) return m;
  }
  bool labelMatch(Meter m) {
    if (id == 'five_hour') return m.label.contains('5');
    if (id == 'seven_day') {
      final l = m.label.toLowerCase();
      return m.label.contains('7') || l.contains('周') || l.contains('week');
    }
    return false;
  }

  for (final m in a.meters) {
    if (labelMatch(m)) return m;
  }
  if (id == 'five_hour') {
    for (final m in a.meters) {
      if (m.kind == 'rolling_window') return m;
    }
    return a.meters.isEmpty ? null : a.meters.first;
  }
  return null;
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

/// 按固定顺序(5h→7d,即 [kAlertWindows] 键序)返回要显示的窗口 id;空集合兜底 five_hour。
/// 托盘 tooltip / 菜单栏 / 悬浮窗共用,保证多平台显示窗口一致。
List<String> displayWindowIds(TraySettings tray) {
  final out = [
    for (final id in kAlertWindows.keys)
      if (tray.displayWindows.contains(id)) id,
  ];
  return out.isEmpty ? const ['five_hour'] : out;
}

/// 一个账户在选中窗口集上的用量短语,窗口间用 " · " 连接。
/// [hourglass]=true 时重置前加 ⏳(macOS 菜单栏风格);窗口多于 1 个时各加短标签(5h/7d),
/// 单窗口省略前缀以保持原有观感。
String _windowsPhrase(
  AccountPulse a,
  List<String> windows, {
  required TrayMetric metric,
  required ResetMode resetMode,
  required bool hourglass,
}) {
  final multi = windows.length > 1;
  return windows.map((id) {
    final m = _windowMeter(a, id);
    final reset = _reset(m, resetMode);
    final label = multi ? '${kAlertWindows[id]} ' : '';
    final tail = reset.isEmpty ? '' : (hourglass ? ' · ⏳$reset' : ' · $reset');
    return '$label${_metricText(m, metric)}$tail';
  }).join(' · ');
}

/// 单个账户的菜单栏单行(无实例前缀,更短):emoji 名称 + 各选中窗口的 用量 · ⏳重置。
/// 供 macOS「全部账户/指定账户」流水屏拼接复用(单行滚动,无需列对齐)。
String renderTrayAccountLine(
  AccountPulse a, {
  required TrayMetric metric,
  required ResetMode resetMode,
  required List<String> windows,
}) {
  final body = _windowsPhrase(a, windows,
      metric: metric, resetMode: resetMode, hourglass: true);
  return '${_statusEmoji(a.status)} ${_accountName(a)} $body';
}

/// Windows 悬浮跑马灯的一段:一个着色圆点 + 不含 emoji 的文本。
/// 原生侧把 [color] 画成圆点(规避 Windows 彩色 emoji 的渲染复杂度)、[text] 用主题色绘制。
/// 账户段([newAccount]=true)= 状态色 + 账户名;窗口段 = 用量分级色 + 标签/用量/重置。
class TickerSeg {
  final int color; // 圆点色 ARGB(0xFFRRGGBB):账户段=状态色,窗口段=用量分级色
  final String text;
  final bool newAccount; // 是否一个账户的起始段(滚动行账户间用更大间隔)
  const TickerSeg(this.color, this.text, {this.newAccount = false});
}

/// Windows 跑马灯(单行滚动)内容:每个账户先一段(状态色圆点 + 名),再对每个选中窗口
/// 一段(用量分级色圆点 + 标签 用量 · 重置)。账户起始段标 [TickerSeg.newAccount],
/// 供原生在账户之间用更大间隔。与 macOS 菜单栏同源(选集/窗口一致),只是状态/用量走原生圆点。
List<TickerSeg> tickerSegments(
  List<AccountPulse> pulses,
  TraySettings tray,
  ResetMode resetMode,
) {
  final windows = displayWindowIds(tray);
  final multi = windows.length > 1;
  final out = <TickerSeg>[];
  for (final a in trayAccounts(pulses, tray)) {
    out.add(TickerSeg(statusColor(a.status).value, _accountName(a),
        newAccount: true));
    for (final id in windows) {
      final m = _windowMeter(a, id);
      final reset = _reset(m, resetMode);
      final label = multi ? '${kAlertWindows[id]} ' : '';
      final tail = reset.isEmpty ? '' : ' · $reset';
      out.add(TickerSeg(meterColor(m?.utilization).value,
          '$label${_metricText(m, tray.metric)}$tail'));
    }
  }
  if (out.isEmpty) {
    out.add(const TickerSeg(0xFF8E8E93, 'quota-pulse', newAccount: true));
  }
  return out;
}

/// Windows 浮窗「多行模式」的一行:着色圆点(可选)+ 缩进 + 文本。
/// 原生侧 dot=true 时画前导圆点([color] ARGB:account 行=状态色,窗口行=用量分级色);
/// indent 为缩进级别(0/1);[text] 内若含制表符 \t,原生按列对齐(实现 account 内重置列对齐)。
class TickerLine {
  final bool dot;
  final int color;
  final int indent;
  final String text;
  const TickerLine({
    required this.dot,
    required this.color,
    required this.indent,
    required this.text,
  });
}

/// Windows 浮窗多行模式内容:每账户 1 行基础信息(状态色圆点 + 实例·名)
/// + 每个选中窗口 1 行(用量分级色圆点 + 缩进:`标签 用量` \t `· ⏳重置`)。
/// 默认两窗口都选 → base/5h/7d 三行;窗口行以 \t 分两列,原生按列对齐(各窗口行重置列对齐)。
List<TickerLine> tickerLines(
  List<AccountPulse> pulses,
  TraySettings tray,
  ResetMode resetMode,
) {
  final windows = displayWindowIds(tray);
  final out = <TickerLine>[];
  for (final a in trayAccounts(pulses, tray)) {
    out.add(TickerLine(
      dot: true,
      color: statusColor(a.status).value,
      indent: 0,
      text: '${a.instance}·${_accountName(a)}',
    ));
    for (final id in windows) {
      final m = _windowMeter(a, id);
      final reset = _reset(m, resetMode);
      final col1 = '${kAlertWindows[id]} ${_metricText(m, tray.metric)}';
      // 用 \t 把「标签 用量」与「· ⏳重置」分成两列,原生设制表位让重置列对齐。
      final text = reset.isEmpty ? col1 : '$col1\t· ⏳$reset';
      out.add(TickerLine(
        dot: true,
        color: meterColor(m?.utilization).value,
        indent: 1,
        text: text,
      ));
    }
  }
  if (out.isEmpty) {
    out.add(const TickerLine(
        dot: false, color: 0xFF8E8E93, indent: 0, text: 'quota-pulse'));
  }
  return out;
}

/// Windows 托盘 tooltip:每个账户占「1 行基础信息 + 每个选中窗口 1 行」——
///   行1:状态emoji + 实例·账户名;随后每个选中窗口一行(缩进:标签 用量/剩余 · ⏳重置)。
/// 比例字体(Segoe UI,app 改不了)下多账户的"列"无法用空格对齐(空格宽 ≠ 字宽),
/// 故改用每账户独立块:块结构一致即视觉整齐。按 [trayAccounts] 选集 + [displayWindowIds] 窗口渲染;
/// tooltip 约 128 字上限,放不下折叠为"…还有 N 个"。
String renderTrayTooltip(
    List<AccountPulse> pulses, TraySettings tray, ResetMode resetMode) {
  final accounts = trayAccounts(pulses, tray);
  if (accounts.isEmpty) return 'quota-pulse';
  final windows = displayWindowIds(tray);
  final multi = windows.length > 1;
  final lines = <String>[];
  var total = 0;
  for (var i = 0; i < accounts.length; i++) {
    final a = accounts[i];
    final l1 = '${_statusEmoji(a.status)} ${a.instance}·${_accountName(a)}';
    final wlines = windows.map((id) {
      final m = _windowMeter(a, id);
      final reset = _reset(m, resetMode);
      final label = multi ? '${kAlertWindows[id]} ' : '';
      return reset.isEmpty
          ? '    $label${_metricText(m, tray.metric)}'
          : '    $label${_metricText(m, tray.metric)} · ⏳$reset';
    }).toList();
    // 每行各含一个换行:基础行 + N 个窗口行。
    final cost = l1.length +
        wlines.fold<int>(0, (s, w) => s + w.length) +
        1 +
        wlines.length;
    if (total + cost > 118 && lines.isNotEmpty) {
      lines.add('…还有 ${accounts.length - i} 个');
      break;
    }
    lines.add(l1);
    lines.addAll(wlines);
    total += cost;
  }
  return lines.join('\n');
}
