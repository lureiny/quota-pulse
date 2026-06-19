package sub2api

import (
	"fmt"
	"time"

	"github.com/lureiny/quota-pulse/core/model"
)

// trendHourLayout 是服务端 trend.date 的格式(granularity=hour)。
const trendHourLayout = "2006-01-02 15:04"

// toHourPoints 把 dashboard/trend 的小时桶映射成通用 model.HourPoint。
// date 用与查询 timezone 一致的 loc 解析(见 localTrendZone),保证桶边界与解析同时区,
// 不再二次偏移;UI 端 toLocal 仅在半点偏移回退 UTC 时起作用。
func toHourPoints(r trendResp, loc *time.Location) []model.HourPoint {
	out := make([]model.HourPoint, 0, len(r.Trend))
	for _, p := range r.Trend {
		hr, err := time.ParseInLocation(trendHourLayout, p.Date, loc)
		if err != nil {
			continue // 无法解析的桶直接跳过,不污染时序
		}
		out = append(out, model.HourPoint{
			Hour:        hr,
			Input:       p.InputTokens,
			Output:      p.OutputTokens,
			CacheCreate: p.CacheCreationTokens,
			CacheRead:   p.CacheReadTokens,
			Total:       p.TotalTokens,
		})
	}
	return out
}

// toPulse 把 sub2api 的 usageInfo 映射成通用 model.AccountPulse。
// 每个非空窗口 → 一个 KindRollingWindow 的 Meter。
func toPulse(acc model.Account, u usageInfo) model.AccountPulse {
	var meters []model.Meter

	add := func(id, label string, p *usageProgress) {
		if p == nil {
			return
		}
		util := p.Utilization / 100.0
		m := model.Meter{
			ID:          id,
			Label:       label,
			Kind:        model.KindRollingWindow,
			Unit:        model.UnitPercent,
			Utilization: &util,
			ResetsAt:    p.ResetsAt,
			Detail:      windowDetail(p),
		}
		if p.RemainingSeconds > 0 {
			secs := int64(p.RemainingSeconds)
			m.RemainingSecs = &secs
		}
		meters = append(meters, m)
	}

	// Claude
	add("five_hour", "5h", u.FiveHour)
	add("seven_day", "7d", u.SevenDay)
	add("seven_day_sonnet", "7d Sonnet", u.SevenDaySonnet)
	// Gemini(按需展示)
	add("gemini_shared_daily", "Shared/日", u.GeminiSharedDaily)
	add("gemini_pro_daily", "Pro/日", u.GeminiProDaily)
	add("gemini_flash_daily", "Flash/日", u.GeminiFlashDaily)
	add("gemini_pro_minute", "Pro/分", u.GeminiProMinute)
	add("gemini_flash_minute", "Flash/分", u.GeminiFlashMinute)

	pulse := model.AccountPulse{
		AccountID: acc.ID,
		Name:      acc.Name,
		Platform:  acc.Platform,
		Provider:  providerType,
		Tier:      u.SubscriptionTier,
		Status:    mapStatus(u, meters),
		Meters:    meters,
		Error:     u.Error,
		ActionURL: u.ValidationURL,
	}
	if u.UpdatedAt != nil {
		pulse.UpdatedAt = *u.UpdatedAt
	}
	return pulse
}

// mapStatus 把状态标志 + 窗口使用率归一成总体状态。
func mapStatus(u usageInfo, meters []model.Meter) model.Status {
	switch {
	case u.Error != "":
		return model.StatusError
	case u.IsBanned:
		return model.StatusBanned
	case u.NeedsReauth:
		return model.StatusNeedsReauth
	case u.IsForbidden:
		return model.StatusForbidden
	}

	worst := model.StatusOK
	for _, m := range meters {
		if m.Utilization == nil {
			continue
		}
		switch {
		case *m.Utilization >= 1.0:
			return model.StatusRateLimited // 任一窗口满即限流
		case *m.Utilization >= 0.8:
			worst = model.StatusWarning
		}
	}
	return worst
}

func windowDetail(p *usageProgress) string {
	if p.WindowStats == nil {
		return ""
	}
	ws := p.WindowStats
	if ws.Tokens == 0 && ws.Cost == 0 {
		return ""
	}
	return fmt.Sprintf("%s tok · $%.2f", humanInt(ws.Tokens), ws.Cost)
}

func humanInt(n int64) string {
	switch {
	case n >= 1_000_000:
		return fmt.Sprintf("%.1fM", float64(n)/1e6)
	case n >= 1_000:
		return fmt.Sprintf("%.1fK", float64(n)/1e3)
	default:
		return fmt.Sprintf("%d", n)
	}
}
