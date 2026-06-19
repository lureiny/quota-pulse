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

func TestStoreAggregateIncrementSinceEvict(t *testing.T) {
	st := openTmp(t)
	loc := time.Local
	h14a := time.Date(2026, 6, 19, 14, 5, 0, 0, loc)  // 14:00 桶
	h14b := time.Date(2026, 6, 19, 14, 50, 0, 0, loc) // 同 14:00 桶
	h15 := time.Date(2026, 6, 19, 15, 1, 0, 0, loc)   // 15:00 桶

	if err := st.AddRows("inst", []model.UsageRow{
		{ID: 1, AccountID: "a", CreatedAt: h14a, Input: 100, Output: 50, CacheCreate: 10, CacheRead: 5},
		{ID: 2, AccountID: "a", CreatedAt: h14b, Input: 20, Output: 10},
		{ID: 3, AccountID: "b", CreatedAt: h15, Input: 7},
	}); err != nil {
		t.Fatal(err)
	}
	if got := st.LastID("inst"); got != 3 {
		t.Fatalf("LastID=%d want 3", got)
	}

	// 账户 a:两条都落 14:00 桶 → 合并为 1 个小时点,数值相加。
	pts := st.Query("inst", "a", 0)
	if len(pts) != 1 {
		t.Fatalf("a hours=%d want 1", len(pts))
	}
	if pts[0].Input != 120 || pts[0].Output != 60 || pts[0].CacheCreate != 10 ||
		pts[0].CacheRead != 5 || pts[0].Total != 195 {
		t.Errorf("a 14:00 = %+v", pts[0])
	}

	// 第二批:14:00 桶再增量(累加),并新增 15:00 桶。
	if err := st.AddRows("inst", []model.UsageRow{
		{ID: 4, AccountID: "a", CreatedAt: h14a, Input: 5},
		{ID: 5, AccountID: "a", CreatedAt: h15, Input: 3},
	}); err != nil {
		t.Fatal(err)
	}
	if got := st.LastID("inst"); got != 5 {
		t.Fatalf("LastID=%d want 5", got)
	}
	pts = st.Query("inst", "a", 0)
	if len(pts) != 2 {
		t.Fatalf("a hours=%d want 2", len(pts))
	}
	if pts[0].Input != 125 { // 120 + 5,累加而非覆盖
		t.Errorf("a 14:00 input=%d want 125", pts[0].Input)
	}
	if pts[1].Input != 3 {
		t.Errorf("a 15:00 input=%d want 3", pts[1].Input)
	}

	// since 过滤:只取 15:00 起。
	cut := time.Date(2026, 6, 19, 15, 0, 0, 0, loc).Unix()
	pts = st.Query("inst", "a", cut)
	if len(pts) != 1 || pts[0].Input != 3 {
		t.Errorf("since 15:00 = %+v", pts)
	}

	// Evict 早于 15:00 → 删掉 14:00 桶。
	st.Evict("inst", cut)
	pts = st.Query("inst", "a", 0)
	if len(pts) != 1 || pts[0].Input != 3 {
		t.Errorf("after evict = %+v", pts)
	}

	// 账户 b 独立。
	if pb := st.Query("inst", "b", 0); len(pb) != 1 || pb[0].Input != 7 {
		t.Errorf("b = %+v", pb)
	}
}

func TestStoreEmptyAndLastID(t *testing.T) {
	st := openTmp(t)
	if st.LastID("x") != 0 {
		t.Error("empty LastID should be 0")
	}
	if err := st.AddRows("x", nil); err != nil {
		t.Errorf("empty AddRows: %v", err)
	}
	if st.LastID("x") != 0 {
		t.Error("empty AddRows must not change LastID")
	}
}
