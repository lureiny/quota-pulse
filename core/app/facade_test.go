package app

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/lureiny/quota-pulse/core/config"
)

func TestNewFromJSONUnknownProvider(t *testing.T) {
	_, err := NewFromJSON(`{"providers":[{"type":"nope","base_url":"http://x"}]}`)
	if err == nil {
		t.Fatal("expected error for unknown provider type")
	}
}

func TestSnapshotEmpty(t *testing.T) {
	a, err := NewFromJSON(`{"providers":[
	  {"type":"sub2api","name":"t","base_url":"http://localhost:1/",
	   "poll":{"passive_interval":"60s","active_interval":"10m"}}
	]}`)
	if err != nil {
		t.Fatal(err)
	}
	if got := a.SnapshotJSON(); got != "[]" {
		t.Errorf("snapshot = %s, want []", got)
	}
}

func TestSetSignalsNoPanic(t *testing.T) {
	a, err := NewFromJSON(`{"providers":[{"type":"sub2api","base_url":"http://x"}]}`)
	if err != nil {
		t.Fatal(err)
	}
	a.SetPopoverOpen(true)
	a.SetOnBattery(true)
	a.SetAsleep(true) // 仅验证不 panic
}

func TestDailyRequestFromUsesCalendarDaysAcrossDST(t *testing.T) {
	loc, err := time.LoadLocation("America/New_York")
	if err != nil {
		t.Skipf("timezone database unavailable: %v", err)
	}
	// 2024-11-03 是回拨日(25 小时)。最近 3 个自然日应从 11-01 00:00 开始,
	// 而不是把 11-03 00:00 机械减去 48 小时得到偏一小时的边界。
	now := time.Date(2024, 11, 3, 12, 0, 0, 0, loc)
	want := time.Date(2024, 11, 1, 0, 0, 0, 0, loc).Unix()
	if got := dailyRequestFrom(now, 3, loc); got != want {
		t.Fatalf("requestFrom=%d (%s), want %d (%s)", got, time.Unix(got, 0).In(loc), want, time.Unix(want, 0).In(loc))
	}
}

func TestChartQueryErrorUsesFailureSentinel(t *testing.T) {
	a, err := New(config.Config{Chart: config.ChartConfig{
		Enabled: true,
		DBPath:  filepath.Join(t.TempDir(), "usage.db"),
	}})
	if err != nil {
		t.Fatal(err)
	}
	if a.usageDB == nil {
		t.Fatal("usage database did not open")
	}
	if err := a.usageDB.Close(); err != nil {
		t.Fatal(err)
	}
	if got := a.ChartSeriesJSON("inst", "account", 24); got != "" {
		t.Fatalf("chart query failure=%q, want empty-string failure sentinel", got)
	}
}
