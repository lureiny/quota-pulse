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
	// maxSincePages 是 FetchUsageSince 翻页的失控上限(纯防护,远高于任何真实数据量)。
	maxSincePages = 100000
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
	now := time.Now()
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
			// 从同一份列表响应派生「管理状态」(429/529/暂停/停用/配额…),随 acc 带进 toPulse。
			State: deriveAccountState(a, now),
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

// FetchUsageSince 实现 provider.UsageLogFetcher:增量拉取该实例的原始请求日志(合并后的流A)。
//
// 走后端 /admin/usage(每请求一行,留空 account_id = 全实例),按 **id 降序** 翻页,
// 收集 id>sinceID 的新行。终止条件「有且仅有一个」:某页出现 id<=sinceID —— id 降序保证
// 其后必更旧,追到游标即停(空闲/少量增量通常 1 页);空页作物理兜底。**绝不按短页(len<size)
// 判末页**(sub2api 快分页可能返回短页却非末页 → 会漏行),也绝不按行数/页数截断。
//
// 页大小自适应:起始用动态小页(空闲/少量增量一两页即追到游标,只发小请求);若某页**整页皆新**
// (len≥size 且未 straddle)= 积压(如长时间离线后),则升到 1000 大页并**从 page=1 重收**
// ——避免小页积压时一行一页翻很多次(0 塌陷)。升页时从头重收(而非中途改 page_size,否则
// page 偏移错位会漏行);重收的少量行由本地 (instance,id) 主键去重吸收,不漏不重。
// from 仅用于收窄服务端扫描(date 粒度回退一天缓冲跨午夜倒挂),不作终止。
func (p *Provider) FetchUsageSince(ctx context.Context, sinceID int64, from time.Time, pageSize int) ([]model.UsageEvent, error) {
	pageSize = clampPageSize(pageSize)
	// start_date 回退一天缓冲:服务端过滤是「日历天」粒度,而 created_at 可能与 id 倒挂
	// (跨午夜请求:created_at 落前一天、id 却是新的)。不加这天缓冲,凌晨时 from 所在天
	// 之前的倒挂新行会被服务端过滤掉、游标永不前进 → 漏行。多抓的旧行由 straddle/去重吸收。
	startDate := from.AddDate(0, 0, -1).Format("2006-01-02")
	endDate := time.Now().AddDate(0, 0, 1).Format("2006-01-02") // 多给一天,吸收时区/跨天边界

	size := pageSize
	for {
		out := make([]model.UsageEvent, 0, 256)
		escalate := false
		for page := 1; ; page++ {
			// 失控防护(从属于调用方 ctx 超时):正常靠 straddle/空页终止;若服务端异常地一直返回
			// 整页 id>sinceID(永不 straddle 也不空页),此上限兜底报错(不做部分落库→无洞、下拍重来)。
			// 上限远高于任何真实 30d 数据量与超时内可达页数,正常路径绝不触及。
			if page > maxSincePages {
				return nil, fmt.Errorf("FetchUsageSince: 翻页超上限 %d,疑似服务端未返回游标行", maxSincePages)
			}
			resp, err := p.fetchUsagePage(ctx, page, size, "desc", startDate, endDate)
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
			// 整页皆新且还在小页 → 积压:升 1000 从头重收(page 偏移一致才不漏)。
			if len(resp.Items) >= size && size < 1000 {
				escalate = true
				break
			}
		}
		if escalate {
			size = 1000
			continue
		}
		return out, nil
	}
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

// FetchEarliest 实现 provider.EarliestFetcher:一次请求(id 升序、page_size=1)取该实例
// 全历史最早的一条事件——「拉全量历史」的硬地板/进度基准。用宽日期范围当全时段;asc 首行
// = 全局最老(id 全序,不受日历天粒度模糊影响)。无数据时 ok=false。
func (p *Provider) FetchEarliest(ctx context.Context) (model.UsageEvent, bool, error) {
	endDate := time.Now().AddDate(0, 0, 1).Format("2006-01-02") // 多给一天,吸收时区边界
	resp, err := p.fetchUsagePage(ctx, 1, 1, "asc", "2000-01-01", endDate)
	if err != nil {
		return model.UsageEvent{}, false, err
	}
	if len(resp.Items) == 0 {
		return model.UsageEvent{}, false, nil
	}
	return toEvent(resp.Items[0]), true, nil
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
