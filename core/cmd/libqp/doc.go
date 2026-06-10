// Command libqp 把 quota-pulse 核心编译成 C 共享/静态库,供桌面端
// 通过 dart:ffi 调用。
//
// 桌面共享库(需 C 工具链,带 qpcgo tag):
//
//	go build -tags qpcgo -buildmode=c-shared -o libqp.dylib ./cmd/libqp   # macOS
//	go build -tags qpcgo -buildmode=c-shared -o libqp.so    ./cmd/libqp   # Linux
//	go build -tags qpcgo -buildmode=c-shared -o libqp.dll   ./cmd/libqp   # Windows(mingw)
//
// iOS 静态库(打成 xcframework):
//
//	go build -tags qpcgo -buildmode=c-archive -o libqp.a ./cmd/libqp
//
// 不带 qpcgo tag 时,本目录只是一个空占位程序,使 `go build ./...` /
// `go vet ./...` 在没有 C 工具链时也能保持绿色。实际 C-ABI 导出见 capi.go。
package main

func main() {}
