# sub2api 用量刷新 / 缓存机制

> 本文整理 **sub2api 服务端**([Wei-Shaw/sub2api](https://github.com/Wei-Shaw/sub2api))的「账户用量」是怎么产生、缓存、刷新的,用来指导 quota-pulse 的 `core/providers/sub2api/` 客户端实现。
>
> 这些是 sub2api 服务端的内部行为,**在 quota-pulse 代码里看不到 rationale**,但直接决定了我们能不能拿到数据、数据有多新。
>
> 依据:阅读 sub2api `main` 分支源码(2026-06,commit `e34ad2b` 附近)。**外部项目,行号/实现可能随版本变化**,引用行号仅供定位。

---

## 0. quota-pulse 是怎么调的

客户端(`core/providers/sub2api/client.go`)打两个 admin 接口(鉴权 header `x-api-key`):

```
GET /api/v1/admin/accounts                  # 列出账户(ETag/304)
GET /api/v1/admin/accounts/:id/usage?source=passive|active&force=true   # 取单账户用量
```

`ListAccounts` 与用量刷新无关、总能列出全部账户;真正决定「拿不拿得到用量」的是 `/usage` 的 **`source`** 与 **`force`** 两个参数。

服务端入口:`handler/admin/account_handler.go` 的 `GetUsage`
```go
source := c.DefaultQuery("source", "active")   // 默认 active
force  := c.Query("force") == "true"
if source == "passive" {
    usage, err = accountUsageService.GetPassiveUsage(ctx, accountID)
} else {                                         // 其余一律当 active
    usage, err = accountUsageService.GetUsage(ctx, accountID, force)
}
```

---

## 1. 别混淆:这里有两套完全不同的「缓存」

| 缓存 | 存储 | 内容 | 与 `/usage` 接口的关系 |
|---|---|---|---|
| `billing_cache`(`service/billing_cache_service.go`、`repository/billing_cache.go`) | **Redis** | 用户**计费额度**:余额 / 订阅 / RPM / user×platform quota | **无关**。这是计费/限流用的,不是 admin usage |
| 账户**用量被动数据** | **`accounts` 表的 `Extra` JSON 字段** + `SessionWindowEnd` 列 | 5h/7d 利用率与重置、采样时间戳等(键如 `session_window_utilization`、`passive_usage_7d_utilization`、`passive_usage_7d_reset`、`passive_usage_sampled_at`、`codex_usage_*`) | **就是它**。`source=passive` 读的就是这份 Extra |

下面讲的「被动用量」全部指第二套(`accounts.Extra`)。

---

## 2. 三条读取路径:passive / active / force

- **`passive`** → `GetPassiveUsage`:**纯只读 `account.Extra`,绝不回源**。开头有硬门槛
  ```go
  if !account.IsAnthropicOAuthOrSetupToken() {  // Platform==Anthropic && Type∈{OAuth,SetupToken}
      return nil, fmt.Errorf("passive usage only supported for Anthropic OAuth/SetupToken accounts")
  }
  ```
  即 **passive 只支持 Anthropic 的 OAuth / SetupToken 账号**,其余平台/类型一律报错。
- **`active`** → `GetUsage(accountID, force)`:**按平台分支去现取**(回源上游、探测、或本地估算,见 §4),带进程内短缓存。
- **`force=true`**:**全局唯一真正起作用的地方是 OpenAI/Codex**(跳过 10min probe 节流)。对 Anthropic / Gemini / Antigravity **不起作用**(Anthropic active 只查它的 3min `apiCache`,从不读 force)。

---

## 3. 被动用量何时写入(是不是「每次请求都刷」)

被动数据**不是定时刷新,而是请求事件触发**——账户被真实调用、上游返回用量/限流信息时,gateway 把它写回 `account.Extra`。**只有 Anthropic 和 OpenAI/Codex 两类账号有被动采样**。

### Anthropic — 每次「带限流头的成功请求」都写,无节流
- 写入函数:`ratelimit_service.go` 的 `UpdateSessionWindow(account, resp.Header)`。
- 触发点:`gateway_service.go` 4 处(Claude OAuth 流/非流 + API-Key 透传 流/非流)。
- 条件:① 平台 Anthropic;② 响应**成功**(`<400`,4xx/5xx 在状态码闸门就被拦掉);③ 响应必须带 `anthropic-ratelimit-unified-5h-status` 头(没带头直接 `return`)。
- **没有任何时间节流/去抖**:满足条件就解析头、整条 `UpdateExtra` 写库;`passive_usage_sampled_at` 只是每次写入盖的时间戳,**从不被读取、不参与判断**。窗口重置时先把旧的被动字段清空再写新值。

### OpenAI / Codex — 每次成功 OAuth 转发采样,有 30s/账号节流
- 写入函数:`openai_gateway_service.go` 的 `updateCodexUsageSnapshot`(从响应头 `ParseCodexRateLimitHeaders` 取限流快照写 Extra)。
- 触发点:各转发路径成功后(chat_completions / messages / responses 流与非流)。
- 节流:`openAICodexSnapshotPersistMinInterval = 30s`(每账号),**异步**写库。

### 一句话
> **被动用量 = 该账户「每次被真实调用」时跟着刷**(Anthropic 无节流、Codex 30s 节流)。停止调用 → 被动数据冻结在最后一次请求的值;从没被调用过 → 没有被动数据。

---

## 4. 五平台逐一对照

### Anthropic(OAuth / SetupToken)
- **active**:`fetchOAuthUsageRaw` 回源 Claude 的 usage API(OAuth);SetupToken 走 `estimateSetupTokenUsage`(从 Extra 估算)。一次 active 后 `syncActiveToPassive` 把结果**回写 Extra**,所以 active 过一次、passive 也能读到新值。
- **被动**:有(§3)。
- **force**:无效(只查 `apiCache`)。
- **passive**:✅ 唯一支持。

### Bedrock(注意:是 Anthropic 平台 + `Bedrock` 类型,不是独立平台)
- **active**:`GetUsage` 里**不匹配任何分支**,`CanGetUsage()`(=`Type==OAuth`)为 false → 落到末尾 `return nil, fmt.Errorf("account type bedrock does not support usage query")`。
- **被动**:无(`forwardBedrock` 不写 Extra)。
- **passive**:❌ 报错(类型不是 OAuth/SetupToken)。
- **结论**:Bedrock 账号**两端都拿不到用量**,无上游接口、无本地估算。

### Gemini — 纯本地估算
- **active**:`getGeminiUsage` **不回源、不探测**。配额上限取自 **config**(`gemini_quota.go`,按 tier 给 RPD/RPM);已用量取自**本地 DB**(`usageLogRepo.GetModelStatsWithFilters` 查今日 / 当前分钟窗口),算出 daily(RPD)/ minute(RPM)进度。
- **被动**:无。
- **force**:不传入,无效。
- **passive**:❌ 报错(平台不符)。

### OpenAI / Codex(OAuth)
- **active**:`getOpenAIUsage(force)` 先用 `buildCodexUsageProgressFromExtra` 读 Extra 被动快照,再叠本地 DB WindowStats;陈旧或 `force` 时才发 probe(向 `chatgptCodexURL` 发最小测试请求,从响应头取限流写回 Extra)。
- **被动**:有(§3,30s 节流)。
- **force**:✅ **唯一真正用 force 的平台**——`forceProbe` 跳过 `openAIProbeCacheTTL=10min` 的 probe 节流,强制探测一次。
- **passive**:❌ 报错(平台不符;Codex 数据要走 active 读 Extra+probe)。

### Antigravity
- **active**:`getAntigravityUsage` 回源上游 **Code-Assist** 管理接口(`FetchAvailableModels` 取各模型 utilization/reset + `LoadCodeAssist` 取 tier 与 AI Credits)。403 返回 forbidden 降级标记而非报错。
- **被动**:无用量采样(只有 429 credits 耗尽的错误态标记 `setCreditsExhausted`)。
- **force**:不传入,无效。
- **passive**:❌ 报错(平台不符)。

### 对比表

| | Anthropic (OAuth/SetupToken) | Bedrock (Anthropic+Bedrock 型) | Gemini | OpenAI / Codex (OAuth) | Antigravity |
|---|---|---|---|---|---|
| **被动采样** | ✅ `UpdateSessionWindow`,**无节流** | ❌ | ❌ | ✅ `updateCodexUsageSnapshot`,**30s/账号**,async | ❌(仅 429 credits 标记) |
| **active 取法** | 回源 Claude usage API(`fetchOAuthUsageRaw`);SetupToken 估算 | ❌ 报错"does not support" | 本地估算(config 限额 ÷ 本地 DB 计数) | 读 Extra 快照 + 必要时 probe `chatgptCodexURL` | 回源 Code-Assist(`FetchAvailableModels`+`LoadCodeAssist`) |
| **force 作用** | 无 | 无意义 | 无 | ✅ 跳过 10min probe 节流 | 无 |
| **passive 支持** | ✅ 唯一 | ❌ 报错 | ❌ 报错 | ❌ 报错 | ❌ 报错 |
| **进程缓存** | `apiCache` 3min/1min(含负缓存)+ singleflight + 800ms jitter;`windowStats` 1min | 无 | `windowStats` 1min(本地 DB);无专属缓存 | `openAIProbeCache` 10min(可被 force 跳过)+ Extra 快照陈旧判定 10min;`windowStats` 1min | `antigravityCache`:成功/forbidden 3min、其他错误 1min + singleflight |

---

## 5. passive 取不到时:报错 vs 空数据(对客户端很重要)

`source=passive` 失败有**两种**结果,客户端要区别对待:

1. **账户类型不符**(非 Anthropic OAuth/SetupToken,含 Bedrock / Gemini / OpenAI / Antigravity)→ 服务端**返回错误**(`passive usage only supported for ...`,HTTP 非 2xx)。
2. **合规但从没采样过**(Anthropic OAuth/SetupToken 但该账户从没被调用过)→ **返回 200 + 空数据**(5h 利用率 0、无 7d)。

> quota-pulse 的 `pollOnce` 对「FetchUsage 报错」的账户会 **跳过、不显示**;对「200 空数据」的账户会 **显示成用量 —**。所以我们看到的「启动只剩活跃账户、其余不显示」,不显示的那批大概率是**类型不符被报错**的;合规无样本的反而会显示空。

---

## 6. 对 quota-pulse 的影响 / 对接结论

- **启动必须 `active` 回源一次**:否则非活跃 / 无被动样本的账户在 passive 下取不到(报错被跳过,或显示空)。这就是 v0.7.1 的修复点——`core/poller/poller.go` 启动首次 `Fresh: true`,把全部账户加载出来;之后再默认走被动、不周期性回源。
- **被动数据的新鲜度 = 该账户最后一次被真实调用的时刻**(Anthropic 实时跟每次请求、Codex 30s 节流)。久不调用的账户,passive 读到的是旧值(直到窗口重置清空、5h 过期归零、或主动回源)。
- **被动只对 Anthropic OAuth/SetupToken 有效**。如果将来要支持非 Anthropic 账号,客户端对它们应**始终用 `active`**(passive 必然报错)。当前 `Settings.toConfigJson()` 对所有 provider 统一发 `source=passive`(被动周期)+ 可选 `active` 回源——对纯 Anthropic 实例没问题,混入其它平台账号时要注意它们只能靠 active。
- **`force` 基本没用(对 Anthropic)**:手动刷新发 `force=true`,但 Anthropic active 在它自己的 3min `apiCache` 内可能直接返回缓存值,不一定真回源 Claude——这解释了「连点两次刷新值不变」。只有 OpenAI/Codex 的 force 会强制探测。

---

## 7. 关键文件索引(sub2api 服务端,便于核对)

| 关注点 | 文件 : 函数 |
|---|---|
| 路由 | `backend/internal/server/routes/admin.go` → `accounts.GET("/:id/usage", ...)` |
| handler(解析 source/force) | `backend/internal/handler/admin/account_handler.go` → `GetUsage` |
| passive 读 | `backend/internal/service/account_usage_service.go` → `GetPassiveUsage` |
| active 分发 + 各平台 | 同上 → `GetUsage` / `getOpenAIUsage` / `getGeminiUsage` / `getAntigravityUsage` / `fetchOAuthUsageRaw` / `estimateSetupTokenUsage` / `syncActiveToPassive` |
| Anthropic 被动写入 | `backend/internal/service/ratelimit_service.go` → `UpdateSessionWindow` |
| Anthropic 触发点 | `backend/internal/service/gateway_service.go`(4 处 `UpdateSessionWindow`) |
| Codex 被动写入 | `backend/internal/service/openai_gateway_service.go` → `updateCodexUsageSnapshot` |
| Antigravity 回源 | `backend/internal/service/antigravity_quota_fetcher.go` → `FetchQuota` |
| Gemini 估算 | `backend/internal/service/gemini_quota.go` |
| 账户类型判定 | `backend/internal/service/account.go` → `CanGetUsage` / `IsAnthropicOAuthOrSetupToken` / `IsBedrock` |
| 计费缓存(无关 usage) | `backend/internal/service/billing_cache_service.go` |
