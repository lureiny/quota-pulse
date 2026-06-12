package poller

import (
	"context"
	"strings"
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
	ctx     context.Context // 运行期 ctx,供手动刷新使用
	cancel  context.CancelFunc
	running bool
}

func New(store *Store, onUpdate func([]model.AccountPulse)) *Poller {
	return &Poller{
		store:    store,
		onUpdate: onUpdate,
		maxConc:  6,
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
	p.ctx = ctx
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

// Refresh 触发强制回源。key="" 全部;"instance|" 整个实例;"instance|accountID" 单个账户。
func (p *Poller) Refresh(key string) {
	p.mu.Lock()
	ctx := p.ctx
	bindings := append([]binding(nil), p.bindings...)
	p.mu.Unlock()
	if ctx == nil {
		return // 未启动
	}

	if key == "" {
		for i := range bindings {
			go p.pollOnce(ctx, bindings[i], provider.FetchOptions{Fresh: true})
		}
		return
	}

	inst, accID, ok := splitKey(key)
	if !ok {
		return
	}
	for i := range bindings {
		if bindings[i].instance == inst {
			b := bindings[i]
			if accID == "" {
				go p.pollOnce(ctx, b, provider.FetchOptions{Fresh: true}) // 整个实例
			} else {
				go p.refreshOne(ctx, b, accID) // 单个账户
			}
			return
		}
	}
}

func splitKey(key string) (instance, accountID string, ok bool) {
	i := strings.IndexByte(key, '|')
	if i < 0 {
		return "", "", false
	}
	return key[:i], key[i+1:], true
}

// refreshOne 只强制回源单个账户。
func (p *Poller) refreshOne(ctx context.Context, b binding, accountID string) {
	accounts, err := b.prov.ListAccounts(ctx)
	if err != nil {
		return
	}
	for _, acc := range accounts {
		if acc.ID != accountID {
			continue
		}
		cctx, cancel := context.WithTimeout(ctx, 20*time.Second)
		pulse, err := b.prov.FetchUsage(cctx, acc, provider.FetchOptions{Fresh: true})
		cancel()
		if err != nil {
			return // 失败保留上次成功
		}
		pulse.Instance = b.instance
		if pulse.UpdatedAt.IsZero() {
			pulse.UpdatedAt = time.Now()
		}
		p.store.Put(pulse)
		if p.onUpdate != nil {
			p.onUpdate(p.store.Snapshot())
		}
		return
	}
}

func (p *Poller) loop(ctx context.Context, b binding) {
	// 启动首次始终强制回源一次,加载全部账户:被动缓存对"冷账户"常为空,否则首屏会
	// 缺账户(只显示已有缓存的少数)。这是一次性加载、非周期性,不构成自动化特征;
	// 是否"周期性"回源仍由 active 开关控制(默认关 → 之后只走被动缓存)。
	p.pollOnce(ctx, b, provider.FetchOptions{Fresh: true})

	timer := time.NewTimer(b.sched.NextInterval())
	defer timer.Stop()

	lastActive := time.Now()

	for {
		select {
		case <-ctx.Done():
			return

		case <-timer.C:
			if !b.sched.Paused() {
				// active<=0:关闭周期性自动回源,本拍只走被动缓存(Fresh=false)。
				active := b.sched.ActiveInterval()
				fresh := active > 0 && time.Since(lastActive) >= active
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
				// 拉取失败:保留上一次成功的数据,不覆盖、不展示错误。
				return
			}
			pulse.Instance = b.instance
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
