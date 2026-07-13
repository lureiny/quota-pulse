# quota-pulse 设计方案

> 状态说明:本文保留最初选型与演进 rationale；当前已实现 macOS + Windows、SQLite 图表/热力图和原生 ticker。
> 现行维护结论与遗留风险见 [`docs/code-review-2026-07.md`](docs/code-review-2026-07.md)，具体代码不变量以 `AGENTS.md` 与测试为准。

> 一个跨平台的"用量脉搏"预览栏:在 macOS 菜单栏 / Windows·Linux 托盘 / iOS·Android 上,
> 快速查看 sub2api(以及未来 one-api / new-api 等)各账户的用量窗口。
> **第一版只做 macOS,只读展示,不做任何操作。**

本文档分为三部分回答你的三个要求:
1. 选型(语言 + 跨平台框架),并附上"原生 vs 跨平台"的实测结论(回答你的 Q3/Q4)。
2. 项目目录结构(把多平台通用部分抽出来)。
3. 接口抽象(Provider 抽象 + 通用数据模型),让未来接 one-api / new-api 几乎零改动。

---

## 0. 已确认的 sub2api 接口事实(设计的地基)

这些是直接从 sub2api 源码反查出来的,不是猜的:

| 项 | 结论 |
|---|---|
| 鉴权 | HTTP header `x-api-key`,base url 来自 `SUB2API_BASE_URL` |
| 统一信封 | `{ code, message, data }`;列表为 `data: { items, total, page, page_size, pages }` |
| 账户列表 | `GET /api/v1/admin/accounts?page=&page_size=&platform=&type=&status=&search=&sort_by=`,**支持 ETag / If-None-Match → 304**(轮询省流量的关键) |
| 用量接口 | `GET /api/v1/admin/accounts/:id/usage?source=active\|passive&force=true` |
| 用量返回 | `data` 是 `UsageInfo`,核心是**一组"用量窗口"对象** |

`UsageInfo` 的关键结构(决定了我们的抽象):

```
UsageInfo {
  source, updated_at
  // 每个都是 UsageProgress,可能为 null(不同平台返回不同窗口集合)
  five_hour          // Claude 5 小时滚动窗口
  seven_day          // Claude 7 天滚动窗口
  seven_day_sonnet   // Claude 7 天 Sonnet 窗口
  gemini_shared_daily / gemini_pro_daily / gemini_flash_daily      // Gemini 日配额
  gemini_shared_minute / gemini_pro_minute / gemini_flash_minute   // Gemini RPM
  antigravity_quota  // map[model]→quota
  subscription_tier  // FREE/PRO/ULTRA/UNKNOWN
  is_forbidden / needs_reauth / is_banned / forbidden_type / validation_url
  ai_credits[]
  error
}

UsageProgress {
  utilization        // 使用率 %(0~100+)
  resets_at          // 重置时间
  remaining_seconds  // 距重置剩余秒数
  window_stats { requests, tokens, cost, standard_cost, user_cost }
  used_requests, limit_requests
}
```

**最重要的观察**:sub2api 的用量本质是"**一组带重置时间的滚动窗口(rolling window)**"。
而 one-api / new-api 的用量本质是"**累计配额计数器(cumulative quota:已用 vs 总额)**,基本没有滚动重置"。
我们的抽象必须同时容纳这两种模型 —— 这正是第 6 节 `Meter.kind` 要解决的核心问题。

`source` 参数是省资源的核心开关:`passive` = 读缓存不打上游(便宜),`active`/`force=true` = 可能回源(贵)。

---

## 1. 选型:Go 核心 + Flutter UI(主推),Compose Multiplatform 备选

### 1.1 结论先行

- **语言/核心**:用 **Go** 写平台无关的核心(provider 抽象、轮询、缓存、数据模型)。
  贴合你的技术栈,HTTP/并发是 Go 的强项,且可以一份核心喂给所有平台。
- **UI/外壳**:用 **Flutter(Dart)** 写一份 UI,覆盖 macOS/Windows/Linux/iOS/Android 五端。
- 你"不懂前端"这条:**Dart + Flutter 是对后端开发最友好的 UI 上手路径**(强类型、声明式、文档好、热重载),
  比学 Web(HTML/CSS/JS,Tauri/Wails 路线)或同时学 Swift+Kotlin(纯原生路线)负担小得多。

> **为什么不是 Tauri / Wails?** 两者 UI 层都是 Web 前端(HTML/CSS/JS),对"不懂前端"的你是**最不友好**的;
> 且 Tauri 移动端是 WebView,iOS 上还有 App Store 4.2 被拒风险。直接出局。

> **为什么不是纯原生(Go 核心 + 各端原生 UI)?** 见 1.4,UI 复用率≈0,要你同时学 Swift/SwiftUI + Kotlin/Compose +
> Windows/Linux 托盘,对单人 + 不懂前端是灾难级维护负担。它只在"极致原生手感"是硬需求时才值得。

### 1.2 直接回答你的 Q3/Q4:原生 vs 跨平台,性能差异大吗?会不会影响系统稳定性?

**对"小而几乎全程空闲的菜单栏轮询应用"这一类,差距真实但不大,且唯一真正要在意的维度是"空闲 CPU/耗电",不是内存。** 调研到的实测数据:

| 维度 | 原生(Swift/SwiftUI 菜单栏) | Flutter 桌面 | Tauri(参考) | Electron(反面参考) |
|---|---|---|---|---|
| 空闲内存 | ~12–40 MB | ~40–90 MB | ~30–50 MB | ~150–300 MB |
| 冷启动 | 最快(无 VM) | ~1.8s | ~1.4s | ~3.2s |
| 渲染(小进度条) | 60fps 轻松 | 60fps(Impeller,<3ms/帧) | 60fps | 16–17ms/帧 |
| **空闲 CPU/耗电** | **≈0%(NSTimer)** | **历史上有"每帧重绘税"~6–10% CPU(macOS),个别 Linux 更高** | 接近原生(静态 WebView 不重绘) | 高 |

要点解读:
- **内存**:Flutter 比原生多 ~30–60 MB,对任何现代机器是零头,**不是决策因素**。
- **启动/渲染**:对一个开机登录就常驻、只画几根进度条的应用,**完全无所谓**。
- **唯一真正的痛点 = Flutter 历史上的"空闲重绘税"**(每个 vsync 都重绘,即使 UI 没变),
  对一个**常驻后台**的 agent 会持续吃 CPU/耗电。这是 Flutter 唯一实打实的短板。
  缓解手段见 1.3 的"架构性消除"。
- **系统稳定性**:**几乎不用担心。** 操作系统对每个进程做隔离(launchd/ReportCrash),
  你这个 app 不管用原生还是 Flutter/Tauri 崩了,都只崩它自己,**不会拖垮系统**。
  真正会"影响系统稳定性"的是:装 LaunchDaemon、脚本注入、系统级 hook、崩溃自重启风暴 —— 我们的设计**一律不碰**(纯只读、用户级 LaunchAgent、随时可退)。

**一句话**:对这个应用,原生 vs 跨平台的性能差距小到可以忽略,**唯一要主动处理的是 Flutter 的空闲重绘**,而下面的架构正好天然把它消掉。

### 1.3 关键架构决策:外壳常驻极简,重 UI 按需实例化

为了同时拿到"跨平台一份 UI 复用"和"原生级的空闲占用",采用**分层 + 按需**策略:

```
常驻部分(几乎零成本) = 原生托盘图标 + Go 核心(轮询/缓存)
重 UI 部分(只在你点开弹层时才渲染) = Flutter 视图
```

- 菜单栏/托盘图标本身由 Flutter 的 `tray_manager` 管理(跨平台一份),图标是静态的,不触发持续重绘。
- 弹层(popover)平时是隐藏的;**只有点开时 Flutter 视图才可见并渲染**,关闭即停。
  这样"空闲重绘税"在 99% 的时间里根本不发生 —— 这是把 Flutter 唯一短板架构性消除的关键。
- 真正常驻 24h 跑的是 **Go 核心的轮询**,这是 Go 的主场,效率高、可控。

### 1.4 主推 Flutter 的理由(对比备选 Compose Multiplatform)

| | **Flutter + Go(主推)** | Compose Multiplatform + Go(备选) | 纯原生 + Go(不推荐) |
|---|---|---|---|
| 五端覆盖 | 全部 Stable(最久经考验) | iOS 2025-05 才 Stable | 全部,但各写各的 |
| UI 复用率 | **一份 UI 全端** | 一份 UI 全端 | **≈0%** |
| Go 核心接入 | 桌面/iOS 走 `dart:ffi`,Android 走 gomobile AAR —— **有 Cwtch 生产级先例** | 桌面/移动走 JNI + gomobile,桥接配置更繁琐 | gomobile + cgo,各端各包一层 |
| 托盘/菜单栏 | `tray_manager`/`system_tray` + macOS 原生 `NSStatusItem` 配方成熟 | 桌面有内置 `Tray` composable(无需第三方) | 各端原生,Linux/Windows 托盘很折腾 |
| 对"不懂前端"的你 | Dart 上手最快、文档最好 | Kotlin 也友好,但 JNI 桥接更重 | 要学 Swift+Kotlin+Win/Linux UI,劝退 |
| 性能短板 | 空闲重绘税(已被 1.3 架构消除) | JVM 桌面内存/启动偏重 | 无(最优,但代价是工作量) |
| 风险 | tray 包仍在演进;iOS 必须 Mac 构建 | iOS 仅 ~1 年 Stable;JNI 配置复杂 | 维护 4–5 套 UI |

> **Cwtch** 是 Flutter UI + Go 核心(libCwtch-go,`dart:ffi` 桌面 + gomobile 安卓)在 Android/Win/Linux/macOS
> 四端发布的生产级实证 —— 我们的架构几乎是它的翻版,风险可控。

**什么时候改选 Compose Multiplatform?** 如果你强烈希望整个栈都留在"JVM/强类型服务端"心智里、
且想要桌面**内置** Tray(免第三方包演进风险),CMP 是同样合理的选择。其余结论(Go 核心 + 通用抽象)完全不变。

---

## 2. 总体架构(分层)

```
┌──────────────────────────────────────────────────────────────┐
│  apps/  各平台外壳(薄)                                          │
│  macOS 菜单栏 · Windows/Linux 托盘 · iOS/Android 前台页面         │
│  —— 只负责:托盘图标、弹层窗口、生命周期、把"开机自启/省电"接到系统 │
├──────────────────────────────────────────────────────────────┤
│  ui/  Flutter 共享 UI(一份)                                     │
│  PulseList · MeterBar(进度条) · AccountTile · Settings          │
│  —— 只消费"通用数据模型 AccountPulse / Meter",不认识任何具体平台   │
├──────────────────────────────────────────────────────────────┤
│  bridge/  跨语言桥(极薄,JSON over C-ABI / gomobile)             │
│  Dart FFI ↔ C ABI ↔ Go;事件用 delegate/回调上推                  │
├──────────────────────────────────────────────────────────────┤
│  core/  Go 平台无关核心(一份,喂给所有端)                          │
│  provider 抽象 · 通用模型 · 轮询引擎 · 缓存 · 配置 · 传输/鉴权       │
│  └─ providers/sub2api  (今天)                                    │
│  └─ providers/oneapi · providers/newapi  (未来,实现同一接口即可)   │
└──────────────────────────────────────────────────────────────┘
```

**通用部分 = `core/`(Go)+ `ui/`(Flutter)+ `bridge/`**。
**平台特定部分 = `apps/<platform>/`**,且尽量只剩"托盘 + 窗口 + 系统集成"这点东西。

桥接的三条编译路径(Cwtch 验证过):
- 桌面(mac/win/linux):`go build -buildmode=c-shared` → `.dylib/.so/.dll`,Dart `dart:ffi` 直接调。
- iOS:`go build -buildmode=c-archive` → 打包成 `.xcframework`(iOS 不让加载任意动态库,必须静态),Dart `ffi` 调。
- Android:`gomobile bind -target android` → `.aar`,经 `MethodChannel` 调(或纯 FFI `.so`)。

桥接面**故意做窄**:只暴露少量 C 函数,**全部以 JSON 字符串收发**(规避 gomobile 不支持 map/struct 切片/裸回调的限制),Go→UI 的事件走"接口/delegate"模式上推。

---

## 3. 项目目录结构

> 下面是**目标全平台结构**(最终形态)。**v1 实际落地有出入**(单平台务实简化,以 §7 为准):
> ① 共享 UI **已抽到 `ui/` 包**(`package:quota_pulse_ui`,`lib/src/` + barrel),`apps/macos` 经 path 依赖、仅剩 `main.dart`;② C-ABI 在 `core/cmd/libqp/capi.go` 而非 `core/bridge/capi.go`
> (`core/bridge/` 只放 gomobile 的 `mobile.go`);③ 构建脚本是
> `apps/macos/{setup_macos,build_app,build_macos_dylib}.sh` 而非 `build/build_core_*.sh`;
> ④ macOS 走纯 Flutter + `tray_manager`,无 `Runner/StatusBarController.swift`。

```
quota-pulse/
├── core/                          # ★ 通用核心(Go module),平台无关
│   ├── go.mod
│   ├── model/                     # 通用数据模型(provider 无关)
│   │   ├── account.go             #   Account
│   │   ├── pulse.go               #   AccountPulse / Status
│   │   └── meter.go               #   Meter / MeterKind / Unit
│   ├── provider/                  # ★ 抽象接口(第 6 节核心)
│   │   ├── provider.go            #   type Provider interface + Capabilities
│   │   ├── registry.go            #   provider 注册表(按 type 创建实例)
│   │   └── transport.go           #   HTTP 客户端 + AuthScheme(可配 header)
│   ├── providers/                 # 各 provider 实现 + 映射器
│   │   ├── sub2api/
│   │   │   ├── client.go          #   调 /admin/accounts、/usage
│   │   │   ├── types.go           #   贴源码的 UsageInfo/UsageProgress DTO
│   │   │   └── mapper.go          #   UsageInfo → []Meter / AccountPulse
│   │   ├── oneapi/                #   (未来) 同样三件套
│   │   └── newapi/                #   (未来)
│   ├── poller/                    # 轮询引擎(自适应间隔/并发/退避/ETag)
│   │   ├── poller.go
│   │   ├── schedule.go            #   省电:弹层关/休眠/电池时降频或暂停
│   │   └── cache.go               #   内存缓存 + 条件请求(If-None-Match)
│   ├── config/                    # 配置(多 provider 实例、账户筛选、间隔)
│   │   └── config.go
│   ├── app/                       # 核心门面:UI 只跟它打交道
│   │   └── facade.go              #   Start/Stop/Snapshot/Refresh/Subscribe
│   └── bridge/                    # 导出给桥接层的 C-ABI / gomobile 入口
│       ├── capi.go                #   //export QP_Start / QP_Snapshot ...(c-shared/archive)
│       └── mobile.go              #   gomobile 友好的接口(delegate 回调)
│
├── ui/                            # ★ 通用 UI(Flutter,一份覆盖五端)
│   ├── pubspec.yaml
│   └── lib/
│       ├── bridge/                #   Dart FFI 绑定 + 平台通道封装
│       │   └── qp_bridge.dart     #   把 JSON ↔ Dart 模型,屏蔽各端差异
│       ├── models/                #   AccountPulse/Meter 的 Dart 镜像(从 JSON 反序列化)
│       ├── widgets/
│       │   ├── meter_bar.dart     #   单个 Meter 的进度条(滚动窗口/累计配额统一渲染)
│       │   ├── account_tile.dart  #   一个账户一行
│       │   └── pulse_list.dart    #   列表 + 状态色(OK/告警/限流/封禁)
│       ├── pages/
│       │   ├── popover_page.dart  #   桌面弹层主体
│       │   ├── mobile_home.dart   #   移动端主页面
│       │   └── settings_page.dart #   配置 provider/base_url/key/间隔
│       └── app.dart
│
├── apps/                          # 各平台外壳(薄;只做托盘+窗口+系统集成)
│   ├── macos/                     # ★ 第一版只做这个
│   │   ├── Runner/                #   LSUIElement=YES(无 Dock)、NSStatusItem 宿主
│   │   ├── StatusBarController.swift  # NSStatusItem + NSPopover,挂 FlutterViewController
│   │   └── Info.plist
│   │   # 也可纯 Flutter 用 tray_manager,省去 Swift;见 §8
│   ├── windows/                   # (后续) tray_manager
│   ├── linux/                     # (后续) tray_manager / SNI
│   ├── ios/                       # (后续) 前台页 + BGAppRefreshTask 尽力刷新
│   └── android/                   # (后续) 前台页 + 可选前台服务
│
├── build/                         # 构建脚本:编译 Go → 各 ABI 产物,拷进 ui/apps
│   ├── build_core_desktop.sh      #   c-shared → .dylib/.so/.dll
│   ├── build_core_ios.sh          #   c-archive → .xcframework(需 macOS+Xcode)
│   └── build_core_android.sh      #   gomobile bind → .aar
│
├── docs/
│   └── DESIGN.md                  # 本文件
└── README.md
```

复用边界一目了然:**`core/` + `ui/` + `bridge/` 是 100% 跨平台复用;`apps/<platform>/` 才是每端各写,而且被压到最薄。**

---

## 4. 通用数据模型(provider 无关)

UI 永远只认识下面这三个结构,**不认识 sub2api / one-api 任何字段**。这是"未来换平台 UI 零改动"的根。

```go
// core/model/meter.go
type MeterKind string
const (
    KindRollingWindow MeterKind = "rolling_window" // sub2api 5h/7d:有 resets_at
    KindCumulative    MeterKind = "cumulative"     // one-api/new-api:已用 vs 总额,通常无重置
    KindRate          MeterKind = "rate"           // RPM/TPM 之类的速率上限
)

type Unit string
const ( UnitPercent Unit="percent"; UnitRequests Unit="requests"
        UnitTokens Unit="tokens";   UnitUSD Unit="usd"; UnitCount Unit="count" )

// 一个"表盘":无论滚动窗口还是累计配额,UI 都渲染成一根进度条
type Meter struct {
    ID            string     `json:"id"`             // 稳定键:"five_hour"/"seven_day"/"quota"
    Label         string     `json:"label"`          // 展示名:"5h"/"7d"/"配额"
    Kind          MeterKind  `json:"kind"`
    Utilization   *float64   `json:"utilization"`    // 0.0~1.0+(归一化;未知为 nil)
    Used          *float64   `json:"used,omitempty"` // 绝对值(可选)
    Limit         *float64   `json:"limit,omitempty"`
    Unit          Unit       `json:"unit"`
    ResetsAt      *time.Time `json:"resets_at,omitempty"`      // 滚动/周期才有
    RemainingSecs *int64     `json:"remaining_secs,omitempty"`
    Detail        string     `json:"detail,omitempty"`         // "1.2M tokens · $3.4" 之类副标
}

// core/model/pulse.go
type Status string
const ( StatusOK Status="ok"; StatusWarning="warning"; StatusRateLimited="rate_limited"
        StatusForbidden="forbidden"; StatusNeedsReauth="needs_reauth"
        StatusBanned="banned"; StatusError="error" )

type AccountPulse struct {
    AccountID string    `json:"account_id"`
    Name      string    `json:"name"`
    Platform  string    `json:"platform"`           // 上游平台:claude/gemini/...
    Provider  string    `json:"provider"`           // 来源:sub2api/oneapi/newapi
    Status    Status    `json:"status"`
    Tier      string    `json:"tier,omitempty"`     // 订阅等级(若有)
    Meters    []Meter   `json:"meters"`             // ★ 一组表盘 —— 抽象的灵魂
    UpdatedAt time.Time `json:"updated_at"`
    Error     string    `json:"error,omitempty"`
    ActionURL string    `json:"action_url,omitempty"` // 如 validation_url(展示用,不执行)
}
```

**为什么这样能同时容纳两种模型**:
- sub2api 的 `five_hour`(滚动窗口)→ `Meter{Kind:rolling_window, Utilization:0.42, ResetsAt:..., RemainingSecs:...}`,UI 画进度条 + "2h13m 后重置"。
- one-api 的 token 配额(累计)→ `Meter{Kind:cumulative, Used:3.4, Limit:10, Unit:usd}`,UI 画同一根进度条 + "$3.4 / $10",**没有重置倒计时**。
- UI 的 `MeterBar` 只看 `Utilization` 画长度,看 `Kind`/`ResetsAt` 决定副标 —— **一套渲染逻辑通吃**。

---

## 5. 轮询 / 性能 / 稳定性设计(对应你的"高性能、不影响系统稳定性")

全部放在 Go 核心 `poller/`,这是 Go 的主场:

1. **便宜优先**:常规轮询一律用 `source=passive`(读 sub2api 缓存,不回源);
   只有用户手动点"刷新"或稀疏的定时(如每 5–10 分钟一次)才用 `source=active&force=true`。
2. **条件请求**:账户列表用 `If-None-Match`(sub2api 已支持 ETag → 304),命中就几乎零流量。
3. **连接复用**:单 `http.Client` + keep-alive + gzip;按账户并发但限流(如最多 4–6 并发)。
4. **自适应/省电**(`schedule.go`):
   - 弹层关闭 → 降频(如 60s);弹层打开 → 短时提频(如 10s)给"实时感"。
   - 桌面休眠 / 切到电池 → 进一步降频或暂停;唤醒/插电 → 立即拉一次再恢复。
   - 网络不可达 → 暂停 + 指数退避;限流(429)→ 退避并把账户标 `rate_limited`。
5. **不碰系统稳定性的红线**:用户级 **LaunchAgent**(不是 Daemon)、不做脚本注入/系统 hook、
   崩溃不自重启风暴、纯只读。OS 进程隔离 + 这些自律 ⇒ 不可能拖垮系统。
6. **移动端现实**:iOS **后台无法稳定 60s 轮询**(`BGAppRefreshTask` 是"尽力而为"、系统择机)。
   所以移动端定位为"**前台打开时实时拉取**" + 可选静默推送/后台尽力刷新,而不是常驻脉搏。
   这点要在产品预期上讲清楚(menubar 的"常驻脉搏"是桌面专属)。

---

## 6. ★ Provider 抽象(让未来接 one-api / new-api 几乎零改动)

这是第 3 个要求的核心。三层抽象:**统一传输/鉴权 → 统一接口 → 各自 mapper**。

### 6.1 接口

```go
// core/provider/provider.go
type Provider interface {
    Type() string                                   // "sub2api"/"oneapi"/"newapi"
    DisplayName() string

    // 列出该 provider 下的账户(sub2api=账户;one-api=token/channel)
    ListAccounts(ctx context.Context) ([]model.Account, error)

    // 拉单个账户用量,直接产出"通用模型"(各 provider 内部做 mapping)
    FetchUsage(ctx context.Context, accountID string, opt FetchOptions) (model.AccountPulse, error)

    // 能力声明:让 UI 自适应(比如累计配额型就不显示"重置倒计时")
    Capabilities() Capabilities
}

type FetchOptions struct {
    Fresh bool // false=便宜(passive/缓存);true=回源(active/force)
}

type Capabilities struct {
    HasRollingWindows bool // sub2api=true;one-api=false
    HasCumulativeQuota bool // one-api=true
    SupportsConditionalGet bool // sub2api 列表=true
    DefaultMeterIDs []string // UI 默认展示哪些表盘
}
```

### 6.2 统一传输 + 鉴权(各平台 header 不同,抽出来)

```go
// core/provider/transport.go
type AuthScheme struct {
    Header  string // sub2api:"x-api-key";one-api:"Authorization"
    Prefix  string // one-api:"Bearer ";sub2api:""
    Extra   map[string]string // new-api 还要 "New-Api-User":"<id>"
}

type Client struct {
    BaseURL string
    Auth    AuthScheme
    http    *http.Client // 复用 + ETag 缓存
}
```

### 6.3 各 provider 只做"原生响应 → 通用模型"的 mapper

**sub2api mapper(今天就能写,字段已确认)**:

```go
// core/providers/sub2api/mapper.go(示意)
func toPulse(acc Account, u UsageInfo) model.AccountPulse {
    var meters []model.Meter
    add := func(id, label string, p *UsageProgress) {
        if p == nil { return }
        util := p.Utilization / 100.0
        meters = append(meters, model.Meter{
            ID: id, Label: label, Kind: model.KindRollingWindow, Unit: model.UnitPercent,
            Utilization: &util, ResetsAt: p.ResetsAt, RemainingSecs: int64p(p.RemainingSeconds),
            Detail: fmtWindow(p.WindowStats), // "1.2M tok · $3.4"
        })
    }
    add("five_hour", "5h", u.FiveHour)
    add("seven_day", "7d", u.SevenDay)
    add("seven_day_sonnet", "7d Sonnet", u.SevenDaySonnet)
    add("gemini_pro_daily", "Pro/日", u.GeminiProDaily)
    // ... 其余 gemini / antigravity 同理
    return model.AccountPulse{
        AccountID: acc.ID, Name: acc.Name, Platform: acc.Platform, Provider: "sub2api",
        Tier: u.SubscriptionTier, Status: mapStatus(u), Meters: meters,
        UpdatedAt: deref(u.UpdatedAt), Error: u.Error, ActionURL: u.ValidationURL,
    }
}

func mapStatus(u UsageInfo) model.Status {
    switch {
    case u.IsBanned:    return model.StatusBanned
    case u.NeedsReauth: return model.StatusNeedsReauth
    case u.IsForbidden: return model.StatusForbidden
    // 任一窗口 util≥100 → rate_limited;≥80 → warning
    }
    return model.StatusOK
}
```

**one-api / new-api mapper(未来,基于其配额模型;字段名上线前需对其真实 API 校验)**:

- one-api(songquanpeng/one-api):配额是整数,`QuotaPerUnit` 默认 500000 = $1。
  - 列账户 ≈ 列 token:`GET /api/token/`(分页),字段 `remain_quota`/`used_quota`/`unlimited_quota`/`expired_time`/`name`/`status`。
  - 用户总额:`GET /api/user/self` → `quota`/`used_quota`/`request_count`。
  - 鉴权:Web 用 session cookie;程序化用 header `Authorization: <系统访问令牌>`。
- new-api(QuantumNous/new-api):同上,但**额外需要 header `New-Api-User: <id>`**,并有 dashboard 端点。
- 映射:`used_quota`/`(used+remain)` → `Meter{Kind:cumulative, Used, Limit, Unit:usd}`,**无 ResetsAt**;
  若有 RPM/TPM 限制 → 额外 `Meter{Kind:rate, Unit:count}`。
  `Capabilities{HasRollingWindows:false, HasCumulativeQuota:true}`,UI 自动不画重置倒计时。

> 因为 UI 只消费 `AccountPulse`/`Meter`,接一个新平台 = **写一个 client + 一个 mapper + 注册**,
> `ui/`、`apps/` 一行不用动。这就是要求 3 想要的扩展性。

### 6.4 配置(支持多 provider 实例并存)

```yaml
# 一个用户可以同时盯多个后台
providers:
  - type: sub2api
    name: "我的 sub2api"
    base_url: https://xxx
    api_key: ${SUB2API_ADMIN_API_KEY}
    accounts: { filter: { status: active } }   # 或显式 id 列表
    poll: { passive_interval: 60s, active_interval: 600s }
  - type: oneapi          # 未来
    name: "团队 one-api"
    base_url: https://yyy
    api_key: ${ONEAPI_TOKEN}
```

---

## 7. macOS 第一版落地(最终实现)

> 已选「省事路线」:Flutter + `tray_manager` + `window_manager` + `LSUIElement`,**无 Swift 业务代码**;
> 集成走**进程内 FFI**。v1 共享 UI 暂放 `apps/macos/lib/`(按可抽取结构组织,待第二平台再上移 `ui/`)。

**① Go 核心 → `libqp.dylib`**
- 包:`model` · `config` · `provider`(接口 + `AuthScheme`/带 ETag 的客户端 + 注册表) ·
  `providers/sub2api`(client / types / mapper) · `poller`(cache / schedule / poller) ·
  `app`(门面) · `bridge/mobile.go`(gomobile) · `cmd/libqp`(C-ABI) · `cmd/qpctl`(联调 CLI)。
- C-ABI 导出 9 个:`QP_Init/Start/Stop/SnapshotJSON/Refresh/SetForeground/SetOnBattery/SetAsleep/Free`
  (`core/cmd/libqp/capi.go`,`-tags qpcgo`)。
- 编库:`apps/macos/build_macos_dylib.sh`(`-buildmode=c-shared`,arm64+amd64 通用,`@rpath` install-name)。

**② Flutter:共享层 `ui/` 包 + macOS 薄壳 `apps/macos/`**
- 共享包 `ui/`(`package:quota_pulse_ui`,`lib/src/` + barrel `quota_pulse_ui.dart`),各 `apps/<platform>` 经 path 依赖:
  - `bridge/`:`native_core.dart`(dart:ffi 绑定 9 个 `QP_*`,**按平台选 dylib/dll/so**)· `pulse_source.dart`(可替换的抽象边界)· `ffi_pulse_source.dart`(FFI 实现)。
  - `models/pulse.dart`(`AccountPulse`/`Meter`)· `format.dart`(状态色/进度条色/时长/百分比)。
  - `state/`:`pulse_controller.dart`(每 2s 读快照、算峰值)· `settings_store.dart`(存 url/key、生成配置 JSON)。
  - `widgets/`:`meter_bar`·`account_tile`·`status_dot`;`pages/`:`popover_page`·`settings_page`。
- macOS 薄壳 `apps/macos/lib/main.dart`:`tray_manager` 菜单栏(图标 + 实时峰值% + 右键菜单)+
  `window_manager` 无边框弹层(失焦即收)+ 核心生命周期。资源 `assets/tray_icon.png`(模板图标)。

**③ 原生 Runner 补丁(脚本自动套,无需开 Xcode)→ `apps/macos/runner_patches/`**
- `AppDelegate.swift`(隐藏窗口不退出)· `Debug/Release.entitlements`(`network.client` 出站)· `Info.plist` 的 `LSUIElement`(去 Dock)。

**④ 一次性搭建 + 一键打包(见 §9 M2.5 / SETUP.md)**
- `setup_macos.sh`:生成 `macos/` runner + 套补丁 + `flutter pub get`。
- `build_app.sh`:`dylib → flutter build → 注入 .app/Contents/Frameworks → ad-hoc 签名 → .dmg`。

**数据流(进程内 FFI)**
```
Flutter UI ──每2s── QP_SnapshotJSON() ──dart:ffi──▶ libqp.dylib(Go core 自己轮询 sub2api)
设置保存   ── QP_Init(json)+QP_Start() ──▶ 同上
开/收弹层  ── QP_SetForeground(bool) ──▶ Go 调度器提频/降频(省电)
```

**验收**:菜单栏图标 → 点开弹层 → 各账户 5h/7d 进度条 + 重置倒计时 + 状态色;「刷新」强制回源;改 URL/Key 即时重连。

> **备选(未采用):macOS 原生壳** —— Swift `StatusBarController`(`NSStatusItem` + `NSPopover`)挂
> `FlutterViewController`,手感更原生、空闲更省;若 Flutter 空闲重绘成为问题再切换(见 §8 风险表)。
> 后续按 `windows → linux → ios → android` 增量加 `apps/<platform>/`,`core` 与 `lib/`(models/widgets/bridge 接口)基本不动。

---

## 8. 主要风险与缓解

| 风险 | 缓解 |
|---|---|
| Flutter 空闲重绘吃电 | 弹层关闭即不渲染(§1.3);用新版 Impeller;必要时桌面壳改原生 NSStatusItem |
| gomobile 类型受限(无 map/struct 切片/裸回调) | 桥接面**全程 JSON 字符串**,事件走 delegate 接口(Cwtch 同款) |
| iOS 必须 Mac + Xcode 构建、静态 xcframework | CI 用 mac runner;比照 `apps/macos/build_macos_dylib.sh`,固化 `c-archive`/xcframework 打包脚本 |
| `tray_manager` 仍在演进 / Linux(GNOME)托盘脆弱 | 桌面优先级 mac>win>linux;Linux 落地时再评估 SNI/原生壳 |
| one-api/new-api 字段与鉴权细节 | 上线前用真实实例校验端点/字段;抽象已用 `Capabilities` 预留差异 |
| iOS 后台无法常驻轮询 | 产品上明确"移动端=前台实时 + 尽力后台刷新",不承诺常驻脉搏 |

---

## 9. 里程碑

> 状态:✅ 已完成 · ◐ 部分 · ☐ 计划 · ⚠ 注意。截至 2026-06。

### M1 — macOS MVP(核心 + 菜单栏壳) ✅ 基本完成
- ✅ Go 核心:`model` / `provider`(接口 + `AuthScheme` + 带 ETag 的 HTTP 客户端 + 工厂注册表) /
  `poller`(快照存储 + 调度器) / `config` / `app` 门面 / `bridge`。`go build`·`go vet`·`go test` 全绿。
- ✅ sub2api provider:`client` + DTO `types` + `mapper`(`UsageInfo → []Meter`),状态归一
  (warning / rate_limited / forbidden / needs_reauth / banned)。
- ✅ 桥接:`core/cmd/libqp/capi.go` 的 C-ABI(9 个 `QP_*` 导出,`c-shared`/`c-archive` 均可编);
  `core/bridge/mobile.go` 的 gomobile 友好接口。
- ✅ macOS 壳(走"省事路线":Flutter + `tray_manager` + `window_manager` + `LSUIElement`,零 Swift 业务代码):
  菜单栏图标 + 实时峰值% → 弹层 → 5h/7d 进度条 + 重置倒计时 + 状态色;设置页填 `base_url`/`x-api-key`。
- ✅ 集成方式:**进程内 FFI**(已选定);Dart 侧 `PulseSource` 抽象,日后改"本地进程"方案不动 UI。
- ✅ 共享 UI **已抽到 `ui/` 包**(`package:quota_pulse_ui`,M3 前置提前完成):`apps/macos` 仅剩
  `main.dart` 薄壳,`native_core` 已按平台选 dylib/dll/so —— Windows/Linux 接入可直接复用。

### M2 — 体验与省电 ◐ 大部分已随 M1 落地
- ✅ ETag 条件请求(列表 304)、passive 优先 + 稀疏 active 回源、并发限流(≤6)。
- ✅ 状态色与告警阈值(≥80% warning、≥100% rate_limited)、设置页。
- ✅ 弹层开/合自适应提频/降频(`setForeground` 经 FFI 驱动 Go 调度器)。
- ◐ 电池/休眠/网络变化:`SetOnBattery`/`SetAsleep` 已在核心与 FFI 暴露,但 **macOS 壳尚未接
  系统电源/睡眠/网络事件**去调用——待补。
- ☐ 429 退避细化、错误态申诉链接(`action_url`)点击跳转。

### M2.5 — 一键打包与分发 ✅ 新增并完成
- ✅ `apps/macos/setup_macos.sh`:一次性生成 runner + 套补丁(PlistBuddy 写 `LSUIElement`),**全程免 Xcode**。
- ✅ `apps/macos/build_app.sh`:一键 `dylib → flutter build → 注入 .app/Contents/Frameworks →
  ad-hoc 签名 → .dmg`,**全程免 Xcode**。
- ✅ 多人分发(**无需 Apple 开发者账号**):ad-hoc 签名满足 Apple Silicon 运行要求;接收方首次"右键→打开"一次。
- ☐ **公证(notarize)**:要双击零提示需 Developer ID($99/年)+ `notarytool` + `stapler`——未来可选。
- ⚠ 这两个脚本为 macOS 专用,**尚未在实机跑通**(开发机为 Linux),首次执行以实际为准。

### M3 — Windows ◐ 代码完成(待 Windows 实机构建)· Linux ☐

> 因分层(通用核心 / 通用 UI / 薄外壳),Windows 增量主要落在「壳 + DLL 构建 + 打包」,功能本身白拿。
> `apps/windows/` 已写全(壳 + `.ico` + PowerShell 一键脚本 + 文档);仅差在 Windows 机器上跑 `build_app.ps1` 终验。

**✅ 前置重构(完成)**:共享 UI 已抽到 `ui/` 包(`package:quota_pulse_ui`,`lib/src/` + barrel);
`apps/macos`、`apps/windows` 均经 path 依赖、各自仅剩 `main.dart`;`native_core` 按平台选 dylib/dll/so。

**✅ 完全复用(0 改动,已落地)**
- 整个 Go 核心:`cmd/libqp/capi.go` **同一份源码**,Windows 上编出 `libqp.dll`(`-buildmode=c-shared` + mingw-w64)。
- Flutter 业务层全部来自 `ui/` 包(`models`/`format`/`widgets`/`pages`/`state`/`bridge`)。

**✅ 小改(已落地)**
- `ui/bridge/native_core.dart`:库名按平台选(`.dll`/`.dylib`/`.so`),Windows 从 exe 同级目录加载。
- `apps/windows/lib/main.dart`:弹层 `bottomRight`(托盘在右下)、`.ico` 图标、峰值走 `setToolTip`
  (Windows 托盘无标题)、`skipTaskbar` 去任务栏。

**✅ 新增(Windows 专属,已写好)**
- `setup_windows.ps1`(生成 Win32 runner;**Windows 不沙箱,无需 runner 补丁**)。
- `assets/tray_icon.ico`(彩色托盘图标)。
- `build_windows_dll.ps1`(mingw 编 `libqp.dll`)+ `build_app.ps1`(flutter build → 拷 dll 到 exe 同级 → 便携 zip)。

**☐ 待办**
- ⚠ 在 Windows 实机跑 `setup_windows.ps1` + `build_app.ps1` 终验(本机为 Linux,未编译过)。
- (可选)**Authenticode** 签名避开 **SmartScreen**(同 Gatekeeper 套路);MSIX/Inno 安装器;单实例 mutex;弹层精确贴托盘。

**比 macOS 反而更省**:Windows 不沙箱,**无需 entitlements**(`network.client`),出站 HTTP 直接通,且无需 runner 补丁。

**Linux ☐**(稍后):同样复用核心 + `ui/`;新增 `apps/linux` + `libqp.so` 构建;托盘走 `tray_manager`,
但 GNOME 无原生托盘(需 AppIndicator / StatusNotifier 扩展),落地时再评估。桌面优先级 mac > win > linux。

### M4 — iOS / Android ☐
- `gomobile bind` 接 `core/bridge`(AAR / xcframework);移动端定位"前台实时 + 尽力后台刷新"
  (iOS `BGAppRefreshTask` 不保证 60s 轮询,见 §5.6)。

### M5 — 接入 one-api / new-api ☐
- 新增 `core/providers/oneapi`·`newapi`(client + mapper,累计配额 → `Meter{Kind: cumulative}`);
  UI / 外壳零改动。上线前用真实实例校验端点/字段(见 §6.3)。

---

### 附:为什么这套抽象是对的(一句话总结)

> sub2api 把用量表达成"一组带重置时间的滚动窗口",one-api/new-api 把用量表达成"累计配额计数器"。
> 我们用 `Meter{Kind, Utilization, [ResetsAt], [Used/Limit]}` 把两者归一成"一根进度条 + 可选副标",
> UI 只认这个模型;于是**接新平台 = 写一个 mapper,UI/外壳零改动**。
