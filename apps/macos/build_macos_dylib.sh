#!/usr/bin/env bash
# 在 macOS 上运行:把 Go 核心编译成通用(arm64+amd64)libqp.dylib,供 dart:ffi 加载。
# 需要:Xcode 命令行工具 + Go。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$SCRIPT_DIR/../../core"
OUT_DIR="$SCRIPT_DIR/build"
mkdir -p "$OUT_DIR"

build_arch() {
  local arch="$1"
  echo "==> 编译 darwin/$arch"
  CGO_ENABLED=1 GOOS=darwin GOARCH="$arch" \
    go -C "$CORE_DIR" build -tags qpcgo -buildmode=c-shared \
    -o "$OUT_DIR/libqp-$arch.dylib" ./cmd/libqp
}

build_arch arm64
# Intel 切片(可选)。若交叉编译失败,可注释掉这一行,只出 arm64。
build_arch amd64

if [[ -f "$OUT_DIR/libqp-amd64.dylib" ]]; then
  echo "==> lipo 合并通用库"
  lipo -create -output "$OUT_DIR/libqp.dylib" \
    "$OUT_DIR/libqp-arm64.dylib" "$OUT_DIR/libqp-amd64.dylib"
else
  cp "$OUT_DIR/libqp-arm64.dylib" "$OUT_DIR/libqp.dylib"
fi

# 设为 @rpath,嵌入 .app 后从 Contents/Frameworks 解析。
install_name_tool -id @rpath/libqp.dylib "$OUT_DIR/libqp.dylib"

echo "==> 完成:$OUT_DIR/libqp.dylib"
file "$OUT_DIR/libqp.dylib"
echo
echo "提示:一般不用单独跑本脚本——./build_app.sh 会调用它,并自动把 dylib"
echo "      注入 .app + ad-hoc 签名(无需 Xcode)。仅在走手动 Xcode 流程时,"
echo "      才把此 dylib 设为 'Embed & Sign'。"
