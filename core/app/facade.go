// Package app 是核心门面。桥接层(FFI / gomobile)与任何宿主只跟 App 打交道,
// 不直接触碰 provider / poller 细节。
package app

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"

	"github.com/lureiny/quota-pulse/core/config"
	"github.com/lureiny/quota-pulse/core/model"
	"github.com/lureiny/quota-pulse/core/poller"
	"github.com/lureiny/quota-pulse/core/provider"

	// 副作用导入:触发各 provider 在 init() 中自注册。
	// 未来新增平台只需在此加一行 _ import。
	_ "github.com/lureiny/quota-pulse/core/providers/sub2api"
)

// App 持有配置、快照存储与轮询器。
type App struct {
	cfg   config.Config
	store *poller.Store
	poll  *poller.Poller

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
	a.poll.SetChart(a.cfg.Chart)

	used := map[string]bool{}
	for i, pc := range a.cfg.Providers {
		prov, err := provider.Build(pc)
		if err != nil {
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

// Stop 停止轮询。
func (a *App) Stop() { a.poll.Stop() }

// Refresh 触发一次强制回源。
func (a *App) Refresh(accountID string) { a.poll.Refresh(accountID) }

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
