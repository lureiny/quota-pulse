// Package poller 周期性拉取各 provider 的账户用量,写入内存快照,并回调订阅者。
// 调度策略(降频/提频/暂停)集中在这里,是"高性能、不影响系统稳定性"的落点。
package poller

import (
	"sort"
	"sync"

	"github.com/lureiny/quota-pulse/core/model"
)

// Store 保存最新一轮快照,key = provider|accountID。
type Store struct {
	mu sync.RWMutex
	m  map[string]model.AccountPulse
}

func NewStore() *Store {
	return &Store{m: make(map[string]model.AccountPulse)}
}

func key(providerType, accountID string) string {
	return providerType + "|" + accountID
}

// Put 写入/覆盖一个账户的脉搏。
func (s *Store) Put(p model.AccountPulse) {
	s.mu.Lock()
	s.m[key(p.Provider, p.AccountID)] = p
	s.mu.Unlock()
}

// Snapshot 返回所有账户的稳定排序快照(先按 provider,再按 name)。
func (s *Store) Snapshot() []model.AccountPulse {
	s.mu.RLock()
	out := make([]model.AccountPulse, 0, len(s.m))
	for _, p := range s.m {
		out = append(out, p)
	}
	s.mu.RUnlock()

	sort.Slice(out, func(i, j int) bool {
		if out[i].Provider != out[j].Provider {
			return out[i].Provider < out[j].Provider
		}
		if out[i].Name != out[j].Name {
			return out[i].Name < out[j].Name
		}
		return out[i].AccountID < out[j].AccountID
	})
	return out
}
