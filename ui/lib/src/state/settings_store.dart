import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

/// 一个 sub2api 实例(一个后台 + 一份鉴权)。
class Sub2apiInstance {
  final String id; // 稳定 id(钉住托盘 / 列表 key 用)
  final String name;
  final String baseUrl;
  final String apiKey;

  const Sub2apiInstance({
    required this.id,
    this.name = '',
    this.baseUrl = '',
    this.apiKey = '',
  });

  bool get configured => baseUrl.trim().isNotEmpty && apiKey.trim().isNotEmpty;

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'base_url': baseUrl, 'api_key': apiKey};

  factory Sub2apiInstance.fromJson(Map<String, dynamic> j) => Sub2apiInstance(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        baseUrl: j['base_url'] as String? ?? '',
        apiKey: j['api_key'] as String? ?? '',
      );
}

/// 多实例列表布局。
enum ListLayout { grouped, tabs }

/// 主题模式(可设置;默认跟随系统)。
enum ThemeChoice { system, light, dark }

extension ThemeChoiceX on ThemeChoice {
  ThemeMode toThemeMode() => switch (this) {
        ThemeChoice.system => ThemeMode.system,
        ThemeChoice.light => ThemeMode.light,
        ThemeChoice.dark => ThemeMode.dark,
      };
}

/// 托盘显示内容模式。
enum TrayMode { allAccounts, pinnedAccounts }

/// 托盘显示量:使用量(利用率)或剩余量(1-利用率)。默认使用量。
enum TrayMetric { usage, remaining }

/// 重置时间显示:倒计时(剩余时间)或绝对时刻。主页与托盘/菜单栏同时生效。
enum ResetMode { countdown, absolute }

/// 可作为通知触发源的滚动窗口(id → 展示名);当前支持 Claude 5h / 7d。
/// id 与 core mapper 一致(five_hour / seven_day)。
const Map<String, String> kAlertWindows = {
  'five_hour': '5h',
  'seven_day': '7d',
};

/// 超阈值通知默认监听的窗口(5h + 7d 都开)。
const Set<String> _kDefaultOverWindows = {'five_hour', 'seven_day'};

/// 托盘/悬浮窗/菜单栏默认显示的窗口(5h + 7d 都显示;多行模式即 base/5h/7d 三行)。
const Set<String> _kDefaultDisplayWindows = {'five_hour', 'seven_day'};

/// 解析窗口集合;缺省(键不存在)用 fallback,空列表表示"全关"。
Set<String> _parseWindowSet(Object? raw, Set<String> fallback) {
  if (raw is List) {
    return raw.map((e) => e.toString()).where(kAlertWindows.containsKey).toSet();
  }
  return {...fallback};
}

/// 托盘内容设置(跨平台;Windows=tooltip,macOS=菜单栏标题)。
class TraySettings {
  final TrayMode mode;
  final List<String> pinnedKeys; // 指定账户(可多选)的 key 列表 "instance|accountId"
  final int tickerMs; // 滚动步进间隔(ms;越小越顺也越快)。macOS 菜单栏 + Windows 跑马灯共用
  final int tickerWidth; // 滚动可见宽(字符数)。macOS 菜单栏 + Windows 跑马灯共用
  final TrayMetric metric; // 显示使用量 / 剩余量(默认使用量)
  final Set<String> displayWindows; // 显示哪些滚动窗口(5h/7d,可多选;跨平台生效)
  // Windows 桌面悬浮跑马灯(macOS 无此项;原生浮窗,见 apps/windows/runner_patches/win_ticker)
  final bool windowsTickerEnabled; // 是否启用(默认开)
  final bool windowsTickerMultiline; // 显示模式:false=单行滚动(默认),true=多行铺开
  final bool windowsTickerHideFullscreen; // 前台全屏时自动隐藏(默认关=始终显示)
  final int? windowsTickerX; // 浮窗位置(物理像素;null=原生用默认右下角)
  final int? windowsTickerY;
  // Windows 滚动浮窗可见宽(逻辑像素;可拖拽浮窗边缘或设置滑块调到整屏宽)。
  // null=沿用 tickerWidth*9 兜底,保证老用户无回归;一经拖拽/拉滑块即写入具体像素值。
  final int? windowsTickerWidth;
  // Windows 浮窗「空闲透明度」百分比(鼠标不在窗口上时):0=关闭(常亮不透明),越大越透。
  // 默认 40(≈60% 不透明)。滚动/多行均生效。
  final int windowsTickerIdleTransparency;

  const TraySettings({
    this.mode = TrayMode.allAccounts, // 默认:全部账户
    this.pinnedKeys = const [],
    this.tickerMs = 300, // 默认最慢/最稳(滑块下限即此值)
    this.tickerWidth = 10, // 默认窗口宽 10 字
    this.metric = TrayMetric.usage, // 默认显示使用量
    this.displayWindows = _kDefaultDisplayWindows, // 默认 5h + 7d 都显示
    this.windowsTickerEnabled = true, // 默认开启
    this.windowsTickerMultiline = false, // 默认单行滚动
    this.windowsTickerHideFullscreen = false,
    this.windowsTickerX,
    this.windowsTickerY,
    this.windowsTickerWidth,
    this.windowsTickerIdleTransparency = 40,
  });

  TraySettings copyWith({
    TrayMode? mode,
    List<String>? pinnedKeys,
    int? tickerMs,
    int? tickerWidth,
    TrayMetric? metric,
    Set<String>? displayWindows,
    bool? windowsTickerEnabled,
    bool? windowsTickerMultiline,
    bool? windowsTickerHideFullscreen,
    int? windowsTickerX,
    int? windowsTickerY,
    int? windowsTickerWidth,
    int? windowsTickerIdleTransparency,
  }) =>
      TraySettings(
        mode: mode ?? this.mode,
        pinnedKeys: pinnedKeys ?? this.pinnedKeys,
        tickerMs: tickerMs ?? this.tickerMs,
        tickerWidth: tickerWidth ?? this.tickerWidth,
        metric: metric ?? this.metric,
        displayWindows: displayWindows ?? this.displayWindows,
        windowsTickerEnabled: windowsTickerEnabled ?? this.windowsTickerEnabled,
        windowsTickerMultiline:
            windowsTickerMultiline ?? this.windowsTickerMultiline,
        windowsTickerHideFullscreen:
            windowsTickerHideFullscreen ?? this.windowsTickerHideFullscreen,
        windowsTickerX: windowsTickerX ?? this.windowsTickerX,
        windowsTickerY: windowsTickerY ?? this.windowsTickerY,
        windowsTickerWidth: windowsTickerWidth ?? this.windowsTickerWidth,
        windowsTickerIdleTransparency:
            windowsTickerIdleTransparency ?? this.windowsTickerIdleTransparency,
      );

  /// 清掉浮窗位置(「重置位置」用;copyWith 无法把字段置回 null)。
  TraySettings clearWindowsTickerPos() => TraySettings(
        mode: mode,
        pinnedKeys: pinnedKeys,
        tickerMs: tickerMs,
        tickerWidth: tickerWidth,
        metric: metric,
        displayWindows: displayWindows,
        windowsTickerEnabled: windowsTickerEnabled,
        windowsTickerMultiline: windowsTickerMultiline,
        windowsTickerHideFullscreen: windowsTickerHideFullscreen,
        windowsTickerX: null,
        windowsTickerY: null,
        windowsTickerWidth: windowsTickerWidth, // 重置位置不动宽度
        windowsTickerIdleTransparency: windowsTickerIdleTransparency,
      );

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'pinned_keys': pinnedKeys,
        'ticker_ms': tickerMs,
        'ticker_width': tickerWidth,
        'metric': metric.name,
        'display_windows': displayWindows.toList(),
        'win_ticker_enabled': windowsTickerEnabled,
        'win_ticker_multiline': windowsTickerMultiline,
        'win_ticker_hide_fullscreen': windowsTickerHideFullscreen,
        if (windowsTickerX != null) 'win_ticker_x': windowsTickerX,
        if (windowsTickerY != null) 'win_ticker_y': windowsTickerY,
        if (windowsTickerWidth != null) 'win_ticker_width': windowsTickerWidth,
        'win_ticker_idle_transparency': windowsTickerIdleTransparency,
      };

  factory TraySettings.fromJson(Map<String, dynamic> j) => TraySettings(
        mode: _parseTrayMode(j['mode']),
        pinnedKeys: _parsePinnedKeys(j),
        tickerMs: (j['ticker_ms'] as num?)?.toInt() ?? 300,
        tickerWidth: (j['ticker_width'] as num?)?.toInt() ?? 10,
        metric: TrayMetric.values.firstWhere(
          (m) => m.name == j['metric'],
          orElse: () => TrayMetric.usage,
        ),
        displayWindows:
            _parseWindowSet(j['display_windows'], _kDefaultDisplayWindows),
        windowsTickerEnabled: j['win_ticker_enabled'] as bool? ?? true,
        windowsTickerMultiline: j['win_ticker_multiline'] as bool? ?? false,
        windowsTickerHideFullscreen:
            j['win_ticker_hide_fullscreen'] as bool? ?? false,
        windowsTickerX: (j['win_ticker_x'] as num?)?.toInt(),
        windowsTickerY: (j['win_ticker_y'] as num?)?.toInt(),
        windowsTickerWidth: (j['win_ticker_width'] as num?)?.toInt(),
        windowsTickerIdleTransparency:
            (j['win_ticker_idle_transparency'] as num?)?.toInt() ?? 40,
      );
}

/// 迁移:老的 pinnedAccount → pinnedAccounts;已移除的 custom/未知 → allAccounts。
TrayMode _parseTrayMode(Object? raw) {
  switch (raw) {
    case 'pinnedAccount':
    case 'pinnedAccounts':
      return TrayMode.pinnedAccounts;
    default:
      return TrayMode.allAccounts;
  }
}

/// 迁移:新 pinned_keys(列表)优先;否则取老的单个 pinned_key。
List<String> _parsePinnedKeys(Map<String, dynamic> j) {
  final list = j['pinned_keys'];
  if (list is List) {
    return list.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
  }
  final single = j['pinned_key'];
  if (single is String && single.isNotEmpty) return [single];
  return const [];
}

/// 顶层设置:多实例 + 布局 + 托盘内容。
class Settings {
  final List<Sub2apiInstance> instances;
  final ListLayout layout;
  final TraySettings tray;
  final ThemeChoice themeMode;
  final ResetMode resetMode; // 重置时间:倒计时 / 绝对(主页 + 托盘/菜单栏同时生效)
  final bool alertEnabled; // 通知总开关(默认开)
  final int alertThreshold; // 提醒阈值(百分比,默认 90;超阈值与恢复共用此边界)
  final Set<String> alertOverWindows; // 超阈值通知监听的窗口(默认 5h+7d)
  final Set<String> alertRecoverWindows; // 额度恢复通知监听的窗口(默认空=关)
  // 后台拉取节奏(喂给核心 poll 配置):
  final int pollPassiveSecs; // 被动刷新间隔(读 sub2api 缓存,始终开;默认 60s)
  final bool pollActiveEnabled; // 自动强制回源开关(有自动化特征,默认关)
  final int pollActiveSecs; // 自动回源间隔(仅 pollActiveEnabled 时生效;默认 600s=10m)

  const Settings({
    this.instances = const [],
    this.layout = ListLayout.grouped,
    this.tray = const TraySettings(),
    this.themeMode = ThemeChoice.system,
    this.resetMode = ResetMode.countdown,
    this.alertEnabled = true,
    this.alertThreshold = 90,
    this.alertOverWindows = _kDefaultOverWindows,
    this.alertRecoverWindows = const <String>{},
    this.pollPassiveSecs = 60,
    this.pollActiveEnabled = false,
    this.pollActiveSecs = 600,
  });

  bool get configured => instances.any((i) => i.configured);

  Settings copyWith({
    List<Sub2apiInstance>? instances,
    ListLayout? layout,
    TraySettings? tray,
    ThemeChoice? themeMode,
    ResetMode? resetMode,
    bool? alertEnabled,
    int? alertThreshold,
    Set<String>? alertOverWindows,
    Set<String>? alertRecoverWindows,
    int? pollPassiveSecs,
    bool? pollActiveEnabled,
    int? pollActiveSecs,
  }) =>
      Settings(
        instances: instances ?? this.instances,
        layout: layout ?? this.layout,
        tray: tray ?? this.tray,
        themeMode: themeMode ?? this.themeMode,
        resetMode: resetMode ?? this.resetMode,
        alertEnabled: alertEnabled ?? this.alertEnabled,
        alertThreshold: alertThreshold ?? this.alertThreshold,
        alertOverWindows: alertOverWindows ?? this.alertOverWindows,
        alertRecoverWindows: alertRecoverWindows ?? this.alertRecoverWindows,
        pollPassiveSecs: pollPassiveSecs ?? this.pollPassiveSecs,
        pollActiveEnabled: pollActiveEnabled ?? this.pollActiveEnabled,
        pollActiveSecs: pollActiveSecs ?? this.pollActiveSecs,
      );

  /// 已配置实例 → (唯一展示名, 实例)。唯一名规则与核心 facade 去重一致(避免 key 串号),
  /// 也与 poller 盖到 pulse.instance 上的名字一致 —— 主页据此把实例名匹配到 URL。
  List<MapEntry<String, Sub2apiInstance>> _uniqueInstances() {
    final used = <String>{};
    final out = <MapEntry<String, Sub2apiInstance>>[];
    for (var i = 0; i < instances.length; i++) {
      final inst = instances[i];
      if (!inst.configured) continue;
      final base = inst.name.trim().isEmpty ? 'sub2api ${i + 1}' : inst.name.trim();
      var unique = base;
      var k = 2;
      while (used.contains(unique)) {
        unique = '$base ($k)';
        k++;
      }
      used.add(unique);
      out.add(MapEntry(unique, inst));
    }
    return out;
  }

  /// 构造核心配置 JSON。
  String toConfigJson() {
    final providers = <Map<String, dynamic>>[];
    for (final e in _uniqueInstances()) {
      final inst = e.value;
      providers.add({
        'type': 'sub2api',
        'name': e.key,
        'base_url': inst.baseUrl.trim(),
        'api_key': inst.apiKey.trim(),
        // 不按 status 过滤:账户限流后 sub2api 会把它改成非 active(自动停用),
        // 过滤会让它从列表消失(网页仍可见)。拉全部账户,真实状态由 UI 状态点体现。
        // 拉取节奏来自设置:被动刷新固定开;自动回源默认关(active_interval=0s 即关)。
        'poll': {
          'passive_interval': '${pollPassiveSecs}s',
          'active_interval': pollActiveEnabled ? '${pollActiveSecs}s' : '0s',
        },
      });
    }
    return jsonEncode({'providers': providers});
  }

  /// 实例(唯一展示名,与 pulse.instance 一致)→ 后台源站 URL(scheme://host[:port],去路径)。
  /// 供主页把实例名做成"点击打开后台"超链接。
  Map<String, String> instanceUrls() {
    final out = <String, String>{};
    for (final e in _uniqueInstances()) {
      final origin = _originOf(e.value.baseUrl.trim());
      if (origin.isNotEmpty) out[e.key] = origin;
    }
    return out;
  }

  Map<String, dynamic> toJson() => {
        'instances': instances.map((e) => e.toJson()).toList(),
        'layout': layout.name,
        'tray': tray.toJson(),
        'theme_mode': themeMode.name,
        'reset_mode': resetMode.name,
        'alert_enabled': alertEnabled,
        'alert_threshold': alertThreshold,
        'alert_over_windows': alertOverWindows.toList(),
        'alert_recover_windows': alertRecoverWindows.toList(),
        'poll_passive_secs': pollPassiveSecs,
        'poll_active_enabled': pollActiveEnabled,
        'poll_active_secs': pollActiveSecs,
      };

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
        instances: ((j['instances'] as List?) ?? const [])
            .map((e) => Sub2apiInstance.fromJson(e as Map<String, dynamic>))
            .toList(),
        layout: ListLayout.values.firstWhere(
          (l) => l.name == j['layout'],
          orElse: () => ListLayout.grouped,
        ),
        tray: j['tray'] != null
            ? TraySettings.fromJson(j['tray'] as Map<String, dynamic>)
            : const TraySettings(),
        themeMode: ThemeChoice.values.firstWhere(
          (t) => t.name == j['theme_mode'],
          orElse: () => ThemeChoice.system,
        ),
        resetMode: ResetMode.values.firstWhere(
          (r) => r.name == j['reset_mode'],
          orElse: () => ResetMode.countdown,
        ),
        alertEnabled: j['alert_enabled'] as bool? ?? true,
        alertThreshold: (j['alert_threshold'] as num?)?.toInt() ?? 90,
        alertOverWindows:
            _parseWindowSet(j['alert_over_windows'], _kDefaultOverWindows),
        alertRecoverWindows:
            _parseWindowSet(j['alert_recover_windows'], const <String>{}),
        pollPassiveSecs: (j['poll_passive_secs'] as num?)?.toInt() ?? 60,
        pollActiveEnabled: j['poll_active_enabled'] as bool? ?? false,
        pollActiveSecs: (j['poll_active_secs'] as num?)?.toInt() ?? 600,
      );
}

/// 从 baseUrl 取源站 "scheme://host[:port]"(去掉路径);无 scheme 时按 https 处理。
/// 无法解析(无 host)返回空串。
String _originOf(String raw) {
  if (raw.isEmpty) return '';
  final s = (raw.startsWith('http://') || raw.startsWith('https://'))
      ? raw
      : 'https://$raw';
  final u = Uri.tryParse(s);
  if (u == null || u.host.isEmpty) return '';
  return '${u.scheme}://${u.host}${u.hasPort ? ':${u.port}' : ''}';
}

/// 持久化:整个 Settings 存成一个 JSON;兼容迁移旧的单实例键。
class SettingsStore {
  static const _kSettings = 'qp.settings';
  static const _kOldBaseUrl = 'qp.base_url';
  static const _kOldApiKey = 'qp.api_key';

  static Future<Settings> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kSettings);
    if (raw != null && raw.isNotEmpty) {
      try {
        return Settings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {
        // 损坏 → 落到迁移/空
      }
    }
    // 迁移旧的单实例配置
    final oldUrl = p.getString(_kOldBaseUrl) ?? '';
    final oldKey = p.getString(_kOldApiKey) ?? '';
    if (oldUrl.isNotEmpty || oldKey.isNotEmpty) {
      return Settings(instances: [
        Sub2apiInstance(id: 'i1', name: 'sub2api', baseUrl: oldUrl, apiKey: oldKey),
      ]);
    }
    return const Settings();
  }

  static Future<void> save(Settings s) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kSettings, jsonEncode(s.toJson()));
  }
}
