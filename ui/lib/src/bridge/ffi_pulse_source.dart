import 'dart:convert';

import 'native_core.dart';
import 'pulse_source.dart';

/// 进程内 FFI 实现:直接调 libqp.dylib。
class FfiPulseSource implements PulseSource {
  NativeCore? _core;

  @override
  void init(String configJson) {
    _core ??= NativeCore.open();
    final rc = _core!.init(configJson);
    if (rc != 0) {
      throw StateError('核心初始化失败(配置无效?)rc=$rc');
    }
  }

  @override
  void start() => _core?.start();

  @override
  void stop() => _core?.stop();

  @override
  void refresh(String accountId) => _core?.refresh(accountId);

  @override
  String snapshotJson() => _core?.snapshotJson() ?? '[]';

  @override
  String chartSeriesJson(String instance, String dimension, int hours) {
    final args = jsonEncode(
        {'instance': instance, 'dimension': dimension, 'hours': hours});
    return _core?.chartSeries(args) ?? '';
  }

  @override
  void ensureCoverage(String instance, int hours) {
    final args = jsonEncode({'instance': instance, 'hours': hours});
    _core?.ensureCoverage(args);
  }

  @override
  void setForeground(bool open) => _core?.setForeground(open);
}
