package sub2api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/lureiny/quota-pulse/core/config"
)

func TestFetchUsageSincePagingCursorCap(t *testing.T) {
	// 两页(desc,最新在前):page1=[5,4,3],page2=[2,1]。
	pages := map[int][]map[string]any{
		1: {
			{"id": 5, "account_id": 10, "created_at": "2026-06-19T15:00:00Z", "input_tokens": 5},
			{"id": 4, "account_id": 10, "created_at": "2026-06-19T14:30:00Z", "input_tokens": 4},
			{"id": 3, "account_id": 11, "created_at": "2026-06-19T14:10:00Z", "input_tokens": 3},
		},
		2: {
			{"id": 2, "account_id": 10, "created_at": "2026-06-19T13:00:00Z", "input_tokens": 2},
			{"id": 1, "account_id": 10, "created_at": "2026-06-19T12:00:00Z", "input_tokens": 1},
		},
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		page, _ := strconv.Atoi(r.URL.Query().Get("page"))
		items := pages[page]
		if items == nil {
			items = []map[string]any{}
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"code": 0, "message": "ok",
			"data": map[string]any{
				"items": items, "total": 5, "page": page, "page_size": 1000, "pages": 2,
			},
		})
	}))
	defer srv.Close()

	prov, err := New(config.ProviderConfig{BaseURL: srv.URL, APIKey: "k"})
	if err != nil {
		t.Fatal(err)
	}
	p := prov.(*Provider)
	from := time.Now().Add(-48 * time.Hour)

	// sinceID=2 → 只取 id>2 的 5,4,3;page2 全 <=2 → 停。
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
	for _, id := range []int64{3, 4, 5} {
		if _, ok := got[id]; !ok {
			t.Errorf("missing id %d", id)
		}
	}
	if got[3] != "11" || got[5] != "10" { // account_id int64 → dims["account"] string
		t.Errorf("account dim mapping wrong: %v", got)
	}

	// 冷启动 sinceID=0 → 全 5 条(翻到末页)。
	if rows, _ = p.FetchUsageSince(context.Background(), 0, from, 10); len(rows) != 5 {
		t.Fatalf("cold rows=%d want 5", len(rows))
	}

	// pageCap=1 → 只第一页 3 条。
	if rows, _ = p.FetchUsageSince(context.Background(), 0, from, 1); len(rows) != 3 {
		t.Fatalf("cap=1 rows=%d want 3", len(rows))
	}
}
