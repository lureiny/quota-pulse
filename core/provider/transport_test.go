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

	c, err := NewClient(srv.URL, AuthScheme{}, "")
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
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

	c, err := NewClient(srv.URL, AuthScheme{}, "")
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
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

// 代理 URL 校验:非法 scheme / 缺 host 报错;socks5h 归一为 socks5;空串 = 直连。
func TestParseProxyURL(t *testing.T) {
	bad := []string{"ftp://127.0.0.1:21", "socks5://", "http://", "://nohost"}
	for _, raw := range bad {
		if _, err := parseProxyURL(raw); err == nil {
			t.Errorf("parseProxyURL(%q) 应报错,却成功", raw)
		}
	}

	u, err := parseProxyURL("")
	if err != nil || u != nil {
		t.Errorf("空代理应返回 (nil, nil),得到 (%v, %v)", u, err)
	}

	u, err = parseProxyURL("socks5h://user:pass@127.0.0.1:1080")
	if err != nil {
		t.Fatalf("socks5h 应被接受: %v", err)
	}
	if u.Scheme != "socks5" {
		t.Errorf("socks5h 应归一为 socks5,得到 %q", u.Scheme)
	}
	if u.User.String() != "user:pass" {
		t.Errorf("userinfo 丢失: %q", u.User.String())
	}

	if _, err := parseProxyURL("HTTPS://proxy.local:8443"); err != nil {
		t.Errorf("大小写混合 scheme 应被接受: %v", err)
	}
}

// 端到端:配置 HTTP 代理后,请求必须经代理发出(代理收到的是绝对 URI)。
func TestGetData_ViaHTTPProxy(t *testing.T) {
	var proxied int32
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !r.URL.IsAbs() {
			t.Errorf("代理应收到绝对 URI,得到 %q", r.URL.String())
		}
		atomic.AddInt32(&proxied, 1)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"code":0,"message":"ok","data":{"via":"proxy"}}`))
	}))
	defer proxy.Close()

	// BaseURL 指向一个永不监听的地址:只有真的走了代理(代理直接应答)才能拿到数据。
	c, err := NewClient("http://127.0.0.1:1", AuthScheme{}, proxy.URL)
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	data, err := c.GetData(context.Background(), "/accounts", false)
	if err != nil {
		t.Fatalf("经代理 GET 失败: %v", err)
	}
	if string(data) != `{"via":"proxy"}` {
		t.Fatalf("got %s, want {\"via\":\"proxy\"}", data)
	}
	if atomic.LoadInt32(&proxied) != 1 {
		t.Fatalf("代理应被命中 1 次,得到 %d", proxied)
	}
}
