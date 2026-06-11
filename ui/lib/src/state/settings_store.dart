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
enum TrayMode { allAccounts, pinnedAccount, custom }

/// 托盘内容设置(跨平台;Windows=tooltip,macOS=菜单栏标题)。
class TraySettings {
  final TrayMode mode;
  final String? pinnedKey; // "instance|accountId"
  final String? template; // custom 模式:支持 {name} {peak} {count}
  final int tickerMs; // macOS「全部账户」菜单栏滚动步进间隔(ms;越小越顺也越快)
  final int tickerWidth; // macOS 菜单栏滚动窗口宽(可见字符数)

  const TraySettings({
    this.mode = TrayMode.pinnedAccount, // 默认:选中账户的 5h 剩余/重置(未选则取最忙的)
    this.pinnedKey,
    this.template,
    this.tickerMs = 300, // 默认最慢/最稳(滑块下限即此值)
    this.tickerWidth = 10, // 默认窗口宽 10 字
  });

  TraySettings copyWith({
    TrayMode? mode,
    String? pinnedKey,
    String? template,
    int? tickerMs,
    int? tickerWidth,
    bool clearPinned = false,
  }) =>
      TraySettings(
        mode: mode ?? this.mode,
        pinnedKey: clearPinned ? null : (pinnedKey ?? this.pinnedKey),
        template: template ?? this.template,
        tickerMs: tickerMs ?? this.tickerMs,
        tickerWidth: tickerWidth ?? this.tickerWidth,
      );

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'pinned_key': pinnedKey,
        'template': template,
        'ticker_ms': tickerMs,
        'ticker_width': tickerWidth,
      };

  factory TraySettings.fromJson(Map<String, dynamic> j) => TraySettings(
        mode: TrayMode.values.firstWhere(
          (m) => m.name == j['mode'],
          // 老数据若是已移除的 globalPeak/countPeak,迁到新默认(与全新安装一致)。
          orElse: () => TrayMode.pinnedAccount,
        ),
        pinnedKey: j['pinned_key'] as String?,
        template: j['template'] as String?,
        tickerMs: (j['ticker_ms'] as num?)?.toInt() ?? 300,
        tickerWidth: (j['ticker_width'] as num?)?.toInt() ?? 10,
      );
}

/// 顶层设置:多实例 + 布局 + 托盘内容。
class Settings {
  final List<Sub2apiInstance> instances;
  final ListLayout layout;
  final TraySettings tray;
  final ThemeChoice themeMode;

  const Settings({
    this.instances = const [],
    this.layout = ListLayout.grouped,
    this.tray = const TraySettings(),
    this.themeMode = ThemeChoice.system,
  });

  bool get configured => instances.any((i) => i.configured);

  Settings copyWith({
    List<Sub2apiInstance>? instances,
    ListLayout? layout,
    TraySettings? tray,
    ThemeChoice? themeMode,
  }) =>
      Settings(
        instances: instances ?? this.instances,
        layout: layout ?? this.layout,
        tray: tray ?? this.tray,
        themeMode: themeMode ?? this.themeMode,
      );

  /// 构造核心配置 JSON;实例名唯一化(与核心 facade 的去重一致,避免 key 串号)。
  String toConfigJson() {
    final used = <String>{};
    final providers = <Map<String, dynamic>>[];
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
      providers.add({
        'type': 'sub2api',
        'name': unique,
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

  Map<String, dynamic> toJson() => {
        'instances': instances.map((e) => e.toJson()).toList(),
        'layout': layout.name,
        'tray': tray.toJson(),
        'theme_mode': themeMode.name,
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
      );
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
