package model

import "time"

// HourPoint 是某「系列」在某一个小时桶内的 token 用量。Hour 为该小时起点(本地时区)。
// 系列由查询维度决定(账户 / api_key / model / user / group …),见 usage.Store.QuerySeries。
type HourPoint struct {
	Hour        time.Time `json:"hour"`         // 小时桶起点
	Input       int64     `json:"input"`        // 输入 token
	Output      int64     `json:"output"`       // 输出 token
	CacheCreate int64     `json:"cache_create"` // 缓存创建 token
	CacheRead   int64     `json:"cache_read"`   // 缓存读取 token
	Total       int64     `json:"total"`        // 合计 token(= 上面四项之和)
	Cost        float64   `json:"cost"`         // 花费合计(USD;与 token 不严格成正比,单独聚合)
}

// Series 是某维度下的一条序列(一个维度值 → 它的小时序列)。
// Key 是维度值(如 account_id / model 名),Name 是展示名。
type Series struct {
	Key    string      `json:"key"`
	Name   string      `json:"name"`
	Points []HourPoint `json:"points"`
}

// UsageEvent 是 sub2api /admin/usage 的一条原始请求事件(本地落库的单位)。
//
// 维度走 Dims(label 风格,key→value 字符串):account/account_name/api_key/
// api_key_name/user/user_name/group/group_name/model … —— 加新维度只需往 Dims 塞键,
// 存储侧用一个 JSON 列承载,零迁移。绝不放 api_key 明文密钥。
type UsageEvent struct {
	ID          int64
	CreatedAt   time.Time
	Input       int64
	Output      int64
	CacheCreate int64
	CacheRead   int64
	Cost        float64
	Dims        map[string]string
}
