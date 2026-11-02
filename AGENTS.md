# AGENTS.md

> 面向 AI 编码代理的仓库指南。假设读者对本项目一无所知。
> 设计与里程碑细节见 `DESIGN.md`(中文);包级说明见 `core/README.md`;sub2api 服务端缓存机制见 `docs/sub2api-usage-cache.md`。

## 项目简介

**quota-pulse** 是一个跨平台的 macOS 菜单栏 / Windows 系统托盘应用,用于一眼查看
[sub2api](https://github.com/Wei-Shaw/sub2api) 账户的用量窗口(Claude 5h / 7d / 7d-Sonnet、
Gemini 日 / 分钟配额等),不用开浏览器。应用是**纯只读**的——绝不修改上游任何数据。

三层架构,**复用边界是本仓库最重要的结构约束**:

| 目录 | 职责 | 复用 |
|---|---|---|
| `core/` | 平台无关 **Go** 引擎:provider 抽象、轮询、缓存、SQLite 用量存储、配置、C-ABI/gomobile 桥 | 100% 共享 |
| `ui/` | 共享 **Flutter** 包 `package:quota_pulse_ui`(`publish_to: none`):模型 / 组件 / 页面 / 状态 / `dart:ffi` 桥 | 100% 共享 |
| `apps/macos/` | macOS 薄壳:自管 Swift `NSStatusItem` 菜单栏(固定图标 + 像素级滚动文本)、无边框弹层、打包 .dmg | 仅壳 |
| `apps/windows/` | Windows 薄壳:`tray_manager` 托盘、Direct2D 原生悬浮窗、打包便携 .zip | 仅壳 |
| `integrations/claude-code/` | 独立的 Claude Code 状态栏脚本(bash + curl + jq,直连 sub2api 单账号,与主应用代码无关) | 独立 |
| `docs/` | 设计文档与博客 | — |

**新增一个 provider** = 新建 `core/providers/<name>/` 包 + 在 `core/app/facade.go` 加一行 blank import,
UI 与外壳零改动。**新增一个平台** = 新建 `apps/<platform>/` 薄壳 + 原生库构建脚本。改代码时务必放在边界的正确一侧。

## 技术栈

- **Go 1.25**(硬性要求:`core/go.mod` 为 `go 1.25.0`,由唯一直接依赖 `modernc.org/sqlite v1.52.0` 的 go.mod 下限强制;不要降低 `go` 指令,`go mod tidy` 会重新升回去)。
- **Flutter SDK ≥ 3.4**(`<4.0.0`),Dart 与 Flutter 桌面(macOS / Windows)。
- Go 核心编译为 C 共享库(`libqp.dylib` / `.dll` / `.so`),Dart 经 `dart:ffi` 调用;另有 gomobile 绑定预留给未来 iOS/Android。
- 关键 Flutter 插件:`window_manager`、`flutter_acrylic`、`screen_retriever`、`tray_manager`(仅 Windows)、`url_launcher`、`local_notifier`、`shared_preferences`、`system_theme`、`win32_registry`(仅 Windows)、`fl_chart`。
- SQLite 用纯 Go 的 `modernc.org/sqlite`(**无 cgo**),`SetMaxOpenConns(1)` + WAL 串行化写入。
- Windows 构建内嵌 MiSans 字体(雅黑缺 Medium/Semibold 字重);macOS 用系统 SF Pro。MiSans 版权属小米,许可证在 `ui/lib/fonts/MiSans-LICENSE.txt`。

## 构建与测试命令

### Go 核心(任意 OS 可验证,无需 C 工具链)

```bash
cd core
go build ./... && go vet ./... && go test ./...   # 完整检查;改完 Go 代码、打 tag 前必跑
go test ./poller/ -run TestName -v                 # 跑单个测试(任意包同理)
go run ./cmd/qpctl -config config.example.json -once  # 真实轮询一轮,stdout 打快照 JSON(需先 export SUB2API_ADMIN_API_KEY)
```

### Flutter 共享包(`ui/` 只被依赖,不直接运行)

```bash
cd ui && flutter pub get && flutter analyze        # dart format lib 格式化
```

### 原生库 libqp(Go 核心 → C 共享库,供 dart:ffi)

```bash
# capi.go 由 qpcgo build tag 守护(需 cgo);无 tag 时 cmd/libqp 是空 stub,保证 go build/vet ./... 常绿
go build -tags qpcgo -buildmode=c-shared -o libqp.dylib ./core/cmd/libqp   # macOS
go build -tags qpcgo -buildmode=c-shared -o libqp.so    ./core/cmd/libqp   # Linux
go build -tags qpcgo -buildmode=c-shared -o libqp.dll   ./core/cmd/libqp   # Windows(需 mingw-w64 gcc)
go build -tags qpcgo -buildmode=c-archive -o libqp.a    ./core/cmd/libqp   # iOS(静态库)
```

### 各平台应用构建(必须在目标 OS 上构建)

```bash
# macOS → .app/.dmg
cd apps/macos && ./setup_macos.sh   # 一次性:生成 gitignore 的 macos/ runner 并套 runner_patches
cd apps/macos && ./build_app.sh     # 通用 dylib → flutter build → 注入 .app + ad-hoc 签名 → dist/*.dmg
flutter run -d macos                # 本地调试(需先 setup)

# Windows → 便携 .zip(PowerShell)
cd apps\windows; ./setup_windows.ps1  # 一次性:生成 windows/ runner 并注入原生悬浮窗补丁
cd apps\windows; ./build_app.ps1      # libqp.dll(mingw-w64)→ flutter build → dist/*.zip
flutter run -d windows
```

注意:生成的 Flutter runner(`apps/macos/macos/`、`apps/windows/windows/`)被 **gitignore**,全新克隆里不存在;
`runner_patches/` 才是事实来源,`setup_*` 脚本把它覆盖到生成的 runner 上;`build_app.*` 在没跑过 setup 时会中止。
版本号在构建期经 `--dart-define=QP_VERSION` 注入(取自 `git describe` 或 `$QP_VERSION`,见 `ui/lib/src/version.dart`)。

## 架构要点

### FFI/JSON 边界(Dart ↔ Go)

非标量数据**全部以 JSON 字符串**跨边界——没有共享 FFI 结构体,连 C-ABI 入参也是 JSON(所以每个 C 签名只有 `char*`/`int`)。一次读取的链路:

```
Widget → PulseController → PulseSource(抽象) → FfiPulseSource → NativeCore(dart:ffi)
  → QP_*(char*) → C.GoString → json.Unmarshal → app.App 门面 → poller/usage 存储
  → json.Marshal → C.CString → Dart toDartString() → QP_Free
```

- **`core/app/facade.go` 是宿主唯一接触的 Go 类型**。三个薄适配器包它:C-ABI(`core/cmd/libqp/capi.go`,16 个 `QP_*` 导出:`QP_Init/Start/Stop/SnapshotJSON/ChartSeries/ChartDailySeries/Coverage/EnsureCoverage/Refresh/SetForeground/SetOnBattery/SetAsleep/DebugSet/DebugReport/DebugReset/Free`)、gomobile 桥(`core/bridge/mobile.go`)、`qpctl` CLI。
- **两种投递模型**:桌面端**拉**(定时调 `QP_SnapshotJSON`,C-ABI 无回调);移动端**推**(gomobile `Delegate.OnSnapshot`)。
- **FFI 内存所有权是双分配器契约**(`ui/lib/src/bridge/native_core.dart`):Dart 传入的字符串由 Dart 分配 → 用 `malloc.free` 释放;Go 返回的字符串是 `C.CString` → 用 `QP_Free` 释放。混用会堆损坏。新增任何返回 `char*` 的导出都要遵守同样纪律。
- 返回哨兵有语义:`''`/null 指针 = 错误(→ `ChartData.failed`);`'[]'` = 真的为空。不要合并这两种情况。

### 两条独立的数据面

1. **滚动窗口快照**(5h/7d 仪表):`poller` 抓取每个账户 → 写入 `poller.Store`(内存 map,键为 `instance|accountID`)→ 每轮结束调 `onUpdate(Snapshot())`。Dart 侧 `PulseController` 是 `ChangeNotifier`,每 ~2s 拉一次 `QP_SnapshotJSON` 仅为渲染;**真正的网络节奏在 Go poller 里**(passive 缓存读默认 60s,可配;active 回源默认关)。
2. **用量事件存储**(小时堆叠图 + GitHub 式热力图):`core/usage/store.go` 是纯 Go SQLite 原始事件库,摄取 `/admin/usage` 事件,跨重启增量同步,按小时/天多维聚合。**按需读取**(`QP_ChartSeries` 等),不走 2s 循环。

两者正交:5h/7d 窗口是 `model.AccountPulse` 里的 `model.Meter{Kind: rolling_window}` 快照;图表是聚合的 `usage_events`。互不推导。

### Provider 抽象(`core/provider` + `core/providers/sub2api`)

`Provider` 是极简接口(`Type`/`DisplayName`/`ListAccounts`/`FetchUsage`/`Capabilities`)。可选能力全是**独立接口、靠类型断言发现**:`LabelSetter`、`UsageLogFetcher`(图表事件摄取)、`EarliestFetcher`(热力图历史下限)。provider 只实现它能实现的,不支持的功能静默降级。

共享传输层(`transport.go`)统一处理鉴权(`AuthScheme{Header, Prefix, Token, Extra}`)、可选出站代理(`ProviderConfig.Proxy`:http/https/socks5,`socks5h` 归一为 socks5,可带 `user:pass@`,支持 `${ENV}`;空=直连不读环境变量,`NewClient` 校验失败即报错)与 ETag/`If-None-Match` **304** 条件 GET(含冷启动 304 强制重取)。

**新增 provider(如 one-api / new-api)只动两处包外代码**:
1. 新建 `core/providers/<name>/`:`client.go`(含 `AuthScheme`)+ `mapper.go`(原生 DTO → `model.AccountPulse`/`[]Meter`);`init()` 调 `provider.Register("<name>", New)`。
2. `core/app/facade.go` 加一行 blank import `_ "…/core/providers/<name>"`。**漏了它 `init()` 不会执行,`Build()` 报 "unknown provider type"。**

`Type()` 字符串必须同时等于 `Register` 键和配置 JSON 里的 `cfg.Type`。累计配额型 provider 发 `Meter{Kind: cumulative, Used, Limit}`(无 `ResetsAt`),UI 经 `Capabilities` 自适应。**绝不把明文 API key 放进 DTO 或事件 Dims。**

### 设置与配置

设置持久化为 `SharedPreferences['qp.settings']` 下的**单个 JSON blob**(`ui/lib/src/state/settings_store.dart` 的 `SettingsStore`),带旧版单实例配置的自动迁移。`Settings` 是不可变值对象(`copyWith`),**不是** `ChangeNotifier`。

两个成本天差地别的 JSON 出口:
- `toJson()` → prefs(便宜,每次 UI 微调都走)。
- `toConfigJson()` → `QP_Init` → **重启 Go 核心**。只含 providers + 固定 chart 块。**纯 UI 字段(主题/布局/托盘/图表视图/重置模式)不要放进去**,否则每次微调都触发核心重启 + 全量用量重取。`chart.range_hours` 钉死为 `kChartFetchHours`(168),UI 端裁剪;`chart.keep_all=true` 让本地 SQLite 只增不减(热力图要全历史)。

## 代码风格与提交约定

- **提交信息用中文**,Conventional Commits 带 scope:`fix(ui):`、`refactor(sync):`、`feat(chart):`、`perf(chart):` 等。与周围历史保持一致。
- 代码注释、文档以中文为主(本仓库注释与文档的主要语言)。
- Go:gofmt 标准风格,`go vet` 必须干净。
- Dart:`dart format lib` 格式化,`flutter analyze` 必须干净(dev 依赖 `flutter_lints`)。
- 告警/托盘窗口集合的权威定义是 `settings_store.dart` 里的 `kAlertWindows`(当前为 `five_hour`/`seven_day`,与 core mapper 的 meter id 一致)——改这一处,筛选芯片、托盘文本、告警器全部跟随。
- 冷启动首次拉取叫「**初始化**」,不叫「播种/seed」。
- 设置页 tab:实例 / 显示 / 托盘 / 通知 / 高级;平台专属块按 `theme.platform` 渲染(macOS 菜单栏滚动条 vs Windows 悬浮窗 + MiSans 署名)。

## 测试策略

- **仓库里所有自动化测试都是 Go 测试**(`core/` 下 11 个 `*_test.go`,覆盖 app/config/netstat/poller/provider/providers/sub2api/usage)。
- **`ui/` 与 `apps/` 下没有任何 `*_test.dart`**——不要去找 Dart 测试目标,也不要新设 Dart 测试基建,除非用户明确要求。
- 验证标准:`cd core && go build ./... && go vet ./... && go test ./...` 全绿(本机已验证通过)。
- 改跨边界行为(FFI、快照 JSON 形状、配置 JSON)时,桌面两端都要过一遍构建脚本。

## 关键不变量(容易踩的坑)

- **`poller.Store` 的键必须保持 `instance|accountID`。** 去掉实例前缀会把不同 sub2api 实例里同编号的账户静默合并。Dart 侧实例名去重(`_uniqueInstances`)必须与 Go 门面去重完全一致——显示名是与 `pulse.instance` 的 join 键。
- **抗回退缓存守卫**(`Store.Put`):仅当入站 pulse 满足 `len(Meters)==0 && Error=="" && Status==StatusOK && 已有条目有 Meters` 时才跳过。这挡住 passive「冷」空读把好好的数据闪成空白。放宽它会压制真实的 banned/error 状态迁移;两个方向都在 `core/poller/cache_test.go` 里有测试。
- **启动强制抓取**:`loop()` 启动时总是做一次 `Fresh=true` 抓取,与主动刷新开关(默认关)无关,保证多账户实例首屏即完整。不要把它挂到 active 设置上(这个回归修过一次)。
- **出错绝不覆盖 last-good 数据。** `FetchUsage`/`ListAccounts` 失败提前返回,保留上一快照。
- **图表同步水位线**(`core/usage` + `poller` 流):只有增量流的第一个 pulse 同时写 `last_id` 和覆盖水位线 W;稳态增量路径不得碰 W。`schemaVersion = 4`(镜像到 `PRAGMA user_version`),迁移逻辑在 `core/usage/store.go`。
- **`qpcgo` build tag 是承重的。** `capi.go` 只在 `-tags qpcgo` 下编译;无 tag 时空 `main()` stub 保证无 C 工具链时 `go build/vet ./...` 常绿。
- **macOS 故意不做沙箱**(两份 entitlements 里 `app-sandbox=false`),这样 `autostart.dart` 才能写 `~/Library/LaunchAgents`。不要重新加回 `app-sandbox`。
- **Windows 编 `libqp.dll` 需要 mingw-w64 gcc**(Go c-shared 需要外部编译器;MSVC 只编 Flutter runner)。两个工具链并存,DLL 只要与 `quota_pulse.exe` 同目录即可。

## 安全注意事项

- 应用对上游**纯只读**:只发 GET,绝不调用任何会修改 sub2api 状态的接口。新增 provider 方法时保持这一性质。
- API key 只经 `x-api-key` 头传输;**不得**把明文 key 写进日志、DTO、事件 Dims、测试夹具或文档示例(示例一律用 `${ENV}` 占位,见 `core/config.example.json`)。
- macOS 非沙箱 + 用户级 LaunchAgent 是刻意的最小权限设计:不装 Daemon、不做脚本注入/系统 hook、崩溃不自重启。
- `integrations/claude-code/` 的安全纪律:**admin key 绝不经过任何 AI agent**——key 只由用户本人在独立终端写入 600 权限的 `statusline.env`,不进 `settings.json`、不进仓库、不粘进对话。改该目录下的安装引导时必须保留这一流程。

## CI 与发布流程

唯一工作流:`.github/workflows/release-desktop.yml`。
- 两个手写构建 job(`build-macos` 跑在 `macos-14`,`build-windows` 跑在 `windows-latest`,均 `setup-go` 1.25)+ 一个 gated `release` job。
- **`workflow_dispatch` = 只验证**(构建两端构件,不建 Release);**推 `v*` tag = 发布**(release job 由 `refs/tags/` 门控)。
- 流程即「先 dispatch 验证,再打 tag 发布」:`gh workflow run release-desktop.yml`,然后 `git tag v0.x.0 && git push origin v0.x.0`。
- 产物:macOS `quota_pulse.dmg`(ad-hoc 签名,首次右键→打开);Windows `quota_pulse-windows.zip`(便携,首次 SmartScreen 选「仍要运行」)。
