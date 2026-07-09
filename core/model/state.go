package model

import "time"

// Severity 是状态的严重度,UI 据此上色(与具体 provider 无关)。
type Severity string

const (
	SeverityOK      Severity = "ok"      // 绿:正常
	SeverityWarning Severity = "warning" // 琥珀:限流 / 配额超限 / 临时不可调度
	SeverityDanger  Severity = "danger"  // 红:过载 / 错误
	SeverityNeutral Severity = "neutral" // 灰:暂停 / 停用 / 未知
)

// 账户「管理状态」的机器码(AccountState.Code 取值)。与 sub2api 网页
// 「账户管理→状态」列一一对应;UI 侧据此映射本地化文案与颜色。
const (
	StateOK                = "ok"                 // 正常(active 且可调度)
	StateRateLimited       = "rate_limited"       // 429:被上游限流,rate_limit_reset_at 前不参与调度
	StateOverloaded        = "overloaded"         // 529:上游过载,overload_until 前避让
	StateTempUnschedulable = "temp_unschedulable" // 命中临时不可调度规则,temp_unschedulable_until 前跳过
	StateError             = "error"              // 账户状态=error(带 error_message)
	StateQuotaExceeded     = "quota_exceeded"     // 配额(总/日/周)已用尽
	StatePaused            = "paused"             // 人工暂停(schedulable=false)
	StateInactive          = "inactive"           // 停用(status=inactive)
	StateUnknown           = "unknown"
)

// 模型级限流的类型(ModelState.Kind 取值)。
const (
	ModelKindRateLimit        = "rate_limit"        // 普通模型限流
	ModelKindCreditsExhausted = "credits_exhausted" // AICredits 积分已用尽
	ModelKindCreditsActive    = "credits_active"    // 模型限流但开启 overages,正在走积分
)

// AccountState 是账户的「管理状态」快照,镜像 sub2api 网页「账户管理→状态」列。
//
// provider 无关:任何按账户调度/计费的后台都可产出;不支持则留 nil,UI 不显示这一块。
// 它与 AccountPulse.Status(由用量窗口使用率推导)正交并存 —— Status 讲「窗口打没打满」,
// State 讲「后台把这个账户置于什么调度状态」(429 限流 / 529 过载 / 暂停 / 停用 / 配额超限 …)。
type AccountState struct {
	Code     string       `json:"code"`                // 机器码,见上方 State* 常量
	Severity Severity     `json:"severity"`            // UI 上色档
	ResetsAt *time.Time   `json:"resets_at,omitempty"` // 有「解除时间」的状态(429/529/临时不可调度)→ 倒计时
	Reason   string       `json:"reason,omitempty"`    // tooltip 详情:error_message / temp_unschedulable_reason
	Models   []ModelState `json:"models,omitempty"`    // 模型级限流(网页的第二排徽章)
}

// ModelState 是单个模型 / scope 的限流态(sub2api extra.model_rate_limits 的一项)。
type ModelState struct {
	Model    string     `json:"model"`               // 模型 / scope 键(UI 侧做短名别名)
	Kind     string     `json:"kind"`                // 见上方 ModelKind* 常量
	ResetsAt *time.Time `json:"resets_at,omitempty"` // 解除时刻 → 倒计时
}
