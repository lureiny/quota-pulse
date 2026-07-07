// Package bridge 暴露一个 gomobile 友好的 API,供 iOS/Android 通过
// `gomobile bind` 调用。跨边界只用 string 与 interface(gomobile 安全子集),
// 复杂数据一律以 JSON 字符串传递。
//
// 生成绑定:
//
//	gomobile bind -target=android -o quotapulse.aar  ./bridge
//	gomobile bind -target=ios     -o QuotaPulse.xcframework ./bridge
package bridge

import (
	"context"

	"github.com/lureiny/quota-pulse/core/app"
)

// Delegate 由原生侧(Swift / Kotlin / Dart)实现,用于接收快照推送。
// gomobile 要求回调走接口(delegate)而非裸函数。
type Delegate interface {
	OnSnapshot(json string)
}

// Engine 是 gomobile bind 暴露的入口。
type Engine struct {
	app    *app.App
	cancel context.CancelFunc
}

// NewEngine 用 JSON 配置创建引擎。
func NewEngine(configJSON string) (*Engine, error) {
	a, err := app.NewFromJSON(configJSON)
	if err != nil {
		return nil, err
	}
	return &Engine{app: a}, nil
}

// Start 开始轮询;d 可为 nil(只轮询不推送)。
func (e *Engine) Start(d Delegate) {
	if d != nil {
		e.app.Subscribe(d.OnSnapshot)
	}
	ctx, cancel := context.WithCancel(context.Background())
	e.cancel = cancel
	e.app.Start(ctx)
}

// Stop 停止轮询。
func (e *Engine) Stop() {
	if e.cancel != nil {
		e.cancel()
	}
	e.app.Stop()
}

// SnapshotJSON 返回当前快照(JSON)。
func (e *Engine) SnapshotJSON() string { return e.app.SnapshotJSON() }

// Refresh 触发一次强制回源。
func (e *Engine) Refresh(accountID string) { e.app.Refresh(accountID) }

// ChartSeries 按维度聚合用量序列,返回 {series,coverageFrom,requestedFrom} 的 JSON。
func (e *Engine) ChartSeries(instance, dimension string, hours int) string {
	return e.app.ChartSeriesJSON(instance, dimension, hours)
}

// ChartDailySeries 同 ChartSeries,但按本地日聚合最近 days 天(供热力图)。
func (e *Engine) ChartDailySeries(instance, dimension string, days int) string {
	return e.app.ChartDailySeriesJSON(instance, dimension, days)
}

// Coverage 返回 {coverageFrom,earliestEvent} 的 JSON(供热力图判断补齐进度)。
func (e *Engine) Coverage(instance string) string { return e.app.CoverageJSON(instance) }

// EnsureCoverage 触发按需回填,确保本地覆盖延伸到 now-hours(异步)。
func (e *Engine) EnsureCoverage(instance string, hours int) { e.app.EnsureCoverage(instance, hours) }

// 以下信号供宿主把系统状态喂给调度器(省电/实时感)。

func (e *Engine) SetForeground(v bool) { e.app.SetPopoverOpen(v) }
func (e *Engine) SetOnBattery(v bool)  { e.app.SetOnBattery(v) }
func (e *Engine) SetAsleep(v bool)     { e.app.SetAsleep(v) }
