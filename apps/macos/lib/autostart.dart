import 'dart:io';

/// macOS 开机自启动:在 ~/Library/LaunchAgents 写一个 RunAtLoad 的 LaunchAgent,
/// 登录后由 launchd 拉起当前 app。纯 Dart(dart:io 写文件),无需原生代码。
/// 前提:app 非沙箱(见 Release.entitlements;沙箱应用无法写 LaunchAgents)。
/// 开/关在下次登录生效。
class Autostart {
  static const _label = 'com.quota-pulse';

  static String get _plistPath {
    final home = Platform.environment['HOME'] ?? '';
    return '$home/Library/LaunchAgents/$_label.plist';
  }

  static Future<bool> isEnabled() => File(_plistPath).exists();

  static Future<void> setEnabled(bool enable) async {
    final file = File(_plistPath);
    if (enable) {
      await file.parent.create(recursive: true);
      await file.writeAsString(_plist(Platform.resolvedExecutable));
    } else if (await file.exists()) {
      await file.delete();
    }
  }

  static String _plist(String exe) {
    // App 路径允许包含 & / < / >;直接插入 XML 会生成损坏的 LaunchAgent。
    final escaped = exe
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$_label</string>
	<key>ProgramArguments</key>
	<array>
		<string>$escaped</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
</dict>
</plist>
''';
  }
}
