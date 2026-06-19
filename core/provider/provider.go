// Package provider 定义所有用量来源(sub2api / one-api / new-api ...)必须实现的
// 统一接口,以及它们共用的 HTTP 传输与注册表。
//
// 设计要点:Provider 直接产出"通用模型"(model.AccountPulse),各平台的字段差异
// 在各自的 mapper 内消化。UI 只消费通用模型,因此新增平台不需要改动 UI / 外壳。
package provider

import (
	"context"

	"github.com/lureiny/quota-pulse/core/model"
)

// FetchOptions 控制单次拉取行为。
type FetchOptions struct {
	// Fresh=true 强制回源(sub2api: source=active&force=true),代价高;
	// false 走便宜的被动缓存(sub2api: source=passive)。
	Fresh bool
}

// Capabilities 声明 provider 的能力,供 UI 自适应展示
// (例如累计配额型不显示"重置倒计时")。
type Capabilities struct {
	HasRollingWindows      bool     // 是否有带重置的滚动窗口(sub2api=true)
	HasCumulativeQuota     bool     // 是否是累计配额模型(one-api=true)
	SupportsConditionalGet bool     // 列表是否支持 ETag/304(sub2api=true)
	DefaultMeterIDs        []string // UI 默认优先展示的表盘
}

// Provider 是一个用量来源。实现者只需把原生响应映射成通用模型。
type Provider interface {
	Type() string        // 稳定类型键:sub2api / oneapi / newapi
	DisplayName() string // 人类可读名

	// ListAccounts 列出该来源下要监控的账户。
	ListAccounts(ctx context.Context) ([]model.Account, error)

	// FetchUsage 拉取单个账户用量并产出通用脉搏。
	// 传入完整 Account 以便结果携带 name/platform(用量响应通常不含这些)。
	FetchUsage(ctx context.Context, acc model.Account, opt FetchOptions) (model.AccountPulse, error)

	// Capabilities 返回能力声明。
	Capabilities() Capabilities
}

// TrendFetcher 是一个可选能力:能拉取单账户的小时级 token 时序。
// 并非所有 provider 都支持(目前仅 sub2api),故独立于 Provider 主接口,
// 由 poller 通过类型断言探测:if tf, ok := prov.(provider.TrendFetcher); ok { ... }。
//
// hours 为期望回看的小时数(由图表配置决定);返回按时间升序的小时桶。
type TrendFetcher interface {
	FetchTrend(ctx context.Context, acc model.Account, hours int) ([]model.HourPoint, error)
}
