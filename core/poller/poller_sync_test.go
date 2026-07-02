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

// logProv 实现 Provider + UsageLogFetcher(合并后两法),可编程响应并计数。
type logProv struct {
	accounts []model.Account
	mu       sync.Mutex
	sinceN   int // FetchUsageSince 调用次数(增量流A)
	winN     int // FetchUsageWindow 调用次数(首拍播种 / 反向流B)
	since    func(sinceID int64) []model.UsageEvent
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

// 首拍(LastID==0):按时间播种 [now-12h, now],写 last_id 与覆盖水位 W;不走 id 游标。
func TestFirstRunSeedsWindowAndCoverage(t *testing.T) {
	fp := &logProv{}
	p, db := newSyncPoller(t, fp)
	fp.window = func(from, to time.Time) ([]model.UsageEvent, bool) {
		return []model.UsageEvent{evt(7, time.Now().Add(-3*time.Hour))}, true // 抓全
	}
	p.sync(context.Background(), p.bindings[0], fp)

	if fp.winN != 1 {
		t.Fatalf("首拍应走时间播种(FetchUsageWindow),winN=%d want 1", fp.winN)
	}
	if fp.sinceN != 0 {
		t.Errorf("首拍不该走 id 游标,sinceN=%d want 0", fp.sinceN)
	}
	if db.LastID("inst") != 7 {
		t.Errorf("首拍应写 last_id=7,got %d", db.LastID("inst"))
	}
	// W 应 ≈ now-12h(BackfillHours 默认 12,抓全 → W=seedFrom)。
	wantW := time.Now().Add(-12 * time.Hour).Unix()
	if w := db.CoverageFrom("inst"); w == 0 || abs(w-wantW) > 5 {
		t.Errorf("首拍覆盖水位 W=%d want≈%d(now-12h)", w, wantW)
	}
}

// 关键回归:已播种(LastID>0)且最新事件很旧(3h 前,原设计会判「落后」走 1000 前向重扫),
// 现在只走 id 游标一次小请求,绝不再触发时间窗/1000 大页重扫。
func TestCursorNoRescanWhenNewestEventOld(t *testing.T) {
	fp := &logProv{}
	p, db := newSyncPoller(t, fp)
	// 播一条 3h 前的事件:LastID=10、MAX=now-3h(旧)。
	if err := db.AddEvents("inst", []model.UsageEvent{evt(10, time.Now().Add(-3*time.Hour))}); err != nil {
		t.Fatal(err)
	}
	fp.since = func(sinceID int64) []model.UsageEvent { return nil } // 上游无新数据

	p.sync(context.Background(), p.bindings[0], fp)

	if fp.sinceN != 1 {
		t.Fatalf("应走 id 游标增量一次,sinceN=%d want 1", fp.sinceN)
	}
	if fp.winN != 0 {
		t.Fatalf("空闲不该重扫时间窗/1000 大页,winN=%d want 0(空转 bug 回归)", fp.winN)
	}
}

// 已播种:id 游标增量并入新行、喂环比;增量流不动覆盖水位 W。
func TestCursorMergesNewAndKeepsCoverage(t *testing.T) {
	fp := &logProv{}
	p, db := newSyncPoller(t, fp)
	if err := db.AddEvents("inst", []model.UsageEvent{evt(10, time.Now().Add(-5*time.Minute))}); err != nil {
		t.Fatal(err)
	}
	fp.since = func(sinceID int64) []model.UsageEvent {
		return []model.UsageEvent{evt(11, time.Now().Add(-1*time.Minute))}
	}
	p.sync(context.Background(), p.bindings[0], fp)

	if fp.sinceN != 1 {
		t.Fatalf("sinceN=%d want 1", fp.sinceN)
	}
	if db.LastID("inst") != 11 {
		t.Errorf("lastID=%d want 11", db.LastID("inst"))
	}
	if p.lastNew["inst"] != 1 {
		t.Errorf("环比未记录本周期新增:lastNew=%d want 1", p.lastNew["inst"])
	}
	// 增量流不得写覆盖水位(未做反向补齐 → W 仍 0)。
	if w := db.CoverageFrom("inst"); w != 0 {
		t.Errorf("增量流谎报覆盖:W=%d want 0", w)
	}
}

// 反向流B 门槛:未播种(LastID==0)时不跑,交给流A 先播种;已播种后才补。
func TestBackfillGatedUntilSeeded(t *testing.T) {
	fp := &logProv{}
	p, db := newSyncPoller(t, fp)
	fp.window = func(from, to time.Time) ([]model.UsageEvent, bool) {
		return []model.UsageEvent{evt(1, time.Now().Add(-2*time.Hour))}, true
	}

	// 未播种:Backfill 应被门槛拦下。
	p.Backfill("inst", 168)
	if fp.winN != 0 {
		t.Fatalf("未播种时反向流不该跑,winN=%d want 0", fp.winN)
	}

	// 播种后(LastID>0):Backfill 正常跑。
	if err := db.AddEvents("inst", []model.UsageEvent{evt(5, time.Now().Add(-1*time.Hour))}); err != nil {
		t.Fatal(err)
	}
	p.Backfill("inst", 168)
	if fp.winN < 1 {
		t.Fatalf("已播种后反向流应跑,winN=%d want>=1", fp.winN)
	}
	if db.CoverageFrom("inst") == 0 {
		t.Error("反向补齐后应写覆盖水位 W")
	}
}

// 同流重入保护:syncing 在途时 sync 直接返回,不重复拉取。
func TestSyncGuardPreventsReentry(t *testing.T) {
	fp := &logProv{}
	p, _ := newSyncPoller(t, fp)
	p.syncMu.Lock()
	p.guardFor("inst").syncing = true
	p.syncMu.Unlock()

	p.sync(context.Background(), p.bindings[0], fp)
	if fp.sinceN != 0 || fp.winN != 0 {
		t.Errorf("在途时不该拉取,sinceN=%d winN=%d want 0/0", fp.sinceN, fp.winN)
	}
}

func abs(x int64) int64 {
	if x < 0 {
		return -x
	}
	return x
}
