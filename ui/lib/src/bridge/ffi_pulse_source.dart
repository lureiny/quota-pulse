import 'dart:convert';

import 'chart_worker.dart';
import 'native_core.dart';
import 'pulse_source.dart';

/// 进程内 FFI 实现:直接调 libqp.dylib。
///
/// 会打到 SQLite 的三个查询(chartSeries / chartDailySeries / coverage)不在这里执行,
/// 而是转交给常驻的 [ChartWorkerClient] 后台 isolate —— 它们单次可达数秒,留在主 isolate
/// 就是「点击展开卡」「切换维度卡」的成因。其余导出都不碰库,留在主 isolate 同步调。
class FfiPulseSource implements PulseSource {
  NativeCore? _core;
  Future<ChartWorkerClient?>? _workerFut;

  @override
  void init(String configJson) {
    _core ??= NativeCore.open();
    final rc = _core!.init(configJson);
    if (rc != 0) {
      throw StateError('核心初始化失败(配置无效?)rc=$rc');
    }
  }

  /// 懒启动后台 worker:第一次真要查图表时才付这份开销。
  ///
  /// 核心重启(改实例配置会走 stop → init)**不重建 isolate**:库句柄和符号地址在进程内
  /// 永久有效,重建只是白付线程创建和 Go 侧的 M attach。
  Future<ChartWorkerClient?> _ensureWorker() {
    final core = _core;
    if (core == null) return Future<ChartWorkerClient?>.value(null);
    return _workerFut ??= () async {
      try {
        final w = await ChartWorkerClient.spawn(core.libraryPath);
        // worker 意外退出(被 VM 回收 / 崩溃)后清掉缓存的 Future,让下次查询重建一个。
        // 不这么做的话 _ensureWorker 会一直返回那个已死的 client,图表再也不会恢复。
        w.onDead = () => _workerFut = null;
        return w;
      } catch (_) {
        // 失败不要粘住:清掉缓存的 Future,让下一次查询可以重试。
        // 否则一次瞬时的 spawn 失败会把图表永久钉死在「取数异常」。
        _workerFut = null;
        return null;
      }
    }();
  }

  @override
  void start() => _core?.start();

  @override
  void stop() => _core?.stop();

  @override
  void refresh(String accountId) => _core?.refresh(accountId);

  @override
  String snapshotJson() => _core?.snapshotJson() ?? '[]';

  // slot 是 worker 侧的抢占键,只标识「哪一块图」,**不含维度/跨度/年份** ——
  // 同一块图上任何一次新请求都应该顶掉它自己那一发未开始的旧请求。若把参数编进 slot,
  // 用户切年份就产生新键,旧的顶不掉,连点几下会排起长队。
  @override
  Future<String> chartSeriesJson(
      String instance, String dimension, int hours) async {
    final w = await _ensureWorker();
    if (w == null) return '';
    return w.query(
      kind: ChartQueryKind.hourly,
      slot: 'h|$instance',
      instance: instance,
      dimension: dimension,
      span: hours,
    );
  }

  @override
  Future<String> chartDailySeriesJson(
      String instance, String dimension, int days) async {
    final w = await _ensureWorker();
    if (w == null) return '';
    return w.query(
      kind: ChartQueryKind.daily,
      slot: 'd|$instance',
      instance: instance,
      dimension: dimension,
      span: days,
    );
  }

  @override
  Future<String> coverageJson(String instance) async {
    final w = await _ensureWorker();
    if (w == null) return '';
    return w.query(
      kind: ChartQueryKind.coverage,
      slot: 'c|$instance',
      instance: instance,
    );
  }

  /// 不碰 SQLite(Go 侧只读原子变量),留在主 isolate 同步调。
  @override
  String chartVersionsJson() => _core?.chartVersions() ?? '';

  @override
  void ensureCoverage(String instance, int hours) {
    final args = jsonEncode({'instance': instance, 'hours': hours});
    _core?.ensureCoverage(args);
  }

  @override
  void setForeground(bool open) => _core?.setForeground(open);

  @override
  void debugSet(
      {required bool enabled,
      required int maxSamples,
      required int maxMemBytes}) {
    final args = jsonEncode({
      'enabled': enabled,
      'maxSamples': maxSamples,
      'maxMemBytes': maxMemBytes,
    });
    _core?.debugSet(args);
  }

  @override
  String debugReportJson() =>
      _core?.debugReport() ?? '{"enabled":false,"instances":[]}';

  @override
  void debugReset() => _core?.debugReset();

  @override
  void shutdown() {
    final f = _workerFut;
    _workerFut = null;
    f?.then((w) => w?.dispose()).catchError((Object _) {});
  }
}
