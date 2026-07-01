package poller

import (
	"context"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/lureiny/quota-pulse/core/config"
	"github.com/lureiny/quota-pulse/core/model"
	"github.com/lureiny/quota-pulse/core/provider"
	"github.com/lureiny/quota-pulse/core/usage"
)

// logProv 实现 Provider + UsageLogFetcher,可编程各方法响应并计数(测三条同步流)。
type logProv struct {
	accounts []model.Account
	mu       sync.Mutex
	sinceN   int
	ascN     int
	winN     int
	since    func(sinceID int64) []model.UsageEvent
	asc      func(from, to time.Time, startPage int) ([]model.UsageEvent, bool, time.Time)
	window   func(from, to time.Time) ([]model.UsageEvent, bool)
}

func (f *logProv) Type() string                        { return "log" }
func (f *logProv) DisplayName() string                 { return "log" }
func (f *logProv) Capabilities() provider.Capabilities { return provider.Capabilities{} }
func (f *logProv) ListAccounts(context.Context) ([]model.Account, error) {
	return f.accounts, nil
}
func (f *logProv) FetchUsage(context.Context, model.Account, provider.FetchOptions) (model.AccountPulse, error) {
	return model.AccountPulse{}, nil
}
func (f *logProv) FetchUsageSince(_ context.Context, sinceID int64, _ time.Time, _ int) ([]model.UsageEvent, error) {
	f.mu.Lock()
	f.sinceN++
	f.mu.Unlock()
	if f.since != nil {
		return f.since(sinceID), nil
	}
	return nil, nil
}
func (f *logProv) FetchUsageWindow(_ context.Context, from, to time.Time, _ int) ([]model.UsageEvent, bool, error) {
	f.mu.Lock()
	f.winN++
	f.mu.Unlock()
	if f.window != nil {
		evs, c := f.window(from, to)
		return evs, c, nil
	}
	return nil, true, nil
}
func (f *logProv) FetchUsageWindowAsc(_ context.Context, from, to time.Time, _, _, startPage int) ([]model.UsageEvent, bool, time.Time, int, error) {
	f.mu.Lock()
	f.ascN++
	f.mu.Unlock()
	if f.asc != nil {
		evs, c, m := f.asc(from, to, startPage)
		return evs, c, m, startPage + 1, nil
	}
	return nil, true, time.Time{}, startPage + 1, nil
}

func evt(id int64, ts time.Time) model.UsageEvent {
	return model.UsageEvent{ID: id, CreatedAt: ts, Dims: map[string]string{"account": "1"}}
}

func newSyncPoller(t *testing.T, fp *logProv) (*Poller, *usage.Store) {
	t.Helper()
	db, err := usage.Open(filepath.Join(t.TempDir(), "u.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	p := New(NewStore(), nil)
	cfg := config.Config{Chart: config.ChartConfig{Enabled: true}}.Normalized().Chart
	p.SetChart(cfg, db)
	p.AddProvider(fp, NewScheduler(config.PollConfig{}), "inst")
	p.ctx = context.Background() // Backfill 需要运行期 ctx
	return p, db
}

// 环比动态页:上周期 0→1;n×margin;clamp 1000。
func TestSteadyPageSizeEnvelope(t *testing.T) {
	p := New(NewStore(), nil)
	p.SetChart(config.Config{Chart: config.ChartConfig{Enabled: true}}.Normalized().Chart, nil) // PageMargin=2

	if got := p.steadyPageSize("x"); got != 1 {
		t.Errorf("无历史 page=%d want 1", got)
	}
	p.noteSteadyCount("x", 50)
	if got := p.steadyPageSize("x"); got != 100 {
		t.Errorf("50×2 page=%d want 100", got)
	}
	p.noteSteadyCount("x", 600)
	if got := p.steadyPageSize("x"); got != 1000 {
		t.Errorf("clamp page=%d want 1000", got)
	}
	p.noteSteadyCount("x", 0)
	if got := p.steadyPageSize("x"); got != 1 {
		t.Errorf("上周期0→page=%d want 1", got)
	}
}

// 空实例:前向 drain 直接返回,不打接口。
func TestForwardDrainSkipsEmptyInstance(t *testing.T) {
	fp := &logProv{}
	p, _ := newSyncPoller(t, fp)
	p.forwardDrain(context.Background(), p.bindings[0], fp)
	if fp.ascN != 0 {
		t.Errorf("空实例不该调 asc,ascN=%d", fp.ascN)
	}
}

// 前向 drain:12h 空缺由旧到新补齐,事件入库、maxTS 前移、追上即停。
func TestForwardDrainFillsGap(t *testing.T) {
	fp := &logProv{}
	p, db := newSyncPoller(t, fp)
	old := time.Now().Add(-12 * time.Hour)
	if err := db.AddEvents("inst", []model.UsageEvent{evt(1, old)}); err != nil {
		t.Fatal(err)
	}
	recent := time.Now().Add(-20 * time.Minute) // 追上门限(2h)内
	fp.asc = func(from, to time.Time, _ int) ([]model.UsageEvent, bool, time.Time) {
		return []model.UsageEvent{evt(2, time.Now().Add(-1*time.Hour)), evt(3, recent)}, true, recent
	}
	p.forwardDrain(context.Background(), p.bindings[0], fp)

	if fp.ascN != 1 {
		t.Fatalf("ascN=%d want 1", fp.ascN)
	}
	if db.LastID("inst") != 3 {
		t.Errorf("lastID=%d want 3", db.LastID("inst"))
	}
	if mx := db.MaxCreatedAt("inst"); mx != recent.Unix() {
		t.Errorf("maxTS=%d want %d(前移到最新)", mx, recent.Unix())
	}
}

// 前向翻页续抓:单块 rowBudget 截断后,用 nextPage 从同一 from 续翻,不卡在同一天(修 HIGH-2)。
func TestForwardDrainPageContinuation(t *testing.T) {
	fp := &logProv{}
	p, db := newSyncPoller(t, fp)
	old := time.Now().Add(-6 * time.Hour)
	if err := db.AddEvents("inst", []model.UsageEvent{evt(1, old)}); err != nil {
		t.Fatal(err)
	}
	mid := time.Now().Add(-3 * time.Hour)
	recent := time.Now().Add(-10 * time.Minute)
	fp.asc = func(_, _ time.Time, startPage int) ([]model.UsageEvent, bool, time.Time) {
		if startPage == 1 { // 首块:截断(complete=false),maxSeen 仍落后门限
			return []model.UsageEvent{evt(2, old.Add(time.Hour)), evt(3, mid)}, false, mid
		}
		return []model.UsageEvent{evt(4, recent)}, true, recent // 续块:抓全
	}
	p.forwardDrain(context.Background(), p.bindings[0], fp)

	if fp.ascN != 2 {
		t.Fatalf("ascN=%d want 2(截断后应 nextPage 续翻,不卡天)", fp.ascN)
	}
	if db.LastID("inst") != 4 {
		t.Errorf("lastID=%d want 4(续块也入库)", db.LastID("inst"))
	}
}

// steady↔forward 互斥:前向在途时稳态跳过。
func TestSteadyYieldsWhenForwardInflight(t *testing.T) {
	fp := &logProv{}
	p, _ := newSyncPoller(t, fp)
	p.syncMu.Lock()
	p.guardFor("inst").forward = true
	p.syncMu.Unlock()

	p.steadySync(context.Background(), p.bindings[0], fp)
	if fp.sinceN != 0 {
		t.Errorf("前向在途时稳态不该拉取,sinceN=%d", fp.sinceN)
	}
}

// 反向补历史:冷启动把覆盖下界补到 ~30d(30d 内 complete → W 到 target)。
func TestEnsureBackfillReachesRetention(t *testing.T) {
	fp := &logProv{}
	p, db := newSyncPoller(t, fp)
	fp.window = func(from, to time.Time) ([]model.UsageEvent, bool) {
		return []model.UsageEvent{evt(1, time.Now().Add(-1*time.Hour))}, true // 一次抓全
	}
	p.ensureBackfill(context.Background(), "inst")

	if fp.winN < 1 {
		t.Fatalf("winN=%d want>=1", fp.winN)
	}
	w := db.CoverageFrom("inst")
	target := time.Now().Add(-744 * time.Hour).Unix()
	if !(w > 0 && w <= target+3600) {
		t.Errorf("覆盖下界 W=%d 未到 ~30d(target=%d)", w, target)
	}
}

// 稳态增量:追到游标即停,新增量喂给环比;不谎报覆盖水位(修既有 bug)。
func TestSteadyDoesNotOverclaimCoverage(t *testing.T) {
	fp := &logProv{}
	p, db := newSyncPoller(t, fp)
	// 先播一条近端事件,使 regime=CAUGHT_UP。
	if err := db.AddEvents("inst", []model.UsageEvent{evt(10, time.Now().Add(-5*time.Minute))}); err != nil {
		t.Fatal(err)
	}
	fp.since = func(sinceID int64) []model.UsageEvent {
		return []model.UsageEvent{evt(11, time.Now().Add(-1*time.Minute))}
	}
	p.steadySync(context.Background(), p.bindings[0], fp)

	if fp.sinceN != 1 {
		t.Fatalf("sinceN=%d want 1", fp.sinceN)
	}
	// 稳态不得把覆盖下界 W 抬到 from(now-2h);W 应仍为 0(未做反向补齐)。
	if w := db.CoverageFrom("inst"); w != 0 {
		t.Errorf("稳态谎报覆盖:W=%d want 0", w)
	}
	if p.lastNew["inst"] != 1 {
		t.Errorf("环比未记录本周期新增:lastNew=%d want 1", p.lastNew["inst"])
	}
}
