// Command qpctl 是一个最小命令行驱动,用于本地手动验证核心:
// 读配置、轮询一轮、把快照打到 stdout。便于在没有 UI 时联调 sub2api。
//
//	go run ./cmd/qpctl -config ../config.example.json -once
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"time"

	"github.com/lureiny/quota-pulse/core/app"
	"github.com/lureiny/quota-pulse/core/config"
)

func main() {
	cfgPath := flag.String("config", "config.example.json", "配置文件路径")
	once := flag.Bool("once", false, "只拉一轮就退出")
	flag.Parse()

	cfg, err := config.Load(*cfgPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "load config:", err)
		os.Exit(1)
	}
	a, err := app.New(cfg)
	if err != nil {
		fmt.Fprintln(os.Stderr, "init app:", err)
		os.Exit(1)
	}

	a.Subscribe(func(js string) {
		fmt.Println(js)
		if *once {
			a.Stop()
		}
	})

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	a.Start(ctx)

	if *once {
		// 给首轮一点时间;首轮回调里会 Stop。
		select {
		case <-ctx.Done():
		case <-time.After(30 * time.Second):
		}
		return
	}
	<-ctx.Done()
}
