package provider

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

// 冷 304:服务端(或中间层)对没带条件头的请求也回 304。
// 期望 GetData 不报错,而是去条件头 + no-cache 强制回源拿到真正的 body。
func TestGetData_Cold304_ForcesFreshRetry(t *testing.T) {
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := atomic.AddInt32(&hits, 1)
		// 第一次(无 no-cache)假装命中中间层缓存回 304;带 no-cache 的重试才给 body。
		if n == 1 && r.Header.Get("Cache-Control") == "" {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"code":0,"message":"ok","data":{"v":1}}`))
	}))
	defer srv.Close()

	c := NewClient(srv.URL, AuthScheme{})
	data, err := c.GetData(context.Background(), "/usage?source=passive", false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if string(data) != `{"v":1}` {
		t.Fatalf("got %s, want {\"v\":1}", data)
	}
	if got := atomic.LoadInt32(&hits); got != 2 {
		t.Fatalf("expected 2 requests (304 then forced), got %d", got)
	}
}

// 命中 304 且本地有缓存 → 直接返回上次的 data,不再读 body。
func TestGetData_304_ServesCache(t *testing.T) {
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := atomic.AddInt32(&hits, 1)
		if n == 1 {
			w.Header().Set("ETag", `"abc"`)
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"code":0,"data":{"v":42}}`))
			return
		}
		// 后续带 If-None-Match 的请求回 304。
		if r.Header.Get("If-None-Match") != `"abc"` {
			t.Errorf("expected If-None-Match, got %q", r.Header.Get("If-None-Match"))
		}
		w.WriteHeader(http.StatusNotModified)
	}))
	defer srv.Close()

	c := NewClient(srv.URL, AuthScheme{})
	if _, err := c.GetData(context.Background(), "/accounts", true); err != nil {
		t.Fatalf("first GET: %v", err)
	}
	data, err := c.GetData(context.Background(), "/accounts", true)
	if err != nil {
		t.Fatalf("second GET: %v", err)
	}
	if string(data) != `{"v":42}` {
		t.Fatalf("got %s, want cached {\"v\":42}", data)
	}
	if got := atomic.LoadInt32(&hits); got != 2 {
		t.Fatalf("expected 2 requests, got %d", got)
	}
}

func TestResponseCacheIsBoundedAndEvictsOldest(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"code":0,"data":{"path":"` + r.URL.Path + `"}}`))
	}))
	defer srv.Close()

	c := NewClient(srv.URL, AuthScheme{})
	c.cacheMaxEntries = 2
	c.cacheMaxBytes = 1 << 20
	for _, path := range []string{"/one", "/two", "/three"} {
		if _, err := c.GetData(context.Background(), path, false); err != nil {
			t.Fatal(err)
		}
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.cache) != 2 {
		t.Fatalf("cache entries=%d want 2", len(c.cache))
	}
	if _, ok := c.cache["/one"]; ok {
		t.Fatal("oldest cache entry was not evicted")
	}
	if c.cacheBytes > c.cacheMaxBytes {
		t.Fatalf("cache bytes=%d exceeds max=%d", c.cacheBytes, c.cacheMaxBytes)
	}
}

func TestResponseCacheDropsEntryLargerThanByteBudget(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"code":0,"data":{"payload":"larger-than-budget"}}`))
	}))
	defer srv.Close()
	c := NewClient(srv.URL, AuthScheme{})
	c.cacheMaxEntries = 10
	c.cacheMaxBytes = 4
	if _, err := c.GetData(context.Background(), "/large", false); err != nil {
		t.Fatal(err)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.cache) != 0 || c.cacheBytes != 0 {
		t.Fatalf("oversized response remained cached: entries=%d bytes=%d", len(c.cache), c.cacheBytes)
	}
}
