# quota-pulse core

平台无关的核心:provider 抽象、通用数据模型、轮询/缓存、配置,以及给桌面(FFI)
和移动端(gomobile)的桥接层。一份核心喂所有平台。详见仓库根 `DESIGN.md`。

## 包结构

| 包 | 职责 |
|---|---|
| `model` | 通用数据模型 `Account` / `AccountPulse` / `Meter`(UI 唯一消费的结构) |
| `config` | 运行配置(JSON,支持 `${ENV}` 与 `"60s"` 时长) |
| `provider` | `Provider` 接口、`AuthScheme` + HTTP 客户端(ETag/304)、工厂注册表 |
| `providers/sub2api` | sub2api 实现:client + DTO + mapper(`UsageInfo` → `[]Meter`) |
| `poller` | 轮询引擎 + 快照存储 + 调度器(省电:弹层/电池/休眠自适应) |
| `usage` | SQLite 原始事件库、增量游标/覆盖水位、小时/本地日多维聚合 |
| `netstat` | 可选的进程内 HTTP 流量采样与聚合报告(有采样数/内存上限) |
| `app` | 门面 `App`:桥接层与宿主只跟它打交道 |
| `bridge` | gomobile 友好 API(`Engine` + `Delegate`,JSON over 边界) |
| `cmd/libqp` | C-ABI 导出(`-buildmode=c-shared`/`c-archive`,需 `-tags qpcgo`) |
| `cmd/qpctl` | 本地联调用的最小 CLI |

## 构建与测试

```bash
# 纯 Go 编译/检查/测试(无需 C 工具链)
go build ./...
go vet ./...
go test ./...

# 本地联调(填好 config.example.json + 导出 SUB2API_ADMIN_API_KEY)
go run ./cmd/qpctl -config config.example.json -once

# 桌面共享库(Dart FFI 用;需 cgo)
go build -tags qpcgo -buildmode=c-shared -o libqp.dylib ./cmd/libqp   # macOS
go build -tags qpcgo -buildmode=c-shared -o libqp.so    ./cmd/libqp   # Linux

# 移动端绑定(需 gomobile / Xcode / Android NDK)
gomobile bind -target=ios     -o QuotaPulse.xcframework ./bridge
gomobile bind -target=android -o quotapulse.aar         ./bridge
```

`-once` 会并发等待所有 provider 完成一轮强制回源,然后只输出一份最终快照;
不会在第一个实例回调时提前退出。

## 同步与内存边界

- 首次 usage 初始化由 `Store.AddInitialEvents` 在一个事务内提交事件、`last_id` 与覆盖水位 W。
  空窗口也原子写 W;稳态 `AddEvents` 只推进游标,绝不改 W。
- 历史回填被页上限截断时,W 只推进到已抓到的最老事件;截断且零事件不推进。
- HTTP 304 数据缓存为有界 FIFO(默认 64 条 / 16 MiB),避免日期×页码路径长期堆积。
- retention 清理按精确 `created_at` 执行,不会误删截止小时内仍在保留期的事件。

## 扩展新平台(one-api / new-api)

1. 新建 `providers/oneapi/`,实现 `provider.Provider`:
   - `client.go`:调其配额端点(如 `/api/token/`),`AuthScheme{Header:"Authorization", Prefix:"Bearer "}`;
     new-api 额外 `Extra{"New-Api-User": id}`。
   - `mapper.go`:把"已用/总额配额"映射成 `Meter{Kind: KindCumulative, Used, Limit, Unit: UnitUSD}`(无 `ResetsAt`)。
   - `Capabilities{HasCumulativeQuota: true, HasRollingWindows: false}`。
   - `init()` 里 `provider.Register("oneapi", New)`。
2. 在 `app/facade.go` 顶部加一行 `_ "…/providers/oneapi"`。
3. **UI 与各平台外壳零改动** —— 它们只消费 `AccountPulse`/`Meter`。
