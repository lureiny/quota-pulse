//go:build qpcgo

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"sync"
	"time"
	"unsafe"

	"github.com/lureiny/quota-pulse/core/app"
	"github.com/lureiny/quota-pulse/core/logx"
)

var (
	mu     sync.Mutex
	engine *app.App
	cancel context.CancelFunc
)

func withApp(f func(a *app.App)) {
	mu.Lock()
	a := engine
	mu.Unlock()
	if a != nil {
		f(a)
	}
}

// QP_Init 用 JSON 配置初始化引擎。成功返回 0,失败返回 -1。
//
//export QP_Init
func QP_Init(configJSON *C.char) (rc C.int) {
	// 注意具名返回:panic 被接住后零值是 0(=成功),必须显式改成 -1,
	// 否则宿主会以为初始化成功、后续所有调用都拿到一个空引擎。
	defer func() {
		if logx.Recover("QP_Init") {
			rc = -1
		}
	}()
	a, err := app.NewFromJSON(C.GoString(configJSON))
	if err != nil {
		logx.Printf("QP_Init failed: %v", err)
		return -1
	}
	mu.Lock()
	engine = a
	mu.Unlock()
	return 0
}

// QP_Start 开始轮询。
//
//export QP_Start
func QP_Start() {
	defer logx.Recover("QP_Start")
	mu.Lock()
	a := engine
	if a == nil {
		mu.Unlock()
		return
	}
	var ctx context.Context
	ctx, cancel = context.WithCancel(context.Background())
	mu.Unlock()
	a.Start(ctx)
}

// QP_Stop 停止轮询。
//
//export QP_Stop
func QP_Stop() {
	defer logx.Recover("QP_Stop")
	mu.Lock()
	a := engine
	c := cancel
	mu.Unlock()
	if c != nil {
		c()
	}
	if a != nil {
		a.Stop()
	}
}

// QP_SnapshotJSON 返回当前快照(JSON)。返回的 C 字符串由调用方用 QP_Free 释放。
//
//export QP_SnapshotJSON
func QP_SnapshotJSON() *C.char {
	defer logx.Recover("QP_SnapshotJSON")
	mu.Lock()
	a := engine
	mu.Unlock()
	if a == nil {
		return C.CString("[]")
	}
	return C.CString(a.SnapshotJSON())
}

// QP_ChartSeries 按维度聚合用量序列(JSON 进、JSON 出)。
// argsJSON: {"instance":"...","dimension":"account|api_key|model|user|group","hours":168}
// 返回 {series,coverageFrom,requestedFrom} 的 JSON;返回的 C 字符串由调用方用 QP_Free 释放。
//
//export QP_ChartSeries
func QP_ChartSeries(argsJSON *C.char) *C.char {
	defer logx.Recover("QP_ChartSeries")
	mu.Lock()
	a := engine
	mu.Unlock()
	if a == nil {
		return C.CString(`{"series":[],"coverageFrom":0,"requestedFrom":0}`)
	}
	var args struct {
		Instance  string `json:"instance"`
		Dimension string `json:"dimension"`
		Hours     int    `json:"hours"`
	}
	_ = json.Unmarshal([]byte(C.GoString(argsJSON)), &args)
	// 进/出断点:不可恢复的内存违例 recover 接不住,但「有 start 没 end」
	// 能把崩溃位置钉在这一段里。同时顺带记慢查询。
	logx.Printf("QP_ChartSeries start inst=%q dim=%q hours=%d", args.Instance, args.Dimension, args.Hours)
	t0 := time.Now()
	out := a.ChartSeriesJSON(args.Instance, args.Dimension, args.Hours)
	logx.Printf("QP_ChartSeries done  inst=%q %dms %dB", args.Instance, time.Since(t0).Milliseconds(), len(out))
	return C.CString(out)
}

// QP_ChartDailySeries 同 QP_ChartSeries,但按本地日聚合最近 days 天(供热力图)。
// argsJSON: {"instance":"...","dimension":"account|api_key|model|user|group","days":366}
// 返回 {series,coverageFrom,requestedFrom} 的 JSON;返回的 C 字符串由调用方用 QP_Free 释放。
//
//export QP_ChartDailySeries
func QP_ChartDailySeries(argsJSON *C.char) *C.char {
	defer logx.Recover("QP_ChartDailySeries")
	mu.Lock()
	a := engine
	mu.Unlock()
	if a == nil {
		return C.CString(`{"series":[],"coverageFrom":0,"requestedFrom":0}`)
	}
	var args struct {
		Instance  string `json:"instance"`
		Dimension string `json:"dimension"`
		Days      int    `json:"days"`
	}
	_ = json.Unmarshal([]byte(C.GoString(argsJSON)), &args)
	logx.Printf("QP_ChartDailySeries start inst=%q dim=%q days=%d", args.Instance, args.Dimension, args.Days)
	t0 := time.Now()
	out := a.ChartDailySeriesJSON(args.Instance, args.Dimension, args.Days)
	logx.Printf("QP_ChartDailySeries done  inst=%q %dms %dB", args.Instance, time.Since(t0).Milliseconds(), len(out))
	return C.CString(out)
}

// QP_Coverage 返回某实例的覆盖水位与全历史最早事件(供热力图判断补齐进度/年份列表)。
// argsJSON: {"instance":"..."}
// 返回 {coverageFrom,earliestEvent} 的 JSON;返回的 C 字符串由调用方用 QP_Free 释放。
//
//export QP_Coverage
func QP_Coverage(argsJSON *C.char) *C.char {
	defer logx.Recover("QP_Coverage")
	mu.Lock()
	a := engine
	mu.Unlock()
	if a == nil {
		return C.CString(`{"coverageFrom":0,"earliestEvent":0}`)
	}
	var args struct {
		Instance string `json:"instance"`
	}
	_ = json.Unmarshal([]byte(C.GoString(argsJSON)), &args)
	return C.CString(a.CoverageJSON(args.Instance))
}

// QP_ChartVersions 返回 {"实例名": 数据版本号, ...} 的 JSON。
// 版本号只在该实例的图表输入真的变了时递增;宿主据此决定要不要重新聚合。
// 极廉价(一次读锁 + 几十字节序列化),可高频调用。
// 返回的 C 字符串由调用方用 QP_Free 释放。
//
//export QP_ChartVersions
func QP_ChartVersions() *C.char {
	defer logx.Recover("QP_ChartVersions")
	mu.Lock()
	a := engine
	mu.Unlock()
	if a == nil {
		return C.CString("{}")
	}
	return C.CString(a.ChartVersionsJSON())
}

// QP_EnsureCoverage 触发按需回填:确保某实例本地覆盖延伸到 now-hours(异步、立即返回)。
// argsJSON: {"instance":"...","hours":168}
//
//export QP_EnsureCoverage
func QP_EnsureCoverage(argsJSON *C.char) {
	defer logx.Recover("QP_EnsureCoverage")
	mu.Lock()
	a := engine
	mu.Unlock()
	if a == nil {
		return
	}
	var args struct {
		Instance string `json:"instance"`
		Hours    int    `json:"hours"`
	}
	_ = json.Unmarshal([]byte(C.GoString(argsJSON)), &args)
	a.EnsureCoverage(args.Instance, args.Hours)
}

// QP_Refresh 触发一次强制回源。
//
//export QP_Refresh
func QP_Refresh(accountID *C.char) {
	defer logx.Recover("QP_Refresh")
	withApp(func(a *app.App) { a.Refresh(C.GoString(accountID)) })
}

// QP_SetForeground 弹层打开=1(提频),关闭=0(降频)。
//
//export QP_SetForeground
func QP_SetForeground(v C.int) {
	defer logx.Recover("QP_SetForeground")
	withApp(func(a *app.App) { a.SetPopoverOpen(v != 0) })
}

// QP_SetOnBattery 电池供电=1 时降频。
//
//export QP_SetOnBattery
func QP_SetOnBattery(v C.int) {
	defer logx.Recover("QP_SetOnBattery")
	withApp(func(a *app.App) { a.SetOnBattery(v != 0) })
}

// QP_SetAsleep 休眠/无网=1 时暂停轮询。
//
//export QP_SetAsleep
func QP_SetAsleep(v C.int) {
	defer logx.Recover("QP_SetAsleep")
	withApp(func(a *app.App) { a.SetAsleep(v != 0) })
}

// QP_DebugSet 开启/关闭客户端读流量采样(调试)。
// argsJSON: {"enabled":true,"maxSamples":200000,"maxMemBytes":33554432}
// enabled=true 重置缓冲并开采;false 停采(保留已采样本)。上限省略/<=0 走默认。
//
//export QP_DebugSet
func QP_DebugSet(argsJSON *C.char) {
	defer logx.Recover("QP_DebugSet")
	mu.Lock()
	a := engine
	mu.Unlock()
	if a == nil {
		return
	}
	var args struct {
		Enabled     bool  `json:"enabled"`
		MaxSamples  int   `json:"maxSamples"`
		MaxMemBytes int64 `json:"maxMemBytes"`
	}
	_ = json.Unmarshal([]byte(C.GoString(argsJSON)), &args)
	a.DebugSet(args.Enabled, args.MaxSamples, args.MaxMemBytes)
}

// QP_DebugReport 返回当前采样报告(JSON)。返回的 C 字符串由调用方用 QP_Free 释放。
//
//export QP_DebugReport
func QP_DebugReport() *C.char {
	defer logx.Recover("QP_DebugReport")
	mu.Lock()
	a := engine
	mu.Unlock()
	if a == nil {
		return C.CString(`{"enabled":false,"instances":[]}`)
	}
	return C.CString(a.DebugReportJSON())
}

// QP_DebugReset 清空已采样本(保留开关与上限)。
//
//export QP_DebugReset
func QP_DebugReset() {
	defer logx.Recover("QP_DebugReset")
	withApp(func(a *app.App) { a.DebugReset() })
}

// QP_Log 让宿主(Dart)把一行日志写进**同一个**日志文件。
//
// 刻意不让 Dart 自己写文件:两个写者写一个文件要么加锁要么分文件,
// 而排查崩溃时最需要的恰恰是「Dart 侧动作」与「Go 侧动作」在同一条时间线上对齐 ——
// 比如「worker spawn → 打开 dylib → QP_ChartDailySeries start → (没有 done)」。
// 日志没开时这里是一次原子读 + 立即返回。
//
//export QP_Log
func QP_Log(line *C.char) {
	defer logx.Recover("QP_Log")
	if !logx.Enabled() {
		return
	}
	logx.Printf("%s", C.GoString(line))
}

// QP_LogPath 返回当前日志文件路径(未启用返回空串),供 UI 展示「日志在哪」。
// 返回的 C 字符串由调用方用 QP_Free 释放。
//
//export QP_LogPath
func QP_LogPath() *C.char {
	defer logx.Recover("QP_LogPath")
	return C.CString(logx.Path())
}

// QP_Free 释放由本库返回的 C 字符串。
//
//export QP_Free
func QP_Free(p *C.char) {
	defer logx.Recover("QP_Free")
	C.free(unsafe.Pointer(p))
}
