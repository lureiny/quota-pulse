import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../bridge/pulse_source.dart';
import '../models/pulse.dart';

/// 一条被缓存的图表结果。失效条件是 **版本号变了 OR 跨桶了**(见 [PulseController] 的说明)。
class _ChartEntry<T> {
  _ChartEntry(this.data, this.version, this.bucket, this.at);
  final T data;
  final int version;
  final int bucket;

  /// 这条结果取回来的时刻。只用于「最小重查间隔」节流 —— 见 [PulseController] 里
  /// `_heatmapMinInterval` 的说明。
  final DateTime at;
}

/// PulseController 周期性从 [PulseSource] 读取快照并通知 UI,同时充当图表数据的
/// **版本号缓存 + 可见性闸门**。
///
/// 真正的网络轮询发生在 Go 核心里(按其调度节奏);这里只是廉价地把核心内存中的最新
/// 快照拉过来渲染,默认每 2 秒一次。
///
/// ## 为什么要缓存图表
///
/// 图表走的是 `core/usage` 的 SQLite 聚合,数据量大时单次可达数秒。而稳态下这些数据
/// **往往一整轮都没变** —— `AddEvents` 是 `INSERT OR IGNORE`,重复事件全被忽略,
/// poller 空闲期的 page_size 还会收敛到 1。于是「每 10 秒重算一遍逐字节相同的结果」
/// 就是纯粹的浪费,也是「CPU 偶尔跑很高」的主要来源。
///
/// Go 侧为此提供了每实例的数据版本号(`QP_ChartVersions`),只在事件真的落库 / 覆盖水位
/// 真的前移 / 真的淘汰了行 / 最早锚点到手时才递增。读它只要几百纳秒,而一次聚合要几秒。
///
/// ## 为什么光有版本号还不够,必须再叠一个「时间桶」
///
/// 查询窗口是相对 `now` 的:小时图每过一个整点右边界就推进一格,热力图每过本地午夜就
/// 多一列;更要命的是 Go 侧的 `requestedFrom` 是现算的 `now`,而 [ChartData.fullyCovered]
/// 拿它和 `coverageFrom` 比 —— 只按版本号缓存的话,一个安静的实例会把 `requestedFrom`
/// 一起冻住,「正在补齐…」的灰带永远不消失。
///
/// 所以失效条件是 **版本号变 OR 跨桶**:小时图跨小时、热力图跨本地日、覆盖状态跨 5 分钟。
/// 比单纯的 TTL 更准 —— 闲着不会白查,窗口真的移动时立刻重取。
class PulseController extends ChangeNotifier {
  PulseController(this._source);

  final PulseSource _source;

  /// 快照拉取间隔。**面板隐藏时也保持同一节奏,不降频、更不停表** ——
  /// 隐藏时托盘 tooltip 和 Windows 悬浮窗跑马灯就是全部 UI,它们全挂在
  /// `notifyListeners()` 上,降频只会让唯一可见的东西变迟钝。
  ///
  /// 而这一拍本身极便宜:数据没变时只有「一次 FFI 取快照 + Go 侧 marshal + 字符串比对」,
  /// 实测 5/20/60 个账户分别是 28µs / 149µs / 380µs,脏检查会拦住重建、托盘推送和
  /// 跑马灯 MethodChannel。真正吃 CPU 的是图表聚合,那条由 [setVisible] 单独把关。
  static const Duration _interval = Duration(seconds: 2);

  /// 缓存条目上限。键是 (实例 × 维度 × 跨度),热力图的天数还会随日期漂移,
  /// 不封顶会缓慢长大。超了就按插入序淘汰最老的(Dart 的 Map 保持插入序)。
  static const int _maxCacheEntries = 64;

  /// 热力图的**最小重查间隔**。
  ///
  /// 版本号闸门只保证「没有新数据就不查」;但账号正在跑流量时,事件是持续入库的
  /// (而且面板打开时 poller 会被提频到 10s,见 core/poller/schedule.go 的 NextInterval),
  /// 于是版本号每一拍都在变,热力图就会每 10 秒重跑一次全历史按天聚合 ——
  /// 单次几秒的话等于常占半个核。UI 不会卡(查询在后台 isolate),但风扇会响。
  ///
  /// 热力图是**按天**粒度的:一天一个格子,60 秒内不可能有任何可见变化。所以这里限一道
  /// 下限,把「有新数据」的重查频率从 10s 降到 60s,视觉上完全无损。
  ///
  /// 小时图不加节流:它便宜得多(实测几十到几百毫秒),而且最右边那根柱子值得跟得紧。
  /// 覆盖状态也不加:它已经按 5 分钟分桶,且加了 created_at 索引后是微秒级。
  ///
  /// 注意这只压查询,不压 `ensureCoverage` —— 图表 widget 的 10 秒定时器照常跑,
  /// 补历史的幂等重试链节奏不变(否则拉全量历史会慢 6 倍)。
  static const Duration _heatmapMinInterval = Duration(seconds: 60);

  Timer? _timer;
  List<AccountPulse> _pulses = const [];
  String? _error;

  /// 上一拍的快照 JSON 原文。脏检查在 **解析之前**比字符串 —— 这样连 jsonDecode 的钱
  /// 都省下来了。
  String? _lastSnapshotJson;

  Map<String, int> _versions = const {};
  bool _versionsKnown = false;
  int _unknownSeq = 0;

  // 默认**不可见**:两个壳启动时都先 windowManager.hide(),而 PopoverPage(连同两个
  // 图表 widget 和它们的定时器)是立即挂载的。初值给 true 的话,「常驻托盘、从不打开面板」
  // 这个最常见的形态下闸门完全失效 —— 每 10 秒照样为每个实例跑一次全量聚合,
  // 直到用户第一次「打开再关闭」面板为止。壳会在 _startCore 里用真实可见态覆盖它。
  bool _visible = false;

  // 引擎代次。核心重启(改实例/代理/图表开关)会 +1,用来拦住**跨重启的在途查询**:
  // 那条查询发出时记的是旧引擎的版本号,回包时缓存已被清空,它却会把旧结果连同旧版本号
  // 一起写回去。新引擎的版本号从 0 重新计数,一旦爬到同一个值就会假命中 ——
  // 热力图的时间桶是「本地日」,这种假命中最长可以持续近 24 小时。
  int _chartEpoch = 0;

  final Map<String, _ChartEntry<ChartData>> _chartCache = {};
  final Map<String, _ChartEntry<Coverage>> _coverageCache = {};

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

  void startPolling({Duration? interval}) {
    _tick();
    _timer?.cancel();
    _timer = Timer.periodic(interval ?? _interval, (_) => _tick());
  }

  void stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  /// 弹层是否可见。壳在显示/隐藏面板时调。
  ///
  /// 不可见时图表**只读缓存、不再发起查询** —— 用户看不见的图不值得为它跑几秒的聚合。
  /// 这是「关掉面板 CPU 仍然高」的直接解法。
  ///
  /// 快照那一拍**不受影响**,照常 2 秒(见 [_interval]):托盘和跑马灯靠它活着,
  /// 而它便宜到不值得为省它做任何事。
  ///
  /// 注意这里**不碰** `setForeground` —— 那条是喂给 Go poller 的调度信号(控制回源频率),
  /// 语义不同,由壳各自调用,别在这里耦合。
  void setVisible(bool v) {
    if (_visible == v) return;
    _visible = v;
  }

  /// 核心重启后必须调:新引擎的版本号从 0 重新计数,会和旧缓存里的版本号撞车,
  /// 不清就会永久命中过期缓存。
  void invalidateCharts() {
    _chartEpoch++;
    _chartCache.clear();
    _coverageCache.clear();
    _versions = const {};
    _versionsKnown = false;
  }

  /// 刷新全部账户。
  void refreshNow() => _source.refresh('');

  /// 只刷新指定账户(key = "instance|accountId",即 AccountPulse.key)。
  void refreshAccount(String key) => _source.refresh(key);

  /// 刷新某个实例的全部账户(key = "instance|")。
  void refreshInstance(String instance) => _source.refresh('$instance|');

  // ---- 图表取数(异步:实现方会把 SQLite 聚合挪到后台 isolate) ----

  /// 按维度取某实例的图表数据(序列 + 覆盖水位)。
  Future<ChartData> chartData(
      String instance, String dimension, int hours) async {
    final key = 'h|$instance|$dimension|$hours';
    return _fetchCached(
      cache: _chartCache,
      key: key,
      instance: instance,
      bucket: _hourBucket(),
      isOk: (d) => d.ok,
      fetch: () async => ChartData.parse(
          await _source.chartSeriesJson(instance, dimension, hours)),
    );
  }

  /// 按维度取某实例**按天**图表数据(热力图)。
  Future<ChartData> dailyChartData(
      String instance, String dimension, int days) async {
    final key = 'd|$instance|$dimension|$days';
    return _fetchCached(
      cache: _chartCache,
      key: key,
      instance: instance,
      bucket: _dayBucket(),
      minInterval: _heatmapMinInterval,
      isOk: (d) => d.ok,
      fetch: () async => ChartData.parse(
          await _source.chartDailySeriesJson(instance, dimension, days)),
    );
  }

  /// 取某实例覆盖状态(水位 + 最早事件),供热力图算补齐进度/年份列表。
  Future<Coverage> coverageData(String instance) async {
    return _fetchCached(
      cache: _coverageCache,
      key: 'c|$instance',
      instance: instance,
      bucket: _minuteBucket(5),
      // Coverage 没有「失败」态(解析失败退化成 empty),这里只把明显的空壳当作
      // 不值得缓存 —— 否则一次瞬时失败会被钉到下次版本变化。
      isOk: (c) => c.coverageFrom != null || c.earliestEvent != null,
      fetch: () async => Coverage.parse(await _source.coverageJson(instance)),
    );
  }

  Future<T> _fetchCached<T>({
    required Map<String, _ChartEntry<T>> cache,
    required String key,
    required String instance,
    required int bucket,
    required bool Function(T) isOk,
    required Future<T> Function() fetch,
    Duration minInterval = Duration.zero,
  }) async {
    // 版本号必须在**发起查询之前**取。查询在途时 Go 可能又写入了数据 —— 记「发起前」的
    // 版本,下一拍自然发现不一致再查一次,自我收敛;记「回包时」的版本会把那次写入永久吞掉。
    final ver = _cacheVersion(instance);
    final epoch = _chartEpoch;
    final hit = cache[key];
    if (hit != null && hit.version == ver && hit.bucket == bucket) {
      return hit.data;
    }
    // 面板不可见:有缓存就用旧的,绝不为看不见的图跑几秒的聚合。
    // 完全没缓存时仍允许查一次,否则重新打开面板会是空白。
    if (!_visible && hit != null) return hit.data;

    // 版本确实变了,但这块图不值得这么勤地重算 → 沿用上次结果,等间隔到了再查。
    // 不更新 hit.at,所以过了 minInterval 自然会放行(版本仍然对不上 → 必然 miss)。
    //
    // 只在**同一个桶**内节流:跨桶意味着窗口真的移动了(热力图跨过本地午夜要多一列),
    // 那是必须立刻反映的结构变化,不能被这道节流挡住。
    if (hit != null &&
        hit.bucket == bucket &&
        minInterval > Duration.zero &&
        DateTime.now().difference(hit.at) < minInterval) {
      return hit.data;
    }

    final data = await fetch();
    // 失败不写缓存(否则一次瞬时失败会被钉死到版本号下次变化为止);
    // 期间核心重启过也不写 —— 那条结果属于上一个引擎,它的版本号会和新引擎的计数撞车。
    if (isOk(data) && epoch == _chartEpoch) {
      cache[key] = _ChartEntry<T>(data, ver, bucket, DateTime.now());
      _trim(cache);
    }
    return data;
  }

  void _trim<T>(Map<String, _ChartEntry<T>> cache) {
    while (cache.length > _maxCacheEntries) {
      cache.remove(cache.keys.first);
    }
  }

  /// 取该实例当前的数据版本号。
  ///
  /// 版本号拿不到时(旧版核心没有这个导出、或引擎还没起)返回一个每次都不同的值,
  /// 让缓存必然落空、退回「照常查询」的旧行为 —— **绝不能当成 0**,那会让一次瞬时
  /// 失败把图表永久冻在缓存上。
  int _cacheVersion(String instance) {
    if (!_versionsKnown) return --_unknownSeq;
    // 版本表里**没有**这个实例 = 取不到,不是「版本 0」。Go 侧的 ver map 是懒填充的
    // (只有 bump 过的实例才有键),而且一旦 UI 的实例显示名与 usage 库的键出现偏差,
    // 按 0 处理会让图表永久冻结(小时图冻到整点、热力图冻到本地午夜)且无自愈路径。
    // 当成未知、照常查询:代价只是一个还没产生过事件的实例会白查(此时库里几乎没有行,
    // 查询极廉价),换的是「永不冻结」。
    return _versions[instance] ?? --_unknownSeq;
  }

  int _hourBucket() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day, n.hour).millisecondsSinceEpoch;
  }

  int _dayBucket() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day).millisecondsSinceEpoch;
  }

  int _minuteBucket(int minutes) =>
      DateTime.now().millisecondsSinceEpoch ~/ (minutes * 60000);

  /// 触发按需回填:确保本地覆盖延伸到 now-hours(异步、即时返回)。
  ///
  /// 调用方**必须在缓存命中的分支里也照常调用它** —— 后台补齐靠这条幂等重试链驱动,
  /// 跳过它会让补齐卡在中途再也不被催动。它本身是廉价的(Go 侧起个 goroutine 就返回,
  /// 且对「已覆盖 / 在途」有幂等保护)。
  void ensureCoverage(String instance, int hours) =>
      _source.ensureCoverage(instance, hours);

  // ---- 每拍 ----

  void _tick() {
    String raw;
    String? err;
    try {
      raw = _source.snapshotJson();
    } catch (e) {
      raw = _lastSnapshotJson ?? '[]';
      err = e.toString();
    }

    // 版本号每拍都刷:图表要靠它判断缓存是否还有效。极廉价,不碰 SQLite。
    _refreshVersions();

    // 脏检查:快照一字未变、也没有错误态要处理 → 直接返回。
    // 不重建 widget 树、不重推托盘、不重推悬浮窗。
    //
    // 托盘/跑马灯的「重置倒计时」不会因此冻住:它读的是快照里的 Meter.remainingSecs
    // 这个静态字段(见 format.fmtResetPhrase),本来就只在 Go 写了新快照时才跳数。
    if (err == null && raw == _lastSnapshotJson && _error == null) return;

    if (err == null) {
      try {
        _pulses = AccountPulse.listFromJson(raw);
      } catch (e) {
        err = e.toString();
      }
    }

    final changed = raw != _lastSnapshotJson || err != _error;
    _lastSnapshotJson = raw;
    _error = err;
    if (changed) notifyListeners();
  }

  void _refreshVersions() {
    String raw;
    try {
      raw = _source.chartVersionsJson();
    } catch (_) {
      _versionsKnown = false;
      return;
    }
    if (raw.isEmpty) {
      _versionsKnown = false; // '' = 取不到 → 退回「照常查询」
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        _versionsKnown = false;
        return;
      }
      final out = <String, int>{};
      decoded.forEach((k, v) {
        if (v is num) out['$k'] = v.toInt();
      });
      _versions = out;
      _versionsKnown = true;
    } catch (_) {
      _versionsKnown = false;
    }
  }

  @override
  void dispose() {
    stopPolling();
    super.dispose();
  }
}
