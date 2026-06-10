# 一键:源码 → quota_pulse.exe(同目录带 libqp.dll)→ 便携 zip。
# 需要:Windows + Flutter(含 Visual Studio C++ 工作负载)+ Go + mingw-w64。
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

if (-not (Test-Path "windows")) {
  Write-Error "未找到 windows\。请先运行 .\setup_windows.ps1"
}

Write-Host "==> 1/4 编译 Go 核心 → libqp.dll"
& "$here\build_windows_dll.ps1"
$dll = Join-Path $here "build\libqp.dll"
if (-not (Test-Path $dll)) { Write-Error "未找到 $dll" }

Write-Host "==> 2/4 flutter build windows --release"
flutter build windows --release

Write-Host "==> 3/4 把 libqp.dll 拷到 Release 目录(exe 同级,DynamicLibrary.open 即可解析)"
$exe = Get-ChildItem -Recurse -Path "build\windows" -Filter "quota_pulse.exe" |
       Select-Object -First 1
if (-not $exe) { Write-Error "未找到构建产物 quota_pulse.exe" }
$rel = $exe.Directory.FullName
Copy-Item $dll $rel -Force
Write-Host "    release: $rel"

Write-Host "==> 4/4 打包便携 zip"
New-Item -ItemType Directory -Force "dist" | Out-Null
$zip = Join-Path $here "dist\quota_pulse-windows.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path (Join-Path $rel "*") -DestinationPath $zip

Write-Host ""
Write-Host "完成:"
Write-Host "  便携目录: $rel"
Write-Host "  分发 zip : $zip"
Write-Host ""
Write-Host "分发:把 zip 发给对方 → 解压 → 运行 quota_pulse.exe。"
Write-Host "未签名时首次会被 SmartScreen 拦:点「更多信息」→「仍要运行」(同 macOS 右键打开)。"
