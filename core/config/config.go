// Package config 定义 quota-pulse 的运行配置(纯数据,零外部依赖)。
package config

import (
	"encoding/json"
	"fmt"
	"os"
	"time"
)

// Config 是顶层配置:可同时监控多个 provider 实例。
type Config struct {
	Providers []ProviderConfig `json:"providers"`
	Chart     ChartConfig      `json:"chart"` // 主面板小时用量图表
}

// ChartConfig 控制每站点小时级用量堆叠柱状图。
type ChartConfig struct {
	Enabled    bool `json:"enabled"`     // 是否拉取并展示小时时序(关闭则零额外请求)
	RangeHours int  `json:"range_hours"` // 回看小时数(决定 trend 拉取窗口)
}

const chartMaxRangeHours = 168 // 7d,上限防误配拉太宽

func (c ChartConfig) withDefaults() ChartConfig {
	if c.RangeHours <= 0 {
		c.RangeHours = 24
	}
	if c.RangeHours > chartMaxRangeHours {
		c.RangeHours = chartMaxRangeHours
	}
	return c
}

// ProviderConfig 描述一个 provider 实例(一个后台 + 一份鉴权 + 轮询策略)。
type ProviderConfig struct {
	Type     string          `json:"type"`     // sub2api / oneapi / newapi
	Name     string          `json:"name"`     // 展示名
	BaseURL  string          `json:"base_url"` //
	APIKey   string          `json:"api_key"`  // 支持 ${ENV} 展开
	Accounts AccountSelector `json:"accounts"` // 选哪些账户
	Poll     PollConfig      `json:"poll"`     //
}

// AccountSelector 决定监控哪些账户:优先用显式 IDs,否则用 Filter。
type AccountSelector struct {
	IDs    []string          `json:"ids,omitempty"`    // 显式账户 id
	Filter map[string]string `json:"filter,omitempty"` // 如 {"status":"active","platform":"openai"}
}

// PollConfig 是轮询节奏。
type PollConfig struct {
	PassiveInterval Duration `json:"passive_interval"` // 便宜轮询(被动缓存,不回源)
	ActiveInterval  Duration `json:"active_interval"`  // 稀疏回源(刷新上游)
}

func (p PollConfig) withDefaults() PollConfig {
	if p.PassiveInterval <= 0 {
		p.PassiveInterval = Duration(60 * time.Second)
	}
	// ActiveInterval <= 0 表示关闭自动强制回源(默认即关:周期性回源有明显自动化特征)。
	// 不再兜底成 10m;手动刷新(Poller.Refresh)仍会强制回源,不受此影响。
	if p.ActiveInterval < 0 {
		p.ActiveInterval = 0
	}
	return p
}

// Normalized 返回一份填好默认值的副本。
func (c Config) Normalized() Config {
	out := c
	out.Providers = append([]ProviderConfig(nil), c.Providers...)
	for i := range out.Providers {
		out.Providers[i].Poll = out.Providers[i].Poll.withDefaults()
	}
	out.Chart = out.Chart.withDefaults()
	return out
}

// Load 从 JSON 文件读取配置。
func Load(path string) (Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return Config{}, err
	}
	return Parse(raw)
}

// Parse 解析 JSON 字节,并展开 api_key 中的 ${ENV}。
func Parse(raw []byte) (Config, error) {
	var c Config
	if err := json.Unmarshal(raw, &c); err != nil {
		return Config{}, fmt.Errorf("parse config: %w", err)
	}
	for i := range c.Providers {
		c.Providers[i].APIKey = os.ExpandEnv(c.Providers[i].APIKey)
	}
	return c.Normalized(), nil
}

// Duration 让 time.Duration 能以 "60s" / "10m" 字符串出现在 JSON 中,
// 同时兼容裸数字(纳秒)。
type Duration time.Duration

// D 返回底层 time.Duration。
func (d Duration) D() time.Duration { return time.Duration(d) }

func (d Duration) MarshalJSON() ([]byte, error) {
	return json.Marshal(time.Duration(d).String())
}

func (d *Duration) UnmarshalJSON(b []byte) error {
	var v any
	if err := json.Unmarshal(b, &v); err != nil {
		return err
	}
	switch x := v.(type) {
	case float64:
		*d = Duration(time.Duration(x))
	case string:
		dur, err := time.ParseDuration(x)
		if err != nil {
			return fmt.Errorf("invalid duration %q: %w", x, err)
		}
		*d = Duration(dur)
	default:
		return fmt.Errorf("invalid duration: %v", v)
	}
	return nil
}
