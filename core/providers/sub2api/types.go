package sub2api

import "time"

// 以下 DTO 贴合 sub2api 后端源码,只取展示所需字段。

// accountDTO 是 GET /api/v1/admin/accounts 的列表项。
// 除基本标识外,带上后端「账户管理→状态」列所需的调度 / 限流 / 配额字段
// (这些字段本就在同一响应里,deriveState 据此镜像网页状态列)。
type accountDTO struct {
	ID       int64  `json:"id"`
	Name     string `json:"name"`
	Platform string `json:"platform"`
	Type     string `json:"type"`
	Status   string `json:"status"` // active / inactive / error

	ErrorMessage string `json:"error_message"`
	Schedulable  bool   `json:"schedulable"`

	// 429 限流 / 529 过载 / 临时不可调度:各带「解除时间」,前端据此判是否生效 + 倒计时。
	RateLimitedAt    *time.Time `json:"rate_limited_at"`
	RateLimitResetAt *time.Time `json:"rate_limit_reset_at"`
	OverloadUntil    *time.Time `json:"overload_until"`

	TempUnschedulableUntil  *time.Time `json:"temp_unschedulable_until"`
	TempUnschedulableReason string     `json:"temp_unschedulable_reason"`

	// API Key 账号配额(总 / 日 / 周);used>=limit>0 即「配额超限」。
	QuotaLimit       *float64 `json:"quota_limit"`
	QuotaUsed        *float64 `json:"quota_used"`
	QuotaDailyLimit  *float64 `json:"quota_daily_limit"`
	QuotaDailyUsed   *float64 `json:"quota_daily_used"`
	QuotaWeeklyLimit *float64 `json:"quota_weekly_limit"`
	QuotaWeeklyUsed  *float64 `json:"quota_weekly_used"`

	Extra accountExtraDTO `json:"extra"`
}

// accountExtraDTO 只取 extra 里状态列用得到的两项(其余键忽略)。
type accountExtraDTO struct {
	AllowOverages   bool                         `json:"allow_overages"`
	ModelRateLimits map[string]modelRateLimitDTO `json:"model_rate_limits"`
}

// modelRateLimitDTO 是 extra.model_rate_limits 的一项(单模型 / scope 的限流窗口)。
type modelRateLimitDTO struct {
	RateLimitedAt    *time.Time `json:"rate_limited_at"`
	RateLimitResetAt *time.Time `json:"rate_limit_reset_at"`
}

// accountListDTO 是分页信封里的 data。
type accountListDTO struct {
	Items    []accountDTO `json:"items"`
	Total    int64        `json:"total"`
	Page     int          `json:"page"`
	PageSize int          `json:"page_size"`
	Pages    int          `json:"pages"`
}

// windowStats 对应后端 service.WindowStats。
type windowStats struct {
	Requests     int64   `json:"requests"`
	Tokens       int64   `json:"tokens"`
	Cost         float64 `json:"cost"`
	StandardCost float64 `json:"standard_cost"`
	UserCost     float64 `json:"user_cost"`
}

// usageProgress 对应后端 service.UsageProgress(单个窗口的进度)。
type usageProgress struct {
	Utilization      float64      `json:"utilization"` // 0~100+
	ResetsAt         *time.Time   `json:"resets_at"`
	RemainingSeconds int          `json:"remaining_seconds"`
	WindowStats      *windowStats `json:"window_stats"`
	UsedRequests     int64        `json:"used_requests"`
	LimitRequests    int64        `json:"limit_requests"`
}

// usageRef 是 account/group 等内嵌的最小引用(id+name)。
type usageRef struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
}

// usageKeyRef 是内嵌 api_key:只取 id+name,**绝不取 key 明文密钥**。
type usageKeyRef struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
}

// usageUserRef 是内嵌 user:用 email 当展示名(username 常为空)。
type usageUserRef struct {
	ID       int64  `json:"id"`
	Email    string `json:"email"`
	Username string `json:"username"`
}

// usageLogItem 对应 GET /admin/usage 返回 data.items[] 的单条(AdminUsageLog,只取所需)。
type usageLogItem struct {
	ID                  int64         `json:"id"`
	CreatedAt           time.Time     `json:"created_at"`
	AccountID           int64         `json:"account_id"`
	APIKeyID            int64         `json:"api_key_id"`
	UserID              int64         `json:"user_id"`
	GroupID             int64         `json:"group_id"`
	Model               string        `json:"model"`
	InputTokens         int64         `json:"input_tokens"`
	OutputTokens        int64         `json:"output_tokens"`
	CacheCreationTokens int64         `json:"cache_creation_tokens"`
	CacheReadTokens     int64         `json:"cache_read_tokens"`
	ActualCost          float64       `json:"actual_cost"`
	Account             *usageRef     `json:"account"`
	APIKey              *usageKeyRef  `json:"api_key"`
	User                *usageUserRef `json:"user"`
	Group               *usageRef     `json:"group"`
}

// usageListResp 对应 GET /admin/usage 的 data 分页信封(GetData 已剥外层)。
type usageListResp struct {
	Items    []usageLogItem `json:"items"`
	Total    int64          `json:"total"`
	Page     int            `json:"page"`
	PageSize int            `json:"page_size"`
	Pages    int            `json:"pages"`
}

// usageInfo 对应后端 service.UsageInfo(GET /accounts/:id/usage 的 data)。
type usageInfo struct {
	Source    string     `json:"source"`
	UpdatedAt *time.Time `json:"updated_at"`

	// Claude 窗口
	FiveHour       *usageProgress `json:"five_hour"`
	SevenDay       *usageProgress `json:"seven_day"`
	SevenDaySonnet *usageProgress `json:"seven_day_sonnet"`
	// 7d Fable(= Anthropic 7d_oi / overage-included 周窗口,Opus/premium 级家族)。
	// 与 seven_day/sonnet 同级、同为 UsageProgress;passive 可采(extra.passive_usage_7d_oi_*)。
	SevenDayFable *usageProgress `json:"seven_day_fable"`

	// Gemini 窗口
	GeminiSharedDaily  *usageProgress `json:"gemini_shared_daily"`
	GeminiProDaily     *usageProgress `json:"gemini_pro_daily"`
	GeminiFlashDaily   *usageProgress `json:"gemini_flash_daily"`
	GeminiSharedMinute *usageProgress `json:"gemini_shared_minute"`
	GeminiProMinute    *usageProgress `json:"gemini_pro_minute"`
	GeminiFlashMinute  *usageProgress `json:"gemini_flash_minute"`

	SubscriptionTier string `json:"subscription_tier"` // FREE/PRO/ULTRA/UNKNOWN

	// 状态标志
	IsForbidden   bool   `json:"is_forbidden"`
	ForbiddenType string `json:"forbidden_type"` // validation / violation / forbidden
	ValidationURL string `json:"validation_url"`
	NeedsReauth   bool   `json:"needs_reauth"`
	IsBanned      bool   `json:"is_banned"`

	Error string `json:"error"`
}
