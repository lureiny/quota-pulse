package sub2api

import (
	"encoding/json"
	"testing"

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

// TestToPulseFableWindow 锁住 7d Fable(7d_oi)窗口:与 sonnet 同级映射成一个 meter,
// id=seven_day_fable、label="7d Fable",utilization/resets 正确透传;不带 window_stats 时无 detail。
func TestToPulseFableWindow(t *testing.T) {
	raw := `{
	  "source": "passive",
	  "five_hour":        {"utilization": 10.0},
	  "seven_day":        {"utilization": 20.0},
	  "seven_day_sonnet": {"utilization": 30.0},
	  "seven_day_fable":  {"utilization": 88.0, "remaining_seconds": 7200,
	                       "resets_at": "2026-07-10T00:00:00Z"}
	}`
	var u usageInfo
	if err := json.Unmarshal([]byte(raw), &u); err != nil {
		t.Fatal(err)
	}
	p := toPulse(model.Account{ID: "1", Platform: "claude"}, u)

	var fable *model.Meter
	for i := range p.Meters {
		if p.Meters[i].ID == "seven_day_fable" {
			fable = &p.Meters[i]
			break
		}
	}
	if fable == nil {
		t.Fatalf("no seven_day_fable meter; got %d meters", len(p.Meters))
	}
	if fable.Label != "7d Fable" {
		t.Errorf("label = %q, want %q", fable.Label, "7d Fable")
	}
	if fable.Kind != model.KindRollingWindow {
		t.Errorf("kind = %q, want rolling_window", fable.Kind)
	}
	if fable.Utilization == nil || *fable.Utilization < 0.87 || *fable.Utilization > 0.89 {
		t.Errorf("utilization = %v, want ~0.88", fable.Utilization)
	}
	if fable.RemainingSecs == nil || *fable.RemainingSecs != 7200 {
		t.Errorf("remaining = %v, want 7200", fable.RemainingSecs)
	}
	if fable.ResetsAt == nil {
		t.Error("resets_at not carried through")
	}
	if fable.Detail != "" {
		t.Errorf("detail = %q, want empty (no window_stats)", fable.Detail)
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
