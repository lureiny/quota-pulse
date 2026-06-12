package poller

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/lureiny/quota-pulse/core/config"
	"github.com/lureiny/quota-pulse/core/model"
	"github.com/lureiny/quota-pulse/core/provider"
)

// fakeProvider:ListAccounts 返回固定账户;FetchUsage 可配置成功值或错误。
type fakeProvider struct {
	accounts []model.Account
	pulse    model.AccountPulse
	fetchErr error
}

func (f *fakeProvider) Type() string        { return "fake" }
func (f *fakeProvider) DisplayName() string { return "fake" }
func (f *fakeProvider) Capabilities() provider.Capabilities {
	return provider.Capabilities{}
}
func (f *fakeProvider) ListAccounts(context.Context) ([]model.Account, error) {
	return f.accounts, nil
}
func (f *fakeProvider) FetchUsage(context.Context, model.Account, provider.FetchOptions) (model.AccountPulse, error) {
	if f.fetchErr != nil {
		return model.AccountPulse{}, f.fetchErr
	}
	return f.pulse, nil
}

// 拉取失败时,store 应保留上一次成功的数据,而不是被错误覆盖/清空。
func TestPollKeepsLastSuccessOnFetchError(t *testing.T) {
	store := NewStore()
	store.Put(model.AccountPulse{Instance: "inst", AccountID: "1", Name: "上次成功"})

	fp := &fakeProvider{
		accounts: []model.Account{{ID: "1", Name: "acct1"}},
		fetchErr: errors.New("boom"),
	}
	p := New(store, nil)
	p.AddProvider(fp, NewScheduler(config.PollConfig{}), "inst")

	p.pollOnce(context.Background(), p.bindings[0], provider.FetchOptions{})

	snap := store.Snapshot()
	if len(snap) != 1 {
		t.Fatalf("snapshot len = %d, want 1(失败不应新增/清空)", len(snap))
	}
	if snap[0].Name != "上次成功" || snap[0].Status == model.StatusError {
		t.Errorf("失败覆盖了上次成功:%+v", snap[0])
	}
}

// 成功时正常写入并盖上实例名。
func TestPollPutsOnSuccess(t *testing.T) {
	store := NewStore()
	fp := &fakeProvider{
		accounts: []model.Account{{ID: "2", Name: "acct2"}},
		pulse:    model.AccountPulse{AccountID: "2", Name: "acct2"},
	}
	p := New(store, nil)
	p.AddProvider(fp, NewScheduler(config.PollConfig{}), "myinst")

	p.pollOnce(context.Background(), p.bindings[0], provider.FetchOptions{})

	snap := store.Snapshot()
	if len(snap) != 1 || snap[0].Instance != "myinst" {
		t.Fatalf("成功未正确写入/盖章:%+v", snap)
	}
}

// refreshOne 只更新指定账户,其它账户不动。
func TestRefreshOneOnlyTargetAccount(t *testing.T) {
	store := NewStore()
	store.Put(model.AccountPulse{Instance: "inst", AccountID: "1", Name: "旧1"})
	store.Put(model.AccountPulse{Instance: "inst", AccountID: "2", Name: "旧2"})

	fp := &fakeProvider{
		accounts: []model.Account{{ID: "1"}, {ID: "2"}},
		pulse:    model.AccountPulse{AccountID: "2", Name: "刷新后2"},
	}
	p := New(store, nil)
	p.AddProvider(fp, NewScheduler(config.PollConfig{}), "inst")

	p.refreshOne(context.Background(), p.bindings[0], "2")

	var a1, a2 model.AccountPulse
	for _, s := range store.Snapshot() {
		switch s.AccountID {
		case "1":
			a1 = s
		case "2":
			a2 = s
		}
	}
	if a1.Name != "旧1" {
		t.Errorf("账户1 不应被动:%q", a1.Name)
	}
	if a2.Name != "刷新后2" || a2.Instance != "inst" {
		t.Errorf("账户2 未正确刷新:%+v", a2)
	}
}

func TestSplitKey(t *testing.T) {
	inst, acc, ok := splitKey("实例A|40")
	if !ok || inst != "实例A" || acc != "40" {
		t.Errorf("splitKey = %q,%q,%v", inst, acc, ok)
	}
	// 实例级:accountID 为空。
	inst, acc, ok = splitKey("实例A|")
	if !ok || inst != "实例A" || acc != "" {
		t.Errorf("实例级 splitKey = %q,%q,%v", inst, acc, ok)
	}
	if _, _, ok := splitKey("no-pipe"); ok {
		t.Error("无分隔符应 ok=false")
	}
}

// coldProvider:模拟"冷账户"——被动(Fresh=false)读缓存失败,主动(Fresh=true)回源成功。
type coldProvider struct {
	accounts []model.Account
}

func (c *coldProvider) Type() string        { return "cold" }
func (c *coldProvider) DisplayName() string { return "cold" }
func (c *coldProvider) Capabilities() provider.Capabilities {
	return provider.Capabilities{}
}
func (c *coldProvider) ListAccounts(context.Context) ([]model.Account, error) {
	return c.accounts, nil
}
func (c *coldProvider) FetchUsage(_ context.Context, acc model.Account, opt provider.FetchOptions) (model.AccountPulse, error) {
	if !opt.Fresh {
		return model.AccountPulse{}, errors.New("passive 冷账户无缓存")
	}
	return model.AccountPulse{AccountID: acc.ID, Name: acc.Name}, nil
}

// 回归:启动首次必须强制回源(Fresh=true),否则被动缓存会漏掉冷账户,
// 多账户实例首屏只显示有缓存的少数。v0.7.0 曾因把启动也 gate 在 active 开关上
// 导致此回归(active 默认关 → 启动走被动 → 冷账户被跳过)。
func TestLoopInitialFetchLoadsAllAccountsEvenWhenActiveOff(t *testing.T) {
	store := NewStore()
	done := make(chan struct{}, 1)
	p := New(store, func([]model.AccountPulse) {
		select {
		case done <- struct{}{}:
		default:
		}
	})
	// active 关(PollConfig 不设 active → 0);passive 设大,避免首拍后又触发轮询。
	sched := NewScheduler(config.PollConfig{PassiveInterval: config.Duration(time.Hour)})
	p.AddProvider(&coldProvider{accounts: []model.Account{
		{ID: "1", Name: "a1"}, {ID: "2", Name: "a2"}, {ID: "3", Name: "a3"},
	}}, sched, "inst")

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go p.loop(ctx, p.bindings[0])

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("启动首次 pollOnce 未在预期内完成")
	}
	cancel()

	if n := len(store.Snapshot()); n != 3 {
		t.Fatalf("启动应回源加载全部 3 个账户,实际 %d(冷账户被漏掉=回归)", n)
	}
}
