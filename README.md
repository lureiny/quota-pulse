# quota-pulse

一个跨平台的「用量脉搏」预览栏:在系统菜单栏 / 托盘里快速查看
[sub2api](https://github.com/Wei-Shaw/sub2api) 各账户的用量窗口(5h / 7d 等),
只读展示。抽象做了分层,未来可扩展到 one-api / new-api 等平台。

## 结构

```
core/          平台无关 Go 核心(provider 抽象 · 轮询 · 缓存 · C-ABI/gomobile 桥)
ui/            跨平台 Flutter 共享包 package:quota_pulse_ui(模型 / UI / 状态 / FFI 桥)
apps/macos/    macOS 菜单栏薄壳 + 打包(.dmg)
apps/windows/  Windows 托盘薄壳 + 打包(.zip)
DESIGN.md      总体设计:选型 · 架构 · Provider 抽象 · 里程碑
```

> 复用边界:`core/` + `ui/` 跨平台 100% 复用;`apps/<platform>/` 只是各自的薄外壳(托盘/窗口/打包)。

## 本地构建

- **macOS**:见 [`apps/macos/SETUP.md`](apps/macos/SETUP.md) — `./setup_macos.sh && ./build_app.sh` → `.dmg`
- **Windows**:见 [`apps/windows/SETUP.md`](apps/windows/SETUP.md) — `./setup_windows.ps1; ./build_app.ps1` → `.zip`
- **Go 核心**:见 [`core/README.md`](core/README.md) — `go build ./... && go test ./...`

## 自动构建(GitHub Actions)

推一个 `v*` tag 即在云端 macOS / Windows runner 上自动编译并发布到 Releases:

```bash
git tag v0.1.0 && git push origin v0.1.0
```

工作流见 [`.github/workflows/release-desktop.yml`](.github/workflows/release-desktop.yml)。
也可在 Actions 页手动触发(workflow_dispatch),只产出构件、不建 Release。

> 产物未做付费签名/公证:macOS 首次「右键→打开」,Windows 首次 SmartScreen「仍要运行」。

## 字体

**Windows 端**打包内嵌 [MiSans](https://hyperos.mi.com/font/download)(小米,免费商用):
系统中文字体雅黑缺 Medium/Semibold,会把 `w500/w600` 就近吸附成 Regular/Bold,
字重忽粗忽细;内嵌 MiSans 修正。**macOS** 用系统 SF Pro(字重本就齐全,无需替换,也不增体积)。
字体版权归小米所有,许可见 [`ui/lib/fonts/MiSans-LICENSE.txt`](ui/lib/fonts/MiSans-LICENSE.txt)。

## 状态

详见 [DESIGN.md §9 里程碑](DESIGN.md)。M1(macOS)代码完成并可打包;M3(Windows)代码完成,待实机/CI 终验。
