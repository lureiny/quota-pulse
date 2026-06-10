#!/usr/bin/env bash
# 一次性:生成 macOS runner 并套好补丁——全程不需要打开 Xcode。
# 之后用 ./build_app.sh 反复出包,或 flutter run -d macos 调试。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ ! -d macos ]]; then
  echo "==> 生成 macOS runner(到临时目录,只取 macos/,不动 lib/ 与 pubspec)"
  tmp="$(mktemp -d)"
  flutter create --platforms=macos --org com.lureiny --project-name quota_pulse "$tmp"
  cp -R "$tmp/macos" ./macos
  rm -rf "$tmp"
else
  echo "==> macos/ 已存在,跳过生成"
fi

echo "==> 套 runner 补丁"
cp runner_patches/AppDelegate.swift         macos/Runner/AppDelegate.swift
cp runner_patches/DebugProfile.entitlements macos/Runner/DebugProfile.entitlements
cp runner_patches/Release.entitlements      macos/Runner/Release.entitlements

# LSUIElement=true(无 Dock 图标,菜单栏专属)——用 PlistBuddy 脚本化,无需手改。
plist="macos/Runner/Info.plist"
if /usr/libexec/PlistBuddy -c "Print :LSUIElement" "$plist" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Set :LSUIElement true" "$plist"
else
  /usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$plist"
fi
echo "    + LSUIElement=true"

echo "==> flutter pub get"
flutter pub get

echo
echo "完成。下一步:"
echo "  ./build_app.sh         # 出 dist/quota_pulse.app + .dmg(可分发)"
echo "  flutter run -d macos   # 本地调试运行"
