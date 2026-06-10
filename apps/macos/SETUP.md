# quota-pulse · macOS 搭建 / 打包指南

把 Go 核心(`libqp.dylib`)嵌进一个 Flutter 菜单栏 App,通过 `dart:ffi` 调用,
最终产出一个**自包含、可双击运行、可分发**的 `quota_pulse.app`(+ `.dmg`)。
**全程在 macOS 上做,且不需要打开 Xcode。** 需要 Xcode 命令行工具 + Flutter SDK + Go。

```
apps/macos/
├── lib/main.dart         # 薄壳入口(共享 UI 在 ../../ui 的 quota_pulse_ui 包)
├── pubspec.yaml          # 依赖:quota_pulse_ui(path) / tray_manager / window_manager
├── assets/tray_icon.png  # 菜单栏模板图标
├── setup_macos.sh        # ① 一次性:生成 runner + 套补丁(免 Xcode)
├── build_app.sh          # ② 一键:出 dist/quota_pulse.app + .dmg(免 Xcode)
├── build_macos_dylib.sh  # (被 build_app.sh 调用)编 Go → libqp.dylib
├── runner_patches/        # 套到 macos/ 的补丁(脚本自动应用)
└── macos/                 # 由 setup_macos.sh 生成(此处暂无)
```

> 共享 UI / 模型 / 状态 / FFI 桥在 `../../ui`(`package:quota_pulse_ui`),`flutter pub get` 会经 path 依赖自动拉取。

---

## 推荐流程:两条命令出包(不开 Xcode)

### 0. 准备

```bash
flutter --version                  # Flutter 3.24+ / Dart 3.4+
flutter config --enable-macos-desktop
go version                         # Go 1.24
```

### 1. 一次性脚手架

```bash
cd apps/macos
./setup_macos.sh
```

它做三件事(都脚本化、无需手点):生成 `macos/` runner → 套补丁(`AppDelegate` 不退出 +
entitlements 的 `network.client` 出站权限 + `Info.plist` 的 `LSUIElement` 无 Dock)→ `flutter pub get`。

### 2. 一键出包

```bash
./build_app.sh
```

它做五步:编 `libqp.dylib`(arm64+amd64 通用)→ `flutter build macos --release` →
把 dylib **注入** `.app/Contents/Frameworks` → **ad-hoc 签名**(dylib + 整包,Apple Silicon 必需)→
打成 `.dmg`。产物:

```
dist/quota_pulse.app   # 自包含 App
dist/quota_pulse.dmg   # 可分发镜像(带「拖到 Applications」)
```

> 改了 `core/` 或 `lib/` 后,重跑 `./build_app.sh` 即可。日常调试用 `flutter run -d macos`。

### 3. 分发(多人 · 无开发者账号)

把 `quota_pulse.dmg` 发给对方 → 拖进「应用程序」。因为**没做 Apple 公证**,首次打开要绕过
Gatekeeper 一次(这和大量开源 macOS 应用一样):

- **右键点 App →「打开」→** 弹窗里再点「打开」(之后双击照常);或
- 终端一行:`xattr -dr com.apple.quarantine /Applications/quota_pulse.app`

> 想做到「别人双击零提示」需要 Apple 开发者账号($99/年)做 **codesign + 公证**——
> 那是另一条路,不在本流程里。

### 4. 使用

1. 菜单栏出现图标(+ 实时峰值百分比)。
2. 左键点开 → 弹层。首次运行自动进设置页。
3. 填 **Base URL** 和 **Admin API Key**(`x-api-key`)→ **保存并连接**。
4. 看到各账户的 5h / 7d 等窗口进度条 + 重置倒计时 + 状态色。右键菜单:刷新 / 设置 / 退出。

---

## 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| `flutter build macos` 报签名错误 | 多数情况下免账号也能本地 ad-hoc 构建;若报错,打开 `macos/Runner.xcworkspace` → Runner → Signing & Capabilities → Team 选 None / 勾「Sign to Run Locally」,再重跑 `./build_app.sh`(末尾会自动 ad-hoc 重签)。 |
| 对方打不开,提示「无法验证开发者」 | 正常(未公证)。按上面第 3 步「右键→打开」或 `xattr` 去隔离。 |
| Apple Silicon 上闪退/「已损坏」 | 注入的 dylib 没签名。确认 `build_app.sh` 第 4 步执行成功(`codesign --verify` 通过)。 |
| 菜单栏什么都没有 | 确认 `assets/tray_icon.png` 已随 `flutter pub get` 打包(pubspec 的 `flutter.assets`)。 |
| 弹「无法加载 libqp.dylib」 | 注入或签名失败;重跑 `./build_app.sh`,看第 3、4 步日志。 |
| 账户全是「错误/超时」 | ① entitlements 缺 `network.client`(`setup_macos.sh` 已套);② URL/Key 填错;③ 网络不通。 |
| 数据不刷新 | 默认 60s 被动轮询、10m 稀疏回源;点「刷新」立即强制回源。 |

---

## 备选:手动 Xcode 流程(仅在脚本签名出问题时回退)

1. `./build_macos_dylib.sh` 出 `build/libqp.dylib`。
2. `flutter create --platforms=macos --org com.lureiny --project-name quota_pulse /tmp/qp_gen && cp -R /tmp/qp_gen/macos ./macos && rm -rf /tmp/qp_gen`
3. 手动套 `runner_patches/`(三个文件 + 按 `Info.plist.additions.md` 加 `LSUIElement`)。
4. Xcode 打开 `macos/Runner.xcworkspace` → Runner target → General →
   「Frameworks, Libraries, and Embedded Content」→ `+` → Add Other… → 选 `build/libqp.dylib` → **Embed & Sign**。
5. `flutter pub get && flutter run -d macos`。

---

## 数据流回顾(FFI)

```
Flutter UI ──每2s── snapshotJson() ──dart:ffi──▶ libqp.dylib(Go core)
                                                   └ 自己按节奏轮询 sub2api
设置保存 ── init(configJson) + start() ──▶ 同上
开/收弹层 ── setForeground(bool) ──▶ Go 调度器提频/降频(省电)
```

Go 核心负责真正的网络轮询与缓存;Dart 只廉价地读内存快照来渲染。
