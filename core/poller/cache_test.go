package poller

import (
	"testing"

	"github.com/lureiny/quota-pulse/core/model"
)

// 不同实例的同号账户不能互相覆盖(多 sub2api 的核心正确性)。
func TestStoreKeepsSameAccountIDAcrossInstances(t *testing.T) {
	s := NewStore()
	s.Put(model.AccountPulse{Instance: "A", AccountID: "40", Name: "a40"})
	s.Put(model.AccountPulse{Instance: "B", AccountID: "40", Name: "b40"})

	if got := len(s.Snapshot()); got != 2 {
		t.Fatalf("snapshot len = %d, want 2(实例不应串号)", got)
	}

	// 同实例同号 → 覆盖,不新增。
	s.Put(model.AccountPulse{Instance: "A", AccountID: "40", Name: "a40-updated"})
	snap := s.Snapshot()
	if len(snap) != 2 {
		t.Fatalf("覆盖后 len = %d, want 2", len(snap))
	}

	// 排序:先按 Instance(A 在 B 前)。
	if snap[0].Instance != "A" || snap[1].Instance != "B" {
		t.Errorf("排序 = %s,%s, want A,B", snap[0].Instance, snap[1].Instance)
	}
	if snap[0].Name != "a40-updated" {
		t.Errorf("同实例同号未覆盖:%s", snap[0].Name)
	}
}

// 防回退:被动轮询返回的"空窗口 + ok + 无错误"不应把已有好数据抹空;
// 但真正的异常状态(banned 等)即便无窗口也要写入。
func TestStorePutDoesNotRegressGoodDataToEmpty(t *testing.T) {
	s := NewStore()
	s.Put(model.AccountPulse{
		Instance: "A", AccountID: "40", Name: "a40", Status: model.StatusOK,
		Meters: []model.Meter{{ID: "five_hour", Label: "5h"}},
	})

	// 被动空数据(meters 空 + ok + 无 error)→ 不覆盖好数据。
	s.Put(model.AccountPulse{Instance: "A", AccountID: "40", Name: "a40", Status: model.StatusOK})
	snap := s.Snapshot()
	if len(snap) != 1 || len(snap[0].Meters) != 1 {
		t.Fatalf("空数据覆盖了好数据:meters=%d, want 1", len(snap[0].Meters))
	}

	// 异常状态(banned)即便无窗口也要写入(账号封禁是有意义的变化)。
	s.Put(model.AccountPulse{Instance: "A", AccountID: "40", Name: "a40", Status: model.StatusBanned})
	if snap = s.Snapshot(); snap[0].Status != model.StatusBanned {
		t.Fatalf("有意义的异常状态被挡掉:status=%q, want banned", snap[0].Status)
	}
}
