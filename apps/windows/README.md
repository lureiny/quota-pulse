# quota-pulse · Windows

quota-pulse 的 **Windows 系统托盘外壳**:托盘图标 + 弹层,查看 sub2api 各账户用量窗口。
与 macOS 复用**同一个** `ui/` 共享包(`package:quota_pulse_ui`)和**同一个** Go 核心;
本目录只是 Windows 薄壳(托盘 / 窗口 / 打包)。

## 文档

| 想了解 | 看这里 |
|---|---|
| 怎么在 Windows 上构建 / 打包 / 分发 | [`./SETUP.md`](./SETUP.md) |
| 整体设计(选型、抽象、里程碑) | [`../../DESIGN.md`](../../DESIGN.md) |
| 共享层 / macOS 壳 | [`../macos/README.md`](../macos/README.md) |
| Go 核心 | [`../../core/README.md`](../../core/README.md) |

## 与 macOS 壳的差异(其余全部共用)

| 维度 | macOS | Windows |
|---|---|---|
| 托盘图标 | 模板 `.png`(系统染色) | 彩色 `.ico` |
| 峰值显示 | 菜单栏标题文字(`setTitle`) | 托盘 **tooltip**(`setToolTip`,Windows 托盘无标题) |
| 弹层定位 | 右上 `topRight` | 右下 `bottomRight`(托盘在右下) |
| 隐藏图标栏 | `LSUIElement`(无 Dock) | `skipTaskbar`(无任务栏按钮) |
| Runner 补丁 | 需要(AppDelegate / entitlements / Info.plist) | **不需要**(Windows 不沙箱) |
| 库文件 | `libqp.dylib` | `libqp.dll` |
| 嵌入方式 | 注入 `.app/Contents/Frameworks` + ad-hoc 签名 | 拷到 `.exe` 同级目录 |
| 打包 | `.dmg` | 便携 `.zip` |
| 首次打开拦截 | Gatekeeper →「右键→打开」 | SmartScreen →「更多信息→仍要运行」 |

> 这些差异全部集中在 `lib/main.dart` 这层薄壳里;模型 / UI / 状态 / FFI 桥一行没动。

## 目录

```
apps/windows/
├── README.md             本文件
├── SETUP.md              构建 / 打包 / 分发指南
├── pubspec.yaml          依赖:quota_pulse_ui(path) / tray_manager / window_manager
├── assets/tray_icon.ico  系统托盘图标(32×32)
├── setup_windows.ps1     ① 生成 runner + pub get
├── build_windows_dll.ps1 (被 build_app 调用)编 Go → libqp.dll(mingw)
├── build_app.ps1         ② 一键出 dist\quota_pulse-windows.zip
├── dist\                 构建产物(zip),build_app 生成
├── lib\main.dart         薄壳入口:托盘 + 弹层 + 核心生命周期(其余皆来自 ui 包)
└── windows\              由 setup_windows.ps1 生成(Flutter Win32 runner)
```

## 快速开始(细节见 SETUP.md)

```powershell
cd apps\windows
.\setup_windows.ps1    # 一次性:生成 runner + pub get
.\build_app.ps1        # 一键:出 dist\quota_pulse-windows.zip
# 调试改用: flutter run -d windows
```

## 状态 / 已知边界

- 复用 macOS 已验证的 Go 核心(`go build`/`test` 绿)与 `ui/` 共享包;Windows 壳为 Windows 专属新增。
- ⚠ 脚本与壳**未在本机(Linux)实机编译**,首次在 Windows 上 `flutter pub get` / `build` 才能终验;
  最可能需要微调的是 `tray_manager`/`window_manager` 在 Windows 的行为或版本解析,贴报错即可修。
- 未做 Authenticode 签名:可分发,接收方首次走 SmartScreen「仍要运行」。
- 弹层贴右下角(MVP);精确贴托盘上方为后续优化。
