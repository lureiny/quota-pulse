package sub2api

import (
	"testing"
	"time"

	"github.com/lureiny/quota-pulse/core/model"
)

func TestDeriveAccountState_Primary(t *testing.T) {
	now := time.Date(2026, 7, 9, 12, 0, 0, 0, time.UTC)
	future := func(d time.Duration) *time.Time { u := now.Add(d); return &u }
	past := func(d time.Duration) *time.Time { u := now.Add(-d); return &u }
	f := func(v float64) *float64 { return &v }

	cases := []struct {
		name     string
		dto      accountDTO
		wantCode string
		wantSev  model.Severity
		wantRst  bool   // 期望 ResetsAt 非空
		wantRsn  string // 期望 Reason
	}{
		{
			name:     "active+schedulable → ok",
			dto:      accountDTO{Status: "active", Schedulable: true},
			wantCode: model.StateOK, wantSev: model.SeverityOK,
		},
		{
			name:     "inactive → inactive",
			dto:      accountDTO{Status: "inactive", Schedulable: true},
			wantCode: model.StateInactive, wantSev: model.SeverityNeutral,
		},
		{
			name:     "status=error → error+reason",
			dto:      accountDTO{Status: "error", Schedulable: true, ErrorMessage: "boom"},
			wantCode: model.StateError, wantSev: model.SeverityDanger, wantRsn: "boom",
		},
		{
			name:     "!schedulable → paused",
			dto:      accountDTO{Status: "active", Schedulable: false},
			wantCode: model.StatePaused, wantSev: model.SeverityNeutral,
		},
		{
			name:     "rate_limit_reset_at future → rate_limited",
			dto:      accountDTO{Status: "active", Schedulable: true, RateLimitResetAt: future(30 * time.Minute)},
			wantCode: model.StateRateLimited, wantSev: model.SeverityWarning, wantRst: true,
		},
		{
			name:     "rate_limit_reset_at past → ok (已解除)",
			dto:      accountDTO{Status: "active", Schedulable: true, RateLimitResetAt: past(30 * time.Minute)},
			wantCode: model.StateOK, wantSev: model.SeverityOK,
		},
		{
			name:     "overload_until future → overloaded",
			dto:      accountDTO{Status: "active", Schedulable: true, OverloadUntil: future(10 * time.Minute)},
			wantCode: model.StateOverloaded, wantSev: model.SeverityDanger, wantRst: true,
		},
		{
			name: "temp_unschedulable future → temp_unschedulable+reason",
			dto: accountDTO{Status: "active", Schedulable: true,
				TempUnschedulableUntil: future(5 * time.Minute), TempUnschedulableReason: "429 too many"},
			wantCode: model.StateTempUnschedulable, wantSev: model.SeverityWarning, wantRst: true, wantRsn: "429 too many",
		},
		{
			name: "quota total exceeded → quota_exceeded",
			dto: accountDTO{Status: "active", Schedulable: true,
				QuotaUsed: f(10), QuotaLimit: f(10)},
			wantCode: model.StateQuotaExceeded, wantSev: model.SeverityWarning,
		},
		{
			name: "quota daily exceeded → quota_exceeded",
			dto: accountDTO{Status: "active", Schedulable: true,
				QuotaDailyUsed: f(5), QuotaDailyLimit: f(4)},
			wantCode: model.StateQuotaExceeded, wantSev: model.SeverityWarning,
		},
		{
			name: "quota limit=0 不算超限 → ok",
			dto: accountDTO{Status: "active", Schedulable: true,
				QuotaUsed: f(5), QuotaLimit: f(0)},
			wantCode: model.StateOK, wantSev: model.SeverityOK,
		},
		// ---- 优先级 ----
		{
			name: "429 抢占 error+overload → rate_limited",
			dto: accountDTO{Status: "error", Schedulable: false, ErrorMessage: "boom",
				RateLimitResetAt: future(time.Hour), OverloadUntil: future(time.Hour)},
			wantCode: model.StateRateLimited, wantSev: model.SeverityWarning, wantRst: true,
		},
		{
			name: "529 抢占 error → overloaded",
			dto: accountDTO{Status: "error", Schedulable: true, ErrorMessage: "boom",
				OverloadUntil: future(time.Hour)},
			wantCode: model.StateOverloaded, wantSev: model.SeverityDanger, wantRst: true,
		},
		{
			name: "error 优先于 temp_unschedulable",
			dto: accountDTO{Status: "error", Schedulable: true, ErrorMessage: "boom",
				TempUnschedulableUntil: future(time.Hour)},
			wantCode: model.StateError, wantSev: model.SeverityDanger, wantRsn: "boom",
		},
		{
			name: "temp_unschedulable 优先于 inactive",
			dto: accountDTO{Status: "inactive", Schedulable: true,
				TempUnschedulableUntil: future(time.Hour), TempUnschedulableReason: "r"},
			wantCode: model.StateTempUnschedulable, wantSev: model.SeverityWarning, wantRst: true, wantRsn: "r",
		},
		{
			name: "inactive 优先于 quota/paused",
			dto: accountDTO{Status: "inactive", Schedulable: false,
				QuotaUsed: f(10), QuotaLimit: f(1)},
			wantCode: model.StateInactive, wantSev: model.SeverityNeutral,
		},
		{
			name: "quota 优先于 paused",
			dto: accountDTO{Status: "active", Schedulable: false,
				QuotaUsed: f(10), QuotaLimit: f(1)},
			wantCode: model.StateQuotaExceeded, wantSev: model.SeverityWarning,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			st := deriveAccountState(c.dto, now)
			if st == nil {
				t.Fatal("state 为 nil")
			}
			if st.Code != c.wantCode {
				t.Errorf("Code = %q, want %q", st.Code, c.wantCode)
			}
			if st.Severity != c.wantSev {
				t.Errorf("Severity = %q, want %q", st.Severity, c.wantSev)
			}
			if (st.ResetsAt != nil) != c.wantRst {
				t.Errorf("ResetsAt 非空 = %v, want %v", st.ResetsAt != nil, c.wantRst)
			}
			if st.Reason != c.wantRsn {
				t.Errorf("Reason = %q, want %q", st.Reason, c.wantRsn)
			}
		})
	}
}

func TestDeriveModelStates(t *testing.T) {
	now := time.Date(2026, 7, 9, 12, 0, 0, 0, time.UTC)
	fut := func(d time.Duration) *time.Time { u := now.Add(d); return &u }
	past := func(d time.Duration) *time.Time { u := now.Add(-d); return &u }
	mk := func(reset *time.Time) modelRateLimitDTO { return modelRateLimitDTO{RateLimitResetAt: reset} }

	t.Run("空 → nil", func(t *testing.T) {
		if got := deriveModelStates(accountDTO{}, now); got != nil {
			t.Errorf("want nil, got %v", got)
		}
	})

	t.Run("AICredits → credits_exhausted", func(t *testing.T) {
		a := accountDTO{Extra: accountExtraDTO{
			ModelRateLimits: map[string]modelRateLimitDTO{"AICredits": mk(fut(time.Hour))},
		}}
		got := deriveModelStates(a, now)
		if len(got) != 1 || got[0].Kind != model.ModelKindCreditsExhausted || got[0].Model != "AICredits" {
			t.Fatalf("got %+v", got)
		}
	})

	t.Run("overages 且积分未耗尽 → credits_active", func(t *testing.T) {
		a := accountDTO{Extra: accountExtraDTO{
			AllowOverages:   true,
			ModelRateLimits: map[string]modelRateLimitDTO{"claude-opus-4-8": mk(fut(time.Hour))},
		}}
		got := deriveModelStates(a, now)
		if len(got) != 1 || got[0].Kind != model.ModelKindCreditsActive {
			t.Fatalf("got %+v", got)
		}
	})

	t.Run("overages 但积分正耗尽(AICredits生效) → 普通模型仍 rate_limit", func(t *testing.T) {
		a := accountDTO{Extra: accountExtraDTO{
			AllowOverages: true,
			ModelRateLimits: map[string]modelRateLimitDTO{
				"AICredits":       mk(fut(time.Hour)),
				"claude-opus-4-8": mk(fut(time.Hour)),
			},
		}}
		got := deriveModelStates(a, now)
		// 排序后 AICredits 在前:credits_exhausted;opus:rate_limit(因 hasActiveAICredits)
		if len(got) != 2 {
			t.Fatalf("want 2, got %+v", got)
		}
		if got[0].Model != "AICredits" || got[0].Kind != model.ModelKindCreditsExhausted {
			t.Errorf("got[0]=%+v", got[0])
		}
		if got[1].Model != "claude-opus-4-8" || got[1].Kind != model.ModelKindRateLimit {
			t.Errorf("got[1]=%+v", got[1])
		}
	})

	t.Run("无 overages → 普通模型 rate_limit", func(t *testing.T) {
		a := accountDTO{Extra: accountExtraDTO{
			ModelRateLimits: map[string]modelRateLimitDTO{"gemini-3-pro": mk(fut(time.Hour))},
		}}
		got := deriveModelStates(a, now)
		if len(got) != 1 || got[0].Kind != model.ModelKindRateLimit {
			t.Fatalf("got %+v", got)
		}
	})

	t.Run("已解除的项被过滤", func(t *testing.T) {
		a := accountDTO{Extra: accountExtraDTO{
			ModelRateLimits: map[string]modelRateLimitDTO{
				"a": mk(past(time.Minute)),
				"b": mk(fut(time.Minute)),
			},
		}}
		got := deriveModelStates(a, now)
		if len(got) != 1 || got[0].Model != "b" {
			t.Fatalf("got %+v", got)
		}
	})

	t.Run("按模型名排序输出", func(t *testing.T) {
		a := accountDTO{Extra: accountExtraDTO{
			ModelRateLimits: map[string]modelRateLimitDTO{
				"zeta":  mk(fut(time.Hour)),
				"beta":  mk(fut(time.Hour)),
				"alpha": mk(fut(time.Hour)),
			},
		}}
		got := deriveModelStates(a, now)
		if len(got) != 3 || got[0].Model != "alpha" || got[1].Model != "beta" || got[2].Model != "zeta" {
			t.Fatalf("排序错误: %+v", got)
		}
	})
}
