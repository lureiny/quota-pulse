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
	"unsafe"

	"github.com/lureiny/quota-pulse/core/app"
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
func QP_Init(configJSON *C.char) C.int {
	a, err := app.NewFromJSON(C.GoString(configJSON))
	if err != nil {
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
	return C.CString(a.ChartSeriesJSON(args.Instance, args.Dimension, args.Hours))
}

// QP_EnsureCoverage 触发按需回填:确保某实例本地覆盖延伸到 now-hours(异步、立即返回)。
// argsJSON: {"instance":"...","hours":168}
//
//export QP_EnsureCoverage
func QP_EnsureCoverage(argsJSON *C.char) {
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
	withApp(func(a *app.App) { a.Refresh(C.GoString(accountID)) })
}

// QP_SetForeground 弹层打开=1(提频),关闭=0(降频)。
//
//export QP_SetForeground
func QP_SetForeground(v C.int) {
	withApp(func(a *app.App) { a.SetPopoverOpen(v != 0) })
}

// QP_SetOnBattery 电池供电=1 时降频。
//
//export QP_SetOnBattery
func QP_SetOnBattery(v C.int) {
	withApp(func(a *app.App) { a.SetOnBattery(v != 0) })
}

// QP_SetAsleep 休眠/无网=1 时暂停轮询。
//
//export QP_SetAsleep
func QP_SetAsleep(v C.int) {
	withApp(func(a *app.App) { a.SetAsleep(v != 0) })
}

// QP_DebugSet 开启/关闭客户端读流量采样(调试)。
// argsJSON: {"enabled":true,"maxSamples":200000,"maxMemBytes":33554432}
// enabled=true 重置缓冲并开采;false 停采(保留已采样本)。上限省略/<=0 走默认。
//
//export QP_DebugSet
func QP_DebugSet(argsJSON *C.char) {
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
	withApp(func(a *app.App) { a.DebugReset() })
}

// QP_Free 释放由本库返回的 C 字符串。
//
//export QP_Free
func QP_Free(p *C.char) {
	C.free(unsafe.Pointer(p))
}
