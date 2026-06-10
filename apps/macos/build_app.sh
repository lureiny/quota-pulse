#!/usr/bin/env bash
# 一键:源码 → quota_pulse.app(注入并 ad-hoc 签名 libqp.dylib)→ quota_pulse.dmg。
# 需要:macOS + Flutter + Go。无需 Apple 开发者账号(用 ad-hoc 签名)。
# 全程不开 Xcode。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="quota_pulse"
DIST="$SCRIPT_DIR/dist"

if [[ ! -d macos ]]; then
  echo "未找到 macos/。请先运行:./setup_macos.sh" >&2
  exit 1
fi

echo "==> 1/5 编译 Go 核心为通用 dylib"
bash build_macos_dylib.sh
DYLIB="$SCRIPT_DIR/build/libqp.dylib"
[[ -f "$DYLIB" ]] || { echo "未找到 $DYLIB" >&2; exit 1; }

echo "==> 2/5 flutter build macos --release"
flutter build macos --release
APP="$(find build/macos/Build/Products/Release -maxdepth 1 -name '*.app' | head -n1)"
[[ -d "$APP" ]] || { echo "未找到构建产物 .app" >&2; exit 1; }
echo "    app: $APP"

echo "==> 3/5 注入 dylib 到 .app/Contents/Frameworks(@rpath 解析)"
FW="$APP/Contents/Frameworks"
mkdir -p "$FW"
cp "$DYLIB" "$FW/libqp.dylib"
install_name_tool -id @rpath/libqp.dylib "$FW/libqp.dylib" 2>/dev/null || true

echo "==> 4/5 ad-hoc 签名(Apple Silicon 必需)"
# 由内而外:先签注入的 dylib,再用 entitlements 重签整个 app(保住沙箱网络权限)。
codesign --force --sign - "$FW/libqp.dylib"
codesign --force --deep --sign - \
  --entitlements macos/Runner/Release.entitlements "$APP"
codesign --verify --deep --strict "$APP" && echo "    ✔ 签名校验通过"

echo "==> 5/5 打包 .dmg"
mkdir -p "$DIST"
rm -rf "$DIST/$(basename "$APP")" "$DIST/$APP_NAME.dmg"
cp -R "$APP" "$DIST/"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO \
  "$DIST/$APP_NAME.dmg" >/dev/null
rm -rf "$STAGE"

echo
echo "完成:"
echo "  .app → $DIST/$(basename "$APP")"
echo "  .dmg → $DIST/$APP_NAME.dmg"
echo
echo "分发:把 $APP_NAME.dmg 发给对方 → 拖进「应用程序」。"
echo "首次打开(未公证,绕过 Gatekeeper 一次):"
echo "  · 右键点 App →「打开」→ 弹窗里再点「打开」;或"
echo "  · 终端:xattr -dr com.apple.quarantine /Applications/$(basename "$APP")"
