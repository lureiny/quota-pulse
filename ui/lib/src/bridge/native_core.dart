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

  /// 已加载镜像的 dlopen 句柄地址。**后台 isolate 要用它来复现同一次加载。**
  ///
  /// 为什么不传路径让对端自己 open:那样是第二次 dlopen,解析结果理论上相同、
  /// 实际上取决于 @rpath / 搜索路径在该调用点如何展开。一旦解析到**另一个文件**,
  /// 进程里就会出现两份 libqp、两个 Go runtime(golang/go#65050 明确说这会炸),
  /// 而且第二份的全局 engine 从没 QP_Init 过 —— 表现就是闪退或静默空数据。
  /// 传句柄没有这个歧义:拿到的必然是同一个镜像。
  int get handleAddress => _lib.handle.address;

  /// 按已加载镜像的句柄地址构造(供后台 isolate 用)。
  /// 句柄是进程级的,跨 isolate 传一个 int 是安全的;**永不调 DynamicLibrary.close()**
  /// —— Go 的 c-shared 不支持 dlclose。
  factory NativeCore.fromHandleAddress(int address, String label) => NativeCore._(
        DynamicLibrary.fromHandle(Pointer<Void>.fromAddress(address)),
        label,
      );

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
