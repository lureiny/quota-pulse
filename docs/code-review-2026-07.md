# 全项目代码审查与维护记录（2026-07）

本文记录 2026-07-11 对 quota-pulse 的一次全仓审查。它不是发布说明，而是后续维护者判断“为什么这样改、哪些债务还在”的依据。

## 审查范围与方法

- Go：`core/app`、`poller`、`provider`、`providers/sub2api`、`usage`、`netstat`、C-ABI、gomobile 与 `qpctl`。
- Flutter/Dart：共享模型、设置持久化、FFI 内存所有权、图表、通知、托盘文本，以及 macOS / Windows 壳层。
- 原生与工程：Swift 菜单栏、Windows C++ 浮窗、构建脚本、CI、Claude Code 状态栏集成和现有文档。
- 验证基线：Go build/vet/test/race、Flutter analyze、C-shared 构建、脚本语法与 fixture 冒烟。

## 本轮已修复

| 级别 | 问题 | 影响 | 处理 |
|---|---|---|---|
| P0 | 首次 usage 同步先提交事件/`last_id`，再单独写覆盖水位 W | 两次提交间崩溃会留下 `last_id>0 && W=0`，重启后永久跳过初始化窗口 | 新增 `usage.Store.AddInitialEvents`，事件、游标和 W 在一个 SQLite 事务提交；失败回滚测试覆盖 |
| P1 | `/admin/accounts` 只读取第一页 | 超过 200 个账户时静默漏账户 | 按响应 `pages` 拉全，保留每页 ETag，并加入异常页数上限 |
| P1 | HTTP `data` 缓存按完整 path 永久增长 | 历史回填的日期和页码不断制造新键，长期运行可能占用大量内存 | 加入 64 条 / 16 MiB 双上限 FIFO，并复制 `RawMessage`，不再钉住完整 envelope backing array |
| P1 | `Evict` 按 `hour_local` 删除 | 截止时间落在小时中间时，会误删同小时但仍在保留期内的事件 | 改按精确 `created_at` 删除，并增加 `(instance, created_at)` 索引 |
| P1 | 截断且零事件的回填仍可能推进 W | 无法证明覆盖进度时会把未知区间标成已覆盖 | `complete=false && len(events)==0` 时不写游标/水位，留待下轮重试 |
| P1 | `qpctl -once` 在第一个 provider 回调就停止，且可能仍等满 30 秒 | 多实例输出可能是局部快照，单实例也有无谓等待 | 增加等待全部 provider 的 `PollOnce`，完成后只输出最终快照 |
| P1 | `ListAccounts` 已拿到新的账户管理状态，但 `FetchUsage` 失败时整条丢弃 | 不支持 passive 的账户会长期冻结 429/暂停/配额状态 | 只把列表派生的 `AccountState` 合并进已有 last-good，窗口/更新时间保持不变，也不创建空账户 |
| P2 | 本地日左界用 `(days-1)*86400` | 夏令时切换附近会偏一小时，漏/多一个日桶 | 改用本地日历 `AddDate`，并加入 DST 回拨测试 |
| P2 | C-ABI 重复 `QP_Init` 不回收旧引擎 | 非标准调用顺序会遗留轮询器和 SQLite 句柄 | 成功构建新引擎后原子替换，并停止旧引擎；失败仍保留旧引擎 |
| P2 | SQLite 图表查询错误被折叠成空序列 | UI 会把数据库故障误显示成“所选区间暂无请求”，破坏 `''`=失败、`[]`=真空的 FFI 约定 | 查询 API 返回显式 error；facade 用空串 failure sentinel，Dart 进入“数据获取异常”态 |
| P2 | provider 重复注册会静默覆盖 | 新 provider 或插件键冲突时行为取决于初始化顺序 | 重复 key 立即 panic，在开发/测试阶段暴露冲突 |
| P2 | FFI 默认库名先于包内绝对路径 | Windows/Linux 可能从当前工作目录误载同名库 | 包内/可执行文件同级路径优先，默认搜索路径只作开发兜底 |
| P2 | Claude Code 状态栏缓存仅以账户 ID 命名且放在共享临时目录 | 多实例同号账户串缓存；Linux `/tmp` 下权限边界不理想；并发写可读到半文件 | 改为用户私有 cache、实例/账户/source 匿名指纹、原子写；admin key 通过 stdin header 交给 curl，不进入 argv |
| P2 | 开机自启边界问题 | macOS 特殊字符路径会破坏 plist；Windows 便携目录移动后仍误报“已启用” | XML 转义；Windows 校验注册项是否确实指向当前 exe |
| P2 | 通知“首次静默”只用一个全局标志 | 多 provider 首轮并发时，后到实例的高用量可能被误报为运行期越阈值 | 改为按 `instance|account|meter` 分别 seed，晚到的首个样本同样静默 |
| P3 | Flutter `Color.value` 弃用、macOS 冗余 import | 新 SDK 静态分析有噪声 | 改为 `toARGB32()` 并清理 import |

## 本轮验证结果

- `go build ./...`、`go vet ./...`、`go test -race ./...`：通过。
- `go build -tags qpcgo -buildmode=c-shared`：通过；`build_macos_dylib.sh` 生成并由 `lipo` 验证 arm64 + x86_64 universal dylib。
- `flutter analyze`：`ui/`、`apps/macos/`、`apps/windows/` 均为 0 issue。macOS 额外有第三方插件 SPM 的未来兼容 warning，见遗留风险。
- `bash -n` 与状态栏 fixture：通过，包含非法数值配置回退冒烟。
- 本机没有完整 Xcode（缺 `xcodebuild`），因此 macOS app debug build 无法在本轮本地完成；Windows 原生 runner/C++ 也必须在 Windows 目标机或 CI 验证。它们属于环境验证缺口，不记作代码通过。

## 架构结论

`core/ → ui/ → apps/<platform>/` 的主边界仍然正确，provider 也保持“新增实现只改 provider 包 + facade blank import”的扩展模型。本轮修复没有把 sub2api DTO、SQLite 或平台 API 泄漏到共享模型之外。

当前最明显的边界压力在桌面壳：`apps/macos/lib/main.dart` 与 `apps/windows/lib/main.dart` 都包含一套相似的设置保存、核心重启、通知、调试和页面路由协调逻辑。平台托盘、定位、浮窗仍应留在壳层，但通用协调逻辑下一轮可下沉为 `ui/` 内的 `DesktopShellCoordinator`，平台侧只实现 tray/window/autostart adapter。这个重构需要先有 Dart 单元测试和两端集成冒烟，否则一次性搬运的回归风险高于收益，本轮没有强行改动。

另外几个热点文件（`settings_page.dart`、`hourly_chart.dart`、Windows `win_ticker.cpp`）体积较大，但目前职责仍可辨认。建议按“可独立测试的状态/布局算法”拆分，而不是只为了行数拆文件。

## 尚未清零的风险与建议顺序

1. **管理员 API key 仍由 SharedPreferences 明文持久化。** 建议引入共享 `CredentialStore` 抽象：macOS Keychain、Windows Credential Manager/DPAPI；用稳定实例 ID 作为引用，`Settings` 只存 credential ref，并提供一次性迁移与失败回滚。
2. **Dart 侧没有自动化测试。** 优先给 `Settings` JSON 迁移、tray 文本、`ChartData`、通知去重和配置导入导出补纯 Dart 测试；随后再抽壳层 coordinator。
3. **核心停止不是等待式关闭。** 当前取消 context 后会立即关闭 usage DB，已在途同步可能收到 `database is closed` 并在下轮/下次启动重试。若未来要求严格的优雅关闭，应给 poller 的网络/同步任务做 WaitGroup，同时保证订阅回调中调用 Stop 不会自锁。
4. **依赖存在有意保留的 major 更新。** `window_manager 0.5.x` 与 `flutter_lints 6.x` 可解析，但应在 macOS、Windows 目标机都完成打包和交互冒烟后升级，不能只凭 analyze 通过。
5. **平台原生代码缺少独立 CI 静态检查。** Windows C++ 目前只能随 Windows release job 编译；可增加常规 push/PR 的 verify workflow，跑 Go race、三份 Flutter analyze、macOS/Windows debug build 和脚本冒烟。
6. **macOS analyze 已提示 `window_manager` 与 `local_notifier` 尚不支持 Swift Package Manager。** 当前仍是 warning，但 Flutter 明示未来会升级为 error；升级插件前要确认其 SPM 支持，或在生成 runner/CI 中明确固定 CocoaPods 路径。
7. **历史接口只有日历日过滤、事件却按 id 排序。** 极高流量实例若在 W 所在日的较新事件已超过 `page_cap`，反向流可能反复触不到 W 左侧。彻底解决需要持久化“扫描进度”或上游提供精确时间/id 边界，不能靠把 W 提前来掩盖；当前实现宁可保持未覆盖，也不谎报完成。

## 后续维护清单

每次涉及同步或存储时，至少复核以下不变量：

- `poller.Store` 的 key 必须是 `instance|accountID`。
- 只有首次增量初始化能同时写 `last_id` 与 W，且必须同一事务；稳态增量不改 W。
- 回填被截断时，W 只能到“已证明抓到”的最老位置；零进度不能谎报完成。
- 任何拉取错误都不能覆盖 last-good 快照。
- 所有 Go 返回的 C 字符串只能由 `QP_Free` 释放；Dart 入参只能由 `malloc.free` 释放。
- UI-only 设置不能进入 `toConfigJson()`，避免无意义重启核心。
- generated runner 仍是 gitignored 产物；补丁源只在 `runner_patches/`。

建议每个发布周期至少执行：

```bash
cd core
go build ./... && go vet ./... && go test -race ./...

cd ../ui
flutter pub get && flutter analyze

cd ../apps/macos
flutter pub get && flutter analyze

cd ../windows
flutter pub get && flutter analyze
```

目标平台发布前再运行各自 `setup_*` + `build_app.*`，并人工确认托盘、弹层、开机自启、配置迁移和一次真实只读拉取。
