import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Settings 保存用户输入的连接信息(v1 仅一个 sub2api)。
class Settings {
  final String baseUrl;
  final String apiKey;

  const Settings({this.baseUrl = '', this.apiKey = ''});

  bool get configured => baseUrl.trim().isNotEmpty && apiKey.trim().isNotEmpty;

  /// 构造核心需要的配置 JSON。
  String toConfigJson() => jsonEncode({
        'providers': [
          {
            'type': 'sub2api',
            'name': 'sub2api',
            'base_url': baseUrl.trim(),
            'api_key': apiKey.trim(),
            'accounts': {
              'filter': {'status': 'active'}
            },
            'poll': {'passive_interval': '60s', 'active_interval': '10m'},
          }
        ]
      });
}

/// SettingsStore 用 shared_preferences 持久化设置。
class SettingsStore {
  static const _kBaseUrl = 'qp.base_url';
  static const _kApiKey = 'qp.api_key';

  static Future<Settings> load() async {
    final p = await SharedPreferences.getInstance();
    return Settings(
      baseUrl: p.getString(_kBaseUrl) ?? '',
      apiKey: p.getString(_kApiKey) ?? '',
    );
  }

  static Future<void> save(Settings s) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kBaseUrl, s.baseUrl.trim());
    await p.setString(_kApiKey, s.apiKey.trim());
  }
}
