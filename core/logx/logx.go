// Package logx 是一个极简的文件日志:单文件、按大小轮转一次、并发安全、默认关闭。
//
// 存在的理由:这个 App 在排查线上问题时**一行日志都没有** —— Go 侧和 Dart 侧都不写。
// 桌面端又没有终端可看(从 Finder / 资源管理器启动时 stdout 进系统日志、极难捞),
// 出现闪退时只能靠系统崩溃报告倒推,成本极高。
//
// 设计取舍:
//   - **不引第三方日志库**。这里只要「能落盘、能轮转、不会把磁盘写爆」,标准库够了。
//   - **同步写**。日志量很小(生命周期事件 + 错误 + 慢查询),同步写省掉一整套缓冲/刷盘/
//     退出时丢日志的复杂度;真正频繁的东西不该进日志。
//   - **永不 panic、永不返回错误**。日志本身绝不能成为新的故障源:写失败就静默丢弃。
//   - 默认关闭,由配置打开(见 config.LogConfig)。关闭时 [Printf] 是一次原子读 + 立即返回。
package logx

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"sync/atomic"
	"time"
)

const (
	// maxBytes 是单个日志文件的上限,超过就轮转成 .1(只保留一代)。
	// 2MB 足够装下几天的生命周期日志,又不至于让用户的配置目录变大。
	maxBytes = 2 << 20
)

var (
	enabled atomic.Bool

	mu   sync.Mutex
	f    *os.File
	size int64
	path string
)

// Open 打开日志文件并启用日志。重复调用会先关掉旧的(核心重启会走到)。
// 失败时静默保持关闭状态 —— 日志不可用绝不能影响主功能。
func Open(p string) {
	if p == "" {
		return
	}
	mu.Lock()
	defer mu.Unlock()

	if f != nil {
		_ = f.Close()
		f = nil
	}
	if dir := filepath.Dir(p); dir != "" {
		_ = os.MkdirAll(dir, 0o755)
	}
	h, err := os.OpenFile(p, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		enabled.Store(false)
		return
	}
	st, err := h.Stat()
	if err != nil {
		_ = h.Close()
		enabled.Store(false)
		return
	}
	f, size, path = h, st.Size(), p
	enabled.Store(true)
}

// Close 关闭日志并停用。
func Close() {
	enabled.Store(false)
	mu.Lock()
	defer mu.Unlock()
	if f != nil {
		_ = f.Close()
		f = nil
	}
}

// Path 返回当前日志文件路径(未启用时为空串)。供 UI 展示「日志在哪」。
func Path() string {
	if !enabled.Load() {
		return ""
	}
	mu.Lock()
	defer mu.Unlock()
	return path
}

// Enabled 报告日志是否已启用。热路径上想跳过昂贵的参数拼接时先问它。
func Enabled() bool { return enabled.Load() }

// Printf 写一行日志(自动加时间戳与换行)。未启用时立即返回。
func Printf(format string, args ...any) {
	if !enabled.Load() {
		return
	}
	line := time.Now().Format("2006-01-02 15:04:05.000") + " " + fmt.Sprintf(format, args...) + "\n"

	mu.Lock()
	defer mu.Unlock()
	if f == nil {
		return
	}
	// 超限先轮转:当前文件改名成 .1(覆盖上一代),重新开一个。
	// 只保留一代 —— 崩溃排查看的是最近的日志,留太多没意义还占地方。
	if size+int64(len(line)) > maxBytes {
		_ = f.Close()
		f = nil
		_ = os.Rename(path, path+".1")
		h, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
		if err != nil {
			enabled.Store(false)
			return
		}
		f, size = h, 0
	}
	n, err := f.Write([]byte(line))
	if err != nil {
		// 写失败(磁盘满 / 文件被删)→ 停掉日志,绝不重试、绝不上抛。
		enabled.Store(false)
		return
	}
	size += int64(n)
}

// Recover 在 defer 里捕获 panic、写进日志并吞掉。
//
// **这是本包最重要的一个函数。** Go 的 panic 在 c-shared 库里会直接终止宿主进程 ——
// 表现为「App 闪退」,而且崩溃报告里只能看到线程栈、看不到 Go 的 panic 信息。
// 在每个 C-ABI 导出口 defer 一个 Recover,panic 就会变成「一行日志 + 该调用返回零值」,
// 既保住了进程,也把原因落到了盘上。
//
// where 用调用点的导出名(如 "QP_ChartSeries"),便于定位。
// 返回是否真的捕获到了 panic —— 调用方据此把返回值改成失败态
// (例如 QP_Init 的零值 0 表示成功,panic 后必须改成 -1)。
//
// **注意它的能力边界**:recover 只能接住 Go 的 panic。真正的内存访问违例
// (堆损坏、cgo 里的段错误)是不可恢复的,进程照样会挂 —— 那种情况下要靠
// 导出口的「进/出」日志留下断点:有 start 没 end 就说明死在那一段里。
func Recover(where string) bool {
	r := recover()
	if r == nil {
		return false
	}
	// 即使日志没开也要尽力留痕:stderr 在从终端启动时可见,
	// 从 Finder 启动时会进 macOS 统一日志(log show 能捞到)。
	msg := fmt.Sprintf("PANIC in %s: %v\n%s", where, r, stack())
	if enabled.Load() {
		Printf("%s", msg)
	} else {
		fmt.Fprintln(os.Stderr, "[quota-pulse] "+msg)
	}
	return true
}

func stack() string {
	buf := make([]byte, 16<<10)
	n := runtime.Stack(buf, false) // 只要当前 goroutine,全量栈在这里没有额外价值
	return string(buf[:n])
}
