package provider

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
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

	mu    sync.Mutex
	etags map[string]etagEntry // path -> 上次 etag + data
}

type etagEntry struct {
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
		etags: make(map[string]etagEntry),
	}
}

// GetData 发起 GET、解开信封、返回 data 原始字节。
// useETag=true 时带 If-None-Match;命中 304 直接返回上次缓存的 data(几乎零流量)。
func (c *Client) GetData(ctx context.Context, path string, useETag bool) (json.RawMessage, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.BaseURL+path, nil)
	if err != nil {
		return nil, err
	}
	c.Auth.apply(req)
	req.Header.Set("Accept", "application/json")

	if useETag {
		c.mu.Lock()
		prev, ok := c.etags[path]
		c.mu.Unlock()
		if ok && prev.etag != "" {
			req.Header.Set("If-None-Match", prev.etag)
		}
	}

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if useETag && resp.StatusCode == http.StatusNotModified {
		c.mu.Lock()
		prev := c.etags[path]
		c.mu.Unlock()
		return prev.data, nil
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("GET %s -> %d: %s", path, resp.StatusCode, snippet(body))
	}

	var env Envelope
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("decode envelope: %w", err)
	}
	if env.Code != 0 {
		return nil, fmt.Errorf("api error code=%d: %s", env.Code, env.Message)
	}

	if useETag {
		if et := resp.Header.Get("ETag"); et != "" {
			c.mu.Lock()
			c.etags[path] = etagEntry{etag: et, data: env.Data}
			c.mu.Unlock()
		}
	}
	return env.Data, nil
}

func snippet(b []byte) string {
	const max = 200
	s := strings.TrimSpace(string(b))
	if len(s) > max {
		return s[:max] + "…"
	}
	return s
}
