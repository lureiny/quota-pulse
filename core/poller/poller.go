package poller

import (
	"context"
	"math"
	"strings"
	"sync"
	"time"

	"github.com/lureiny/quota-pulse/core/config"
	"github.com/lureiny/quota-pulse/core/model"
	"github.com/lureiny/quota-pulse/core/provider"
	"github.com/lureiny/quota-pulse/core/usage"
)

// binding 把一个 provider 实例与它的调度器绑定。
type binding struct {
	prov     provider.Provider
	sched    *Scheduler
	instance string // 实例显示名,盖到每个 pulse 上用于区分/分组
}

// instGuard 是单实例两条同步流的在途标记(syncMu 保护)。
// A(增量)与 B(反向补历史)区间不重叠(A 补 id>LastID 的最新段、B 补 W 左侧的更早段),
// 可并发;各自的 guard 仅防同流重入(单周期可能 >SyncMinSecs)。
type instGuard struct {
	syncing  bool // 增量流A 在途
	backward bool // 反向补历史流B 在途
}

// Poller 周期性拉取所有 provider 的所有账户用量。
type Poller struct {
	store    *Store
	onUpdate func([]model.AccountPulse)
	maxConc  int

	bindings []binding

	chart    config.ChartConfig // 小时图表配置
	usageDB  *usage.Store       // 本地原始事件库(nil=关闭/开库失败,降级不展示图)
	syncMu   sync.Mutex
	lastSync map[string]time.Time  // instance → 上次同步时刻(稳态每实例节流)
	guard    map[string]*instGuard // instance → 三条流的在途标记(见 instGuard)
	lastNew  map[string]int        // instance → 上周期稳态新增行数(环比,动态定 page_size)

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
		lastSync: make(map[string]time.Time),
		guard:    make(map[string]*instGuard),
		lastNew:  make(map[string]int),
	}
}

// guardFor 取(必要时建)某实例的在途标记。调用方须持 syncMu。
func (p *Poller) guardFor(instance string) *instGuard {
	g := p.guard[instance]
	if g == nil {
		g = &instGuard{}
		p.guard[instance] = g
	}
	return g
}

// SetChart 配置小时图表与本地库(须在 Start 前调用)。usageDB=nil 或 Enabled=false
// 时完全不同步、不展示图。
func (p *Poller) SetChart(c config.ChartConfig, db *usage.Store) {
	p.chart = c
	p.usageDB = db
}

// syncInstance 是每拍的同步编排(每实例按 SyncMinSecs 节流)。只驱动增量流A;
// 反向补历史流B 独立、由 UI 按需触发(见 Backfill)。
func (p *Poller) syncInstance(ctx context.Context, b binding) {
	if p.usageDB == nil || !p.chart.Enabled {
		return
	}
	lf, ok := b.prov.(provider.UsageLogFetcher)
	if !ok {
		return
	}

	// 每实例节流(流B 有各自 guard,不受此约束)。
	p.syncMu.Lock()
	last := p.lastSync[b.instance]
	if !last.IsZero() && time.Since(last) < time.Duration(p.chart.SyncMinSecs)*time.Second {
		p.syncMu.Unlock()
		return
	}
	p.lastSync[b.instance] = time.Now()
	p.syncMu.Unlock()

	p.sync(ctx, b, lf)
}

// sync 是增量流A(合并了原「稳态①」与「前向补空缺②」)。自驱周期、纯 id 游标、不按时间截断:
//   - 首拍(LastID==0,完全首次运行、本地零进度):按时间播种 [now-SeedHours, now](SeedHours=
//     BackfillHours,默认 12h),同时写 last_id 与覆盖水位 W(唯一同时写二者的地方)。
//   - 已播种(LastID>0):按 id 降序拉 id>LastID 的全部新行,straddle 到游标即停;查询左界压到
//     now-RetentionHours 仅作扫描下限(不作终止)→ 单次补齐有界在 30d。空闲时一页即追到游标、
//     只发 1 次小请求(消除原前向流按 MAX 判落后而无限重扫的空转 bug)。
//
// 单周期原子:一次性收齐再落库(要么全成、要么下拍重来),天然无洞。W 不再由 MAX 派生。
func (p *Poller) sync(ctx context.Context, b binding, lf provider.UsageLogFetcher) {
	// 防同流重入(单周期大积压可能 >SyncMinSecs)。
	p.syncMu.Lock()
	g := p.guardFor(b.instance)
	if g.syncing {
		p.syncMu.Unlock()
		return
	}
	g.syncing = true
	p.syncMu.Unlock()
	defer func() {
		p.syncMu.Lock()
		p.guardFor(b.instance).syncing = false
		p.syncMu.Unlock()
	}()

	evictFloor := time.Now().Add(-time.Duration(p.chart.RetentionHours) * time.Hour).Unix()

	if p.usageDB.LastID(b.instance) == 0 {
		// 首拍时间播种:[now-SeedHours, now]。
		seedFrom := time.Now().Add(-time.Duration(p.chart.BackfillHours) * time.Hour)
		if floor := time.Unix(evictFloor, 0); seedFrom.Before(floor) {
			seedFrom = floor
		}
		cctx, cancel := context.WithTimeout(ctx, 120*time.Second)
		evs, complete, err := lf.FetchUsageWindow(cctx, seedFrom, time.Now(), p.chart.PageCap)
		cancel()
		if err != nil {
			return
		}
		if err := p.usageDB.AddEvents(b.instance, evs); err != nil {
			return
		}
		// 写覆盖水位 W:抓全 → W=seedFrom;被 pageCap 截断 → W=最老抓到的事件(诚实,不谎报)。
		w := seedFrom.Unix()
		if !complete && len(evs) > 0 {
			oldest := evs[0].CreatedAt
			for _, e := range evs {
				if e.CreatedAt.Before(oldest) {
					oldest = e.CreatedAt
				}
			}
			w = oldest.Unix()
		}
		p.usageDB.NoteCoverage(b.instance, w)
		p.noteSteadyCount(b.instance, len(evs))
		p.usageDB.Evict(b.instance, evictFloor)
		return
	}

	// 已播种:id 游标增量。from 仅作扫描下限(30d),终止靠 straddle。
	sinceID := p.usageDB.LastID(b.instance)
	from := time.Now().Add(-time.Duration(p.chart.RetentionHours) * time.Hour)
	pageSize := p.steadyPageSize(b.instance)

	cctx, cancel := context.WithTimeout(ctx, 120*time.Second)
	evs, err := lf.FetchUsageSince(cctx, sinceID, from, pageSize)
	cancel()
	if err != nil {
		return // 失败下拍再试,不影响快照
	}
	if err := p.usageDB.AddEvents(b.instance, evs); err != nil {
		return
	}
	p.noteSteadyCount(b.instance, len(evs)) // 环比:本周期新增量喂给下周期的 page_size
	p.usageDB.Evict(b.instance, evictFloor)
	// 增量流不动 W:W 由首拍写一次、之后仅反向流B 维护。
}

// steadyPageSize 环比动态定下一周期每页行数 = round(上周期新增 × margin),夹到 [1,1000]。
// 上周期 0 条(或无记录)→ 落到 1(用户要求:空闲期用最小页低成本探测新数据)。
func (p *Poller) steadyPageSize(instance string) int {
	p.syncMu.Lock()
	n := p.lastNew[instance]
	p.syncMu.Unlock()
	size := int(math.Round(float64(n) * p.chart.PageMargin))
	if size < 1 {
		size = 1
	}
	if size > 1000 {
		size = 1000
	}
	return size
}

// noteSteadyCount 记录本周期稳态新增行数,供下周期 steadyPageSize 环比估算。
func (p *Poller) noteSteadyCount(instance string, n int) {
	p.syncMu.Lock()
	p.lastNew[instance] = n
	p.syncMu.Unlock()
}

// Backfill 反向补历史(流B):按需把该实例的本地覆盖补齐到 now-hours(用户在图表上拉大跨度时触发)。
// 只抓缺口 [target, W)(W=当前覆盖水位),抓到哪就把 W 推到哪:抓全 → W=target;
// 被 pageCap 截断 → W=最老抓到的事件(诚实,不谎称覆盖)。每实例串行(在途即跳过)。
// 阻塞执行(含网络),调用方应在 goroutine 里跑。
//
// 门槛:仅在增量流A 已播种(LastID>0)后才补。首次运行时本地零进度,交给流A 先播种
// (它同时写 last_id 与 W);此前不补,避免「首拍播种」与「反向补历史」并发导致区间重叠/重复。
// 无需锁二者:流A 认 last_id、流B 认 W,首拍后职责不重叠。
func (p *Poller) Backfill(instance string, hours int) {
	if p.usageDB == nil || !p.chart.Enabled || hours <= 0 {
		return
	}
	if p.usageDB.LastID(instance) == 0 {
		return // 尚未播种:等流A 首拍
	}

	p.syncMu.Lock()
	g := p.guardFor(instance)
	if g.backward {
		p.syncMu.Unlock()
		return
	}
	g.backward = true
	p.syncMu.Unlock()
	defer func() {
		p.syncMu.Lock()
		p.guardFor(instance).backward = false
		p.syncMu.Unlock()
	}()

	now := time.Now()
	target := now.Add(-time.Duration(hours) * time.Hour)
	// 不补保留窗口之外:再早也会被 Evict,补了白补。
	if floor := now.Add(-time.Duration(p.chart.RetentionHours) * time.Hour); target.Before(floor) {
		target = floor
	}
	// 已覆盖到 target 则无需补。
	to := now
	if w := p.usageDB.CoverageFrom(instance); w > 0 {
		if !target.Before(time.Unix(w, 0)) {
			return
		}
		to = time.Unix(w, 0) // 只补缺口左半段 [target, W)
	}

	p.mu.Lock()
	ctx := p.ctx
	var lf provider.UsageLogFetcher
	for i := range p.bindings {
		if p.bindings[i].instance == instance {
			lf, _ = p.bindings[i].prov.(provider.UsageLogFetcher)
			break
		}
	}
	p.mu.Unlock()
	if ctx == nil || lf == nil {
		return
	}

	cctx, cancel := context.WithTimeout(ctx, 120*time.Second)
	evs, complete, err := lf.FetchUsageWindow(cctx, target, to, p.chart.PageCap)
	cancel()
	if err != nil {
		return
	}
	if err := p.usageDB.AddEvents(instance, evs); err != nil {
		return
	}
	newW := target.Unix()
	if !complete && len(evs) > 0 {
		oldest := evs[0].CreatedAt
		for _, e := range evs {
			if e.CreatedAt.Before(oldest) {
				oldest = e.CreatedAt
			}
		}
		newW = oldest.Unix() // 没抓到 target:覆盖只到最老抓到的事件
	}
	p.usageDB.NoteCoverage(instance, newW)
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
		// 不再启动即全量补 30d:首拍由增量流A 播种最近 SeedHours,更早历史由 UI 按需触发反向流B。
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

	// 并发同步本地小时库(节流;不阻塞快照,图表在本拍或下拍从库读出)。
	go p.syncInstance(ctx, b)

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
