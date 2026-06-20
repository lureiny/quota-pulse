// Package provider 定义所有用量来源(sub2api / one-api / new-api ...)必须实现的
// 统一接口,以及它们共用的 HTTP 传输与注册表。
//
// 设计要点:Provider 直接产出"通用模型"(model.AccountPulse),各平台的字段差异
// 在各自的 mapper 内消化。UI 只消费通用模型,因此新增平台不需要改动 UI / 外壳。
package provider

import (
	"context"
	"time"

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

// UsageLogFetcher 是一个可选能力:增量拉取该来源的原始请求日志(供本地按
// 「账户×本地小时」聚合,见 core/usage)。并非所有 provider 都支持(目前仅 sub2api),
// 故独立于 Provider 主接口,由 poller 通过类型断言探测。
//
//	sinceID  只取 id 大于它的新行(增量游标;0=冷启动回填)
//	from     起始日期(date 粒度过滤的下界;实际仍按 id 精确去重)
//	pageCap  翻页上限(防失控;desc 排序下截断只丢最老的行)
//
// 返回 id>sinceID 的全部新事件(精确时间、各类 token、cost、维度 Dims)。
type UsageLogFetcher interface {
	FetchUsageSince(ctx context.Context, sinceID int64, from time.Time, pageCap int) ([]model.UsageEvent, error)

	// FetchUsageWindow 抓取 [from, to] 时间窗内的「全部」事件(不走 id 游标,靠主键
	// INSERT OR IGNORE 去重),供按需回填历史(用户拉大图表跨度时补齐更早数据)。
	// complete=true 表示在 pageCap 内翻到了末页、窗口内数据已抓全;false 表示被 pageCap
	// 截断(desc 排序下只抓到较新的一段,更早的没拿到 —— 调用方据此把覆盖水位只推到最老
	// 抓到的事件,而非 from,保持诚实)。
	FetchUsageWindow(ctx context.Context, from, to time.Time, pageCap int) (events []model.UsageEvent, complete bool, err error)
}
