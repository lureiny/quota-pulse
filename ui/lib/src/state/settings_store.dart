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

/// 托盘内容设置(跨平台;Windows=tooltip,macOS=菜单栏标题)。
class TraySettings {
  final TrayMode mode;
  final List<String> pinnedKeys; // 指定账户(可多选)的 key 列表 "instance|accountId"
  final int tickerMs; // macOS「全部账户」菜单栏滚动步进间隔(ms;越小越顺也越快)
  final int tickerWidth; // macOS 菜单栏滚动窗口宽(可见字符数)
  final TrayMetric metric; // 显示使用量 / 剩余量(默认使用量)

  const TraySettings({
    this.mode = TrayMode.allAccounts, // 默认:全部账户
    this.pinnedKeys = const [],
    this.tickerMs = 300, // 默认最慢/最稳(滑块下限即此值)
    this.tickerWidth = 10, // 默认窗口宽 10 字
    this.metric = TrayMetric.usage, // 默认显示使用量
  });

  TraySettings copyWith({
    TrayMode? mode,
    List<String>? pinnedKeys,
    int? tickerMs,
    int? tickerWidth,
    TrayMetric? metric,
  }) =>
      TraySettings(
        mode: mode ?? this.mode,
        pinnedKeys: pinnedKeys ?? this.pinnedKeys,
        tickerMs: tickerMs ?? this.tickerMs,
        tickerWidth: tickerWidth ?? this.tickerWidth,
        metric: metric ?? this.metric,
      );

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'pinned_keys': pinnedKeys,
        'ticker_ms': tickerMs,
        'ticker_width': tickerWidth,
        'metric': metric.name,
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

  const Settings({
    this.instances = const [],
    this.layout = ListLayout.grouped,
    this.tray = const TraySettings(),
    this.themeMode = ThemeChoice.system,
    this.resetMode = ResetMode.countdown,
  });

  bool get configured => instances.any((i) => i.configured);

  Settings copyWith({
    List<Sub2apiInstance>? instances,
    ListLayout? layout,
    TraySettings? tray,
    ThemeChoice? themeMode,
    ResetMode? resetMode,
  }) =>
      Settings(
        instances: instances ?? this.instances,
        layout: layout ?? this.layout,
        tray: tray ?? this.tray,
        themeMode: themeMode ?? this.themeMode,
        resetMode: resetMode ?? this.resetMode,
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
        'accounts': {
          'filter': {'status': 'active'}
        },
        'poll': {'passive_interval': '60s', 'active_interval': '10m'},
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
