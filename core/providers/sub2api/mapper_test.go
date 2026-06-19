package sub2api

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/lureiny/quota-pulse/core/model"
)

func TestToPulseRollingWindows(t *testing.T) {
	raw := `{
	  "source": "passive",
	  "five_hour": {"utilization": 42.5, "remaining_seconds": 3600,
	                "window_stats": {"tokens": 1500000, "cost": 3.4}},
	  "seven_day": {"utilization": 12.0, "remaining_seconds": 86400},
	  "subscription_tier": "PRO"
	}`
	var u usageInfo
	if err := json.Unmarshal([]byte(raw), &u); err != nil {
		t.Fatal(err)
	}

	acc := model.Account{ID: "40", Name: "acc40", Platform: "claude"}
	p := toPulse(acc, u)

	if p.Tier != "PRO" {
		t.Errorf("tier = %q, want PRO", p.Tier)
	}
	if p.Provider != providerType {
		t.Errorf("provider = %q", p.Provider)
	}
	if len(p.Meters) != 2 {
		t.Fatalf("meters = %d, want 2", len(p.Meters))
	}

	m := p.Meters[0]
	if m.ID != "five_hour" || m.Kind != model.KindRollingWindow {
		t.Errorf("meter0 = %+v", m)
	}
	if m.Utilization == nil || *m.Utilization < 0.42 || *m.Utilization > 0.43 {
		t.Errorf("utilization = %v, want ~0.425", m.Utilization)
	}
	if m.RemainingSecs == nil || *m.RemainingSecs != 3600 {
		t.Errorf("remaining = %v, want 3600", m.RemainingSecs)
	}
	if m.Detail == "" {
		t.Error("want detail with tokens/cost")
	}
	if p.Status != model.StatusOK {
		t.Errorf("status = %q, want ok", p.Status)
	}
}

func TestToHourPoints(t *testing.T) {
	raw := `{
	  "granularity": "hour",
	  "trend": [
	    {"date": "2026-06-19 13:00", "input_tokens": 100, "output_tokens": 50,
	     "cache_creation_tokens": 10, "cache_read_tokens": 5, "total_tokens": 165},
	    {"date": "2026-06-19 14:00", "input_tokens": 200, "output_tokens": 80,
	     "cache_creation_tokens": 0, "cache_read_tokens": 20, "total_tokens": 300},
	    {"date": "bad-date", "input_tokens": 999, "total_tokens": 999}
	  ]
	}`
	var r trendResp
	if err := json.Unmarshal([]byte(raw), &r); err != nil {
		t.Fatal(err)
	}

	pts := toHourPoints(r, time.UTC)
	if len(pts) != 2 { // 第三条 date 无法解析,应被跳过
		t.Fatalf("points = %d, want 2 (bad date dropped)", len(pts))
	}

	p0 := pts[0]
	if p0.Hour.UTC().Hour() != 13 || p0.Hour.Location() != time.UTC {
		t.Errorf("p0.Hour = %v, want 13:00 UTC", p0.Hour)
	}
	if p0.Input != 100 || p0.Output != 50 || p0.CacheCreate != 10 || p0.CacheRead != 5 || p0.Total != 165 {
		t.Errorf("p0 tokens = %+v", p0)
	}
	if pts[1].Total != 300 || pts[1].CacheRead != 20 {
		t.Errorf("p1 = %+v", pts[1])
	}
}

func TestMapStatus(t *testing.T) {
	if s := mapStatus(usageInfo{IsForbidden: true}, nil); s != model.StatusForbidden {
		t.Errorf("forbidden -> %q", s)
	}
	if s := mapStatus(usageInfo{NeedsReauth: true}, nil); s != model.StatusNeedsReauth {
		t.Errorf("needs_reauth -> %q", s)
	}

	full := 1.0
	warn := 0.85
	rl := mapStatus(usageInfo{}, []model.Meter{{Utilization: &full}})
	if rl != model.StatusRateLimited {
		t.Errorf("full window -> %q, want rate_limited", rl)
	}
	w := mapStatus(usageInfo{}, []model.Meter{{Utilization: &warn}})
	if w != model.StatusWarning {
		t.Errorf("85%% window -> %q, want warning", w)
	}
}
