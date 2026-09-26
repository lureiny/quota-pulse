import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// ---- C 函数签名(对应 core/cmd/libqp/capi.go 的 QP_* 导出) ----

typedef _InitC = Int32 Function(Pointer<Utf8>);
typedef _InitD = int Function(Pointer<Utf8>);
typedef _VoidC = Void Function();
typedef _VoidD = void Function();
typedef _SnapC = Pointer<Utf8> Function();
typedef _SnapD = Pointer<Utf8> Function();
typedef _StrArgC = Void Function(Pointer<Utf8>);
typedef _StrArgD = void Function(Pointer<Utf8>);
typedef _StrToStrC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _StrToStrD = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _IntArgC = Void Function(Int32);
typedef _IntArgD = void Function(int);

/// NativeCore 封装对 libqp.dylib 的 dart:ffi 调用。
class NativeCore {
  NativeCore._(this._lib, this.libraryPath);

  final DynamicLibrary _lib;

  /// 实际打开成功的那个名字/路径。后台 isolate 用它复现同一次加载 —— 不重跑候选探测,
  /// 避免两侧探测结果发散(dlopen/LoadLibrary 是进程级引用计数,再 open 一次只是
  /// refcount++,拿到同一镜像,Go runtime 不会二次初始化)。
  final String libraryPath;

  late final _InitD _init = _lib.lookupFunction<_InitC, _InitD>('QP_Init');
  late final _VoidD _start = _lib.lookupFunction<_VoidC, _VoidD>('QP_Start');
  late final _VoidD _stop = _lib.lookupFunction<_VoidC, _VoidD>('QP_Stop');
  late final _SnapD _snapshot = _lib.lookupFunction<_SnapC, _SnapD>('QP_SnapshotJSON');
  late final _StrArgD _refresh = _lib.lookupFunction<_StrArgC, _StrArgD>('QP_Refresh');
  late final _StrToStrD _chartSeries =
      _lib.lookupFunction<_StrToStrC, _StrToStrD>('QP_ChartSeries');
  late final _StrToStrD _chartDaily =
      _lib.lookupFunction<_StrToStrC, _StrToStrD>('QP_ChartDailySeries');
  late final _StrToStrD _coverage =
      _lib.lookupFunction<_StrToStrC, _StrToStrD>('QP_Coverage');
  late final _StrArgD _ensureCoverage =
      _lib.lookupFunction<_StrArgC, _StrArgD>('QP_EnsureCoverage');
  late final _StrArgD _free = _lib.lookupFunction<_StrArgC, _StrArgD>('QP_Free');
  late final _IntArgD _setForeground =
      _lib.lookupFunction<_IntArgC, _IntArgD>('QP_SetForeground');
  late final _StrArgD _debugSet =
      _lib.lookupFunction<_StrArgC, _StrArgD>('QP_DebugSet');
  late final _SnapD _debugReport =
      _lib.lookupFunction<_SnapC, _SnapD>('QP_DebugReport');
  late final _VoidD _debugReset =
      _lib.lookupFunction<_VoidC, _VoidD>('QP_DebugReset');

  /// 按平台选择核心库文件名:
  ///   macOS → libqp.dylib · Windows → libqp.dll · Linux → libqp.so
  static String _libFileName() {
    if (Platform.isMacOS) return 'libqp.dylib';
    if (Platform.isWindows) return 'libqp.dll';
    if (Platform.isLinux) return 'libqp.so';
    throw UnsupportedError('quota-pulse 桌面核心暂不支持当前平台');
  }

  /// 打开并加载动态库。失败抛异常(由上层展示为"未找到核心库")。
  factory NativeCore.open() {
    final file = _libFileName();
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    // 候选顺序:默认搜索路径 → 可执行文件同级(Windows/Linux 常见) →
    // macOS 嵌入 .app 后的 @rpath(Contents/Frameworks)。
    final candidates = <String>[
      file,
      '$exeDir/$file',
      if (Platform.isMacOS) '@rpath/$file',
    ];

    DynamicLibrary? lib;
    String? hit;
    Object? lastErr;
    for (final name in candidates) {
      try {
        lib = DynamicLibrary.open(name);
        hit = name;
        break;
      } catch (e) {
        lastErr = e;
      }
    }
    if (lib == null || hit == null) {
      throw StateError('无法加载 $file:$lastErr');
    }
    return NativeCore._(lib, hit);
  }

  /// 把后台 isolate 需要的那几个符号**解析成地址**打包带走。
  ///
  /// 为什么不让对端自己 `DynamicLibrary.open(路径)`:那是第二次 dlopen,解析结果取决于
  /// `@rpath` / 搜索路径在该调用点如何展开。一旦解析到**另一个文件**,进程里就会出现两份
  /// libqp、两个 Go runtime(golang/go#65050),而且第二份的全局 engine 从没 QP_Init 过 ——
  /// 表现是闪退或静默空数据。传地址没有这个歧义:指向的必然是同一份已加载代码。
  ///
  /// (注:`dart:ffi` 没有「按句柄构造 DynamicLibrary」的入口,
  /// 传函数指针地址是官方推荐的跨 isolate 共享方式。)
  /// 逐个符号显式 lookup —— **不要抽成泛型辅助函数**:dart:ffi 的转换器要求
  /// 这类调用的类型实参是编译期常量,类型变量会被拒。
  ChartSymbols chartSymbols() {
    int s2s(String name) {
      try {
        return _lib.lookup<NativeFunction<_StrToStrC>>(name).address;
      } catch (_) {
        return 0; // 老库缺这个符号 → 0,对端据此降级
      }
    }

    int sArg(String name) {
      try {
        return _lib.lookup<NativeFunction<_StrArgC>>(name).address;
      } catch (_) {
        return 0;
      }
    }

    return ChartSymbols(
      chartSeries: s2s('QP_ChartSeries'),
      chartDaily: s2s('QP_ChartDailySeries'),
      coverage: s2s('QP_Coverage'),
      free: sArg('QP_Free'),
      log: sArg('QP_Log'),
    );
  }

  int init(String configJson) {
    final p = configJson.toNativeUtf8();
    try {
      return _init(p);
    } finally {
      malloc.free(p);
    }
  }

  void start() => _start();
  void stop() => _stop();
  void setForeground(bool open) => _setForeground(open ? 1 : 0);

  void refresh(String accountId) {
    final p = accountId.toNativeUtf8();
    try {
      _refresh(p);
    } finally {
      malloc.free(p);
    }
  }

  /// 读取快照。返回的 C 字符串由 Go 分配,必须用 QP_Free 释放。
  String snapshotJson() {
    final ptr = _snapshot();
    if (ptr == nullptr) return '[]';
    try {
      return ptr.toDartString();
    } finally {
      _free(ptr);
    }
  }

  /// 按维度取图表数据。argsJson: {"instance","dimension","hours"}。
  /// 返回 {series,coverageFrom,requestedFrom} 的 JSON;C 字符串由 Go 分配,须 QP_Free 释放。
  /// 空指针返回 ''(上层据此判为取数异常,区别于真空数据)。
  String chartSeries(String argsJson) {
    final a = argsJson.toNativeUtf8();
    try {
      final ptr = _chartSeries(a);
      if (ptr == nullptr) return '';
      try {
        return ptr.toDartString();
      } finally {
        _free(ptr);
      }
    } finally {
      malloc.free(a);
    }
  }

  /// 按维度取**按天**图表数据(热力图)。argsJson: {"instance","dimension","days"}。
  /// 返回同 chartSeries 的 {series,coverageFrom,requestedFrom} JSON;空指针返回 ''。
  String chartDailySeries(String argsJson) {
    final a = argsJson.toNativeUtf8();
    try {
      final ptr = _chartDaily(a);
      if (ptr == nullptr) return '';
      try {
        return ptr.toDartString();
      } finally {
        _free(ptr);
      }
    } finally {
      malloc.free(a);
    }
  }

  /// 取覆盖水位/最早事件。argsJson: {"instance"}。返回 {coverageFrom,earliestEvent} JSON;
  /// 空指针返回 '{"coverageFrom":0,"earliestEvent":0}'。
  String coverage(String argsJson) {
    final a = argsJson.toNativeUtf8();
    try {
      final ptr = _coverage(a);
      if (ptr == nullptr) return '{"coverageFrom":0,"earliestEvent":0}';
      try {
        return ptr.toDartString();
      } finally {
        _free(ptr);
      }
    } finally {
      malloc.free(a);
    }
  }

  /// 读每实例的数据版本号,返回 {"实例名": 版本号} 的 JSON。
  ///
  /// 极廉价(Go 侧只读几个原子变量),这正是它能替代「每轮重算聚合」的前提。
  ///
  /// 哨兵:`''` = 取不到(符号缺失 / 空指针),调用方必须退回「照常查询」的旧行为,
  /// **绝不能当成「没变化」** —— 否则一次瞬时失败会让图表永久停止刷新。
  /// `'{}'` = 真的一个实例都没有。
  ///
  /// QP_ChartVersions 是后加的导出:老版 libqp 里没有这个符号,而 lookupFunction 找不到
  /// 符号会抛 ArgumentError。若在字段初始化时直接 lookup,用户拿旧 DLL 配新 exe 会让
  /// 整个 App 起不来。所以这里惰性解析 + 吞掉异常,降级成「版本永远未知」。
  // QP_ChartVersions 是无参导出(char* QP_ChartVersions(void)),用 _SnapC/_SnapD。
  _SnapD? _chartVersionsFn;
  bool _chartVersionsResolved = false;

  String chartVersions() {
    if (!_chartVersionsResolved) {
      _chartVersionsResolved = true;
      try {
        _chartVersionsFn = _lib.lookupFunction<_SnapC, _SnapD>('QP_ChartVersions');
      } catch (_) {
        _chartVersionsFn = null; // 旧库:降级,不致命
      }
    }
    final fn = _chartVersionsFn;
    if (fn == null) return '';
    final ptr = fn();
    if (ptr == nullptr) return '';
    try {
      return ptr.toDartString();
    } finally {
      _free(ptr); // Go 分配 → QP_Free
    }
  }

  // QP_Log / QP_LogPath 是后加的导出,老库里没有 → 惰性解析 + 吞异常,降级成「不记日志」。
  _StrArgD? _logFn;
  bool _logResolved = false;

  /// 把一行日志写进 Go 侧的同一个日志文件(日志没开时是廉价 no-op)。
  /// 这样 Dart 侧动作与 Go 侧动作落在**同一条时间线**上,排查崩溃时不用对齐两份日志。
  void log(String line) {
    if (!_logResolved) {
      _logResolved = true;
      try {
        _logFn = _lib.lookupFunction<_StrArgC, _StrArgD>('QP_Log');
      } catch (_) {
        _logFn = null;
      }
    }
    final fn = _logFn;
    if (fn == null) return;
    final p = line.toNativeUtf8();
    try {
      fn(p);
    } catch (_) {
      // 记日志本身绝不能成为新的故障源
    } finally {
      malloc.free(p);
    }
  }

  /// 当前日志文件路径(未启用/旧库返回空串),供设置页展示。
  String logPath() {
    try {
      final fn = _lib.lookupFunction<_SnapC, _SnapD>('QP_LogPath');
      final ptr = fn();
      if (ptr == nullptr) return '';
      try {
        return ptr.toDartString();
      } finally {
        _free(ptr);
      }
    } catch (_) {
      return '';
    }
  }

  /// 触发按需回填:确保某实例本地覆盖延伸到 now-hours(异步、立即返回)。
  /// argsJson: {"instance","hours"}。
  void ensureCoverage(String argsJson) {
    final p = argsJson.toNativeUtf8();
    try {
      _ensureCoverage(p);
    } finally {
      malloc.free(p);
    }
  }

  /// 开/关调试采样。argsJson: {"enabled","maxSamples","maxMemBytes"}。
  void debugSet(String argsJson) {
    final p = argsJson.toNativeUtf8();
    try {
      _debugSet(p);
    } finally {
      malloc.free(p);
    }
  }

  /// 读取调试采样报告(JSON)。C 字符串由 Go 分配,须 QP_Free 释放。
  String debugReport() {
    final ptr = _debugReport();
    if (ptr == nullptr) return '{"enabled":false,"instances":[]}';
    try {
      return ptr.toDartString();
    } finally {
      _free(ptr);
    }
  }

  /// 清空已采样本(保留开关与上限)。
  void debugReset() => _debugReset();
}

/// ChartSymbols 是「后台 isolate 需要的函数指针地址」集合。**全是 int,可安全跨 isolate 传递。**
/// 0 表示该符号在当前库里不存在(老版 libqp),对端据此降级而不是崩。
class ChartSymbols {
  const ChartSymbols({
    required this.chartSeries,
    required this.chartDaily,
    required this.coverage,
    required this.free,
    required this.log,
  });

  final int chartSeries;
  final int chartDaily;
  final int coverage;
  final int free;
  final int log;

  /// 三个查询里只要有一个拿不到,就没必要起 worker 了。
  bool get usable => chartSeries != 0 && chartDaily != 0 && coverage != 0 && free != 0;

  List<Object?> toWire() => <Object?>[chartSeries, chartDaily, coverage, free, log];

  static ChartSymbols fromWire(List<Object?> w) => ChartSymbols(
        chartSeries: w[0] as int,
        chartDaily: w[1] as int,
        coverage: w[2] as int,
        free: w[3] as int,
        log: w[4] as int,
      );
}

/// ChartQueryCore 是**只在后台 isolate 里存在**的精简核心:只含图表查询用得到的几个符号,
/// 由主 isolate 解析好地址后传过来重建,不做第二次 dlopen。
///
/// **这里的每个方法都必须与 [NativeCore] 里的同名方法保持相同的内存纪律**(见 CLAUDE.md):
/// Dart 传进去的字符串用 `malloc.free`,Go 返回的字符串用 `QP_Free`。用反了会破坏堆。
/// 之所以不复用 NativeCore:它持有 `DynamicLibrary`,而 dart:ffi 没有按地址重建 DynamicLibrary
/// 的入口,只能按函数指针重建。
class ChartQueryCore {
  ChartQueryCore(ChartSymbols s)
      : _chartSeries = Pointer<NativeFunction<_StrToStrC>>.fromAddress(s.chartSeries)
            .asFunction<_StrToStrD>(),
        _chartDaily = Pointer<NativeFunction<_StrToStrC>>.fromAddress(s.chartDaily)
            .asFunction<_StrToStrD>(),
        _coverage = Pointer<NativeFunction<_StrToStrC>>.fromAddress(s.coverage)
            .asFunction<_StrToStrD>(),
        _free = Pointer<NativeFunction<_StrArgC>>.fromAddress(s.free)
            .asFunction<_StrArgD>(),
        _log = s.log == 0
            ? null
            : Pointer<NativeFunction<_StrArgC>>.fromAddress(s.log)
                .asFunction<_StrArgD>();

  final _StrToStrD _chartSeries;
  final _StrToStrD _chartDaily;
  final _StrToStrD _coverage;
  final _StrArgD _free;
  final _StrArgD? _log;

  /// 三个查询共用一套调用骨架:入参 Dart 分配→malloc.free,返回值 Go 分配→QP_Free。
  /// 空指针返回 ''(上层据此判为取数异常,区别于真空数据)。
  String _call(_StrToStrD fn, String argsJson) {
    final a = argsJson.toNativeUtf8();
    try {
      final ptr = fn(a);
      if (ptr == nullptr) return '';
      try {
        return ptr.toDartString();
      } finally {
        _free(ptr);
      }
    } finally {
      malloc.free(a);
    }
  }

  String chartSeries(String argsJson) => _call(_chartSeries, argsJson);
  String chartDailySeries(String argsJson) => _call(_chartDaily, argsJson);
  String coverage(String argsJson) => _call(_coverage, argsJson);

  /// 写一行日志到 Go 侧同一个日志文件(未启用/老库时是 no-op)。
  void log(String line) {
    final fn = _log;
    if (fn == null) return;
    final p = line.toNativeUtf8();
    try {
      fn(p);
    } catch (_) {
      // 记日志绝不能成为新的故障源
    } finally {
      malloc.free(p);
    }
  }
}
