package usage

import (
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
	acc := seriesByKey(st.QuerySeries("inst", "account", 0))
	if a, ok := acc["2"]; !ok || a.Name != "Claude美区" {
		t.Fatalf("account series: %+v", acc)
	}
	if p := acc["2"].Points; len(p) != 2 || p[0].Input != 120 || p[0].Total != 195 || p[1].Input != 7 {
		t.Errorf("account 2 points: %+v", acc["2"].Points)
	}

	// 按 api_key:序列 3(kc-a,14:00 合并)与 9(kc-b,15:00)。
	keys := seriesByKey(st.QuerySeries("inst", "api_key", 0))
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
	models := seriesByKey(st.QuerySeries("inst", "model", 0))
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
	if got := seriesByKey(st.QuerySeries("inst", "account", 0))["2"].Points[0].Input; got != 120 {
		t.Errorf("dup re-counted: input=%d want 120", got)
	}

	// since 过滤 + Evict 早于 15:00。
	cut := time.Date(2026, 6, 19, 15, 0, 0, 0, loc).Unix()
	if p := seriesByKey(st.QuerySeries("inst", "account", cut))["2"].Points; len(p) != 1 || p[0].Input != 7 {
		t.Errorf("since 15:00: %+v", p)
	}
	st.Evict("inst", cut)
	if p := seriesByKey(st.QuerySeries("inst", "account", 0))["2"].Points; len(p) != 1 || p[0].Input != 7 {
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
