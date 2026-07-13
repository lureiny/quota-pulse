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
  NativeCore._(this._lib);

  final DynamicLibrary _lib;

  late final _InitD _init = _lib.lookupFunction<_InitC, _InitD>('QP_Init');
  late final _VoidD _start = _lib.lookupFunction<_VoidC, _VoidD>('QP_Start');
  late final _VoidD _stop = _lib.lookupFunction<_VoidC, _VoidD>('QP_Stop');
  late final _SnapD _snapshot =
      _lib.lookupFunction<_SnapC, _SnapD>('QP_SnapshotJSON');
  late final _StrArgD _refresh =
      _lib.lookupFunction<_StrArgC, _StrArgD>('QP_Refresh');
  late final _StrToStrD _chartSeries =
      _lib.lookupFunction<_StrToStrC, _StrToStrD>('QP_ChartSeries');
  late final _StrToStrD _chartDaily =
      _lib.lookupFunction<_StrToStrC, _StrToStrD>('QP_ChartDailySeries');
  late final _StrToStrD _coverage =
      _lib.lookupFunction<_StrToStrC, _StrToStrD>('QP_Coverage');
  late final _StrArgD _ensureCoverage =
      _lib.lookupFunction<_StrArgC, _StrArgD>('QP_EnsureCoverage');
  late final _StrArgD _free =
      _lib.lookupFunction<_StrArgC, _StrArgD>('QP_Free');
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
    // 生产路径优先于默认搜索路径,避免 Windows/Linux 从当前工作目录误载同名库。
    // macOS 包内库位于 Contents/Frameworks,由 @rpath 解析。
    final candidates = <String>[
      if (Platform.isMacOS) ...[
        '@rpath/$file',
        '$exeDir/../Frameworks/$file',
        '$exeDir/$file',
      ] else
        '$exeDir/$file',
      file, // 本地开发兜底
    ];

    DynamicLibrary? lib;
    Object? lastErr;
    for (final name in candidates) {
      try {
        lib = DynamicLibrary.open(name);
        break;
      } catch (e) {
        lastErr = e;
      }
    }
    if (lib == null) {
      throw StateError('无法加载 $file:$lastErr');
    }
    return NativeCore._(lib);
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
