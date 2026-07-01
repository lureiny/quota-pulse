package provider

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/lureiny/quota-pulse/core/netstat"
)

// AuthScheme 描述一个 provider 的鉴权方式。不同平台 header 不同:
//
//	sub2api: Header="x-api-key",    Prefix=""
//	one-api: Header="Authorization", Prefix="Bearer "
//	new-api: 同 one-api,外加 Extra{"New-Api-User": "<id>"}
type AuthScheme struct {
	Header string
	Prefix string
	Token  string
	Extra  map[string]string
}

func (a AuthScheme) apply(r *http.Request) {
	if a.Header != "" && a.Token != "" {
		r.Header.Set(a.Header, a.Prefix+a.Token)
	}
	for k, v := range a.Extra {
		r.Header.Set(k, v)
	}
}

// Envelope 是 sub2api 的统一响应信封:{ code, message, data }。
type Envelope struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data"`
}

// Client 是带 ETag 条件请求与连接复用的 HTTP 客户端,供各 provider 复用。
// net/http 默认自动处理 gzip 与 keep-alive。
type Client struct {
	BaseURL string
	Auth    AuthScheme
	HTTP    *http.Client
	Label   string // 实例名(调试采样按此分实例;由 app 在算出去重实例名后回填)

	mu    sync.Mutex
	cache map[string]cacheEntry // path -> 上次 etag + data(供 304 复用)
}

type cacheEntry struct {
	etag string
	data json.RawMessage
}

// NewClient 构造客户端。baseURL 末尾斜杠会被去掉。
func NewClient(baseURL string, auth AuthScheme) *Client {
	return &Client{
		BaseURL: strings.TrimRight(baseURL, "/"),
		Auth:    auth,
		HTTP: &http.Client{
			Timeout: 20 * time.Second,
			Transport: &http.Transport{
				MaxIdleConns:        32,
				MaxIdleConnsPerHost: 8,
				IdleConnTimeout:     90 * time.Second,
			},
		},
		cache: make(map[string]cacheEntry),
	}
}

// GetData 发起 GET、解开信封、返回 data 原始字节。
//
// 304 处理(无论 useETag 与否——有的服务端/中间层即便没收到条件头也会回 304):
//   - 命中 304 且本地有缓存 → 直接返回上次的 data(几乎零流量);
//   - 命中 304 但本地无缓存(冷启动遇到中间层缓存)→ 去条件头、加 no-cache
//     强制回源重试一次,避免「304 → 空响应 → 报错 → 页面加载不出来」。
func (c *Client) GetData(ctx context.Context, path string, useETag bool) (json.RawMessage, error) {
	data, status, err := c.doOnce(ctx, path, useETag, false)
	if err != nil {
		return nil, err
	}
	if status == http.StatusNotModified {
		c.mu.Lock()
		prev, ok := c.cache[path]
		c.mu.Unlock()
		if ok && len(prev.data) > 0 {
			return prev.data, nil
		}
		// 冷 304:无缓存可复用 → 强制回源一次(绕过中间层缓存)。
		data, status, err = c.doOnce(ctx, path, false, true)
		if err != nil {
			return nil, err
		}
		if status == http.StatusNotModified {
			return nil, fmt.Errorf("GET %s -> 304 但无可用缓存", path)
		}
	}
	return data, nil
}

// doOnce 发一次请求并解信封。成功返回 (data, 状态码, nil);
// 命中 304 返回 (nil, 304, nil) 交由上层决定;其余错误照常返回。
//
//	conditional=true  且有上次 etag → 带 If-None-Match;
//	forceFresh=true                 → 带 Cache-Control: no-cache 强制回源。
func (c *Client) doOnce(ctx context.Context, path string, conditional, forceFresh bool) (json.RawMessage, int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.BaseURL+path, nil)
	if err != nil {
		return nil, 0, err
	}
	c.Auth.apply(req)
	req.Header.Set("Accept", "application/json")

	if conditional {
		c.mu.Lock()
		prev, ok := c.cache[path]
		c.mu.Unlock()
		if ok && prev.etag != "" {
			req.Header.Set("If-None-Match", prev.etag)
		}
	}
	if forceFresh {
		req.Header.Set("Cache-Control", "no-cache")
		req.Header.Set("Pragma", "no-cache")
	}

	// 调试采样开启时接管内容编码:自己声明 gzip 使 net/http 不再透明解压,
	// 从而量到「真实压缩后网络字节」(wire),再自行解压得到「数据量」(payload)。
	// 关闭时逐字走原路径(Go 自动 gzip + 自动解压),仅一次原子读的开销。
	dbg := netstat.Enabled()
	if dbg {
		req.Header.Set("Accept-Encoding", "gzip")
	}

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotModified {
		if dbg {
			netstat.Record(c.Label, path, 0, 0, resp.StatusCode) // 304:响应体≈0 字节
		}
		return nil, resp.StatusCode, nil
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return nil, resp.StatusCode, err
	}
	if dbg {
		wire := len(body) // 接管编码后 body 即网络原始字节(可能是 gzip 流)
		if strings.EqualFold(resp.Header.Get("Content-Encoding"), "gzip") {
			if gr, gzErr := gzip.NewReader(bytes.NewReader(body)); gzErr == nil {
				if dec, dErr := io.ReadAll(io.LimitReader(gr, 32<<20)); dErr == nil {
					body = dec // 解压后交给下方信封解析
				}
				_ = gr.Close()
			}
		}
		netstat.Record(c.Label, path, wire, len(body), resp.StatusCode)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, resp.StatusCode, fmt.Errorf("GET %s -> %d: %s", path, resp.StatusCode, snippet(body))
	}

	var env Envelope
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, resp.StatusCode, fmt.Errorf("decode envelope: %w", err)
	}
	if env.Code != 0 {
		return nil, resp.StatusCode, fmt.Errorf("api error code=%d: %s", env.Code, env.Message)
	}

	// 缓存 data(+ etag,如有)供后续 304 复用。对所有路径都缓存,
	// 这样 useETag=false 的用量接口遇到 304 也能拿回上次的值。
	c.mu.Lock()
	c.cache[path] = cacheEntry{etag: resp.Header.Get("ETag"), data: env.Data}
	c.mu.Unlock()
	return env.Data, resp.StatusCode, nil
}

func snippet(b []byte) string {
	const max = 200
	s := strings.TrimSpace(string(b))
	if len(s) > max {
		return s[:max] + "…"
	}
	return s
}
