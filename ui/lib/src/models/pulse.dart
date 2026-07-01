import 'dart:convert';

/// 账户总体状态(与 core/model.Status 对应)。
enum PulseStatus { ok, warning, rateLimited, forbidden, needsReauth, banned, error, unknown }

PulseStatus parseStatus(String? s) => switch (s) {
      'ok' => PulseStatus.ok,
      'warning' => PulseStatus.warning,
      'rate_limited' => PulseStatus.rateLimited,
      'forbidden' => PulseStatus.forbidden,
      'needs_reauth' => PulseStatus.needsReauth,
      'banned' => PulseStatus.banned,
      'error' => PulseStatus.error,
      _ => PulseStatus.unknown,
    };

/// Meter 是一个"表盘"(与 core/model.Meter 对应)。
class Meter {
  final String id;
  final String label;
  final String kind; // rolling_window / cumulative / rate
  final String unit;
  final double? utilization; // 0.0~1.0+
  final double? used;
  final double? limit;
  final DateTime? resetsAt;
  final int? remainingSecs;
  final String detail;

  Meter({
    required this.id,
    required this.label,
    required this.kind,
    required this.unit,
    this.utilization,
    this.used,
    this.limit,
    this.resetsAt,
    this.remainingSecs,
    this.detail = '',
  });

  factory Meter.fromJson(Map<String, dynamic> j) => Meter(
        id: j['id'] as String? ?? '',
        label: j['label'] as String? ?? '',
        kind: j['kind'] as String? ?? '',
        unit: j['unit'] as String? ?? '',
        utilization: (j['utilization'] as num?)?.toDouble(),
        used: (j['used'] as num?)?.toDouble(),
        limit: (j['limit'] as num?)?.toDouble(),
        resetsAt: j['resets_at'] != null ? DateTime.tryParse(j['resets_at'] as String) : null,
        remainingSecs: (j['remaining_secs'] as num?)?.toInt(),
        detail: j['detail'] as String? ?? '',
      );
}

/// HourPoint 是某「系列」某小时桶的 token 用量(与 core/model.HourPoint 对应)。
/// hour 由 core 序列化为带本地偏移的 RFC3339,这里 .toLocal() 显示。
class HourPoint {
  final DateTime hour;
  final int input;
  final int output;
  final int cacheCreate;
  final int cacheRead;
  final int total;
  final double cost; // 花费合计(USD;与 token 不严格成正比,单独度量)

  HourPoint({
    required this.hour,
    required this.input,
    required this.output,
    required this.cacheCreate,
    required this.cacheRead,
    required this.total,
    this.cost = 0,
  });

  /// 柱高口径:四类 token 之和(显式含 cache,不依赖服务端 total 的算法)。
  int get sum => input + output + cacheCreate + cacheRead;

  factory HourPoint.fromJson(Map<String, dynamic> j) => HourPoint(
        hour: DateTime.tryParse(j['hour'] as String? ?? '')?.toLocal() ??
            DateTime.fromMillisecondsSinceEpoch(0),
        input: (j['input'] as num?)?.toInt() ?? 0,
        output: (j['output'] as num?)?.toInt() ?? 0,
        cacheCreate: (j['cache_create'] as num?)?.toInt() ?? 0,
        cacheRead: (j['cache_read'] as num?)?.toInt() ?? 0,
        total: (j['total'] as num?)?.toInt() ?? 0,
        cost: (j['cost'] as num?)?.toDouble() ?? 0,
      );
}

/// UsageSeries 是某维度下一条序列(一个维度值 → 它的小时序列;与 core/model.Series 对应)。
/// 由 core 按所选维度(账户/api_key/model/user/group)即时聚合产出。
class UsageSeries {
  final String key;
  final String name;
  final List<HourPoint> points;

  UsageSeries({required this.key, required this.name, required this.points});

  factory UsageSeries.fromJson(Map<String, dynamic> j) => UsageSeries(
        key: j['key'] as String? ?? '',
        name: j['name'] as String? ?? '',
        points: ((j['points'] as List?) ?? const [])
            .map((e) => HourPoint.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  /// 从 ChartSeries JSON 数组解析。
  static List<UsageSeries> listFromJson(String s) {
    final decoded = jsonDecode(s);
    if (decoded is! List) return const [];
    return decoded
        .map((e) => UsageSeries.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

/// ChartData 是一次图表取数的结果:序列 + 本地覆盖水位。供 UI 区分三态:
///   1) 取数/解析失败(ok=false)              → 「数据获取异常」
///   2) series 空且整段已被本地覆盖             → 「该维度暂无请求」(真零)
///   3) coverageFrom 晚于 requestedFrom        → 区间未被本地覆盖,画灰色「未采集/补齐中」带
/// 对应 core/app.chartResp({series,coverageFrom,requestedFrom});时间为 unix 秒。
class ChartData {
  final List<UsageSeries> series;
  final DateTime? coverageFrom; // 本地完整覆盖的最早时刻(null=未知/未提供)
  final DateTime? requestedFrom; // 请求左界 now-hours
  final bool ok; // 取数/解析是否成功(false=异常态)

  const ChartData({
    this.series = const [],
    this.coverageFrom,
    this.requestedFrom,
    this.ok = true,
  });

  static const ChartData failed = ChartData(ok: false);

  /// 请求区间是否都已被本地覆盖(coverageFrom 不晚于 requestedFrom);
  /// 缺水位信息时按「已覆盖」处理(不画未采集带)。
  bool get fullyCovered {
    final c = coverageFrom, r = requestedFrom;
    if (c == null || r == null) return true;
    return !c.isAfter(r);
  }

  /// 解析 QP_ChartSeries 返回。兼容旧的裸数组;空串/非法 → 失败态(ok=false)。
  static ChartData parse(String s) {
    if (s.isEmpty) return failed;
    Object? decoded;
    try {
      decoded = jsonDecode(s);
    } catch (_) {
      return failed;
    }
    if (decoded is List) {
      // 兼容旧形态(裸 []Series):无水位信息。
      return ChartData(
        series: decoded
            .map((e) => UsageSeries.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
    }
    if (decoded is Map) {
      final list = (decoded['series'] as List?) ?? const [];
      return ChartData(
        series: list
            .map((e) => UsageSeries.fromJson(e as Map<String, dynamic>))
            .toList(),
        coverageFrom: _unixSecToLocal(decoded['coverageFrom']),
        requestedFrom: _unixSecToLocal(decoded['requestedFrom']),
      );
    }
    return failed;
  }
}

/// unix 秒 → 本地 DateTime(<=0 视为无,返回 null)。与 HourPoint.hour(本地)可比。
DateTime? _unixSecToLocal(Object? v) {
  final n = (v as num?)?.toInt() ?? 0;
  if (n <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(n * 1000);
}

/// AccountPulse 是一个账户的用量脉搏(与 core/model.AccountPulse 对应)。
class AccountPulse {
  final String accountId;
  final String name;
  final String platform;
  final String provider; // 类型:sub2api / oneapi / newapi
  final String instance; // 实例显示名(区分多个同类型后台;UI 按它分组)
  final PulseStatus status;
  final String tier;
  final List<Meter> meters;
  final DateTime? updatedAt;
  final String error;
  final String actionUrl;

  AccountPulse({
    required this.accountId,
    required this.name,
    required this.platform,
    required this.provider,
    required this.instance,
    required this.status,
    required this.tier,
    required this.meters,
    required this.updatedAt,
    required this.error,
    required this.actionUrl,
  });

  factory AccountPulse.fromJson(Map<String, dynamic> j) => AccountPulse(
        accountId: j['account_id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        platform: j['platform'] as String? ?? '',
        provider: j['provider'] as String? ?? '',
        instance: j['instance'] as String? ?? '',
        status: parseStatus(j['status'] as String?),
        tier: j['tier'] as String? ?? '',
        meters: ((j['meters'] as List?) ?? const [])
            .map((e) => Meter.fromJson(e as Map<String, dynamic>))
            .toList(),
        updatedAt: j['updated_at'] != null ? DateTime.tryParse(j['updated_at'] as String) : null,
        error: j['error'] as String? ?? '',
        actionUrl: j['action_url'] as String? ?? '',
      );

  /// 跨实例唯一键(分组 / 钉住托盘用)。
  String get key => '$instance|$accountId';

  /// 该账户所有表盘里的最高使用率(用于菜单栏标题/状态色)。
  double? get peakUtilization {
    double? peak;
    for (final m in meters) {
      final u = m.utilization;
      if (u == null) continue;
      if (peak == null || u > peak) peak = u;
    }
    return peak;
  }

  /// 从快照 JSON 数组解析。
  static List<AccountPulse> listFromJson(String s) {
    final decoded = jsonDecode(s);
    if (decoded is! List) return const [];
    return decoded
        .map((e) => AccountPulse.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
