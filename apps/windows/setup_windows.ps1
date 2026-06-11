# 一次性:生成 Windows runner、套原生补丁、拉依赖。Windows 不沙箱。
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

# ==> 套悬浮跑马灯原生补丁(幂等:已注入则跳过;锚点缺失则报错中止,避免静默漏打)
Write-Host "==> 套 Windows 原生补丁(win_ticker:悬浮跑马灯)"
Copy-Item "runner_patches\win_ticker.h"   "windows\runner\win_ticker.h"   -Force
Copy-Item "runner_patches\win_ticker.cpp" "windows\runner\win_ticker.cpp" -Force

# flutter_window.cpp:加 include + 在 RegisterPlugins 之后挂上跑马灯通道
$fw = "windows\runner\flutter_window.cpp"
$c = Get-Content $fw -Raw
if ($c -notmatch 'win_ticker\.h') {
  if ($c -notmatch '#include "flutter_window.h"') { throw "flutter_window.cpp 缺少 include 锚点,模板可能已变" }
  if ($c -notmatch 'RegisterPlugins\(flutter_controller_->engine\(\)\);') { throw "flutter_window.cpp 缺少 RegisterPlugins 锚点,模板可能已变" }
  $c = $c -replace '(#include "flutter_window.h")', ('$1' + "`r`n" + '#include "win_ticker.h"')
  $c = $c -replace '(RegisterPlugins\(flutter_controller_->engine\(\)\);)', ('$1' + "`r`n  qp_ticker::Attach(flutter_controller_->engine()->messenger(), GetHandle());")
  Set-Content $fw $c -NoNewline -Encoding UTF8
  Write-Host "    flutter_window.cpp 已注入"
} else {
  Write-Host "    flutter_window.cpp 已含补丁,跳过"
}

# runner/CMakeLists.txt:把 win_ticker.cpp 加进源列表(d2d1/dwrite 由 cpp 内 #pragma comment 自动链接)
$cm = "windows\runner\CMakeLists.txt"
$c = Get-Content $cm -Raw
if ($c -notmatch 'win_ticker\.cpp') {
  if ($c -notmatch '"flutter_window\.cpp"') { throw "runner/CMakeLists.txt 缺少源列表锚点,模板可能已变" }
  $c = $c -replace '("flutter_window\.cpp")', ('$1' + "`r`n  " + '"win_ticker.cpp"')
  Set-Content $cm $c -NoNewline -Encoding UTF8
  Write-Host "    CMakeLists.txt 已注入"
} else {
  Write-Host "    CMakeLists.txt 已含补丁,跳过"
}

Write-Host "==> flutter pub get"
flutter pub get

Write-Host ""
Write-Host "完成。下一步:"
Write-Host "  .\build_app.ps1        # 出 dist\quota_pulse-windows.zip(可分发)"
Write-Host "  flutter run -d windows # 本地调试运行"
