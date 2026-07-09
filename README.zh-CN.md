# quota-pulse

**跨平台的「用量脉搏」预览栏,常驻菜单栏 / 系统托盘。**
不开浏览器就能扫一眼 [sub2api](https://github.com/Wei-Shaw/sub2api) 各账户的用量窗口(5h / 7d、Gemini 日/分钟 等)。只读——绝不改动上游任何东西。

[English](README.md) · 中文

> macOS 常驻**菜单栏**,Windows 常驻**系统托盘**。点一下弹出毛玻璃面板,展示每个账户的用量。重活由共享的 **Go** 核心扛;UI 是共享的 **Flutter** 包;每个平台只是一层薄壳。

---

## 功能

### 📊 用量一览
- **滚动窗口表盘**:从 sub2api 映射的 Claude **5h / 7d / 7d-Sonnet**、Gemini **日 / 分钟** 等窗口——每个一根颜色分级进度条(≤80% 绿 / 80–99% 琥珀 / ≥100% 红)。
- **每窗口明细**:利用率 %、重置时间,以及请求 / Token / 费用统计(如 `1.2M tok · $3.4`)。
- **账户状态一眼可见**:彩色圆点 + emoji:🟢 正常 · 🟡 预警 · 🔴 限流 · ⛔ 禁用 · 🚫 封禁 · 🔑 待重认证 · ⚪ 错误。
- **订阅等级**徽标(FREE / PRO / ULTRA …)按账户显示。
- **限流账户照常可见**——被 sub2api 因限流自动停用的账户仍会被拉取并显示(状态由状态点体现),不会被悄悄丢弃。
- **重置时间随你**:倒计时(`2天3h`、`3h13m`;到「天」级,为 0 时省略天)或绝对时刻(`MM-dd HH:mm`)。该选择对主页**和**托盘/菜单栏同时生效。

### 🖥️ 菜单栏 / 托盘
- **macOS**:自绘 `NSStatusItem`,**固定图标** + 内容溢出时**像素级丝滑滚动**(60 fps),放得下则静态。滚动**宽度**与**速度**可配。
- **Windows**:**每账户 tooltip**(状态 emoji + `实例·账户`,随后每个选中窗口一行缩进),超出 tooltip 长度预算时折叠为 `…还有 N 个`。
- **Windows 悬浮窗**(默认开):一个**可拖拽、置顶的桌面浮条**,原生自绘(Direct2D + 彩色状态圆点)。两种模式:
  - **滚动**——单行,像素级 60 fps 滚动(内容与 macOS 菜单栏同源);放不下就滚,单账户超宽也滚。**拖浮窗左/右边缘即可改宽**(最宽到整屏),也可在设置里用滑块设宽。
  - **多行**——不滚动,每账户铺成「基础行 + 每个选中窗口一行」(如 base / 5h / 7d),窗口高度自适应。
  左键点开主面板,拖动改位置(记忆),可选前台全屏时自动隐藏。
- **显示窗口可配(5h / 7d,可多选)**——跨平台;菜单栏、托盘 tooltip、悬浮窗都只展示你勾选的窗口(默认两个都选)。
- 可显示**用量**或**剩余**百分比,随你。
- 托盘内容范围可配:**全部账户**(默认)或**多选钉住的子集**。

### 🔔 用量提醒
- **两类通知,各自独立可配**——每类还可分别选哪些窗口触发(**5h** / **7d**):
  - **超阈值**(默认**开**,5h + 7d)——用量越过你设的阈值(默认 **90%**)时触发,≥ 100%(限流)时从 🚨 *用量告警* 升级为 🛑 *额度已满*。
  - **额度恢复**(默认**关**)——✅ 当某窗口回落到阈值以下时触发(典型场景是窗口重置)。
- **每个重置周期、每类只提醒一次**——以窗口的重置时间去重,并按 ±10s 容差比较,避免把原始值的抖动误判成新周期(否则每次轮询都会刷屏)。真正重置才开启新周期;恢复通知在用量回落到阈值以下时发出。
- **首次快照静默**(以及重新启用后),避免启动时对已在高位的账户炸出一串通知。
- 每条通知带系统提示音;设置页的**测试按钮**会依次发出每一类的样例(🚨 / 🛑 / ✅),无需等触发阈值即可验证送达并预览。

### 🗂️ 多个 sub2api 后台
- 可配置**任意多个实例**(名称 + Base URL + API key);在设置里增 / 改 / 删。
- **分组**(每实例标题)或**标签页**展示,随你。
- 每个实例的账户以 `实例|账户ID` 为键,**两个后台下相同的账户 ID 也不会串号**。
- **实例名是超链接**——点它用系统浏览器打开该后台。
- 每实例一个**刷新**按钮,强制回源拉取。

### 🎨 外观与交互
- **毛玻璃**面板,透明无边框窗口(`flutter_acrylic` + `window_manager`)。
- **行内展开**某行查看该账户全部窗口;桌面端**悬停**露出刷新操作。
- **系统原生观感**:系统字体(macOS 用 SF Pro;Windows 内嵌 MiSans)与**系统强调色**。
- **浅色 / 深色 / 跟随系统**主题。
- 清晰的**空 / 加载中 / 错误**状态。
- 应用**版本号**显示在设置页底部。

### ⚙️ 配置项(及默认值)

| 设置 | 选项 | 默认 |
|---|---|---|
| sub2api 实例 | 名称 + Base URL + API key(可多个) | — |
| 列表布局 | 分组 · 标签页 | **分组** |
| 主题 | 系统 · 浅色 · 深色 | **系统** |
| 托盘范围 | 全部账户 · 钉住(多选) | **全部账户** |
| 托盘显示量 | 用量 % · 剩余 % | **用量** |
| 显示窗口 *(菜单栏 / 托盘 / 悬浮窗)* | 5h · 7d(多选) | **5h + 7d** |
| 重置显示 | 倒计时 · 绝对 | **倒计时** |
| 滚动宽度 *(macOS 菜单栏)* | 字符数 | **10** |
| 滚动速度 *(macOS 菜单栏 / Windows 滚动模式)* | 毫秒/步(越小越快) | **300** |
| Windows 悬浮窗 | 开 / 关 | **开** |
| Windows 悬浮模式 | 滚动 · 多行 | **滚动** |
| Windows 悬浮窗宽度 *(滚动模式)* | 像素——拖浮窗边缘,最宽到整屏 | **~90px** |
| 全屏时自动隐藏 *(Windows)* | 开 / 关 | 关 |
| 用量提醒(总开关) | 开 / 关 | **开** |
| 提醒阈值 | 50–100% | **90%** |
| 超阈值监听窗口 | 5h · 7d(多选) | **5h + 7d** |
| 额度恢复监听窗口 | 5h · 7d(多选) | **无(关)** |
| 刷新间隔 *(被动读缓存)* | 30s · 1m · 2m · 5m | **1m** |
| 自动强制回源(回源上游) | 关 · 5m · 10m · 30m · 1h | **关** |
| 开机自启 | 开 / 关 | 关 |

设置持久化为 `SharedPreferences` 里的单个 JSON(`qp.settings`);旧的单实例配置会自动迁移。

### 🚀 开机自启
- **macOS**:用户级 `LaunchAgent` plist(`~/Library/LaunchAgents`)——纯 Dart,无 helper。(应用刻意**不沙箱**以便写入。)
- **Windows**:一个指向可执行文件的 `HKCU\…\Run` 注册表项。

### 🧩 引擎内幕(Go 核心)
- **被动 / 主动自适应轮询**——廉价的缓存读取走**可配间隔**(默认 **60s**),外加**可选的**周期性强制回源(**默认关**——周期性回源有明显的自动化特征;开启后间隔可配)。手动刷新按钮始终回源。引擎接受前台 / 电池 / 休眠信号来调节节奏。
- **ETag / `If-None-Match` 304** 条件请求,省上游带宽。
- **防回退缓存**——空的被动响应绝不覆盖已拉到的好数据(无闪烁 / 不丢数据);真实错误仍照常写入。
- **并发受限**——账户并行拉取(≤ 6)且每账户带超时;单个账户失败时保留它上次的快照。
- **Provider 插件架构**——provider 自注册;当前实现 sub2api。
- **原生绑定**——编译成 C 共享库(`libqp.dylib` / `.dll` / `.so`)经 `dart:ffi` 调用;另含 `gomobile` 绑定,为将来 iOS/Android 预留。
- **`qpctl`** 调试 CLI——按一份配置跑一轮轮询并打印快照 JSON。

---

## 架构

```
core/          平台无关 Go 核心(provider 抽象 · 轮询 · 缓存 · C-ABI/gomobile 桥)
ui/            跨平台 Flutter 共享包 package:quota_pulse_ui(模型 / 组件 / 状态 / FFI 桥)
apps/macos/    macOS 菜单栏薄壳 + 打包(.dmg)   — 自绘 Swift NSStatusItem runner
apps/windows/  Windows 托盘薄壳 + 打包(.zip)   — tray_manager
DESIGN.md      总体设计:选型 · 架构 · Provider 抽象 · 里程碑
```

> **复用边界**:`core/` + `ui/` 跨平台 100% 复用;`apps/<platform>/` 只是各自的薄外壳(托盘 / 窗口 / 打包)。

**技术栈**:Go 核心 ↔ Flutter UI 经 `dart:ffi`,菜单栏掺一点原生 Swift。主要 Flutter 插件:`window_manager`、`flutter_acrylic`、`screen_retriever`、`tray_manager`(Windows)、`url_launcher`、`local_notifier`、`shared_preferences`、`system_theme`、`win32_registry`(Windows)。

---

## 安装

从 [**Releases**](https://github.com/lureiny/quota-pulse/releases) 下载最新构建:

- **macOS** — `quota_pulse.dmg`,拖进 Applications。它是 ad-hoc 签名(无付费 Apple 账号),首次启动**右键 → 打开**以绕过 Gatekeeper。
- **Windows** — `quota_pulse-windows.zip`,解压到任意位置运行 `quota_pulse.exe`。绿色免安装。SmartScreen 首次可能告警 → **更多信息 → 仍要运行**。

然后打开**设置**,添加一个 sub2api 实例(它的 **Base URL** + 一个**管理员 API key**),点**保存并连接**。

---

## 从源码构建

需要 **Flutter SDK**(≥ 3.4)与 **Go 1.25**(`modernc.org/sqlite` 要求)。每个平台需在各自的 OS 上构建。

**macOS** → `.dmg`
```bash
cd apps/macos
./setup_macos.sh     # 一次性:生成 runner、打补丁、设置部署目标
./build_app.sh       # 编译 libqp.dylib(universal)+ .app,ad-hoc 签名,打 .dmg
```

**Windows** → 绿色 `.zip`(PowerShell)
```powershell
cd apps\windows
./setup_windows.ps1  # 一次性:生成 runner、pub get
./build_app.ps1      # 编译 libqp.dll(mingw-w64)、.exe,再打包整个文件夹
```

**Go 核心**(任意 OS 可验证)
```bash
cd core
go build ./... && go vet ./... && go test ./...
```

详见 [`apps/macos/SETUP.md`](apps/macos/SETUP.md)、[`apps/windows/SETUP.md`](apps/windows/SETUP.md) 与 [`core/README.md`](core/README.md)。

---

## 字体

**Windows** 端打包内嵌 [MiSans](https://hyperos.mi.com/font/download)(小米,免费商用):系统中文字体缺 Medium/Semibold,会把 `w500/w600` 就近吸附成 Regular/Bold、字重忽粗忽细,内嵌 MiSans 修正。**macOS** 用系统 **SF Pro**(字重本就齐全,也不增体积)。MiSans 版权归小米所有,许可见 [`ui/lib/fonts/MiSans-LICENSE.txt`](ui/lib/fonts/MiSans-LICENSE.txt)。

---

## 状态

macOS / Windows 均由 CI 出包(`.dmg` / `.zip`)。目前实现 sub2api provider。设计理念与里程碑见 [DESIGN.md](DESIGN.md)。
