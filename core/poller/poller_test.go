package poller

import (
	"context"
	"errors"
	"testing"

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
	if _, _, ok := splitKey("no-pipe"); ok {
		t.Error("无分隔符应 ok=false")
	}
}
