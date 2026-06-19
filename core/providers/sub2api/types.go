package sub2api

import "time"

// 以下 DTO 贴合 sub2api 后端源码,只取展示所需字段。

// accountDTO 是 GET /api/v1/admin/accounts 的列表项(精简)。
type accountDTO struct {
	ID       int64  `json:"id"`
	Name     string `json:"name"`
	Platform string `json:"platform"`
	Type     string `json:"type"`
	Status   string `json:"status"`
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

// usageLogItem 对应 GET /admin/usage 返回 data.items[] 的单条(AdminUsageLog,精简)。
type usageLogItem struct {
	ID                  int64     `json:"id"`
	AccountID           int64     `json:"account_id"`
	CreatedAt           time.Time `json:"created_at"`
	InputTokens         int64     `json:"input_tokens"`
	OutputTokens        int64     `json:"output_tokens"`
	CacheCreationTokens int64     `json:"cache_creation_tokens"`
	CacheReadTokens     int64     `json:"cache_read_tokens"`
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
