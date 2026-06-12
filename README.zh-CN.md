# quota-pulse

一个跨平台的「用量脉搏」预览栏:在系统菜单栏 / 托盘里快速查看
[sub2api](https://github.com/Wei-Shaw/sub2api) 各账户的用量窗口(5h / 7d 等),
只读展示。抽象做了分层,未来可扩展到 one-api / new-api 等平台。

[English](README.md) · 中文

## 功能

- **用量表盘**:Claude 5h / 7d / 7d-Sonnet、Gemini 日/分钟 等滚动窗口,颜色分级进度条(≤80% 绿 / 80–99% 黄 / ≥100% 红),含利用率、重置时间与请求/Token/费用明细。
- **状态一眼可见**:状态点 + emoji(🟢 正常 · 🟡 预警 · 🔴 限流 · ⛔ 禁用 · 🚫 封禁 · 🔑 待重认证 · ⚪ 错误)+ 订阅等级徽标;**限流账户照常可见**(不再因被自动停用而消失)。
- **重置时间**:可选倒计时(`2天3h`,天为 0 时省略)或绝对时刻(`MM-dd HH:mm`),主页与托盘/菜单栏同时生效。
- **菜单栏 / 托盘**:macOS 自绘 `NSStatusItem`(固定图标 + 文字溢出时像素级滚动,宽度/速度可配);Windows 每账户 tooltip(基础行 + 每个选中窗口一行);可选显示用量或剩余量;范围支持全部账户(默认)或多选钉住子集。
- **显示窗口可配(5h / 7d,可多选)**:跨平台生效——菜单栏、托盘 tooltip、悬浮窗都只展示你勾选的窗口(默认两个都显示)。
- **Windows 悬浮窗口**(默认开):桌面常驻一个**可拖拽的置顶浮窗**,原生 Direct2D 自绘 + 彩色状态圆点;两种模式——**滚动**(单行,像素级 60fps 滚动,放不下就滚,单账户超宽也滚)、**多行**(不滚动,每账户铺「基础信息 + 各窗口一行」,如 base/5h/7d,窗口高度随行数自适应);左键点开主面板,拖动改位置(记忆),可选全屏时自动隐藏。
- **用量提醒**:两类可独立配置的通知,每类各自可选监听 **5h / 7d** 窗口——**超阈值**(默认开,5h+7d;🚨 告警 → 🛑 用量已满)与**额度恢复**(默认关,✅ 回落到阈值以下/窗口重置时);同类通知在同一重置周期内只弹一次(以 resets_at 为周期指纹,±10s 容差吸收抖动、避免误判成新周期而持续告警);用量回落到阈值以下即发"恢复";首次快照静默;带系统提示音;设置页「发送测试通知」一键依次弹出三种样例(🚨/🛑/✅)核验送达。
- **后台拉取**:被动读 sub2api 缓存的**刷新间隔可配**(默认 1 分钟);**自动强制回源默认关闭**——周期性回源有明显自动化特征,需要时再开并配置间隔(5m/10m/30m/1h);手动刷新按钮始终回源,不受此开关影响。
- **多实例**:可配置任意多个 sub2api 后台,分组或标签页展示;`实例|账户` 唯一键避免串号;实例名可点击用系统浏览器打开后台。
- **外观**:毛玻璃透明无边框弹层;行内展开查看全部窗口;系统字体 + 系统强调色 + 跟随明暗;版本号显示在设置页底部。
- **开机自启**:macOS 写用户级 LaunchAgent;Windows 写注册表 Run 键。
- **Go 核心**:被动/主动自适应轮询(被动 60s 可配;主动回源默认关、可配)、ETag/304 条件请求、空响应防回退缓存、限流并发(≤6)、Provider 插件化、`dart:ffi` + gomobile 桥、`qpctl` 调试 CLI。

## 结构

```
core/          平台无关 Go 核心(provider 抽象 · 轮询 · 缓存 · C-ABI/gomobile 桥)
ui/            跨平台 Flutter 共享包 package:quota_pulse_ui(模型 / UI / 状态 / FFI 桥)
apps/macos/    macOS 菜单栏薄壳 + 打包(.dmg)
apps/windows/  Windows 托盘薄壳 + 打包(.zip)
DESIGN.md      总体设计:选型 · 架构 · Provider 抽象 · 里程碑
```

> 复用边界:`core/` + `ui/` 跨平台 100% 复用;`apps/<platform>/` 只是各自的薄外壳(托盘/窗口/打包)。

## 本地构建

- **macOS**:见 [`apps/macos/SETUP.md`](apps/macos/SETUP.md) — `./setup_macos.sh && ./build_app.sh` → `.dmg`
- **Windows**:见 [`apps/windows/SETUP.md`](apps/windows/SETUP.md) — `./setup_windows.ps1; ./build_app.ps1` → `.zip`
- **Go 核心**:见 [`core/README.md`](core/README.md) — `go build ./... && go test ./...`

版本号编译期注入:`--dart-define=QP_VERSION=$(git describe --tags --always --dirty)`(优先 tag,其次 tag-距离-短SHA,再次短 SHA;`flutter run` 直跑为 `dev`)。

## 自动构建(GitHub Actions)

推一个 `v*` tag 即在云端 macOS / Windows runner 上自动编译并发布到 Releases:

```bash
git tag v0.4.0 && git push origin v0.4.0
```

工作流见 [`.github/workflows/release-desktop.yml`](.github/workflows/release-desktop.yml)。
也可在 Actions 页手动触发(workflow_dispatch),只产出构件、不建 Release。

> 产物未做付费签名/公证:macOS 首次「右键→打开」,Windows 首次 SmartScreen「仍要运行」。

## 字体

**Windows 端**打包内嵌 [MiSans](https://hyperos.mi.com/font/download)(小米,免费商用):
系统中文字体雅黑缺 Medium/Semibold,会把 `w500/w600` 就近吸附成 Regular/Bold,
字重忽粗忽细;内嵌 MiSans 修正。**macOS** 用系统 SF Pro(字重本就齐全,无需替换,也不增体积)。
字体版权归小米所有,许可见 [`ui/lib/fonts/MiSans-LICENSE.txt`](ui/lib/fonts/MiSans-LICENSE.txt)。

## 状态

macOS / Windows 均由 CI 出包(`.dmg` / `.zip`,最新 **v0.4.0**)。目前仅实现 sub2api provider;
模型与核心已按"加一个 mapper 即可接入"的方式设计,future one-api / new-api 无需改 UI。
详见 [DESIGN.md §9 里程碑](DESIGN.md)。
