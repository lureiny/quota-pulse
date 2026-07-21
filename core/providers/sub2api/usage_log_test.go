package sub2api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/lureiny/quota-pulse/core/config"
)

// usageServer 起 mock /admin/usage:按 page 返回预置行,并记录每次请求的 query。
func usageServer(t *testing.T, pages map[int][]map[string]any, totalPages int) (*httptest.Server, func() []map[string]string) {
	t.Helper()
	var mu sync.Mutex
	var reqs []map[string]string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		mu.Lock()
		reqs = append(reqs, map[string]string{
			"page": q.Get("page"), "page_size": q.Get("page_size"),
			"sort_by": q.Get("sort_by"), "sort_order": q.Get("sort_order"),
		})
		mu.Unlock()
		page, _ := strconv.Atoi(q.Get("page"))
		items := pages[page]
		if items == nil {
			items = []map[string]any{}
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"code": 0, "message": "ok",
			"data": map[string]any{"items": items, "total": 0, "page": page, "page_size": 1000, "pages": totalPages},
		})
	}))
	t.Cleanup(srv.Close)
	snapshot := func() []map[string]string {
		mu.Lock()
		defer mu.Unlock()
		return append([]map[string]string(nil), reqs...)
	}
	return srv, snapshot
}

func mkProv(t *testing.T, url string) *Provider {
	t.Helper()
	prov, err := New(config.ProviderConfig{BaseURL: url, APIKey: "k"})
	if err != nil {
		t.Fatal(err)
	}
	return prov.(*Provider)
}

func row(id, acc int, ts string) map[string]any {
	return map[string]any{"id": id, "account_id": acc, "created_at": ts, "input_tokens": id}
}

// 稳态增量:id 降序、page_size 传对、追到游标即停(不翻多余页),冷启动翻到空页收全。
func TestFetchUsageSinceStraddleAndSort(t *testing.T) {
	pages := map[int][]map[string]any{
		1: {row(5, 10, "2026-06-19T15:00:00Z"), row(4, 10, "2026-06-19T14:30:00Z"), row(3, 11, "2026-06-19T14:10:00Z")},
		2: {row(2, 10, "2026-06-19T13:00:00Z"), row(1, 10, "2026-06-19T12:00:00Z")},
	}
	srv, reqs := usageServer(t, pages, 2)
	p := mkProv(t, srv.URL)
	from := time.Now().Add(-48 * time.Hour)

	// sinceID=2 → 取 5,4,3;page2 首行 id=2<=2 → straddle 停。
	rows, err := p.FetchUsageSince(context.Background(), 2, from, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 3 {
		t.Fatalf("since=2 rows=%d want 3", len(rows))
	}
	got := map[int64]string{}
	for _, r := range rows {
		got[r.ID] = r.Dims["account"]
	}
	if got[3] != "11" || got[5] != "10" {
		t.Errorf("account dim mapping wrong: %v", got)
	}
	rq := reqs()
	if rq[0]["sort_by"] != "id" || rq[0]["sort_order"] != "desc" || rq[0]["page_size"] != "10" {
		t.Errorf("query wrong: %v", rq[0])
	}
	if len(rq) != 2 {
		t.Errorf("fetched %d pages, want 2 (追到游标即停,不该翻 page3)", len(rq))
	}

	// 冷启动 sinceID=0 → 全 5 条(page3 空页兜底终止)。
	if rows, _ = p.FetchUsageSince(context.Background(), 0, from, 10); len(rows) != 5 {
		t.Fatalf("cold rows=%d want 5", len(rows))
	}
}

// straddle 在页中间命中即刻停:只收游标之上的行,且不再翻页。
func TestFetchUsageSinceStopsAtCursorMidPage(t *testing.T) {
	pages := map[int][]map[string]any{
		1: {row(5, 1, "2026-06-19T15:00:00Z"), row(4, 1, "2026-06-19T14:00:00Z"),
			row(3, 1, "2026-06-19T13:00:00Z"), row(2, 1, "2026-06-19T12:00:00Z"), row(1, 1, "2026-06-19T11:00:00Z")},
		2: {row(99, 1, "2026-06-19T16:00:00Z")}, // 若错误翻到 page2 会多收,断言可捕获
	}
	srv, reqs := usageServer(t, pages, 2)
	p := mkProv(t, srv.URL)

	rows, _ := p.FetchUsageSince(context.Background(), 3, time.Now().Add(-48*time.Hour), 100)
	if len(rows) != 2 {
		t.Fatalf("rows=%d want 2 (只 5,4;id=3<=3 即停)", len(rows))
	}
	for _, r := range rows {
		if r.ID <= 3 {
			t.Errorf("收进了游标之下的行 id=%d", r.ID)
		}
	}
	if len(reqs()) != 1 {
		t.Errorf("翻了 %d 页,want 1(页中 straddle 即停)", len(reqs()))
	}
}

// 积压升页:小页(size=2)第 1 页整页皆新且未 straddle → 升到 1000 从 page=1 重收,
// 在大页里追到游标即停。验证不再一行一页翻很多次(0 塌陷),且不漏不重。
func TestFetchUsageSinceEscalatesOnBacklog(t *testing.T) {
	// size=2 探测:page1=[10,9](满且皆>游标5)→ 升 1000 重收。
	// size=1000 重收:page1 一次给出 [10..6],其中 id=5<=5 straddle → 收 [10,9,8,7,6]。
	small := map[int][]map[string]any{
		1: {row(10, 1, "2026-06-19T10:00:00Z"), row(9, 1, "2026-06-19T09:00:00Z")},
	}
	big := []map[string]any{
		row(10, 1, "2026-06-19T10:00:00Z"), row(9, 1, "2026-06-19T09:00:00Z"),
		row(8, 1, "2026-06-19T08:00:00Z"), row(7, 1, "2026-06-19T07:00:00Z"),
		row(6, 1, "2026-06-19T06:00:00Z"), row(5, 1, "2026-06-19T05:00:00Z"),
	}
	// 服务端按 page_size 分流:size<1000 走 small[page];size>=1000 一页给 big。
	var mu sync.Mutex
	var sizes []int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		ps, _ := strconv.Atoi(q.Get("page_size"))
		page, _ := strconv.Atoi(q.Get("page"))
		mu.Lock()
		sizes = append(sizes, ps)
		mu.Unlock()
		var items []map[string]any
		if ps >= 1000 {
			if page == 1 {
				items = big
			}
		} else {
			items = small[page]
		}
		if items == nil {
			items = []map[string]any{}
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"code": 0, "message": "ok",
			"data": map[string]any{"items": items, "page": page, "page_size": ps, "pages": 1},
		})
	}))
	t.Cleanup(srv.Close)
	p := mkProv(t, srv.URL)

	rows, err := p.FetchUsageSince(context.Background(), 5, time.Now().Add(-48*time.Hour), 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 5 {
		t.Fatalf("rows=%d want 5 ([10..6],id=5 straddle)", len(rows))
	}
	for _, r := range rows {
		if r.ID <= 5 {
			t.Errorf("收进游标之下的行 id=%d", r.ID)
		}
	}
	mu.Lock()
	defer mu.Unlock()
	// 应先 size=2 探一次,后 size=1000 收一次;绝不是一行一页翻很多次。
	if len(sizes) > 3 {
		t.Errorf("请求次数=%d 偏多(应小页探 1 次 + 大页收 1~2 次),sizes=%v", len(sizes), sizes)
	}
	sawBig := false
	for _, s := range sizes {
		if s >= 1000 {
			sawBig = true
		}
	}
	if !sawBig {
		t.Errorf("积压未升到 1000 大页,sizes=%v", sizes)
	}
}

// clampPageSize:[1,1000] 边界。
func TestClampPageSize(t *testing.T) {
	for _, c := range []struct{ in, want int }{{0, 1}, {-5, 1}, {1, 1}, {500, 500}, {1000, 1000}, {5000, 1000}} {
		if got := clampPageSize(c.in); got != c.want {
			t.Errorf("clampPageSize(%d)=%d want %d", c.in, got, c.want)
		}
	}
}

func TestListAccountsFetchesAllPages(t *testing.T) {
	var mu sync.Mutex
	var requested []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		page := r.URL.Query().Get("page")
		pageNumber, _ := strconv.Atoi(page)
		mu.Lock()
		requested = append(requested, page)
		mu.Unlock()
		items := []map[string]any{{"id": 1, "name": "a1", "status": "active", "schedulable": true}}
		if page == "2" {
			items = []map[string]any{{"id": 2, "name": "a2", "status": "active", "schedulable": true}}
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"code": 0,
			"data": map[string]any{
				"items": items, "page": pageNumber, "page_size": 200, "pages": 2, "total": 2,
			},
		})
	}))
	t.Cleanup(srv.Close)

	p := mkProv(t, srv.URL)
	accounts, err := p.ListAccounts(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(accounts) != 2 || accounts[0].ID != "1" || accounts[1].ID != "2" {
		t.Fatalf("accounts=%+v, want both pages", accounts)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(requested) != 2 || requested[0] != "1" || requested[1] != "2" {
		t.Fatalf("requested pages=%v, want [1 2]", requested)
	}
}
