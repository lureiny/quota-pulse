package poller

import (
	"sync"
	"time"

	"github.com/lureiny/quota-pulse/core/config"
)

// Scheduler 决定下一次轮询间隔。平台外壳通过 Set* 喂入系统信号
//(弹层开合 / 电池 / 休眠),核心据此降频、提频或暂停。
type Scheduler struct {
	mu sync.Mutex

	passive time.Duration
	active  time.Duration

	popoverOpen bool // 弹层打开 → 提频(用户正在看)
	onBattery   bool // 电池供电 → 降频
	asleep      bool // 显示器休眠 / 无网络 → 暂停
}

func NewScheduler(pc config.PollConfig) *Scheduler {
	return &Scheduler{
		passive: pc.PassiveInterval.D(),
		active:  pc.ActiveInterval.D(),
	}
}

func (s *Scheduler) SetPopoverOpen(v bool) { s.set(func() { s.popoverOpen = v }) }
func (s *Scheduler) SetOnBattery(v bool)   { s.set(func() { s.onBattery = v }) }
func (s *Scheduler) SetAsleep(v bool)      { s.set(func() { s.asleep = v }) }

func (s *Scheduler) set(f func()) {
	s.mu.Lock()
	f()
	s.mu.Unlock()
}

// Paused 为 true 时 poller 应跳过本次打点。
func (s *Scheduler) Paused() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.asleep
}

// NextInterval 返回下一次被动轮询间隔。
func (s *Scheduler) NextInterval() time.Duration {
	s.mu.Lock()
	defer s.mu.Unlock()
	switch {
	case s.popoverOpen:
		// 用户正在看 → 给实时感(但不低于 5s,避免打爆)
		return clampMin(s.passive, 10*time.Second, 5*time.Second)
	case s.onBattery:
		return s.passive * 3
	default:
		return s.passive
	}
}

// ActiveInterval 返回稀疏回源间隔。
func (s *Scheduler) ActiveInterval() time.Duration {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.active
}

// clampMin 返回 min(base, cap),但不小于 floor。
func clampMin(base, cap, floor time.Duration) time.Duration {
	v := base
	if cap < v {
		v = cap
	}
	if v < floor {
		v = floor
	}
	return v
}
