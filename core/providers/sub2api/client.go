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
