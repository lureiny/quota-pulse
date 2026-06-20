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
  late final _SnapD _snapshot = _lib.lookupFunction<_SnapC, _SnapD>('QP_SnapshotJSON');
  late final _StrArgD _refresh = _lib.lookupFunction<_StrArgC, _StrArgD>('QP_Refresh');
  late final _StrToStrD _chartSeries =
      _lib.lookupFunction<_StrToStrC, _StrToStrD>('QP_ChartSeries');
  late final _StrArgD _free = _lib.lookupFunction<_StrArgC, _StrArgD>('QP_Free');
  late final _IntArgD _setForeground =
      _lib.lookupFunction<_IntArgC, _IntArgD>('QP_SetForeground');

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

  /// 按维度取小时序列。argsJson: {"instance","dimension","hours"}。
  /// 返回的 C 字符串由 Go 分配,必须用 QP_Free 释放。
  String chartSeries(String argsJson) {
    final a = argsJson.toNativeUtf8();
    try {
      final ptr = _chartSeries(a);
      if (ptr == nullptr) return '[]';
      try {
        return ptr.toDartString();
      } finally {
        _free(ptr);
      }
    } finally {
      malloc.free(a);
    }
  }
}
