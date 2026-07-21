// Package app 是核心门面。桥接层(FFI / gomobile)与任何宿主只跟 App 打交道,
// 不直接触碰 provider / poller 细节。
package app

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/lureiny/quota-pulse/core/config"
	"github.com/lureiny/quota-pulse/core/model"
	"github.com/lureiny/quota-pulse/core/netstat"
	"github.com/lureiny/quota-pulse/core/poller"
	"github.com/lureiny/quota-pulse/core/provider"
	"github.com/lureiny/quota-pulse/core/usage"

	// 副作用导入:触发各 provider 在 init() 中自注册。
	// 未来新增平台只需在此加一行 _ import。
	_ "github.com/lureiny/quota-pulse/core/providers/sub2api"
)

// App 持有配置、快照存储与轮询器。
type App struct {
	cfg     config.Config
	store   *poller.Store
	poll    *poller.Poller
	usageDB *usage.Store // 小时聚合库(nil=图表关闭/开库失败)

	mu      sync.Mutex
	subs    []func(string) // 订阅者(收到 JSON 快照)
	scheds  []*poller.Scheduler
	started bool
}

// New 用配置构建 App(不启动轮询)。
func New(cfg config.Config) (*App, error) {
	a := &App{
		cfg:   cfg.Normalized(),
		store: poller.NewStore(),
	}
	a.poll = poller.New(a.store, a.broadcast)
	// 小时图表:开启则打开本地 SQLite 库;开库失败则降级(图不展示,核心其余照常)。
	var db *usage.Store
	if a.cfg.Chart.Enabled {
		path := a.cfg.Chart.DBPath
		if path == "" {
			path = defaultDBPath()
		}
		if opened, err := usage.Open(path); err == nil {
			db = opened
			a.usageDB = db
		}
	}
	a.poll.SetChart(a.cfg.Chart, db)

	used := map[string]bool{}
	for i, pc := range a.cfg.Providers {
		prov, err := provider.Build(pc)
		if err != nil {
			if a.usageDB != nil {
				_ = a.usageDB.Close()
			}
			return nil, err
		}
		// 计算唯一实例名:优先配置名 → provider 显示名 → 序号;重名自动加后缀。
		base := pc.Name
		if base == "" {
			base = prov.DisplayName()
		}
		if base == "" {
			base = fmt.Sprintf("provider-%d", i+1)
		}
		instance := base
		for k := 2; used[instance]; k++ {
			instance = fmt.Sprintf("%s (%d)", base, k)
		}
		used[instance] = true

		// 把去重后的实例名回填给 provider(供调试采样按实例区分读流量)。
		if ls, ok := prov.(provider.LabelSetter); ok {
			ls.SetLabel(instance)
		}

		sched := poller.NewScheduler(pc.Poll)
		a.poll.AddProvider(prov, sched, instance)
		a.scheds = append(a.scheds, sched)
	}
	return a, nil
}

// NewFromJSON 供桥接层使用:从 JSON 配置字符串构建。
func NewFromJSON(configJSON string) (*App, error) {
	cfg, err := config.Parse([]byte(configJSON))
	if err != nil {
		return nil, err
	}
	return New(cfg)
}

// Start 启动轮询。
func (a *App) Start(ctx context.Context) {
	a.mu.Lock()
	if a.started {
		a.mu.Unlock()
		return
	}
	a.started = true
	a.mu.Unlock()
	a.poll.Start(ctx)
}

// Stop 停止轮询并关闭本地库。
func (a *App) Stop() {
	a.poll.Stop()
	if a.usageDB != nil {
		_ = a.usageDB.Close()
	}
}

// defaultDBPath 返回小时聚合库的默认路径(随系统:macOS Application Support /
// Windows %AppData%);取不到则退回临时目录。
func defaultDBPath() string {
	dir, err := os.UserConfigDir()
	if err != nil || dir == "" {
		dir = os.TempDir()
	}
	return filepath.Join(dir, "quota-pulse", "usage.db")
}

// Refresh 触发一次强制回源。
func (a *App) Refresh(accountID string) { a.poll.Refresh(accountID) }

// PollOnce 对全部 provider 执行一轮强制回源并等待完成。主要供 qpctl 的 -once
// 模式使用;桌面宿主仍应使用 Start + Refresh 的异步模型。
func (a *App) PollOnce(ctx context.Context) {
	a.poll.PollOnce(ctx, provider.FetchOptions{Fresh: true})
}

// Snapshot 返回当前所有账户脉搏。
func (a *App) Snapshot() []model.AccountPulse { return a.store.Snapshot() }

// SnapshotJSON 返回 JSON,供 FFI 字符串边界使用。
func (a *App) SnapshotJSON() string {
	b, err := json.Marshal(a.store.Snapshot())
	if err != nil {
		return "[]"
	}
	return string(b)
}

// chartResp 是图表取数的返回体:序列 + 覆盖水位,供 UI 区分「真没有数据」与「本地尚未
// 覆盖到这么早」(后者画灰色未采集带 + 触发按需补齐)。
type chartResp struct {
	Series        []model.Series `json:"series"`
	CoverageFrom  int64          `json:"coverageFrom"`  // 本地完整覆盖的最早时刻(unix 秒)
	RequestedFrom int64          `json:"requestedFrom"` // 本次请求的左界 now-hours(unix 秒)
}

// ChartSeriesJSON 按 dimension(account/api_key/model/user/group)聚合 instance 最近
// hours 小时的用量,返回 chartResp 的 JSON。库未开则返回空壳。
func (a *App) ChartSeriesJSON(instance, dimension string, hours int) string {
	empty := `{"series":[],"coverageFrom":0,"requestedFrom":0}`
	if a.usageDB == nil {
		return empty
	}
	if hours <= 0 {
		hours = a.cfg.Chart.RangeHours
	}
	now := time.Now()
	reqFrom := now.Add(-time.Duration(hours) * time.Hour).Unix()

	// 覆盖水位:非 KeepAll 时 clamp 到保留窗口下限(更早的迟早被 Evict,不算覆盖);
	// KeepAll(不淘汰)时如实上报,否则 >31d 的历史会被误标未覆盖。从未同步则记 now。
	cov := a.usageDB.CoverageFrom(instance)
	if cov == 0 {
		cov = now.Unix()
	} else if !a.cfg.Chart.KeepAll {
		if floor := now.Add(-time.Duration(a.cfg.Chart.RetentionHours) * time.Hour).Unix(); cov < floor {
			cov = floor
		}
	}

	series, err := a.usageDB.QuerySeries(instance, dimension, reqFrom)
	if err != nil {
		return "" // FFI 约定:空串=取数失败;有覆盖的空 series 才是真空数据
	}
	b, err := json.Marshal(chartResp{
		Series:        series,
		CoverageFrom:  cov,
		RequestedFrom: reqFrom,
	})
	if err != nil {
		return empty
	}
	return string(b)
}

// ChartDailySeriesJSON 同 ChartSeriesJSON,但按**本地日**桶聚合最近 days 天(供 GitHub 式
// 热力图)。reqFrom 用日对齐左界且必须是具体 days —— 绝不用 0/全时段,否则 coverageFrom<=reqFrom
// 的「补齐完成」判据永不成立、UI 永远显示补齐中。
func (a *App) ChartDailySeriesJSON(instance, dimension string, days int) string {
	empty := `{"series":[],"coverageFrom":0,"requestedFrom":0}`
	if a.usageDB == nil {
		return empty
	}
	if days <= 0 {
		days = 366
	}
	now := time.Now()
	// 日对齐左界:今天零点往前 (days-1) 天(本地时区,与 store.dayBucket 一致)。
	reqFrom := dailyRequestFrom(now, days, time.Local)

	cov := a.usageDB.CoverageFrom(instance)
	if cov == 0 {
		cov = now.Unix()
	} else if !a.cfg.Chart.KeepAll {
		if floor := now.Add(-time.Duration(a.cfg.Chart.RetentionHours) * time.Hour).Unix(); cov < floor {
			cov = floor
		}
	}

	series, err := a.usageDB.QueryDailySeries(instance, dimension, reqFrom)
	if err != nil {
		return ""
	}
	b, err := json.Marshal(chartResp{
		Series:        series,
		CoverageFrom:  cov,
		RequestedFrom: reqFrom,
	})
	if err != nil {
		return empty
	}
	return string(b)
}

// dailyRequestFrom 返回包含今天在内最近 days 个本地自然日的左界。
// 必须用 AddDate 而不是 days*86400:夏令时切换日可能是 23/25 小时。
func dailyRequestFrom(now time.Time, days int, loc *time.Location) int64 {
	l := now.In(loc)
	today := time.Date(l.Year(), l.Month(), l.Day(), 0, 0, 0, 0, loc)
	return today.AddDate(0, 0, -(days - 1)).Unix()
}

// coverageResp 是 CoverageJSON 的返回体:覆盖水位 + 全历史最早事件,供热力图画诚实进度与年份列表。
type coverageResp struct {
	CoverageFrom  int64 `json:"coverageFrom"`  // 本地完整覆盖的最早时刻(unix 秒;0=尚未覆盖)
	EarliestEvent int64 `json:"earliestEvent"` // 全历史最早事件(unix 秒;0=未知/无数据)
}

// CoverageJSON 返回该实例的覆盖水位与全历史最早事件,供热力图判断「已补齐到哪/还差多少」。
// earliestEvent 优先服务端最老锚点(异步缓存,未知先 0),兜底本地最早(随补拉渐早)。
func (a *App) CoverageJSON(instance string) string {
	empty := `{"coverageFrom":0,"earliestEvent":0}`
	if a.usageDB == nil {
		return empty
	}
	earliest := a.poll.EarliestAt(instance)
	if earliest == 0 {
		earliest = a.usageDB.MinCreatedAt(instance)
	}
	b, err := json.Marshal(coverageResp{
		CoverageFrom:  a.usageDB.CoverageFrom(instance),
		EarliestEvent: earliest,
	})
	if err != nil {
		return empty
	}
	return string(b)
}

// EnsureCoverage 触发按需回填:确保 instance 的本地覆盖延伸到 now-hours(异步、不阻塞)。
// 已覆盖或库未开则是廉价 no-op。UI 在切大跨度时调用;补齐进度由后续 ChartSeries 的
// coverageFrom 体现。
func (a *App) EnsureCoverage(instance string, hours int) {
	if a.usageDB == nil {
		return
	}
	if hours <= 0 {
		hours = a.cfg.Chart.RangeHours
	}
	go a.poll.Backfill(instance, hours)
}

// Subscribe 注册一个回调,每轮更新后收到 JSON 快照。
func (a *App) Subscribe(fn func(string)) {
	a.mu.Lock()
	a.subs = append(a.subs, fn)
	a.mu.Unlock()
}

// --- 系统信号:供桥接层把宿主状态喂给调度器(省电/实时感) ---

// SetPopoverOpen:弹层打开时提频,关闭时降频。
func (a *App) SetPopoverOpen(v bool) {
	for _, s := range a.scheds {
		s.SetPopoverOpen(v)
	}
}

// SetOnBattery:电池供电时降频。
func (a *App) SetOnBattery(v bool) {
	for _, s := range a.scheds {
		s.SetOnBattery(v)
	}
}

// SetAsleep:休眠/无网络时暂停轮询。
func (a *App) SetAsleep(v bool) {
	for _, s := range a.scheds {
		s.SetAsleep(v)
	}
}

// --- 调试:客户端读流量采样(core/netstat) ---

// DebugSet 开启/关闭采样。enabled=true 时重置缓冲并按上限开采;false 时停采(保留已采样本)。
// maxSamples/maxMemBytes <=0 走 netstat 默认值。
func (a *App) DebugSet(enabled bool, maxSamples int, maxMemBytes int64) {
	if enabled {
		netstat.Enable(maxSamples, maxMemBytes)
	} else {
		netstat.Disable()
	}
}

// DebugReportJSON 返回当前采样报告 JSON(无论开关状态均有效)。
func (a *App) DebugReportJSON() string { return string(netstat.Report()) }

// DebugReset 清空已采样本(保留开关与上限)。
func (a *App) DebugReset() { netstat.Reset() }

func (a *App) broadcast(snap []model.AccountPulse) {
	b, err := json.Marshal(snap)
	if err != nil {
		return
	}
	js := string(b)

	a.mu.Lock()
	subs := append([]func(string){}, a.subs...)
	a.mu.Unlock()

	for _, fn := range subs {
		fn(js)
	}
}
