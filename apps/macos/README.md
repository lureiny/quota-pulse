# quota-pulse · macOS

quota-pulse 的 **macOS 菜单栏外壳**:一个 `LSUIElement` 状态栏应用,点开弹层即可看到
sub2api 各账户的用量窗口(5h / 7d 等)进度条。第一版只读展示,不做任何操作。

这是整个项目的"薄外壳"层之一;真正的拉取/缓存/抽象都在平台无关的 Go 核心里。

## 先读哪份文档

| 想了解 | 看这里 |
|---|---|
| **为什么这么选型**(语言、原生 vs 跨平台、目录结构、Provider 抽象) | [`../../DESIGN.md`](../../DESIGN.md) |
| **怎么在 Mac 上把它跑起来**(逐步:编 dylib → 生成 runner → 套补丁 → 运行) | [`./SETUP.md`](./SETUP.md) |
| **Go 核心的包结构与扩展方式** | [`../../core/README.md`](../../core/README.md) |

> 新手就按顺序:DESIGN(知道在干嘛)→ SETUP(动手跑)→ 本文件(查地图/排错)。

## 它在整体架构里的位置

```
┌─────────────────────────────────────────────┐
│ apps/macos/   ← 本目录:菜单栏 + 弹层窗口(薄)   │
├─────────────────────────────────────────────┤
│ lib/(Flutter UI + FFI 桥)只认识"通用模型"      │
├─────────────────────────────────────────────┤
│   dart:ffi  ↕  libqp.dylib                   │
├─────────────────────────────────────────────┤
│ core/(Go)provider 抽象 · 轮询 · 缓存 · 配置    │
│   └─ providers/sub2api                        │
└─────────────────────────────────────────────┘
```

完整分层与"通用层 vs 平台特定层"的边界见 [DESIGN §2–§3](../../DESIGN.md)。

## 数据流(进程内 FFI)

```
Flutter UI ──每2s── snapshotJson() ──dart:ffi──▶ libqp.dylib(Go core)
                                                  └ 自己按节奏轮询 sub2api、缓存
设置保存   ── init(configJson) + start() ───────▶ 同上
开/收弹层  ── setForeground(bool) ─────────────▶ Go 调度器提频/降频(省电)
```

Go 核心负责真正的网络轮询与缓存;Dart 只廉价地读内存快照来渲染。
对应的 C-ABI 导出在 [`../../core/cmd/libqp/capi.go`](../../core/cmd/libqp/capi.go)。

## 目录地图

> 共享 UI / 模型 / 状态 / FFI 桥已抽到 **`../../ui`(`package:quota_pulse_ui`)**;本目录只剩 macOS 薄壳。

```
apps/macos/                       # macOS 薄壳(托盘 + 窗口 + 打包)
├── README.md              本文件(地图 + 索引)
├── SETUP.md               搭建 / 打包指南(免 Xcode 流程 + 故障排查)
├── pubspec.yaml           依赖:quota_pulse_ui(path) / tray_manager / window_manager
├── assets/tray_icon.png   菜单栏模板图标(44×44)
├── setup_macos.sh         ① 一次性:生成 runner + 套补丁(免 Xcode)
├── build_app.sh           ② 一键:出 dist/quota_pulse.app + .dmg(免 Xcode)
├── build_macos_dylib.sh   (被 build_app.sh 调用)把 core 编成通用 libqp.dylib
├── dist/                  构建产物(.app / .dmg),build_app.sh 生成
├── runner_patches/        套到 flutter 生成的 macos/ 上的补丁(脚本自动应用)
│   ├── AppDelegate.swift          隐藏窗口不退出
│   ├── DebugProfile.entitlements  允许出站 HTTPS(network.client)
│   ├── Release.entitlements       同上
│   └── Info.plist.additions.md    LSUIElement(无 Dock 图标)
└── lib/
    └── main.dart          薄壳入口:托盘 + 弹层窗口 + 核心生命周期(其余皆来自 ui 包)

../../ui/                         # ★ 跨平台共享包 package:quota_pulse_ui
└── lib/
    ├── quota_pulse_ui.dart       barrel(对外导出)
    └── src/
        ├── bridge/   pulse_source(抽象)· native_core(dart:ffi,按平台选 dylib/dll/so)· ffi_pulse_source
        ├── models/   pulse.dart(AccountPulse / Meter)
        ├── state/    pulse_controller(每 2s 读快照)· settings_store(存 url/key)
        ├── format.dart                状态色 / 进度条色 / 时长 / 百分比
        ├── widgets/  meter_bar · account_tile · status_dot
        └── pages/    popover_page(列表) · settings_page(填连接)
```

## 快速开始(细节见 SETUP.md)

```bash
cd apps/macos
./setup_macos.sh     # 一次性:生成 runner + 套补丁(免 Xcode)
./build_app.sh       # 一键:出 dist/quota_pulse.app + .dmg(免 Xcode、ad-hoc 签名)
# 调试改用: flutter run -d macos
```

产物 `dist/quota_pulse.dmg` 可直接发给别人(无 Apple 开发者账号):对方拖进「应用程序」,
首次「右键→打开」一次即可——做法见 [SETUP §3 分发](./SETUP.md)。

## 状态 / 已知边界

- **Go 核心**:`go build` / `go test` 绿;`c-shared` / `c-archive` 均可编;9 个 `QP_*` 导出齐全。
- **Flutter 侧**:在 Linux 上手写并按 pub.dev 文档核对了第三方 API,但**未经 Mac 实机编译**。
  首次 `flutter run` 若报 Dart 错(大概率是 `window_manager` 某方法签名),贴出来即可修。
- **菜单栏文字**:用 `tray_manager.setTitle` 显示实时峰值%;若你的 macOS 不显示文字,
  仍有图标兜底。
- **弹层定位**:MVP 用 `Alignment.topRight`(贴右上角);精确贴到托盘图标下方是后续优化。
- **分发/签名**:`build_app.sh` 做 **ad-hoc 签名**(免开发者账号),产物可发多人,首次需「右键→打开」。
  要双击零提示需 Apple 开发者账号做公证——不在当前流程内。`setup_macos.sh`/`build_app.sh` 为
  macOS 专用脚本,**未在本机(Linux)实跑过**,首次执行如有报错请贴出来。

## 扩展到其它平台 / 其它 provider

- 加 Windows/Linux 托盘、iOS/Android 前台页:复用 `core/` 与 `ui/` 包(models/widgets/bridge 接口),
  只新增对应 `apps/<platform>/`。路线见 [DESIGN §9 里程碑](../../DESIGN.md)。
- 接 one-api / new-api:在 `core/providers/` 加 client + mapper,UI/外壳零改动。
  步骤见 [`../../core/README.md`](../../core/README.md)。
