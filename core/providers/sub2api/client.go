// Package sub2api 实现针对 sub2api 后台管理 API 的 Provider。
//
//	鉴权:  header x-api-key
//	列表:  GET /api/v1/admin/accounts            (支持 ETag/304)
//	用量:  GET /api/v1/admin/accounts/:id/usage  ?source=passive|active&force=true
package sub2api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"strconv"
	"time"

	"github.com/lureiny/quota-pulse/core/config"
	"github.com/lureiny/quota-pulse/core/model"
	"github.com/lureiny/quota-pulse/core/provider"
)

const (
	providerType = "sub2api"
	apiPrefix    = "/api/v1/admin"
)

// 包加载时把自己注册进 provider 工厂表。app 侧用 `_ import` 触发。
func init() {
	provider.Register(providerType, New)
}

// Provider 实现 provider.Provider。
type Provider struct {
	name     string
	client   *provider.Client
	selector config.AccountSelector
}

// New 是注册到工厂表的构造函数。
func New(cfg config.ProviderConfig) (provider.Provider, error) {
	if cfg.BaseURL == "" {
		return nil, fmt.Errorf("sub2api: base_url required")
	}
	name := cfg.Name
	if name == "" {
		name = providerType
	}
	auth := provider.AuthScheme{Header: "x-api-key", Token: cfg.APIKey}
	return &Provider{
		name:     name,
		client:   provider.NewClient(cfg.BaseURL, auth),
		selector: cfg.Accounts,
	}, nil
}

func (p *Provider) Type() string        { return providerType }
func (p *Provider) DisplayName() string { return p.name }

// SetLabel 实现 provider.LabelSetter:把去重后的实例名贴到 HTTP 客户端上,
// 供调试采样(core/netstat)按实例区分读流量。
func (p *Provider) SetLabel(label string) { p.client.Label = label }

func (p *Provider) Capabilities() provider.Capabilities {
	return provider.Capabilities{
		HasRollingWindows:      true,
		HasCumulativeQuota:     false,
		SupportsConditionalGet: true,
		DefaultMeterIDs:        []string{"five_hour", "seven_day"},
	}
}

// ListAccounts 拉取账户列表(带 ETag 条件请求),并按 selector 过滤。
func (p *Provider) ListAccounts(ctx context.Context) ([]model.Account, error) {
	q := url.Values{}
	q.Set("page", "1")
	q.Set("page_size", "200")
	for k, v := range p.selector.Filter {
		if v != "" {
			q.Set(k, v)
		}
	}

	data, err := p.client.GetData(ctx, apiPrefix+"/accounts?"+q.Encode(), true)
	if err != nil {
		return nil, err
	}
	var list accountListDTO
	if err := json.Unmarshal(data, &list); err != nil {
		return nil, fmt.Errorf("decode accounts: %w", err)
	}

	allow := idAllowSet(p.selector.IDs)
	out := make([]model.Account, 0, len(list.Items))
	for _, a := range list.Items {
		id := strconv.FormatInt(a.ID, 10)
		if allow != nil {
			if _, ok := allow[id]; !ok {
				continue
			}
		}
		out = append(out, model.Account{
			ID:       id,
			Name:     a.Name,
			Platform: a.Platform,
			Type:     a.Type,
			Status:   a.Status,
			Provider: providerType,
		})
	}
	return out, nil
}

// FetchUsage 拉取单账户用量并映射成通用脉搏。
func (p *Provider) FetchUsage(ctx context.Context, acc model.Account, opt provider.FetchOptions) (model.AccountPulse, error) {
	q := "source=passive"
	if opt.Fresh {
		q = "source=active&force=true"
	}
	path := apiPrefix + "/accounts/" + url.PathEscape(acc.ID) + "/usage?" + q

	data, err := p.client.GetData(ctx, path, false)
	if err != nil {
		return model.AccountPulse{}, err
	}
	var u usageInfo
	if err := json.Unmarshal(data, &u); err != nil {
		return model.AccountPulse{}, fmt.Errorf("decode usage: %w", err)
	}
	return toPulse(acc, u), nil
}

// clampPageSize 把每页行数夹到 [1, 1000](服务端 page_size 硬顶 1000)。
func clampPageSize(n int) int {
	if n < 1 {
		return 1
	}
	if n > 1000 {
		return 1000
	}
	return n
}

// fetchUsagePage 取 /admin/usage 的一页(按 id 排序;order=asc/desc)。GetData 已剥外层信封。
func (p *Provider) fetchUsagePage(ctx context.Context, page, pageSize int, order, startDate, endDate string) (usageListResp, error) {
	q := url.Values{}
	q.Set("page", strconv.Itoa(page))
	q.Set("page_size", strconv.Itoa(pageSize))
	q.Set("sort_by", "id") // 按 id 排序:全序、唯一、与增量游标同键,翻页确定不漏
	q.Set("sort_order", order)
	q.Set("start_date", startDate)
	q.Set("end_date", endDate)

	data, err := p.client.GetData(ctx, apiPrefix+"/usage?"+q.Encode(), false)
	if err != nil {
		return usageListResp{}, err
	}
	var resp usageListResp
	if err := json.Unmarshal(data, &resp); err != nil {
		return usageListResp{}, fmt.Errorf("decode usage: %w", err)
	}
	return resp, nil
}

// FetchUsageSince 实现 provider.UsageLogFetcher:稳态增量拉取该实例的原始请求日志。
//
// 走后端 /admin/usage(每请求一行,留空 account_id = 全实例),按 **id 降序** 翻小页,
// 收集 id>sinceID 的新行。终止条件「有且仅有一个」:某页出现 id<=sinceID —— id 降序保证
// 其后必更旧,追到游标即停(稳态通常 1 页)。空页作物理兜底。**绝不按行数/页数截断**
// (那会在游标之上留洞、漏行)。时区不传服务端 —— 本地按精确 created_at 分桶(见 usage.Store)。
func (p *Provider) FetchUsageSince(ctx context.Context, sinceID int64, from time.Time, pageSize int) ([]model.UsageEvent, error) {
	pageSize = clampPageSize(pageSize)
	// start_date 回退一天缓冲:服务端过滤是「日历天」粒度,而 created_at 可能与 id 倒挂
	// (跨午夜请求:created_at 落前一天、id 却是新的)。不加这天缓冲,凌晨时 from 所在天
	// 之前的倒挂新行会被服务端过滤掉、游标永不前进 → 漏行。多抓的旧行由 straddle/去重吸收。
	startDate := from.AddDate(0, 0, -1).Format("2006-01-02")
	endDate := time.Now().AddDate(0, 0, 1).Format("2006-01-02") // 多给一天,吸收时区/跨天边界
	out := make([]model.UsageEvent, 0, 256)

	for page := 1; ; page++ {
		resp, err := p.fetchUsagePage(ctx, page, pageSize, "desc", startDate, endDate)
		if err != nil {
			return nil, err
		}
		if len(resp.Items) == 0 {
			break // 物理到底(数据有限):兜底终止
		}
		straddle := false
		for _, it := range resp.Items {
			if it.ID <= sinceID {
				straddle = true // 追到游标:唯一正常终止
				break
			}
			out = append(out, toEvent(it))
		}
		if straddle {
			break
		}
	}
	return out, nil
}

// FetchUsageWindow 实现 provider.UsageLogFetcher:按 id **降序** 抓 [from, to] 窗口内全部事件,
// 供反向回填历史(用户拉大跨度)。不按 id 游标过滤(收全部,靠本地主键去重),pageCap 封顶。
// complete 见接口说明:desc 截断丢的是「较老一段」,故调用方把水位只推到最老抓到的事件。
func (p *Provider) FetchUsageWindow(ctx context.Context, from, to time.Time, pageCap int) ([]model.UsageEvent, bool, error) {
	if pageCap <= 0 {
		pageCap = 20
	}
	startDate := from.AddDate(0, 0, -1).Format("2006-01-02") // 回退一天缓冲(同 FetchUsageSince,吸收日历天/倒挂)
	endDate := to.AddDate(0, 0, 1).Format("2006-01-02")      // 多给一天,吸收时区/跨天边界
	out := make([]model.UsageEvent, 0, 256)
	complete := false

	for page := 1; page <= pageCap; page++ {
		resp, err := p.fetchUsagePage(ctx, page, 1000, "desc", startDate, endDate)
		if err != nil {
			return nil, false, err
		}
		if len(resp.Items) == 0 {
			complete = true // 窗口内无更多数据 = 已抓全
			break
		}
		for _, it := range resp.Items {
			out = append(out, toEvent(it))
		}
		if page >= resp.Pages {
			complete = true // 翻到末页,窗口抓全
			break
		}
	}
	return out, complete, nil
}

// FetchUsageWindowAsc 实现 provider.UsageLogFetcher:前向补空缺,按 id **升序**(由旧到新)
// 抓 [from, to]。从 startPage 起翻,单次调用受 rowBudget 封顶,返回 nextPage 供**同一 from 续翻**
// (关键:from 固定、只推进 page,避免日历天粒度下按 maxSeen 重设 start_date 反复重取同一天首页
// → 卡在同一天漏行)。complete=true 表示翻到窗口末页(不足一页/空页)。maxSeen=本次抓到的
// 最大 created_at(升序连续右端)。用 len<pageSize 判末页,不信 fast 分页的近似 Pages。
func (p *Provider) FetchUsageWindowAsc(ctx context.Context, from, to time.Time, pageSize, rowBudget, startPage int) ([]model.UsageEvent, bool, time.Time, int, error) {
	pageSize = clampPageSize(pageSize)
	if rowBudget <= 0 {
		rowBudget = 5000
	}
	if startPage < 1 {
		startPage = 1
	}
	startDate := from.AddDate(0, 0, -1).Format("2006-01-02") // 回退一天缓冲(吸收日历天/倒挂)
	endDate := to.AddDate(0, 0, 1).Format("2006-01-02")
	out := make([]model.UsageEvent, 0, 256)
	var maxSeen time.Time

	for page := startPage; ; page++ {
		resp, err := p.fetchUsagePage(ctx, page, pageSize, "asc", startDate, endDate)
		if err != nil {
			return nil, false, time.Time{}, page, err
		}
		for _, it := range resp.Items {
			ev := toEvent(it)
			out = append(out, ev)
			if ev.CreatedAt.After(maxSeen) {
				maxSeen = ev.CreatedAt
			}
		}
		if len(resp.Items) < pageSize {
			return out, true, maxSeen, page + 1, nil // 不足一页 = 窗口末页,抓全
		}
		if len(out) >= rowBudget {
			return out, false, maxSeen, page + 1, nil // 行预算截断:下次从 page+1 续(from 不变)
		}
	}
}

func idAllowSet(ids []string) map[string]struct{} {
	if len(ids) == 0 {
		return nil
	}
	m := make(map[string]struct{}, len(ids))
	for _, id := range ids {
		m[id] = struct{}{}
	}
	return m
}
