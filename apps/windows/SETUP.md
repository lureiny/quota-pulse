# quota-pulse · Windows 搭建 / 打包指南

把 Go 核心(`libqp.dll`)和 Flutter 系统托盘壳打成一个**便携 zip**(解压即用、可分发)。
**全程在 Windows 上做。** 复用与 macOS 同一个 `ui/` 共享包,本目录只是 Windows 薄壳。

```
apps/windows/
├── lib/main.dart          # 薄壳入口(共享 UI 在 ../../ui 的 quota_pulse_ui 包)
├── pubspec.yaml           # 依赖:quota_pulse_ui(path) / tray_manager / window_manager
├── assets/tray_icon.ico   # 系统托盘图标(32×32 彩色)
├── setup_windows.ps1      # ① 一次性:生成 runner + pub get
├── build_windows_dll.ps1  # (被 build_app 调用)编 Go → libqp.dll
├── build_app.ps1          # ② 一键:出 dist\quota_pulse-windows.zip
└── windows/               # 由 setup_windows.ps1 生成(此处暂无)
```

> 共享 UI / 模型 / 状态 / FFI 桥在 `..\..\ui`(`package:quota_pulse_ui`),`flutter pub get` 经 path 依赖自动拉取。
> 与 macOS 的差异仅在薄壳:托盘用 `.ico`、峰值走 tooltip(Windows 托盘无标题文字)、弹层贴右下角。

## 0. 准备(装一次)

```powershell
flutter --version            # Flutter 3.24+ / Dart 3.4+
flutter config --enable-windows-desktop
# Visual Studio 2022 + 勾选「使用 C++ 的桌面开发」工作负载(Flutter Windows 构建必需)
go version                   # Go 1.24
gcc --version                # mingw-w64(给 Go 的 cgo 用);没有就装 MSYS2 / TDM-GCC / WinLibs 并加 PATH
```

> 两套 C 工具链各司其职:**MSVC** 编 Flutter 的 Windows runner,**mingw gcc** 编 Go 的 `libqp.dll`。
> 两者通过标准 C ABI 对接,互不冲突。

## 1. 一次性脚手架

```powershell
cd apps\windows
.\setup_windows.ps1
```

生成 `windows\` runner + `flutter pub get`。**Windows 不沙箱,无需任何 runner 补丁**(比 macOS 省事)。

## 2. 一键出包

```powershell
.\build_app.ps1
```

四步:编 `libqp.dll`(mingw)→ `flutter build windows --release` → 把 dll 拷到 exe 同级 → 打成 zip。产物:

```
dist\quota_pulse-windows.zip   # 便携版:解压 → 运行 quota_pulse.exe
```

> 改了 `core\` 或 `ui\` 后,重跑 `.\build_app.ps1`。调试用 `flutter run -d windows`。

## 3. 分发(多人)

把 `quota_pulse-windows.zip` 发出去 → 对方解压 → 双击 `quota_pulse.exe`。
未做代码签名时,首次运行可能被 **SmartScreen** 拦(「Windows 已保护你的电脑」):

- 点「**更多信息**」→「**仍要运行**」即可(和 macOS 的「右键→打开」一个意思)。

> 想去掉这个提示需 **Authenticode 代码签名证书**(向 CA 购买,EV 证书可即时建立信誉)——
> 不在本流程里;不签也能正常分发,只是首次多一步确认。

## 4. 使用

1. 系统托盘(右下角)出现蓝色图标。
2. 左键点它 → 弹层。首次运行自动进设置页。
3. 填 **Base URL** + **Admin API Key**(`x-api-key`)→ **保存并连接**。
4. 看到各账户 5h/7d 进度条 + 重置倒计时 + 状态色。鼠标悬停托盘图标看峰值%。右键菜单:刷新 / 设置 / 退出。

---

## 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| `flutter build windows` 报缺 C++ / MSBuild | 没装 Visual Studio 的「使用 C++ 的桌面开发」工作负载,装上重试 |
| `build_windows_dll.ps1` 报找不到 gcc | 没装 mingw-w64 或不在 PATH;`gcc --version` 应可用 |
| 运行时弹「无法加载 libqp.dll」 | dll 没拷到 exe 同级;确认 `build_app.ps1` 第 3 步成功,zip 里 exe 旁应有 `libqp.dll` |
| 托盘没图标 | 确认 `assets\tray_icon.ico` 已随 `flutter pub get` 打包(pubspec 的 `flutter.assets`) |
| 账户全是「错误/超时」 | Base URL / Key 填错,或网络不通(Windows 不沙箱,无需额外网络权限) |
| 弹层点外面不收起 | 个别情况 `onWindowBlur` 不触发;再点一次托盘图标即可收起 |
| 弹层位置压住任务栏 | MVP 贴 `bottomRight`;精确贴到托盘上方是后续优化 |

---

## 数据流(与 macOS 一致,进程内 FFI)

```
Flutter UI ──每2s── QP_SnapshotJSON() ──dart:ffi──▶ libqp.dll(Go core 自己轮询 sub2api)
设置保存   ── QP_Init(json)+QP_Start() ──▶ 同上
开/收弹层  ── QP_SetForeground(bool) ──▶ Go 调度器提频/降频(省电)
```
