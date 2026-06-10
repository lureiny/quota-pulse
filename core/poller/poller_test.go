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
