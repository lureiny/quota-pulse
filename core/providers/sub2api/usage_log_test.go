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

// 前向 ASC drain:id 升序;抓全→complete;rowBudget 截断→complete=false + maxSeen=连续右端。
func TestFetchUsageWindowAscDrain(t *testing.T) {
	pages := map[int][]map[string]any{
		1: {row(1, 1, "2026-06-01T01:00:00Z"), row(2, 1, "2026-06-01T02:00:00Z"), row(3, 1, "2026-06-01T03:00:00Z")},
		2: {row(4, 1, "2026-06-01T04:00:00Z"), row(5, 1, "2026-06-01T05:00:00Z")},
	}
	srv, reqs := usageServer(t, pages, 2)
	p := mkProv(t, srv.URL)
	from := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	to := time.Date(2026, 6, 2, 0, 0, 0, 0, time.UTC)

	// 无截断:drain 全 5 条(page2 不足一页→末页),complete=true,maxSeen=id5 的时间。
	evs, complete, maxSeen, nextPage, err := p.FetchUsageWindowAsc(context.Background(), from, to, 3, 100, 1)
	if err != nil || !complete || len(evs) != 5 {
		t.Fatalf("full drain: complete=%v len=%d err=%v", complete, len(evs), err)
	}
	if !maxSeen.Equal(time.Date(2026, 6, 1, 5, 0, 0, 0, time.UTC)) {
		t.Errorf("maxSeen=%v want 05:00", maxSeen)
	}
	if reqs()[0]["sort_order"] != "asc" || reqs()[0]["sort_by"] != "id" {
		t.Errorf("asc query wrong: %v", reqs()[0])
	}

	// rowBudget=3 截断:page1 三条即满,complete=false,maxSeen=id3 时间,nextPage=2(供 from 不变续翻)。
	evs2, complete2, maxSeen2, next2, _ := p.FetchUsageWindowAsc(context.Background(), from, to, 3, 3, 1)
	if complete2 || len(evs2) != 3 {
		t.Fatalf("truncated: complete=%v len=%d want false/3", complete2, len(evs2))
	}
	if !maxSeen2.Equal(time.Date(2026, 6, 1, 3, 0, 0, 0, time.UTC)) {
		t.Errorf("maxSeen(trunc)=%v want 03:00", maxSeen2)
	}
	if next2 != 2 {
		t.Errorf("nextPage=%d want 2", next2)
	}

	// 续翻:从 nextPage=2 起(from 不变),拿到剩余 [4,5],complete=true。验证「翻页续抓」拼接无洞。
	evs3, complete3, _, _, _ := p.FetchUsageWindowAsc(context.Background(), from, to, 3, 100, next2)
	if !complete3 || len(evs3) != 2 || evs3[0].ID != 4 || evs3[1].ID != 5 {
		t.Fatalf("resume page2: complete=%v ids=%v want true/[4,5]", complete3, []int64{evs3[0].ID, evs3[1].ID})
	}
	_ = nextPage
}

// clampPageSize:[1,1000] 边界。
func TestClampPageSize(t *testing.T) {
	for _, c := range []struct{ in, want int }{{0, 1}, {-5, 1}, {1, 1}, {500, 500}, {1000, 1000}, {5000, 1000}} {
		if got := clampPageSize(c.in); got != c.want {
			t.Errorf("clampPageSize(%d)=%d want %d", c.in, got, c.want)
		}
	}
}
