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

// FetchTrend 实现 provider.TrendFetcher:拉取单账户最近 hours 小时的 token 时序。
//
// 走后端 dashboard/trend 接口(granularity=hour + account_id 过滤),数据源是真实
// usage_logs(全平台、不限 Anthropic;带 account_id 那条路径不过滤零成本行,故
// Claude 订阅号也照常统计)。统一用 timezone=UTC 查询并按 UTC 解析,保证桶边界
// 与解析一致;start_date 多回看一天以吸收时区/跨天误差(代价仅多几条小时桶)。
func (p *Provider) FetchTrend(ctx context.Context, acc model.Account, hours int) ([]model.HourPoint, error) {
	if hours <= 0 {
		hours = 24
	}
	tz, loc := localTrendZone()
	now := time.Now().In(loc)
	start := now.Add(-time.Duration(hours)*time.Hour - 24*time.Hour)

	q := url.Values{}
	q.Set("granularity", "hour")
	q.Set("account_id", acc.ID)
	q.Set("start_date", start.Format("2006-01-02"))
	q.Set("end_date", now.Format("2006-01-02"))
	q.Set("timezone", tz)

	path := apiPrefix + "/dashboard/trend?" + q.Encode()
	data, err := p.client.GetData(ctx, path, false)
	if err != nil {
		return nil, err
	}
	var r trendResp
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, fmt.Errorf("decode trend: %w", err)
	}
	return toHourPoints(r, loc), nil
}

// localTrendZone 返回 (传给服务端的 timezone 参数, 解析返回 date 用的 Location)。
//
// 服务端按给定 timezone 分桶并以该时区的"墙上时间"格式化 date(YYYY-MM-DD HH24:00),
// 因此必须用同一时区解析,否则整体偏移一个时区(实测:此前传 timezone=UTC 再在 UI
// 端 toLocal,服务端实际按本地时区返回墙上时间 → 差 8h)。
//
// 整点偏移用 Etc/GMT∓H(tzdata / PG 都认;注意符号相反:Etc/GMT-8 表示 UTC+8);
// 半点偏移(印度等少数地区)回退 UTC,解析也用 UTC,由 UI 端 toLocal 兜底显示。
func localTrendZone() (string, *time.Location) {
	_, offset := time.Now().Zone() // 东向 UTC 的偏移秒数(UTC+8 = 28800)
	if offset%3600 == 0 {
		return fmt.Sprintf("Etc/GMT%+d", -offset/3600), time.FixedZone("qplocal", offset)
	}
	return "UTC", time.UTC
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
