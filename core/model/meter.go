package model

import "time"

// MeterKind 区分用量的底层模型。这是让"滚动窗口"与"累计配额"两类 provider
// 共用一套 UI 的关键。
type MeterKind string

const (
	// KindRollingWindow:带重置时间的滚动窗口(sub2api 的 5h / 7d 窗口)。
	KindRollingWindow MeterKind = "rolling_window"
	// KindCumulative:累计配额计数器,已用 vs 总额,通常无重置(one-api / new-api)。
	KindCumulative MeterKind = "cumulative"
	// KindRate:速率上限,如 RPM / TPM。
	KindRate MeterKind = "rate"
)

// Unit 是 Used / Limit 的单位。
type Unit string

const (
	UnitPercent  Unit = "percent"
	UnitRequests Unit = "requests"
	UnitTokens   Unit = "tokens"
	UnitUSD      Unit = "usd"
	UnitCount    Unit = "count"
)

// Meter 是一个"表盘"。无论底层是滚动窗口还是累计配额,UI 都把它渲染成
// 一根进度条 + 可选副标(滚动窗口显示重置倒计时;累计配额显示 已用/总额)。
type Meter struct {
	ID            string     `json:"id"`                       // 稳定键:five_hour / seven_day / quota ...
	Label         string     `json:"label"`                    // 展示名:5h / 7d / 配额
	Kind          MeterKind  `json:"kind"`                     //
	Unit          Unit       `json:"unit"`                     //
	Utilization   *float64   `json:"utilization,omitempty"`    // 归一化使用率 0.0~1.0+(未知为 nil)
	Used          *float64   `json:"used,omitempty"`           // 绝对已用(可选)
	Limit         *float64   `json:"limit,omitempty"`          // 绝对上限(可选)
	ResetsAt      *time.Time `json:"resets_at,omitempty"`      // 重置时间(仅滚动/周期型)
	RemainingSecs *int64     `json:"remaining_secs,omitempty"` // 距重置剩余秒数
	Detail        string     `json:"detail,omitempty"`         // 副标,如 "1.2M tok · $3.4"
}
