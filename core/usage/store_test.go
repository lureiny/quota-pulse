package usage

import (
	"database/sql"
	"path/filepath"
	"testing"
	"time"

	"github.com/lureiny/quota-pulse/core/model"
)

func openTmp(t *testing.T) *Store {
	t.Helper()
	st, err := Open(filepath.Join(t.TempDir(), "usage.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { st.Close() })
	return st
}

func seriesByKey(ss []model.Series) map[string]model.Series {
	m := make(map[string]model.Series, len(ss))
	for _, s := range ss {
		m[s.Key] = s
	}
	return m
}

func mustSeries(t *testing.T, ss []model.Series, err error) []model.Series {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
	return ss
}

func mustHourly(t *testing.T, st *Store, instance, dimension string, since int64) []model.Series {
	t.Helper()
	ss, err := st.QuerySeries(instance, dimension, since)
	return mustSeries(t, ss, err)
}

func mustDaily(t *testing.T, st *Store, instance, dimension string, since int64) []model.Series {
	t.Helper()
	ss, err := st.QueryDailySeries(instance, dimension, since)
	return mustSeries(t, ss, err)
}

func ev(id int64, ts time.Time, acc, accName, key, keyName, model_ string, in, out, cc, cr int64) model.UsageEvent {
	return model.UsageEvent{
		ID: id, CreatedAt: ts, Input: in, Output: out, CacheCreate: cc, CacheRead: cr,
		Dims: map[string]string{
			"account": acc, "account_name": accName,
			"api_key": key, "api_key_name": keyName,
			"model": model_,
		},
	}
}

func TestStoreEventsQuerySeriesMultiDim(t *testing.T) {
	st := openTmp(t)
	mustOK := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	loc := time.Local
	h14a := time.Date(2026, 6, 19, 14, 5, 0, 0, loc)  // 14:00 桶
	h14b := time.Date(2026, 6, 19, 14, 50, 0, 0, loc) // 同 14:00 桶
	h15 := time.Date(2026, 6, 19, 15, 1, 0, 0, loc)   // 15:00 桶

	mustOK(st.AddEvents("inst", []model.UsageEvent{
		ev(1, h14a, "2", "Claude美区", "3", "kc-a", "opus", 100, 50, 10, 5),
		ev(2, h14b, "2", "Claude美区", "3", "kc-a", "opus", 20, 10, 0, 0),
		ev(3, h15, "2", "Claude美区", "9", "kc-b", "sonnet", 7, 0, 0, 0),
	}))
	if st.LastID("inst") != 3 {
		t.Fatalf("LastID=%d want 3", st.LastID("inst"))
	}
	if st.SyncedAt("inst") <= 0 {
		t.Error("SyncedAt should advance after AddEvents")
	}

	// 按 account:账户 2 两个小时桶(14:00 合并 id1+id2;15:00 id3)。
	acc := seriesByKey(mustHourly(t, st, "inst", "account", 0))
	if a, ok := acc["2"]; !ok || a.Name != "Claude美区" {
		t.Fatalf("account series: %+v", acc)
	}
	if p := acc["2"].Points; len(p) != 2 || p[0].Input != 120 || p[0].Total != 195 || p[1].Input != 7 {
		t.Errorf("account 2 points: %+v", acc["2"].Points)
	}

	// 按 api_key:序列 3(kc-a,14:00 合并)与 9(kc-b,15:00)。
	keys := seriesByKey(mustHourly(t, st, "inst", "api_key", 0))
	if len(keys) != 2 {
		t.Fatalf("api_key series=%d want 2", len(keys))
	}
	if keys["3"].Name != "kc-a" || len(keys["3"].Points) != 1 || keys["3"].Points[0].Input != 120 {
		t.Errorf("key 3: %+v", keys["3"])
	}
	if keys["9"].Name != "kc-b" || keys["9"].Points[0].Input != 7 {
		t.Errorf("key 9: %+v", keys["9"])
	}

	// 按 model:opus(14:00 合并)与 sonnet(15:00);model 维度键即名。
	models := seriesByKey(mustHourly(t, st, "inst", "model", 0))
	if models["opus"].Name != "opus" || len(models["opus"].Points) != 1 || models["opus"].Points[0].Input != 120 {
		t.Errorf("model opus: %+v", models["opus"])
	}
	if models["sonnet"].Points[0].Input != 7 {
		t.Errorf("model sonnet: %+v", models["sonnet"])
	}

	// 去重:重复 id 不重复计(INSERT OR IGNORE)。
	mustOK(st.AddEvents("inst", []model.UsageEvent{
		ev(1, h14a, "2", "Claude美区", "3", "kc-a", "opus", 100, 50, 10, 5),
	}))
	if got := seriesByKey(mustHourly(t, st, "inst", "account", 0))["2"].Points[0].Input; got != 120 {
		t.Errorf("dup re-counted: input=%d want 120", got)
	}

	// since 过滤 + Evict 早于 15:00。
	cut := time.Date(2026, 6, 19, 15, 0, 0, 0, loc).Unix()
	if p := seriesByKey(mustHourly(t, st, "inst", "account", cut))["2"].Points; len(p) != 1 || p[0].Input != 7 {
		t.Errorf("since 15:00: %+v", p)
	}
	st.Evict("inst", cut)
	if p := seriesByKey(mustHourly(t, st, "inst", "account", 0))["2"].Points; len(p) != 1 || p[0].Input != 7 {
		t.Errorf("after evict: %+v", p)
	}
}

func TestStoreCoverageWatermark(t *testing.T) {
	st := openTmp(t)
	if st.CoverageFrom("inst") != 0 {
		t.Fatal("初始覆盖水位应为 0")
	}
	// 先设一个较晚的水位(稳态近窗),再设更早的(冷启动/补齐)——只应向更早推进。
	st.NoteCoverage("inst", 2000)
	st.NoteCoverage("inst", 1000)
	if got := st.CoverageFrom("inst"); got != 1000 {
		t.Fatalf("水位应取 min=1000,得 %d", got)
	}
	// 再设更晚的不应抬高(稳态 now-2h 不能覆盖掉冷启动的更早水位)。
	st.NoteCoverage("inst", 1500)
	if got := st.CoverageFrom("inst"); got != 1000 {
		t.Fatalf("更晚的水位不应抬高,仍应 1000,得 %d", got)
	}
	// 无效值 no-op。
	st.NoteCoverage("inst", 0)
	if got := st.CoverageFrom("inst"); got != 1000 {
		t.Fatalf("0 应被忽略,仍应 1000,得 %d", got)
	}
	// 与 AddEvents 互不破坏:AddEvents 推进 last_id,不动 backfilled_from。
	loc := time.Local
	if err := st.AddEvents("inst", []model.UsageEvent{
		ev(5, time.Date(2026, 6, 19, 14, 5, 0, 0, loc), "2", "A", "3", "k", "opus", 1, 1, 0, 0),
	}); err != nil {
		t.Fatal(err)
	}
	if st.LastID("inst") != 5 {
		t.Fatalf("AddEvents 应推进 last_id=5,得 %d", st.LastID("inst"))
	}
	if got := st.CoverageFrom("inst"); got != 1000 {
		t.Fatalf("AddEvents 不应改动覆盖水位,仍应 1000,得 %d", got)
	}
}

func TestAddInitialEventsCommitsCursorAndCoverageAtomically(t *testing.T) {
	st := openTmp(t)
	stamp := time.Now().Add(-time.Hour)
	if err := st.AddInitialEvents("ok", []model.UsageEvent{
		ev(7, stamp, "1", "A", "", "", "m", 1, 0, 0, 0),
	}, stamp.Add(-time.Hour).Unix()); err != nil {
		t.Fatal(err)
	}
	if got := st.LastID("ok"); got != 7 {
		t.Fatalf("last_id=%d want 7", got)
	}
	if got := st.CoverageFrom("ok"); got != stamp.Add(-time.Hour).Unix() {
		t.Fatalf("coverage=%d want %d", got, stamp.Add(-time.Hour).Unix())
	}

	// 让 sync_state 写失败,验证同一事务内先插入的事件也被回滚。
	if _, err := st.db.Exec(`CREATE TRIGGER fail_initial BEFORE INSERT ON sync_state
WHEN NEW.instance='fail' BEGIN SELECT RAISE(ABORT, 'boom'); END;`); err != nil {
		t.Fatal(err)
	}
	if err := st.AddInitialEvents("fail", []model.UsageEvent{
		ev(9, stamp, "1", "A", "", "", "m", 1, 0, 0, 0),
	}, stamp.Add(-time.Hour).Unix()); err == nil {
		t.Fatal("expected transactional sync_state failure")
	}
	if got := st.MinCreatedAt("fail"); got != 0 {
		t.Fatalf("event survived failed initial transaction: min_created_at=%d", got)
	}
	if got := st.LastID("fail"); got != 0 {
		t.Fatalf("cursor survived failed initial transaction: last_id=%d", got)
	}
}

func TestAddInitialEventsEmptyBatchStillMarksCoverage(t *testing.T) {
	st := openTmp(t)
	w := time.Now().Add(-12 * time.Hour).Unix()
	if err := st.AddInitialEvents("empty", nil, w); err != nil {
		t.Fatal(err)
	}
	if got := st.LastID("empty"); got != 0 {
		t.Fatalf("last_id=%d want 0", got)
	}
	if got := st.CoverageFrom("empty"); got != w {
		t.Fatalf("coverage=%d want %d", got, w)
	}
}

func TestStoreEmptyAndLastID(t *testing.T) {
	st := openTmp(t)
	if st.LastID("x") != 0 {
		t.Error("empty LastID should be 0")
	}
	if err := st.AddEvents("x", nil); err != nil {
		t.Errorf("empty AddEvents: %v", err)
	}
	if st.LastID("x") != 0 {
		t.Error("empty AddEvents must not change LastID")
	}
}

func TestQuerySeriesReturnsDatabaseError(t *testing.T) {
	st := openTmp(t)
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := st.QuerySeries("inst", "account", 0); err == nil {
		t.Fatal("query on closed database was reported as a genuine empty series")
	}
}

// MaxCreatedAt = 派生的覆盖上界 covered_to:空实例 0;取最新;Evict 掉更老桶不影响。
func TestMaxCreatedAt(t *testing.T) {
	st := openTmp(t)
	if st.MaxCreatedAt("inst") != 0 {
		t.Errorf("空实例 MaxCreatedAt 应为 0")
	}
	t1 := time.Now().Add(-3 * time.Hour)
	t2 := time.Now().Add(-1 * time.Hour)
	if err := st.AddEvents("inst", []model.UsageEvent{
		ev(1, t1, "1", "", "", "", "m", 0, 0, 0, 0),
		ev(2, t2, "1", "", "", "", "m", 0, 0, 0, 0),
	}); err != nil {
		t.Fatal(err)
	}
	if got := st.MaxCreatedAt("inst"); got != t2.Unix() {
		t.Errorf("MaxCreatedAt=%d want %d(最新)", got, t2.Unix())
	}
	// Evict 掉最老桶,MAX 仍是 t2(前向覆盖右端不被中/老段清理动摇)。
	st.Evict("inst", t1.Add(30*time.Minute).Unix())
	if got := st.MaxCreatedAt("inst"); got != t2.Unix() {
		t.Errorf("Evict 后 MaxCreatedAt=%d want %d", got, t2.Unix())
	}
}

// QuerySeries 除 token 外还按维度/桶聚合 cost(花费与 token 不成正比,单独求和)。
func TestQuerySeriesAggregatesCost(t *testing.T) {
	st := openTmp(t)
	loc := time.Local
	h14a := time.Date(2026, 6, 19, 14, 5, 0, 0, loc)  // 14:00 桶
	h14b := time.Date(2026, 6, 19, 14, 40, 0, 0, loc) // 同 14:00 桶
	mk := func(id int64, ts time.Time, acc string, cost float64) model.UsageEvent {
		return model.UsageEvent{
			ID: id, CreatedAt: ts, Input: 10, Output: 5, Cost: cost,
			Dims: map[string]string{"account": acc, "account_name": "A" + acc},
		}
	}
	if err := st.AddEvents("inst", []model.UsageEvent{
		mk(1, h14a, "2", 1.25),
		mk(2, h14b, "2", 0.75), // 与 id1 同桶同账户 → cost 应合并为 2.0
		mk(3, h14a, "9", 0.50), // 另一账户,单独一序列
	}); err != nil {
		t.Fatal(err)
	}
	acc := seriesByKey(mustHourly(t, st, "inst", "account", 0))
	if p := acc["2"].Points; len(p) != 1 || p[0].Cost != 2.0 {
		t.Errorf("account 2 cost: %+v want 单桶 cost=2.0", p)
	}
	if p := acc["9"].Points; len(p) != 1 || p[0].Cost != 0.5 {
		t.Errorf("account 9 cost: %+v want 单桶 cost=0.5", p)
	}
	// token 侧不受影响:账户 2 两条各 15 token → 合计 30。
	if got := acc["2"].Points[0].Total; got != 30 {
		t.Errorf("token total=%d want 30(cost 聚合不动 token)", got)
	}
}

// QueryDailySeries 按**本地日**桶聚合:同一天不同小时合并、跨天分桶;token/cost/count 都聚合;
// 桶时间为当天零点;sinceUnix 过滤生效。
func TestQueryDailySeries(t *testing.T) {
	st := openTmp(t)
	loc := time.Local
	d19a := time.Date(2026, 6, 19, 9, 5, 0, 0, loc)   // 6/19 日桶
	d19b := time.Date(2026, 6, 19, 22, 40, 0, 0, loc) // 同 6/19 日桶(跨小时)
	d20 := time.Date(2026, 6, 20, 1, 0, 0, 0, loc)    // 6/20 日桶
	mk := func(id int64, ts time.Time, in, out int64, cost float64) model.UsageEvent {
		return model.UsageEvent{ID: id, CreatedAt: ts, Input: in, Output: out, Cost: cost,
			Dims: map[string]string{"account": "2", "account_name": "A"}}
	}
	if err := st.AddEvents("inst", []model.UsageEvent{
		mk(1, d19a, 100, 50, 1.0),
		mk(2, d19b, 20, 10, 0.5), // 与 id1 同日桶 → 合并
		mk(3, d20, 7, 0, 0.25),
	}); err != nil {
		t.Fatal(err)
	}

	acc := seriesByKey(mustDaily(t, st, "inst", "account", 0))
	s, ok := acc["2"]
	if !ok || len(s.Points) != 2 {
		t.Fatalf("daily series account 2: %+v", acc)
	}
	day19 := time.Date(2026, 6, 19, 0, 0, 0, 0, loc)
	if p := s.Points[0]; p.Input != 120 || p.Total != 180 || p.Count != 2 || p.Cost != 1.5 || !p.Hour.Equal(day19) {
		t.Errorf("6/19 日桶: %+v want in=120 total=180 count=2 cost=1.5 hour=%v", p, day19)
	}
	if p := s.Points[1]; p.Input != 7 || p.Count != 1 {
		t.Errorf("6/20 日桶: %+v want in=7 count=1", p)
	}

	// sinceUnix 过滤:只取 6/20 起。
	cut := time.Date(2026, 6, 20, 0, 0, 0, 0, loc).Unix()
	if p := seriesByKey(mustDaily(t, st, "inst", "account", cut))["2"].Points; len(p) != 1 || p[0].Input != 7 {
		t.Errorf("since 6/20: %+v", p)
	}
}

// v3→v4 迁移:老库无 day_local 列,Open 时就地补列 + 按 distinct 小时回填;
// 用 QueryDailySeries 分出两个日桶来证明回填成功(它按 day_local 聚合)。
func TestMigrateV3ToV4DayLocal(t *testing.T) {
	path := filepath.Join(t.TempDir(), "v3.db")
	loc := time.Local
	d19 := time.Date(2026, 6, 19, 9, 5, 0, 0, loc)
	d20 := time.Date(2026, 6, 20, 1, 0, 0, 0, loc)

	// 手搓 v3 形态:usage_events 无 day_local,user_version=3。
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`
CREATE TABLE usage_events(
  instance TEXT NOT NULL, id INTEGER NOT NULL, created_at INTEGER NOT NULL, hour_local INTEGER NOT NULL,
  input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0,
  cache_create INTEGER NOT NULL DEFAULT 0, cache_read INTEGER NOT NULL DEFAULT 0,
  cost REAL NOT NULL DEFAULT 0, dims TEXT NOT NULL DEFAULT '{}', PRIMARY KEY(instance,id));
CREATE TABLE sync_state(instance TEXT PRIMARY KEY, last_id INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0, backfilled_from INTEGER NOT NULL DEFAULT 0);
PRAGMA user_version=3;`); err != nil {
		t.Fatal(err)
	}
	for _, e := range []struct {
		id int64
		ts time.Time
	}{{1, d19}, {2, d20}} {
		if _, err := db.Exec(`INSERT INTO usage_events(instance,id,created_at,hour_local,input,dims) VALUES(?,?,?,?,?,?)`,
			"inst", e.id, e.ts.Unix(), hourBucket(e.ts), 10, `{"account":"2","account_name":"A"}`); err != nil {
			t.Fatal(err)
		}
	}
	db.Close()

	// Open 触发 v3→v4 迁移。
	st, err := Open(path)
	if err != nil {
		t.Fatalf("open(migrate): %v", err)
	}
	defer st.Close()

	acc := seriesByKey(mustDaily(t, st, "inst", "account", 0))
	if p := acc["2"].Points; len(p) != 2 {
		t.Fatalf("迁移后日桶数=%d want 2(day_local 未回填?): %+v", len(p), acc["2"])
	}
	// 新写入的事件也应有 day_local(走 AddEvents 路径)。
	if err := st.AddEvents("inst", []model.UsageEvent{
		{ID: 3, CreatedAt: d20.Add(2 * time.Hour), Input: 5, Dims: map[string]string{"account": "2", "account_name": "A"}},
	}); err != nil {
		t.Fatal(err)
	}
	if p := seriesByKey(mustDaily(t, st, "inst", "account", 0))["2"].Points; len(p) != 2 || p[1].Count != 2 {
		t.Errorf("迁移后新写入未并入日桶: %+v", p)
	}
}

// Evict 把覆盖下界 W 向前夹到保留下限(数据删了不能再谎报覆盖),且不被更早的 Evict 回拉。
func TestEvictClampsCoverage(t *testing.T) {
	st := openTmp(t)
	old := time.Now().Add(-40 * 24 * time.Hour).Unix() // W 声称覆盖到 40d 前
	st.NoteCoverage("inst", old)

	floor := time.Now().Add(-31 * 24 * time.Hour).Unix() // 保留下限 31d
	st.Evict("inst", floor)
	if got := st.CoverageFrom("inst"); got != floor {
		t.Errorf("Evict 后 W=%d want 夹到 floor %d", got, floor)
	}
	// 更早的 Evict 不应把 W 往回拉(只向前夹)。
	st.Evict("inst", time.Now().Add(-50*24*time.Hour).Unix())
	if got := st.CoverageFrom("inst"); got != floor {
		t.Errorf("更早 Evict 后 W=%d 不应回拉,want %d", got, floor)
	}
}

func TestEvictUsesExactEventTimeNotHourBucket(t *testing.T) {
	st := openTmp(t)
	loc := time.Local
	early := time.Date(2026, 7, 11, 14, 5, 0, 0, loc)
	late := time.Date(2026, 7, 11, 14, 50, 0, 0, loc)
	if err := st.AddEvents("inst", []model.UsageEvent{
		ev(1, early, "1", "A", "", "", "m", 10, 0, 0, 0),
		ev(2, late, "1", "A", "", "", "m", 20, 0, 0, 0),
	}); err != nil {
		t.Fatal(err)
	}

	st.Evict("inst", time.Date(2026, 7, 11, 14, 30, 0, 0, loc).Unix())
	points := seriesByKey(mustHourly(t, st, "inst", "account", 0))["1"].Points
	if len(points) != 1 || points[0].Input != 20 || points[0].Count != 1 {
		t.Fatalf("same-hour event after cutoff was evicted: %+v", points)
	}
}
