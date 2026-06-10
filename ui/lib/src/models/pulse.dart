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

/// AccountPulse 是一个账户的用量脉搏(与 core/model.AccountPulse 对应)。
class AccountPulse {
  final String accountId;
  final String name;
  final String platform;
  final String provider;
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
        status: parseStatus(j['status'] as String?),
        tier: j['tier'] as String? ?? '',
        meters: ((j['meters'] as List?) ?? const [])
            .map((e) => Meter.fromJson(e as Map<String, dynamic>))
            .toList(),
        updatedAt: j['updated_at'] != null ? DateTime.tryParse(j['updated_at'] as String) : null,
        error: j['error'] as String? ?? '',
        actionUrl: j['action_url'] as String? ?? '',
      );

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
