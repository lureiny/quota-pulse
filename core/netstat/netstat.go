// Package netstat 是一个进程内、内存态的「客户端读流量」采样器(调试用)。
//
// 服务端不好统计每个实例请求消耗的网络流量,于是在客户端的 HTTP 咽喉点
// (core/provider/transport.go 的 doOnce)按次记录:每个实例、每个 API、每次请求
// 拿到的字节量(wire=压缩后网络字节、payload=解压后数据量)与所用 page_size。
//
// 设计要点:
//   - 运行时开关:关闭时 Record 首行原子判断即返回,零额外开销;不影响任何请求语义。
//   - 上限保护:最大采样次数 + 采样内存上限,任一命中即「停采冻结」(不覆盖旧样本、不 OOM),
//     报告标 truncated 并累加 droppedOver。
//   - 采样只在内存,不落库、不持久化(仅 UI 侧持久化开关与两个上限)。
//   - Disable 只停采、保留样本(便于关掉后再看报告);Reset 才清空;Enable 重置并开采。
//
// 全局单例:整个进程一份(与「每实例一个 provider.Client」的采集点匹配,按 label 分实例)。
package netstat

import (
	"encoding/json"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
)

const (
	defaultMaxSamples  = 200000
	defaultMaxMemBytes = 32 << 20 // 32 MiB
	// sampleCost 是单条样本的估算内存占用(2 个 string header + 5 个 int + 切片摊销),
	// 用于内存上限判断。字符串本体按驻留后各计一次(见 intern)。
	sampleCost = 80
)

// sample 是一次真实 HTTP 往返的采样记录。
type sample struct {
	inst     string // 实例 label(已驻留)
	endpoint string // 归一后的路径模板(已驻留),如 /api/v1/admin/accounts/{id}/usage
	pageSize int    // 查询串 page_size(无则 0)
	page     int    // 查询串 page(无则 0)
	wire     int    // 压缩后网络字节(响应体,不含 header/TLS)
	payload  int    // 解压后数据量
	status   int    // HTTP 状态码(200/304/…)
}

// Recorder 是采样器。零值不可用,通过包级 global 使用。
type Recorder struct {
	enabled atomic.Bool // 快路径开关(Record 首行读)

	mu          sync.Mutex
	maxSamples  int
	maxMemBytes int64
	samples     []sample
	intern      map[string]string // 字符串驻留:避免重复 label/endpoint 各占一份
	memBytes    int64             // 估算已用内存
	droppedOver int               // 命中上限后被丢弃(仅计数)的请求数
	truncated   bool              // 是否已命中上限而停采
}

var global = &Recorder{}

// Enable 重置缓冲并开始采样。上限 <=0 时取默认值。
func Enable(maxSamples int, maxMemBytes int64) {
	if maxSamples <= 0 {
		maxSamples = defaultMaxSamples
	}
	if maxMemBytes <= 0 {
		maxMemBytes = defaultMaxMemBytes
	}
	global.mu.Lock()
	global.maxSamples = maxSamples
	global.maxMemBytes = maxMemBytes
	global.samples = nil
	global.intern = make(map[string]string)
	global.memBytes = 0
	global.droppedOver = 0
	global.truncated = false
	global.mu.Unlock()
	global.enabled.Store(true)
}

// Disable 停止采样但保留已采样本(便于关掉后仍能看报告)。
func Disable() { global.enabled.Store(false) }

// Reset 清空已采样本(保留开关状态与上限)。
func Reset() {
	global.mu.Lock()
	global.samples = nil
	global.intern = make(map[string]string)
	global.memBytes = 0
	global.droppedOver = 0
	global.truncated = false
	global.mu.Unlock()
}

// Enabled 报告当前是否在采样(快路径原子读)。
func Enabled() bool { return global.enabled.Load() }

// Record 记录一次请求。未开启或已命中上限时快速返回。
// path 为带查询串的请求路径;endpoint/page/page_size 在内部解析。
func Record(label, path string, wire, payload, status int) {
	if !global.enabled.Load() {
		return
	}
	global.mu.Lock()
	defer global.mu.Unlock()
	if !global.enabled.Load() { // 与 Disable 竞态时二次确认
		return
	}
	if len(global.samples) >= global.maxSamples || global.memBytes >= global.maxMemBytes {
		global.droppedOver++
		global.truncated = true
		return
	}
	endpoint, page, pageSize := parsePath(path)
	global.samples = append(global.samples, sample{
		inst:     global.internLocked(label),
		endpoint: global.internLocked(endpoint),
		pageSize: pageSize,
		page:     page,
		wire:     wire,
		payload:  payload,
		status:   status,
	})
	global.memBytes += sampleCost
}

// internLocked 驻留字符串(调用方须持 mu),新串计一次内存。
func (r *Recorder) internLocked(s string) string {
	if v, ok := r.intern[s]; ok {
		return v
	}
	r.intern[s] = s
	r.memBytes += int64(len(s))
	return s
}

// parsePath 把请求路径归一成 endpoint 模板(纯数字段 → {id}),并取出 page/page_size。
func parsePath(p string) (endpoint string, page, pageSize int) {
	u, err := url.Parse(p)
	if err != nil {
		return p, 0, 0
	}
	q := u.Query()
	page, _ = strconv.Atoi(q.Get("page"))
	pageSize, _ = strconv.Atoi(q.Get("page_size"))
	segs := strings.Split(u.Path, "/")
	for i, s := range segs {
		if s != "" && isAllDigits(s) {
			segs[i] = "{id}"
		}
	}
	return strings.Join(segs, "/"), page, pageSize
}

func isAllDigits(s string) bool {
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// ---- 报告(读时聚合)----

// PageSizeStat 是某 (实例,api,page_size) 的聚合。
type PageSizeStat struct {
	PageSize     int     `json:"pageSize"`
	Requests     int     `json:"requests"`
	WireTotal    int64   `json:"wireTotal"`
	PayloadTotal int64   `json:"payloadTotal"`
	WireAvg      float64 `json:"wireAvg"`
	PayloadAvg   float64 `json:"payloadAvg"`
}

// APIStat 是某 (实例,api) 的聚合,含按 page_size 的拆分。
type APIStat struct {
	Endpoint     string         `json:"endpoint"`
	Requests     int            `json:"requests"`
	WireTotal    int64          `json:"wireTotal"`
	PayloadTotal int64          `json:"payloadTotal"`
	WireAvg      float64        `json:"wireAvg"`
	PayloadAvg   float64        `json:"payloadAvg"`
	ByPageSize   []PageSizeStat `json:"byPageSize"`
}

// InstanceStat 是某实例的聚合。
type InstanceStat struct {
	Instance     string    `json:"instance"`
	Requests     int       `json:"requests"`
	WireTotal    int64     `json:"wireTotal"`
	PayloadTotal int64     `json:"payloadTotal"`
	APIs         []APIStat `json:"apis"`
}

// ReportJSON 是完整报告体(供 FFI/UI 直接消费)。
type ReportJSON struct {
	Enabled     bool           `json:"enabled"`
	Truncated   bool           `json:"truncated"`
	Samples     int            `json:"samples"`
	DroppedOver int            `json:"droppedOver"`
	MemBytes    int64          `json:"memBytes"`
	MaxSamples  int            `json:"maxSamples"`
	MaxMemBytes int64          `json:"maxMemBytes"`
	Instances   []InstanceStat `json:"instances"`
}

// 内部聚合中间态。
type psAgg struct {
	req           int
	wire, payload int64
}
type apiAgg struct {
	req           int
	wire, payload int64
	byPS          map[int]*psAgg
}
type instAgg struct {
	req           int
	wire, payload int64
	apis          map[string]*apiAgg
}

// Report 聚合当前样本并返回 JSON 字节(始终有效,即便未开启/无样本)。
func Report() []byte {
	global.mu.Lock()
	defer global.mu.Unlock()

	insts := map[string]*instAgg{}
	for _, s := range global.samples {
		ia := insts[s.inst]
		if ia == nil {
			ia = &instAgg{apis: map[string]*apiAgg{}}
			insts[s.inst] = ia
		}
		ia.req++
		ia.wire += int64(s.wire)
		ia.payload += int64(s.payload)

		aa := ia.apis[s.endpoint]
		if aa == nil {
			aa = &apiAgg{byPS: map[int]*psAgg{}}
			ia.apis[s.endpoint] = aa
		}
		aa.req++
		aa.wire += int64(s.wire)
		aa.payload += int64(s.payload)

		pa := aa.byPS[s.pageSize]
		if pa == nil {
			pa = &psAgg{}
			aa.byPS[s.pageSize] = pa
		}
		pa.req++
		pa.wire += int64(s.wire)
		pa.payload += int64(s.payload)
	}

	rep := ReportJSON{
		Enabled:     global.enabled.Load(),
		Truncated:   global.truncated,
		Samples:     len(global.samples),
		DroppedOver: global.droppedOver,
		MemBytes:    global.memBytes,
		MaxSamples:  global.maxSamples,
		MaxMemBytes: global.maxMemBytes,
		Instances:   make([]InstanceStat, 0, len(insts)),
	}
	for name, ia := range insts {
		is := InstanceStat{
			Instance:     name,
			Requests:     ia.req,
			WireTotal:    ia.wire,
			PayloadTotal: ia.payload,
			APIs:         make([]APIStat, 0, len(ia.apis)),
		}
		for ep, aa := range ia.apis {
			as := APIStat{
				Endpoint:     ep,
				Requests:     aa.req,
				WireTotal:    aa.wire,
				PayloadTotal: aa.payload,
				WireAvg:      avg(aa.wire, aa.req),
				PayloadAvg:   avg(aa.payload, aa.req),
				ByPageSize:   make([]PageSizeStat, 0, len(aa.byPS)),
			}
			for ps, pa := range aa.byPS {
				as.ByPageSize = append(as.ByPageSize, PageSizeStat{
					PageSize:     ps,
					Requests:     pa.req,
					WireTotal:    pa.wire,
					PayloadTotal: pa.payload,
					WireAvg:      avg(pa.wire, pa.req),
					PayloadAvg:   avg(pa.payload, pa.req),
				})
			}
			sort.Slice(as.ByPageSize, func(i, j int) bool {
				return as.ByPageSize[i].PageSize < as.ByPageSize[j].PageSize
			})
			is.APIs = append(is.APIs, as)
		}
		// API 按请求数降序,方便一眼看到大头。
		sort.Slice(is.APIs, func(i, j int) bool {
			if is.APIs[i].Requests != is.APIs[j].Requests {
				return is.APIs[i].Requests > is.APIs[j].Requests
			}
			return is.APIs[i].Endpoint < is.APIs[j].Endpoint
		})
		rep.Instances = append(rep.Instances, is)
	}
	sort.Slice(rep.Instances, func(i, j int) bool {
		return rep.Instances[i].Instance < rep.Instances[j].Instance
	})

	b, err := json.Marshal(rep)
	if err != nil {
		return []byte(`{"enabled":false,"instances":[]}`)
	}
	return b
}

func avg(total int64, n int) float64 {
	if n == 0 {
		return 0
	}
	return float64(total) / float64(n)
}
