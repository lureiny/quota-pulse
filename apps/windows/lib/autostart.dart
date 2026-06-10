import 'dart:io';

import 'package:win32_registry/win32_registry.dart';

/// Windows 开机自启动:在 HKCU\...\Run 下写一个指向当前 exe 的值。
/// 纯 Dart(win32_registry 走 FFI),无需原生构建。
/// 注:便携版(.zip)移动目录后注册表里仍是旧路径 → 需重新开启一次。
class Autostart {
  static const _runPath =
      r'Software\Microsoft\Windows\CurrentVersion\Run';
  static const _valueName = 'quota-pulse';

  static Future<bool> isEnabled() async {
    try {
      final key = CURRENT_USER.open(_runPath);
      try {
        final v = key.getString(_valueName);
        return v != null && v.isNotEmpty;
      } finally {
        key.close();
      }
    } catch (_) {
      return false;
    }
  }

  static Future<void> setEnabled(bool enable) async {
    final key = CURRENT_USER.create(_runPath); // readWrite
    try {
      if (enable) {
        // 加引号防路径含空格被拆成参数。REG_SZ 用 StringValue。
        key.setValue(
          _valueName,
          StringValue('"${Platform.resolvedExecutable}"'),
        );
      } else {
        try {
          key.removeValue(_valueName);
        } catch (_) {
          // 值不存在时忽略。
        }
      }
    } finally {
      key.close();
    }
  }
}
