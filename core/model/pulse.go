package model

import "time"

// Status 是账户的总体状态,UI 用它决定状态色。
type Status string

const (
	StatusOK          Status = "ok"
	StatusWarning     Status = "warning"      // 某窗口接近上限(≥80%)
	StatusRateLimited Status = "rate_limited" // 某窗口已满(≥100%)
	StatusForbidden   Status = "forbidden"    // 被限制,需人工验证
	StatusNeedsReauth Status = "needs_reauth" // token 失效需重新授权
	StatusBanned      Status = "banned"       // 账号被封
	StatusError       Status = "error"        // 拉取失败
)

// AccountPulse 是一个账户的"用量脉搏" —— UI 唯一消费的结构。
// 它不包含任何具体 provider 的字段;新增平台只需提供一个能产出它的 mapper。
type AccountPulse struct {
	AccountID string    `json:"account_id"`
	Name      string    `json:"name"`
	Platform  string    `json:"platform"`             // 上游平台
	Provider  string    `json:"provider"`             // 类型:sub2api / oneapi / newapi
	Instance  string    `json:"instance"`             // 实例显示名(区分多个同类型后台;UI 按它分组)
	Status    Status    `json:"status"`               //
	Tier      string    `json:"tier,omitempty"`       // 订阅等级(若有)
	Meters    []Meter   `json:"meters"`               // 一组表盘 —— 抽象的灵魂
	UpdatedAt time.Time `json:"updated_at"`           //
	Error     string    `json:"error,omitempty"`      //
	ActionURL string    `json:"action_url,omitempty"` // 如验证/申诉链接(仅展示,不执行)

	// State 是账户的「管理状态」(429 限流 / 529 过载 / 暂停 / 停用 …),镜像上游后台的状态列。
	// 与 Status 正交:Status 讲窗口用量,State 讲调度状态。provider 不支持则为 nil。
	State *AccountState `json:"state,omitempty"`
}
