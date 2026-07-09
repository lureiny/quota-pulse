package model

// Account 是一个被监控的账户(provider 无关)。
//
//	sub2api:        一个上游账户
//	one-api/new-api: 一个 token 或 channel
type Account struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Platform string `json:"platform"` // 上游平台:claude / gemini / openai ...
	Type     string `json:"type"`     // oauth / apikey / ...
	Status   string `json:"status"`   // active / inactive / error
	Provider string `json:"provider"` // 来源:sub2api / oneapi / newapi

	// State 是账户「管理状态」快照,由支持的 provider 在 ListAccounts 阶段派生并挂载,
	// 随后被 toPulse 复制进 AccountPulse。不支持则为 nil。
	State *AccountState `json:"-"`
}
