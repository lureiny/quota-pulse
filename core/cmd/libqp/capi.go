//go:build qpcgo

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
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

// QP_Free 释放由本库返回的 C 字符串。
//
//export QP_Free
func QP_Free(p *C.char) {
	C.free(unsafe.Pointer(p))
}
