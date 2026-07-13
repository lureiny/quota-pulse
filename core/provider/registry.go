package provider

import (
	"fmt"
	"sort"

	"github.com/lureiny/quota-pulse/core/config"
)

// Factory 由各 provider 包提供,用配置构造一个实例。
type Factory func(cfg config.ProviderConfig) (Provider, error)

var registry = map[string]Factory{}

// Register 注册一个 provider 类型。各 provider 包在 init() 中调用。
func Register(typ string, f Factory) {
	if typ == "" || f == nil {
		panic("provider.Register: empty type or nil factory")
	}
	if _, exists := registry[typ]; exists {
		panic(fmt.Sprintf("provider.Register: duplicate type %q", typ))
	}
	registry[typ] = f
}

// Build 按配置里的 type 构造 provider 实例。
func Build(cfg config.ProviderConfig) (Provider, error) {
	f, ok := registry[cfg.Type]
	if !ok {
		return nil, fmt.Errorf("unknown provider type %q (registered: %v)", cfg.Type, Registered())
	}
	return f(cfg)
}

// Registered 返回已注册的 provider 类型(排序后)。
func Registered() []string {
	out := make([]string, 0, len(registry))
	for k := range registry {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
