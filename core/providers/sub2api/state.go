package sub2api

import (
	"sort"
	"time"

	"github.com/lureiny/quota-pulse/core/model"
)

// deriveAccountState 把一条账户 DTO 的调度/限流/配额字段,派生成通用的
// model.AccountState —— **逐条镜像 sub2api 前端 AccountStatusIndicator.vue 的判定**,
// 使本地展示与网页「账户管理→状态」列完全一致。
//
// 主状态优先级(与 Vue 一致):
//
//	429 限流 > 529 过载 > 错误 > 临时不可调度 > 停用 > 配额超限 > 暂停 > 正常
//
// 其中 429/529 抢占一切(Vue 里它们在 v-else 之外);其余走 statusText 的判定链。
func deriveAccountState(a accountDTO, now time.Time) *model.AccountState {
	st := &model.AccountState{}

	switch {
	case future(a.RateLimitResetAt, now): // 429:被上游限流
		st.Code = model.StateRateLimited
		st.Severity = model.SeverityWarning
		st.ResetsAt = a.RateLimitResetAt
	case future(a.OverloadUntil, now): // 529:上游过载
		st.Code = model.StateOverloaded
		st.Severity = model.SeverityDanger
		st.ResetsAt = a.OverloadUntil
	case a.Status == "error": // 账户状态=error(Vue: hasError 优先于 tempUnsched)
		st.Code = model.StateError
		st.Severity = model.SeverityDanger
		st.Reason = a.ErrorMessage
	case future(a.TempUnschedulableUntil, now): // 命中临时不可调度规则
		st.Code = model.StateTempUnschedulable
		st.Severity = model.SeverityWarning
		st.ResetsAt = a.TempUnschedulableUntil
		st.Reason = a.TempUnschedulableReason
	case a.Status != "active": // 非 active/error → 停用等
		st.Code = model.StateInactive
		st.Severity = model.SeverityNeutral
	case quotaExceeded(a): // 配额(总/日/周)已用尽
		st.Code = model.StateQuotaExceeded
		st.Severity = model.SeverityWarning
	case !a.Schedulable: // 人工暂停
		st.Code = model.StatePaused
		st.Severity = model.SeverityNeutral
	default: // 正常
		st.Code = model.StateOK
		st.Severity = model.SeverityOK
	}

	st.Models = deriveModelStates(a, now)
	return st
}

// deriveModelStates 从 extra.model_rate_limits 派生模型级限流徽章(镜像 Vue activeModelStatuses):
//   - AICredits 键                          → 积分已用尽(credits_exhausted)
//   - 开启 overages 且积分未耗尽             → 走积分(credits_active)
//   - 其余                                    → 普通模型限流(rate_limit)
//
// 仅保留 rate_limit_reset_at 仍在未来的项;按模型名排序输出(map 迭代无序,排序防抖 + 测试稳定)。
func deriveModelStates(a accountDTO, now time.Time) []model.ModelState {
	limits := a.Extra.ModelRateLimits
	if len(limits) == 0 {
		return nil
	}
	aic, ok := limits["AICredits"]
	hasActiveAICredits := ok && future(aic.RateLimitResetAt, now)
	allowOverages := a.Extra.AllowOverages

	names := make([]string, 0, len(limits))
	for m := range limits {
		names = append(names, m)
	}
	sort.Strings(names)

	var out []model.ModelState
	for _, m := range names {
		info := limits[m]
		if !future(info.RateLimitResetAt, now) {
			continue // 已解除
		}
		kind := model.ModelKindRateLimit
		switch {
		case m == "AICredits":
			kind = model.ModelKindCreditsExhausted
		case allowOverages && !hasActiveAICredits:
			kind = model.ModelKindCreditsActive
		}
		out = append(out, model.ModelState{Model: m, Kind: kind, ResetsAt: info.RateLimitResetAt})
	}
	return out
}

// quotaExceeded 判账户配额是否已用尽(总/日/周任一 used>=limit>0),镜像 Vue isQuotaExceeded。
func quotaExceeded(a accountDTO) bool {
	hit := func(used, limit *float64) bool {
		return limit != nil && *limit > 0 && used != nil && *used >= *limit
	}
	return hit(a.QuotaUsed, a.QuotaLimit) ||
		hit(a.QuotaDailyUsed, a.QuotaDailyLimit) ||
		hit(a.QuotaWeeklyUsed, a.QuotaWeeklyLimit)
}

// future 报告 t 是否非空且晚于 now(即「解除时间」仍未到)。
func future(t *time.Time, now time.Time) bool {
	return t != nil && t.After(now)
}
