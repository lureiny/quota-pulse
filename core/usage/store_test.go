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
