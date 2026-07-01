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

// LabelSetter 是一个可选能力:接收一个稳定的实例显示名(app 算出去重后回填)。
// 供调试采样(core/netstat)按实例区分流量。由 app 通过类型断言探测。
type LabelSetter interface {
	SetLabel(label string)
}

// UsageLogFetcher 是一个可选能力:增量拉取该来源的原始请求日志(供本地按
// 「账户×本地小时」聚合,见 core/usage)。并非所有 provider 都支持(目前仅 sub2api),
// 故独立于 Provider 主接口,由 poller 通过类型断言探测。三条流各有一法:
//   - 稳态增量:FetchUsageSince(小页 id-desc,追到游标即停)
//   - 前向补空缺:FetchUsageWindowAsc(大页 id-asc,由旧到新,截断只剩最新一段)
//   - 反向补历史:FetchUsageWindow(大页 desc,按需回填更早)
type UsageLogFetcher interface {
	// FetchUsageSince 稳态增量:按 id 降序小页翻,收集 id>sinceID 的新行。
	//
	//	sinceID   增量游标(上次并入的最大 id)
	//	from      起始日期(date 粒度窗口下界,仅用于收窄查询)
	//	pageSize  每页行数(调用方按上周期新增量动态给,内部夹到 [1,1000])
	//
	// 终止条件「有且仅有一个」:本页出现 id<=sinceID(id 降序 → 其后必更旧,追到游标)。
	// 空页作物理兜底(数据有限必然终止)。绝不按行数/页数截断(那会漏行)。
	FetchUsageSince(ctx context.Context, sinceID int64, from time.Time, pageSize int) ([]model.UsageEvent, error)

	// FetchUsageWindow 抓取 [from, to] 时间窗内的「全部」事件(desc,不走 id 游标,靠主键
	// INSERT OR IGNORE 去重),供反向回填历史。complete=true 表示 pageCap 内翻到末页、
	// 窗口抓全;false 表示被截断(只抓到较新一段,调用方把覆盖水位只推到最老抓到的事件)。
	FetchUsageWindow(ctx context.Context, from, to time.Time, pageCap int) (events []model.UsageEvent, complete bool, err error)

	// FetchUsageWindowAsc 前向补空缺:按 id 升序(由旧到新)抓 [from, to],从 startPage 起翻,
	// 单次受 rowBudget 封顶,返回 nextPage 供**同一 from 续翻**(from 固定、只推进 page,
	// 避免日历天粒度下反复重取同一天首页而卡住漏行)。complete=true 表示翻到末页(窗口抓全);
	// false 表示被 rowBudget 截断。maxSeen=本次抓到的最大 created_at(升序连续右端)。
	FetchUsageWindowAsc(ctx context.Context, from, to time.Time, pageSize, rowBudget, startPage int) (events []model.UsageEvent, complete bool, maxSeen time.Time, nextPage int, err error)
}
