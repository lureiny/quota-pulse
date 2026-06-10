package poller

import (
	"context"
	"sync"
	"time"

	"github.com/lureiny/quota-pulse/core/model"
	"github.com/lureiny/quota-pulse/core/provider"
)

// binding 把一个 provider 实例与它的调度器绑定。
type binding struct {
	prov     provider.Provider
	sched    *Scheduler
	instance string // 实例显示名,盖到每个 pulse 上用于区分/分组
}

// Poller 周期性拉取所有 provider 的所有账户用量。
type Poller struct {
	store    *Store
	onUpdate func([]model.AccountPulse)
	maxConc  int

	bindings []binding

	mu      sync.Mutex
	cancel  context.CancelFunc
	running bool
	refresh chan string // 手动刷新触发(account id;当前实现为整体回源)
}

func New(store *Store, onUpdate func([]model.AccountPulse)) *Poller {
	return &Poller{
		store:    store,
		onUpdate: onUpdate,
		maxConc:  6,
		refresh:  make(chan string, 8),
	}
}

// AddProvider 注册一个 provider 与其调度器(须在 Start 前调用)。
// instance 为该实例的唯一显示名,会盖到它产出的每个 pulse 上。
func (p *Poller) AddProvider(prov provider.Provider, sched *Scheduler, instance string) {
	p.bindings = append(p.bindings, binding{prov: prov, sched: sched, instance: instance})
}

// Start 为每个 provider 起一个轮询 goroutine。
func (p *Poller) Start(ctx context.Context) {
	p.mu.Lock()
	if p.running {
		p.mu.Unlock()
		return
	}
	ctx, cancel := context.WithCancel(ctx)
	p.cancel = cancel
	p.running = true
	bindings := p.bindings
	p.mu.Unlock()

	for i := range bindings {
		go p.loop(ctx, bindings[i])
	}
}

// Stop 取消所有轮询。
func (p *Poller) Stop() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.cancel != nil {
		p.cancel()
	}
	p.running = false
}

// Refresh 触发一次强制回源(对所有 provider)。
func (p *Poller) Refresh(accountID string) {
	select {
	case p.refresh <- accountID:
	default: // 已有待处理刷新,丢弃以防积压
	}
}

func (p *Poller) loop(ctx context.Context, b binding) {
	// 启动即拉一次(便宜的被动读)
	p.pollOnce(ctx, b, provider.FetchOptions{Fresh: false})

	timer := time.NewTimer(b.sched.NextInterval())
	defer timer.Stop()

	lastActive := time.Now()

	for {
		select {
		case <-ctx.Done():
			return

		case <-p.refresh:
			p.pollOnce(ctx, b, provider.FetchOptions{Fresh: true})
			lastActive = time.Now()

		case <-timer.C:
			if !b.sched.Paused() {
				fresh := time.Since(lastActive) >= b.sched.ActiveInterval()
				if fresh {
					lastActive = time.Now()
				}
				p.pollOnce(ctx, b, provider.FetchOptions{Fresh: fresh})
			}
			timer.Reset(b.sched.NextInterval())
		}
	}
}

// pollOnce 拉取一个 provider 的全部账户,并发受限,结果写入 store。
func (p *Poller) pollOnce(ctx context.Context, b binding, opt provider.FetchOptions) {
	accounts, err := b.prov.ListAccounts(ctx)
	if err != nil {
		// 列表失败:本轮跳过,不退出循环(下一拍重试)。
		return
	}

	sem := make(chan struct{}, p.maxConc)
	var wg sync.WaitGroup
	for _, acc := range accounts {
		wg.Add(1)
		sem <- struct{}{}
		go func(acc model.Account) {
			defer wg.Done()
			defer func() { <-sem }()

			cctx, cancel := context.WithTimeout(ctx, 20*time.Second)
			defer cancel()

			pulse, err := b.prov.FetchUsage(cctx, acc, opt)
			if err != nil {
				pulse = model.AccountPulse{
					AccountID: acc.ID,
					Name:      acc.Name,
					Platform:  acc.Platform,
					Provider:  b.prov.Type(),
					Status:    model.StatusError,
					Error:     err.Error(),
				}
			}
			pulse.Instance = b.instance // 统一盖章(成功/失败两路都经过这里)
			if pulse.UpdatedAt.IsZero() {
				pulse.UpdatedAt = time.Now()
			}
			p.store.Put(pulse)
		}(acc)
	}
	wg.Wait()

	if p.onUpdate != nil {
		p.onUpdate(p.store.Snapshot())
	}
}
