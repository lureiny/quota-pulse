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
