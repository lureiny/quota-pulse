package poller

import (
	"context"
	"strings"
	"sync"
	"time"

	"github.com/lureiny/quota-pulse/core/config"
	"github.com/lureiny/quota-pulse/core/model"
	"github.com/lureiny/quota-pulse/core/provider"
)

// trendMinInterval 是 trend(小时时序)的最小重取间隔。小时桶无需更细粒度,
// 故即便弹层打开、被动轮询提频到 10s,trend 仍每账户最多 ~1 次/分钟,
// 而图表每拍都从缓存取到数据 → 视觉"跟随刷新"、服务端负载有界。
const trendMinInterval = 60 * time.Second

// trendEntry 是一个账户的小时时序缓存(带采样时刻,用于节流)。
type trendEntry struct {
	at  time.Time
	pts []model.HourPoint
}

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

	chart      config.ChartConfig // 小时图表配置(是否取、回看多少小时)
	trendMu    sync.Mutex
	trendCache map[string]trendEntry // key=instance|accountID → 上次小时时序(节流用)

	mu      sync.Mutex
	ctx     context.Context // 运行期 ctx,供手动刷新使用
	cancel  context.CancelFunc
	running bool
}

func New(store *Store, onUpdate func([]model.AccountPulse)) *Poller {
	return &Poller{
		store:      store,
		onUpdate:   onUpdate,
		maxConc:    6,
		trendCache: make(map[string]trendEntry),
	}
}

// SetChart 配置小时图表(须在 Start 前调用)。Enabled=false 时完全不取 trend。
func (p *Poller) SetChart(c config.ChartConfig) { p.chart = c }

// attachTrend 在 chart 开启且 provider 支持 trend 时,按 trendMinInterval 节流拉取/
// 复用单账户小时时序,挂到 pulse.Hourly。拉取失败则复用上次缓存(若有),不丢图。
func (p *Poller) attachTrend(ctx context.Context, b binding, acc model.Account, pulse *model.AccountPulse) {
	if !p.chart.Enabled {
		return
	}
	tf, ok := b.prov.(provider.TrendFetcher)
	if !ok {
		return
	}
	k := key(b.instance, acc.ID)

	p.trendMu.Lock()
	ent, cached := p.trendCache[k]
	p.trendMu.Unlock()
	if cached && time.Since(ent.at) < trendMinInterval {
		pulse.Hourly = ent.pts // 新鲜,直接复用
		return
	}

	cctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	pts, err := tf.FetchTrend(cctx, acc, p.chart.RangeHours)
	cancel()
	if err != nil {
		if cached {
			pulse.Hourly = ent.pts // 失败保留上次,图不闪空
		}
		return
	}

	p.trendMu.Lock()
	p.trendCache[k] = trendEntry{at: time.Now(), pts: pts}
	p.trendMu.Unlock()
	pulse.Hourly = pts
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
		p.attachTrend(ctx, b, acc, &pulse)
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
			p.attachTrend(ctx, b, acc, &pulse)
			p.store.Put(pulse)
		}(acc)
	}
	wg.Wait()

	if p.onUpdate != nil {
		p.onUpdate(p.store.Snapshot())
	}
}
