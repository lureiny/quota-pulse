import 'dart:convert';

import 'package:json2yaml/json2yaml.dart';
import 'package:yaml/yaml.dart';

import '../version.dart';
import 'settings_store.dart';

/// 配置导入 / 导出(YAML)。用于在不同机器 / 平台间快速迁移设置。
///
/// 导出外层包一层元信息便于校验与演进:
/// ```yaml
/// app: quota-pulse
/// version: "0.8.0"
/// exported_at: "2026-06-15T18:30:00.000"
/// settings: { ...Settings.toJson()... }
/// ```
/// 跨平台天然兼容:Settings.fromJson 宽松解析,Windows 专属字段在 macOS 上忽略、反之亦然。

/// 把当前 [Settings] 序列化为 YAML 字符串。
/// [includeKeys]=false 时各实例的 `api_key` 置空(不导出明文密钥)。
String exportConfigYaml(Settings s, {required bool includeKeys}) {
  final settingsMap = s.toJson();
  if (!includeKeys) {
    final instances = settingsMap['instances'];
    if (instances is List) {
      for (final inst in instances) {
        if (inst is Map) inst['api_key'] = '';
      }
    }
  }
  final wrapper = <String, dynamic>{
    'app': 'quota-pulse',
    'version': appVersion,
    'exported_at': DateTime.now().toIso8601String(),
    'settings': settingsMap,
  };
  return json2yaml(wrapper);
}

/// 从 YAML(或 JSON,JSON 是 YAML 子集)文本解析出 [Settings]。
/// 容错:有 `settings:` 包装取其内容,否则把整份当作 settings。
/// 解析 / 识别失败抛 [FormatException](带中文提示),调用方据此报错,不应用。
Settings importConfigYaml(String text) {
  if (text.trim().isEmpty) {
    throw const FormatException('内容为空');
  }
  dynamic node;
  try {
    node = loadYaml(text);
  } catch (_) {
    throw const FormatException('无法解析,请确认是有效的 YAML / 配置文件');
  }
  // YamlMap/YamlList 不是 Map<String,dynamic>;用 JSON round-trip 转成纯结构,
  // 规避 fromJson 里 `as Map<String, dynamic>` 的类型坑。
  dynamic plain;
  try {
    plain = jsonDecode(jsonEncode(node));
  } catch (_) {
    throw const FormatException('配置内容格式不正确');
  }
  if (plain is! Map) {
    throw const FormatException('配置内容格式不正确');
  }
  final raw = plain['settings'] ?? plain; // 无包装时直接当 settings
  if (raw is! Map) {
    throw const FormatException('未找到配置内容(settings)');
  }
  try {
    return Settings.fromJson(Map<String, dynamic>.from(raw));
  } catch (_) {
    throw const FormatException('配置内容无法识别为 quota-pulse 配置');
  }
}

// ----- 单个实例的导出 / 导入 -----
//
// 与整份配置的 `settings:` 信封区分:单实例用 `kind: instance` + `instance:` 单对象,
// 只含一个站点的 name / base_url / api_key,便于把某个实例单独搬到另一台机器。
//
// ```yaml
// app: quota-pulse
// kind: instance
// version: "0.10.0"
// exported_at: "2026-06-27T..."
// instance:
//   name: 主力
//   base_url: https://host
//   api_key: sk-...        # includeKeys=false 时为空串
// ```

/// 把单个 [Sub2apiInstance] 序列化为 YAML(只含该实例)。
/// 不导出 `id`(机器本地的托盘钉住/列表 key;导入侧铸新 id)。
/// [includeKeys]=false 时 `api_key` 置空(不导出明文密钥)。
String exportInstanceYaml(Sub2apiInstance inst, {required bool includeKeys}) {
  final wrapper = <String, dynamic>{
    'app': 'quota-pulse',
    'kind': 'instance',
    'version': appVersion,
    'exported_at': DateTime.now().toIso8601String(),
    'instance': <String, dynamic>{
      'name': inst.name,
      'base_url': inst.baseUrl,
      'api_key': includeKeys ? inst.apiKey : '',
    },
  };
  return json2yaml(wrapper);
}

/// 从 YAML(或 JSON)文本解析出**单个** [Sub2apiInstance](`id` 留空,调用方铸新 id)。
/// 容错地从多种结构里取出一个实例:
///   1. `instance:` 单对象(本功能导出格式);
///   2. `settings.instances` 或顶层 `instances` 列表非空 → 取第一个
///      (允许从一份整份导出里抽一个实例);
///   3. 顶层本身就是实例形状(含 base_url / api_key / name 键)。
/// 解析 / 识别失败抛 [FormatException](带中文提示),调用方据此报错,不应用。
Sub2apiInstance importInstanceYaml(String text) {
  if (text.trim().isEmpty) {
    throw const FormatException('内容为空');
  }
  dynamic node;
  try {
    node = loadYaml(text);
  } catch (_) {
    throw const FormatException('无法解析,请确认是有效的 YAML / 配置文件');
  }
  // YamlMap/YamlList → 纯结构(同 importConfigYaml,规避 as Map 类型坑)。
  dynamic plain;
  try {
    plain = jsonDecode(jsonEncode(node));
  } catch (_) {
    throw const FormatException('配置内容格式不正确');
  }
  if (plain is! Map) {
    throw const FormatException('配置内容格式不正确');
  }

  Map? pick;
  final inst = plain['instance'];
  if (inst is Map) {
    pick = inst;
  } else {
    final settings = plain['settings'];
    final list = (settings is Map ? settings['instances'] : null) ?? plain['instances'];
    if (list is List && list.isNotEmpty && list.first is Map) {
      pick = list.first as Map;
    } else if (plain.containsKey('base_url') ||
        plain.containsKey('api_key') ||
        plain.containsKey('name')) {
      pick = plain;
    }
  }
  if (pick == null) {
    throw const FormatException('未找到实例配置');
  }

  final m = Map<String, dynamic>.from(pick);
  m['id'] = ''; // id 机器本地,导入侧铸新;忽略来源里的 id
  final result = Sub2apiInstance.fromJson(m);
  if (result.name.trim().isEmpty &&
      result.baseUrl.trim().isEmpty &&
      result.apiKey.trim().isEmpty) {
    throw const FormatException('实例配置为空(无名称 / URL / 密钥)');
  }
  return result;
}
