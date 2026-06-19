package model

import "time"

// HourPoint 是某账户在某一个小时桶内的 token 用量(来自 sub2api 的
// dashboard/trend 接口,granularity=hour)。Hour 为该小时的起点(本地时区)。
//
// 与 Meter(当前窗口快照)正交:Meter 回答"现在用了多少",HourPoint 回答
// "过去每小时各用了多少",供主面板按站点画堆叠柱状图(按账户着色)。
type HourPoint struct {
	Hour        time.Time `json:"hour"`         // 小时桶起点
	Input       int64     `json:"input"`        // 输入 token
	Output      int64     `json:"output"`       // 输出 token
	CacheCreate int64     `json:"cache_create"` // 缓存创建 token
	CacheRead   int64     `json:"cache_read"`   // 缓存读取 token
	Total       int64     `json:"total"`        // 合计 token(= 上面四项之和)
}

// UsageRow 是 sub2api /admin/usage 的一条原始请求日志(只取分桶所需字段)。
// ID 单调递增,做增量同步游标;CreatedAt 精确,客户端按本地时区分小时桶。
type UsageRow struct {
	ID          int64
	AccountID   string
	CreatedAt   time.Time
	Input       int64
	Output      int64
	CacheCreate int64
	CacheRead   int64
}
