# 把 Go 核心编成 libqp.dll(cgo,需 Go + mingw-w64 gcc)。
# 注:Go 的 c-shared 在 Windows 上必须用 gcc(mingw),不能用 MSVC;
#     但生成的 DLL 是标准 C ABI,Flutter(MSVC 构建)能正常 LoadLibrary 调用。
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$core = Resolve-Path (Join-Path $here "..\..\core")
$out  = Join-Path $here "build"
New-Item -ItemType Directory -Force $out | Out-Null

if (-not (Get-Command gcc -ErrorAction SilentlyContinue)) {
  Write-Error "未找到 gcc(mingw-w64)。请安装并加入 PATH:`n  · MSYS2: pacman -S mingw-w64-x86_64-gcc(用 MINGW64 shell)`n  · 或 TDM-GCC / WinLibs。验证: gcc --version"
}

$env:CGO_ENABLED = "1"
$env:GOOS        = "windows"
$env:GOARCH      = "amd64"
$dll = Join-Path $out "libqp.dll"

Write-Host "==> go build -buildmode=c-shared → $dll"
go -C $core build -tags qpcgo -buildmode=c-shared -o $dll ./cmd/libqp

Write-Host "完成: $dll"
