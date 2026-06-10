# 一次性:生成 Windows runner 并拉依赖。Windows 不沙箱,无需 runner 补丁。
# 之后用 .\build_app.ps1 出包,或 flutter run -d windows 调试。
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

if (-not (Test-Path "windows")) {
  Write-Host "==> 生成 Windows runner(到临时目录,只取 windows\,不动 lib\ 与 pubspec)"
  $tmp = Join-Path $env:TEMP "qp_gen_win"
  if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
  flutter create --platforms=windows --org com.lureiny --project-name quota_pulse $tmp
  Copy-Item -Recurse (Join-Path $tmp "windows") ".\windows"
  Remove-Item -Recurse -Force $tmp
} else {
  Write-Host "==> windows\ 已存在,跳过生成"
}

Write-Host "==> flutter pub get"
flutter pub get

Write-Host ""
Write-Host "完成。下一步:"
Write-Host "  .\build_app.ps1        # 出 dist\quota_pulse-windows.zip(可分发)"
Write-Host "  flutter run -d windows # 本地调试运行"
