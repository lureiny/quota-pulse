/// ChartWorker 是一个**长驻**后台 isolate,专门承担会打到 SQLite 的图表查询。
///
/// 为什么需要它:`QP_ChartSeries` / `QP_ChartDailySeries` / `QP_Coverage` 三个导出
/// 全部走 `core/usage` 的 SQLite 聚合,50 万行实测单次可达数秒。它们原先是同步 FFI,
/// 直接冻住 UI 主 isolate —— 这就是「点击展开卡」「切换维度卡」的直接成因。
///
/// 为什么是**长驻单个**,而不是每次 `Isolate.run`、也不是 isolate 池:
/// - 池是假并行:`core/usage/store.go` 是 `SetMaxOpenConns(1)`,多少个 isolate 发过去
///   都会在 Go 侧排队等同一条连接。并行度买不到,线程和 dlopen 的代价却是真的。
/// - 每次新建 isolate 会让承载线程反复变化,Go runtime 要为每个新进入的 OS 线程挂一个
///   M;而且 `Isolate.run` 没有队列,也就没地方做抢占 —— 用户连点几下年份就会同时跑
///   几遍全量聚合。
/// - 长驻单例天然就是一条串行队列,抢占/合并/限流都有地方落;两分配器契约也只需要在
///   一个地方守住。
///
/// 代价是队头阻塞:一发很慢的热力图会挡住后面便宜的小时图。可接受 —— Go 侧本来就串行,
/// 而且版本号闸门让绝大多数刷新一条查询都不发。
///
/// **内存契约**(见 CLAUDE.md):Dart 传进去的字符串用 `malloc.free`,Go 返回的字符串用
/// `QP_Free`。这套纪律全部封装在 [NativeCore] 里,worker 只通过它调用,绝不在这里手写
/// 裸 FFI —— 用反了会直接破坏堆。同理 [NativeCore] 持有 `DynamicLibrary` 与裸指针,
/// **绝不跨 isolate 传递**:它只在 worker 入口构造、只活在 worker 里。跨边界的一律是
/// `String` 和 `int`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'native_core.dart';

/// 查询种类。与 [_execute] 的分发一一对应。
class ChartQueryKind {
  static const int hourly = 0; // QP_ChartSeries
  static const int daily = 1; // QP_ChartDailySeries
  static const int coverage = 2; // QP_Coverage
}

/// 出队优先级(数字小者先跑)。
///
/// worker 是一条**串行**队列(Go 侧 `SetMaxOpenConns(1)`,并发发过去也只是排队),
/// 所以谁先跑直接决定用户先看到什么。小时图便宜(实测几十~几百毫秒)且要跟手,
/// 热力图昂贵(全历史按天聚合可达数秒)但只有按天粒度 —— 让后者堵在前者前面,
/// 就会出现「打开面板要等半天柱状图才出来」。
int _priorityOf(int kind) => switch (kind) {
      ChartQueryKind.hourly => 0,
      ChartQueryKind.coverage => 1, // 便宜(已加 created_at 索引),且热力图要等它
      _ => 2, // daily:最贵,垫底
    };

/// 主 isolate 侧的客户端:负责 spawn、配对请求/响应。
class ChartWorkerClient {
  ChartWorkerClient._(this._iso, this._tx, this._rx);

  final Isolate _iso;
  final SendPort _tx;
  final ReceivePort _rx;

  final Map<int, Completer<String>> _pending = {};
  int _seq = 0;
  bool _disposed = false;

  /// worker 意外没了时回调(由 [FfiPulseSource] 设置,用于允许下次重建)。
  void Function()? onDead;

  /// 启动 worker。[libraryPath] 必须是主 isolate 里**实际打开成功**的那个路径
  /// ([NativeCore.libraryPath]),不要让 worker 自己重跑候选探测 —— 两侧探测结果发散
  /// 会导致加载到不同镜像,而同进程加载两份 Go c-shared 是会炸的。
  static Future<ChartWorkerClient> spawn(String libraryPath) async {
    final rx = ReceivePort();
    final ready = Completer<SendPort>();
    // 一条**持久**订阅,从头到尾不取消。
    //
    // 不要用 `rx.asBroadcastStream()` 然后 `await stream.first` —— `first` 拿到首个
    // 事件后会取消它那条订阅,而广播包装在最后一个监听者取消时会连带取消上游,
    // 底层 ReceivePort 就被关掉了,后续回包全部丢失。
    void Function(dynamic)? handler;
    void Function()? onGone;
    rx.listen((dynamic msg) {
      // onExit 会往这个端口推一个 null:worker 没了。
      // 不认这条的话,在途的 Completer 永远不 complete —— 表现不是「取数异常」而是
      // **永久加载中**,而且图表每 10 秒还会再挂一个永不完成的 Completer 进来。
      if (msg == null) {
        onGone?.call();
        return;
      }
      if (!ready.isCompleted) {
        if (msg is SendPort) ready.complete(msg);
        return; // 首个消息只可能是 worker 的端口
      }
      handler?.call(msg);
    }, onError: (Object _, StackTrace __) {});

    // 必须是可空局部变量,不能用 late final:握手超时时 spawn 其实已经成功,
    // 不 kill 就会把一个持有 NativeCore(dlopen 引用 + Go 侧一个 M)的 isolate 漏在那,
    // 而上层每 10 秒还会再 spawn 一个,泄漏会累积。
    Isolate? iso;
    try {
      iso = await Isolate.spawn(
        _workerMain,
        <Object?>[rx.sendPort, libraryPath],
        errorsAreFatal: false, // worker 崩了不拖垮宿主;在途请求走兜底哨兵
        onExit: rx.sendPort, // 退出时往上面那条 listen 推一个 null
        debugName: 'qp-chart-worker',
      );
      // worker 若在递出端口前就死了,ready 永远不会完成 —— 没有超时的话
      // 每一次图表查询都会挂住。宁可失败降级成「取数异常」,也不能永久挂起。
      final tx = await ready.future.timeout(const Duration(seconds: 10));
      final c = ChartWorkerClient._(iso, tx, rx);
      handler = c._onMessage;
      onGone = c._onWorkerGone;
      return c;
    } catch (_) {
      iso?.kill(priority: Isolate.immediate);
      rx.close();
      rethrow; // 由 FfiPulseSource._ensureWorker 兜住,降级为「图表取数异常」
    }
  }

  void _onMessage(dynamic msg) {
    // 只认 [id, payload];onError 推来的 [err, stack] 等噪声一律忽略。
    if (msg is! List || msg.length != 2) return;
    final id = msg[0];
    final payload = msg[1];
    if (id is! int || payload is! String) return;
    _pending.remove(id)?.complete(payload);
  }

  /// 发一次查询。
  ///
  /// [slot] 是**抢占键**,必须只表达「这是哪一块图」,不能包含年份/跨度等会变的参数 ——
  /// 否则用户切年份就产生新 slot,旧的那一发顶不掉,连点几下会排起长队。
  ///
  /// 返回值直接是 Go 那边的 JSON。`''` = 取数失败(与 Go 的空指针哨兵一致);被后续同
  /// slot 请求顶掉时同样以 `''` 结束 —— 调用方本来就要丢弃过期结果。
  Future<String> query({
    required int kind,
    required String slot,
    required String instance,
    String dimension = '',
    int span = 0,
  }) {
    if (_disposed) return Future.value('');
    final id = ++_seq;
    final c = Completer<String>();
    _pending[id] = c;
    // 全部是基本类型,可安全跨 isolate。
    _tx.send(<Object?>[id, kind, slot, instance, dimension, span]);
    // 最后一道保险:即使 onExit 也丢了,也绝不让调用方永久挂住。
    // 60 秒远大于任何一次正常聚合(实测最坏几秒),不会误伤。
    return c.future.timeout(const Duration(seconds: 60), onTimeout: () {
      _pending.remove(id);
      return '';
    });
  }

  /// worker 意外退出:把在途的全部以「取数失败」收尾,并通知上层允许重建。
  void _onWorkerGone() {
    if (_disposed) return;
    _disposed = true;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete('');
    }
    _pending.clear();
    _rx.close();
    onDead?.call();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // 在途的一律以「取数失败」收尾,避免上层永远 await 不到。
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete('');
    }
    _pending.clear();
    try {
      _tx.send(null); // 请 worker 自行收摊
    } catch (_) {}
    _rx.close();
    _iso.kill(priority: Isolate.beforeNextEvent);
  }
}

// ---------------------------------------------------------------------------
// 以下运行在 worker isolate 里。
// ---------------------------------------------------------------------------

/// worker 入口。必须是顶层函数([Isolate.spawn] 的要求)。
void _workerMain(List<Object?> boot) {
  final reply = boot[0] as SendPort;
  final libraryPath = boot[1] as String;

  // 本 isolate 里唯一一次构造 NativeCore。dlopen/LoadLibrary 是进程级引用计数,
  // 主 isolate 已加载过,这里只是 refcount++,拿到同一镜像、同一个 Go runtime。
  NativeCore? core;
  try {
    core = NativeCore.openAt(libraryPath);
  } catch (_) {
    core = null; // 打不开:后续一律回错误哨兵,不让宿主挂起
  }

  final rx = ReceivePort();
  reply.send(rx.sendPort);

  // 自己缓冲,而不是直接在 listen 回调里执行:一次聚合是**同步阻塞**的 cgo 调用,
  // 执行期间事件循环停摆。先把同一批到达的请求全收进 buffer 再统一 drain,
  // 这样才看得见「同 slot 有没有更新的一发」,从而抢占掉旧的。
  final buffer = <List<Object?>>[];
  var draining = false;

  Future<void> drain() async {
    if (draining) return;
    draining = true;
    try {
      while (buffer.isNotEmpty) {
        // 按优先级挑,而不是先进先出:一发几秒的热力图不该把要跟手的小时图堵在后面。
        // (已经开始执行的那一发拦不住 —— 同步 cgo 不可抢占。)
        var pick = 0;
        for (var i = 1; i < buffer.length; i++) {
          if (_priorityOfItem(buffer[i]) < _priorityOfItem(buffer[pick])) pick = i;
        }
        final item = buffer.removeAt(pick);
        // 取参与抢占判定本身也必须裹在 try 里 —— _execute 内部虽然全程 try/catch,
        // 但这一段裸着的话,一条畸形消息就会让异常逃出 drain(),那一发**没有任何回包**,
        // 主侧的 Completer 永远挂着。纪律是「每一项都必有回包」,靠结构保证,不靠自觉。
        final id = (item.length == 6 && item[0] is int) ? item[0] as int : null;
        try {
          if (id == null || item[2] is! String) continue; // 畸形消息:丢弃
          final slot = item[2] as String;

          // 同 slot 后面还有更新的 → 这一发已无意义,直接顶掉。
          // (已经开始执行的那一发无法取消,同步 cgo 拦不住,最多浪费一次。)
          //
          // 这条判据依赖一个**不明显的前提**:buffer 里剩下的同 slot 项必然比这一项新。
          // 改成按优先级出队之后它仍然成立,因为 slot 一一对应 kind、kind 一一对应优先级,
          // 所以同 slot 的项优先级必然相同;而上面挑选时用的是严格小于,同优先级保持最小
          // 下标 = 先进先出。**若将来让同 slot 的项拥有不同优先级,这条就会反向抢占
          // (用旧的顶掉新的),必须同步改。**
          if (buffer.any((p) => p.length > 2 && p[2] == slot)) {
            reply.send(<Object?>[id, '']);
            continue;
          }

          reply.send(<Object?>[id, _execute(core, item)]);
        } catch (_) {
          if (id != null) reply.send(<Object?>[id, '']); // 兜底:永远有回包
        } finally {
          // 让出一拍,好让执行期间积压的端口消息进到 buffer,下一轮才能正确抢占。
          // 放在 finally 里:continue 分支也要让出,否则连点时看不到新到的消息。
          await Future<void>.delayed(Duration.zero);
        }
      }
    } finally {
      draining = false;
    }
  }

  rx.listen((dynamic msg) {
    if (msg == null) {
      rx.close(); // 宿主要求收摊
      return;
    }
    if (msg is! List) return;
    buffer.add(msg.cast<Object?>());
    // 用 Future(...) 而不是 scheduleMicrotask:微任务会抢在后续端口消息之前跑,
    // 那样 buffer 里永远只有一条,抢占就失效了。
    unawaited(Future<void>(drain));
  });
}

/// 从一条队列消息里安全地取出优先级(畸形消息垫底,由后面的校验去丢弃)。
int _priorityOfItem(List<Object?> item) =>
    (item.length == 6 && item[1] is int) ? _priorityOf(item[1] as int) : 3;

/// 真正执行一次查询。任何失败都收敛成 `''`(与 Go 空指针哨兵一致),**绝不抛异常** ——
/// 异常会走 isolate 的 onError 通道,那条通道拿不到 requestId,上层将永远 await 不到结果。
String _execute(NativeCore? core, List<Object?> item) {
  if (core == null) return '';
  final kind = item[1] as int;
  final instance = item[3] as String;
  final dimension = item[4] as String;
  final span = item[5] as int;
  try {
    switch (kind) {
      case ChartQueryKind.hourly:
        return core.chartSeries(jsonEncode(
            {'instance': instance, 'dimension': dimension, 'hours': span}));
      case ChartQueryKind.daily:
        return core.chartDailySeries(jsonEncode(
            {'instance': instance, 'dimension': dimension, 'days': span}));
      case ChartQueryKind.coverage:
        return core.coverage(jsonEncode({'instance': instance}));
      default:
        return '';
    }
  } catch (_) {
    return '';
  }
}
