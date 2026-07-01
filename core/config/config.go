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

// ChartConfig 控制每站点小时级用量图。数据来自 /admin/usage 原始日志,
// 经 core/usage 按「账户×本地小时」聚合进本地 SQLite(增量、跨重启保留)。
type ChartConfig struct {
	Enabled    bool `json:"enabled"`     // 是否拉取并展示小时序列(关闭则零额外请求、不开库)
	RangeHours int  `json:"range_hours"` // UI 读取/展示的小时窗口(UI 再按 chartRange 裁剪)

	// 以下为采集/存储调参(一般留空走默认):
	DBPath         string  `json:"db_path,omitempty"`          // 空=os.UserConfigDir()/quota-pulse/usage.db
	BackfillHours  int     `json:"backfill_hours,omitempty"`   // 冷启动回填窗口(默认 24=1d;更大跨度按需补齐)
	RetentionHours int     `json:"retention_hours,omitempty"`  // 本地保留窗口(默认 744=31d,给 30d 视图留边)
	SyncMinSecs    int     `json:"sync_min_secs,omitempty"`    // 每实例同步最小间隔(默认 60s)
	PageCap        int     `json:"page_cap,omitempty"`         // 反向回填翻页上限(默认 20 页×1000 行)
	RowBudget      int     `json:"row_budget,omitempty"`       // 前向补空缺单块行预算(默认 5000)
	GapThreshHours int     `json:"gap_thresh_hours,omitempty"` // regime 门限:gap 超此值走前向大页补(默认 2h)
	PageMargin     float64 `json:"page_margin,omitempty"`      // 稳态动态页 = 上周期新增×margin(默认 2.0)
}

const chartMaxRangeHours = 168 // 7d,上限防误配拉太宽

func (c ChartConfig) withDefaults() ChartConfig {
	if c.RangeHours <= 0 {
		c.RangeHours = 24
	}
	if c.RangeHours > chartMaxRangeHours {
		c.RangeHours = chartMaxRangeHours
	}
	if c.BackfillHours <= 0 {
		c.BackfillHours = 24
	}
	if c.RetentionHours <= 0 {
		c.RetentionHours = 744
	}
	if c.SyncMinSecs <= 0 {
		c.SyncMinSecs = 60
	}
	if c.PageCap <= 0 {
		c.PageCap = 20
	}
	if c.RowBudget <= 0 {
		c.RowBudget = 5000
	}
	if c.GapThreshHours <= 0 {
		c.GapThreshHours = 2
	}
	if c.PageMargin <= 0 {
		c.PageMargin = 2.0
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
