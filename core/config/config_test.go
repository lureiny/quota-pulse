package config

import (
	"testing"
	"time"
)

// 关闭自动回源(active_interval=0,即设置里 "0s")不应被兜底成 10m——
// 默认不强制回源是有意为之(周期性回源有明显自动化特征)。
func TestPollWithDefaults_ActiveDisabledStaysZero(t *testing.T) {
	got := PollConfig{
		PassiveInterval: Duration(30 * time.Second),
		ActiveInterval:  0,
	}.withDefaults()
	if got.ActiveInterval != 0 {
		t.Fatalf("active 应保持 0(关闭),却变成 %v", got.ActiveInterval.D())
	}
	if got.PassiveInterval.D() != 30*time.Second {
		t.Fatalf("passive 应保持 30s,却变成 %v", got.PassiveInterval.D())
	}
}

// 缺省时:被动兜底 60s,主动回源默认关闭(0)。
func TestPollWithDefaults_Fallbacks(t *testing.T) {
	got := PollConfig{}.withDefaults()
	if got.PassiveInterval.D() != 60*time.Second {
		t.Fatalf("passive 默认应为 60s,却是 %v", got.PassiveInterval.D())
	}
	if got.ActiveInterval != 0 {
		t.Fatalf("active 默认应为 0(关闭回源),却是 %v", got.ActiveInterval.D())
	}
}
