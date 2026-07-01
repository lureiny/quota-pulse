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

// instGuard 是单实例三条同步流的在途标记(syncMu 保护)。
// steady↔forward 互斥(都动最新段);backward 独立可与二者并发(只填 maxTS 左侧,区间不重叠)。
type instGuard struct {
	steady   bool // 稳态增量在途
	forward  bool // 前向补空缺在途
	backward bool // 反向补历史在途
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

// gapThresh 返回 regime 门限:gap(=now-covered_to)超此值视为落后,走前向大页补。
func (p *Poller) gapThresh() time.Duration {
	return time.Duration(p.chart.GapThreshHours) * time.Hour
}

// syncInstance 是每拍的同步编排(每实例按 SyncMinSecs 节流)。按 covered_to=MAX(created_at)
// 判定 regime:
//   - 空实例(MAX==0):交给启动的反向 ensureBackfill 播种,本拍不做。
//   - 落后(gap>门限,冷启后/关机后):派前向 forwardDrain 由旧到新补最新段(内部 guard 防重入)。
//   - 追上(gap≤门限):走稳态小页增量。
func (p *Poller) syncInstance(ctx context.Context, b binding) {
	if p.usageDB == nil || !p.chart.Enabled {
		return
	}
	lf, ok := b.prov.(provider.UsageLogFetcher)
	if !ok {
		return
	}

	// 稳态节流(前向/反向有各自的 guard,不受此约束)。
	p.syncMu.Lock()
	last := p.lastSync[b.instance]
	if !last.IsZero() && time.Since(last) < time.Duration(p.chart.SyncMinSecs)*time.Second {
		p.syncMu.Unlock()
		return
	}
	p.lastSync[b.instance] = time.Now()
	p.syncMu.Unlock()

	maxTS := p.usageDB.MaxCreatedAt(b.instance)
	if maxTS == 0 {
		return // 空实例:反向 ensureBackfill 负责播种,前向/稳态都需已有覆盖右端
	}
	if time.Since(time.Unix(maxTS, 0)) > p.gapThresh() {
		go p.forwardDrain(ctx, b, lf) // 落后:前向补最新段(guard 防重入)
		return
	}

	p.steadySync(ctx, b, lf)
}

// steadySync 是稳态增量(流①):id 降序小页,追到游标即停,环比动态定 page_size。
func (p *Poller) steadySync(ctx context.Context, b binding, lf provider.UsageLogFetcher) {
	// steady↔forward 互斥。
	p.syncMu.Lock()
	g := p.guardFor(b.instance)
	if g.forward {
		p.syncMu.Unlock()
		return
	}
	g.steady = true
	p.syncMu.Unlock()
	defer func() {
		p.syncMu.Lock()
		p.guardFor(b.instance).steady = false
		p.syncMu.Unlock()
	}()

	sinceID := p.usageDB.LastID(b.instance)
	from := time.Now().Add(-p.gapThresh()) // 收窄查询窗口;终止仍只靠 straddle
	pageSize := p.steadyPageSize(b.instance)

	cctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	evs, err := lf.FetchUsageSince(cctx, sinceID, from, pageSize)
	cancel()
	if err != nil {
		return // 失败下拍再试,不影响快照
	}
	if err := p.usageDB.AddEvents(b.instance, evs); err != nil {
		return
	}
	p.noteSteadyCount(b.instance, len(evs)) // 环比:本周期新增量喂给下周期的 page_size
	p.usageDB.Evict(b.instance, time.Now().Add(-time.Duration(p.chart.RetentionHours)*time.Hour).Unix())
	// 稳态不动覆盖水位:W(下界)由反向补齐负责;covered_to 由新事件自然前移。
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

// forwardDrain 前向补空缺(流②):由旧到新 ASC 分块 drain [covered_to, now],直到追上门限
// 或 ctx 取消。每块落库后 maxTS 连续前移 → 无洞、可续补(重启从 MAX 续)。大页少请求。
func (p *Poller) forwardDrain(ctx context.Context, b binding, lf provider.UsageLogFetcher) {
	p.syncMu.Lock()
	g := p.guardFor(b.instance)
	if g.forward || g.steady { // 已在途,或稳态正跑(互斥)
		p.syncMu.Unlock()
		return
	}
	g.forward = true
	p.syncMu.Unlock()
	defer func() {
		p.syncMu.Lock()
		p.guardFor(b.instance).forward = false
		p.syncMu.Unlock()
	}()

	maxTS := p.usageDB.MaxCreatedAt(b.instance)
	if maxTS == 0 {
		return // 空实例交给反向 ensureBackfill 播种
	}
	now := time.Now()
	from := time.Unix(maxTS, 0)
	if floor := now.Add(-time.Duration(p.chart.RetentionHours) * time.Hour); from.Before(floor) {
		from = floor // 不补保留窗口之外(反正会被 Evict)
	}
	caughtUp := now.Add(-p.gapThresh())
	evictFloor := now.Add(-time.Duration(p.chart.RetentionHours) * time.Hour).Unix()

	// from 固定,只递进 page:ASC 逐页把 [from, now] 走一遍,每页各取一次(无重取、无卡天)。
	// 每块落库后 maxTS 连续前移;截断留最新段给下一块。追到门限内即交回稳态(id 游标接手,无洞)。
	for page := 1; ; {
		select {
		case <-ctx.Done():
			return
		default:
		}
		cctx, cancel := context.WithTimeout(ctx, 120*time.Second)
		evs, complete, maxSeen, nextPage, err := lf.FetchUsageWindowAsc(cctx, from, now, 1000, p.chart.RowBudget, page)
		cancel()
		if err != nil {
			return // 失败下拍再试
		}
		if err := p.usageDB.AddEvents(b.instance, evs); err != nil {
			return
		}
		p.usageDB.Evict(b.instance, evictFloor)
		if complete {
			return // 窗口抓全
		}
		if len(evs) == 0 {
			return // 防呆:非 complete 却空返回,停,避免空转
		}
		page = nextPage
		if !maxSeen.IsZero() && !maxSeen.Before(caughtUp) {
			return // 已翻到门限内:交回稳态(剩余最新段由稳态 id 游标接手,连续无洞)
		}
	}
}

// ensureBackfill 反向补历史(流③):启动时把覆盖下界 W 补到 now-RetentionHours(最多 30d)。
// 循环调用现成 Backfill(每次填 [target, W) 一段),直到 W 到达 30d 或无进展/ctx 取消。
// 冷启动(W=0)时它负责把整段最近 30d 播种进来(newest-first,近端先到、首屏快)。
func (p *Poller) ensureBackfill(ctx context.Context, instance string) {
	if p.usageDB == nil || !p.chart.Enabled {
		return
	}
	stalls := 0
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}
		target := time.Now().Add(-time.Duration(p.chart.RetentionHours) * time.Hour).Unix()
		before := p.usageDB.CoverageFrom(instance)
		if before > 0 && before <= target+3600 {
			return // 已覆盖到 ~30d(留 1h 容差)
		}
		p.Backfill(instance, p.chart.RetentionHours)
		if p.usageDB.CoverageFrom(instance) != before {
			stalls = 0
			continue // 有进展,继续补
		}
		// 无进展:可能真抓全/出错,也可能 guard 被 UI 按需回填占用 → 有限次退避重试再放弃。
		stalls++
		if stalls >= 5 {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(3 * time.Second):
		}
	}
}

// Backfill 按需把该实例的本地覆盖补齐到 now-hours(用户在图表上拉大跨度时触发)。
// 只抓缺口 [target, W)(W=当前覆盖水位),抓到哪就把 W 推到哪:抓全 → W=target;
// 被 pageCap 截断 → W=最老抓到的事件(诚实,不谎称覆盖)。每实例串行(在途即跳过)。
// 阻塞执行(含网络),调用方应在 goroutine 里跑。
func (p *Poller) Backfill(instance string, hours int) {
	if p.usageDB == nil || !p.chart.Enabled || hours <= 0 {
		return
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
		// 启动即后台把最近 30d 覆盖补齐(反向,只补缺口;冷启动则播种整段近端优先)。
		// 前向补空缺由 syncInstance 按 regime 触发(首个 pollOnce 即评估)。
		if p.usageDB != nil && p.chart.Enabled {
			if _, ok := bindings[i].prov.(provider.UsageLogFetcher); ok {
				go p.ensureBackfill(ctx, bindings[i].instance)
			}
		}
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
