import 'dart:async';

import 'package:flutter/foundation.dart';

import '../bridge/pulse_source.dart';
import '../models/pulse.dart';

/// PulseController 周期性从 [PulseSource] 读取快照并通知 UI。
///
/// 注意:真正的网络轮询发生在 Go 核心里(按其调度节奏);这里只是廉价地
/// 把核心内存中的最新快照拉过来渲染,默认每 2 秒一次。
class PulseController extends ChangeNotifier {
  PulseController(this._source);

  final PulseSource _source;

  Timer? _timer;
  List<AccountPulse> _pulses = const [];
  String? _error;

  List<AccountPulse> get pulses => _pulses;
  String? get error => _error;

  /// 所有账户里的全局最高使用率(用于菜单栏标题)。
  double? get peakUtilization {
    double? peak;
    for (final p in _pulses) {
      final u = p.peakUtilization;
      if (u == null) continue;
      if (peak == null || u > peak) peak = u;
    }
    return peak;
  }

  void startPolling({Duration interval = const Duration(seconds: 2)}) {
    _tick();
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  void stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  /// 刷新全部账户。
  void refreshNow() => _source.refresh('');

  /// 只刷新指定账户(key = "instance|accountId",即 AccountPulse.key)。
  void refreshAccount(String key) => _source.refresh(key);

  void _tick() {
    try {
      _pulses = AccountPulse.listFromJson(_source.snapshotJson());
      _error = null;
    } catch (e) {
      _error = e.toString();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    stopPolling();
    super.dispose();
  }
}
