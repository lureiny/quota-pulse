# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

quota-pulse is a cross-platform menu-bar / system-tray app that shows [sub2api](https://github.com/Wei-Shaw/sub2api) account usage windows (Claude 5h/7d, Gemini daily/minute, …) at a glance. It is **read-only** — it never mutates anything upstream.

**The stack is three layers, and the reuse boundary is load-bearing:**

- `core/` — platform-agnostic **Go** engine (provider abstraction, polling, cache, SQLite usage store, config, the C-ABI/gomobile bridge). 100% shared.
- `ui/` — one shared **Flutter** package `package:quota_pulse_ui` (models, widgets, pages, state, the `dart:ffi` bridge). 100% shared.
- `apps/macos/`, `apps/windows/` — **thin shells** only: tray/menu-bar icon, popover window, autostart, native ticker, packaging.

Adding a provider = a new `core/providers/<name>/` package + one blank-import line, **zero UI/shell changes**. Adding a platform = a new thin `apps/<platform>/` shell + a native-lib build script. Keep code on the correct side of this boundary.

Design rationale and milestones live in `DESIGN.md` (Chinese); package-level notes in `core/README.md`; the passive/active cache design in `docs/sub2api-usage-cache.md`.

## Commands

### Go core (verify on any OS — no C toolchain needed)
```bash
cd core
go build ./... && go vet ./... && go test ./...     # full check; run before tagging a release
go test ./poller/ -run TestName -v                  # single test (any package: ./provider/, ./usage/, ./config/, ./app/)
go run ./cmd/qpctl -config config.example.json -once # one live poll round → snapshot JSON on stdout (needs SUB2API_ADMIN_API_KEY exported)
```
All automated tests in this repo are Go (`core/`). **There are currently no Dart/Flutter `*_test.dart` files** under `ui/` or `apps/` — don't go hunting for a Dart test target.

### Flutter UI package (`ui/`, `publish_to: none` — consumed, never run directly)
```bash
cd ui && flutter pub get && flutter analyze          # dart format lib to format
```

### Build the native lib (`libqp`) — the Go core as a C-shared library for `dart:ffi`
```bash
# Guarded by the `qpcgo` build tag (needs cgo). Without the tag, cmd/libqp is an empty stub so plain `go build ./...` stays green.
go build -tags qpcgo -buildmode=c-shared -o libqp.dylib ./core/cmd/libqp   # macOS
go build -tags qpcgo -buildmode=c-shared -o libqp.so    ./core/cmd/libqp   # Linux
go build -tags qpcgo -buildmode=c-shared -o libqp.dll   ./core/cmd/libqp   # Windows (mingw-w64 gcc required)
go build -tags qpcgo -buildmode=c-archive -o libqp.a    ./core/cmd/libqp   # iOS (static; dynamic libs are forbidden on iOS)
```

### Per-platform app build (must build on the target OS)
```bash
# macOS → .app/.dmg
cd apps/macos && ./setup_macos.sh   # ONE-TIME: scaffolds the gitignored macos/ runner + applies runner_patches
cd apps/macos && ./build_app.sh     # universal libqp.dylib → flutter build → inject+adhoc-sign → dist/*.dmg
flutter run -d macos                # local debug (after setup)

# Windows → portable .zip (PowerShell)
cd apps\windows; ./setup_windows.ps1  # ONE-TIME: scaffolds windows/ runner + injects native ticker patches
cd apps\windows; ./build_app.ps1      # libqp.dll (mingw-w64) → flutter build → dist/*.zip
flutter run -d windows
```
The generated Flutter runner (`apps/macos/macos/`, `apps/windows/windows/`) is **gitignored** and absent in a fresh clone. The `runner_patches/` files are the source of truth; the `setup_*` script copies them over the generated runner. `build_app.*` aborts if setup hasn't run. Version is injected at build time via `--dart-define=QP_VERSION` from `git describe` (or `$QP_VERSION`).

### CI / release (`.github/workflows/release-desktop.yml`)
Two hand-written jobs (`build-macos` on `macos-14`, `build-windows` on `windows-latest`) + a gated `release` job. **`workflow_dispatch` = verify only** (builds both artifacts, no Release). **Push a `v*` tag = ship** (the release job is gated on `refs/tags/`). So the flow is *dispatch to verify, tag to release* (`gh workflow run release-desktop.yml`, then `git tag v0.x.0 && git push origin v0.x.0`).

## Architecture

### The FFI/JSON boundary (Dart ↔ Go)
Everything non-scalar crosses as a **JSON string** — there are no shared FFI structs, and even C-ABI *call arguments* go in as JSON (so every C signature is just `char*`/`int`). The chain for a read:

```
Widget → PulseController → PulseSource(abstract) → FfiPulseSource → NativeCore(dart:ffi)
  → QP_*(char*) → C.GoString → json.Unmarshal → app.App facade → poller/usage store
  → json.Marshal → C.CString → Dart toDartString() → QP_Free
```

- **`core/app/facade.go` is the only Go type hosts touch.** Three thin adapters wrap it: the C-ABI (`core/cmd/libqp/capi.go`, 16 `QP_*` exports), the gomobile bridge (`core/bridge/mobile.go`, for future iOS/Android), and the `qpctl` CLI.
- **Two delivery models:** desktop **pulls** (`QP_SnapshotJSON` on a timer; the C-ABI has no callback); mobile **pushes** (gomobile `Delegate.OnSnapshot`).
- **FFI memory ownership is a two-allocator contract** (`native_core.dart`): strings Dart passes *in* are Dart-allocated → free with `malloc.free`. Strings Go returns *out* are `C.CString` → free with `QP_Free`. Mixing them corrupts the heap. Any new `char*`-returning export needs the same discipline.
- Return sentinels are meaningful: `''`/null ptr = *error* (→ `ChartData.failed`); `'[]'` = genuinely empty. Don't collapse them.

### Two independent data planes
1. **Rolling-window snapshots** (the 5h/7d meters). `poller` fetches every account → writes `poller.Store` (an in-memory map keyed `instance|accountID`) → after each round calls `onUpdate(Snapshot())`. Dart's `PulseController` is a `ChangeNotifier` that pulls `QP_SnapshotJSON` every ~2s just to render; the *real* network cadence lives in the Go poller.
2. **Usage event store** (the charts + GitHub-style heatmap). `core/usage/store.go` is a pure-Go SQLite (`modernc.org/sqlite`, no cgo) raw-event store. Ingests `/admin/usage` events, keeps them across restarts via incremental sync, answers instant multi-dimensional hour/day aggregations. Read **on demand** (`QP_ChartSeries`/`QP_ChartDailySeries`/`QP_Coverage`/`QP_EnsureCoverage`), bypassing the 2s loop.

These are orthogonal: the 5h/7d windows are `model.Meter{Kind: rolling_window}` snapshots inside `model.AccountPulse`; the charts are aggregated `usage_events`. Neither derives from the other.

### Provider abstraction (`core/provider`, `core/providers/sub2api`)
`Provider` is a minimal 4-method interface (`Type`/`DisplayName`/`ListAccounts`/`FetchUsage`/`Capabilities`). Everything optional is a **separate interface discovered by type assertion**: `LabelSetter`, `UsageLogFetcher` (raw chart-event ingest), `EarliestFetcher` (heatmap history floor). A provider implements only what it can; unsupported features silently degrade.

The shared transport (`transport.go`) handles auth (`AuthScheme{Header, Prefix, Token, Extra}`) and ETag/`If-None-Match` **304** conditional GETs centrally, including the cold-304 force-fresh retry.

**To add a provider (e.g. one-api / new-api)** you touch exactly two things outside the new package:
1. New `core/providers/<name>/` with `client.go` (+ `AuthScheme`) and `mapper.go` (native DTOs → `model.AccountPulse`/`[]Meter`); `init()` calls `provider.Register("<name>", New)`.
2. **One blank-import line** in `core/app/facade.go`: `_ "…/core/providers/<name>"`. Forgetting it means `init()` never runs and `Build()` returns "unknown provider type".

The `Type()` string must equal both the `Register` key and `cfg.Type` in config JSON. Cumulative providers emit `Meter{Kind: cumulative, Used, Limit}` (no `ResetsAt`); the UI adapts via `Capabilities`. Never put plaintext API keys in DTOs or event `Dims`.

### Settings & config
Settings persist as a **single JSON blob** under `SharedPreferences['qp.settings']` (`SettingsStore`), with legacy migration from the old single-instance `qp.base_url`/`qp.api_key` keys. `Settings` is an immutable value object (`copyWith`), *not* a `ChangeNotifier`.

Two JSON sinks with very different cost:
- `toJson()` → prefs (cheap; every UI tweak).
- `toConfigJson()` → `QP_Init` → **restarts the Go core**. It contains *only* providers + a fixed chart block. **Keep pure-UI fields (theme/layout/tray/chart-view/reset-mode) out of it**, or every chart-range or tray tweak triggers a core restart + full usage refetch. `chart.range_hours` is pinned to `kChartFetchHours` (168) and the UI crops client-side; `chart.keep_all=true` makes the local SQLite grow-only (the heatmap needs full history).

## Invariants that will bite you

- **`poller.Store` key must stay `instance|accountID`.** Dropping the instance prefix silently merges same-numbered accounts across sub2api instances. The Dart-side instance-name dedup (`_uniqueInstances`) must match the Go facade's dedup exactly — the display name is the join key against `pulse.instance`.
- **Anti-regression cache guard** (`Store.Put`): skip an incoming pulse *only* when `len(Meters)==0 && Error=="" && Status==StatusOK && the existing entry has Meters`. This stops passive "cold" empty reads from flickering good data to blank. Loosening it suppresses real banned/error transitions; both directions are tested in `cache_test.go`.
- **Startup force-fetch**: `loop()` always does one `Fresh=true` fetch at startup regardless of the active-refresh switch (default off), so multi-account instances load fully on first paint. Do not gate this on the active setting (regression fixed once already).
- **Never overwrite last-good data on error.** Failed `FetchUsage`/`ListAccounts` returns early and keeps the previous snapshot.
- **Chart-sync watermarks** (`core/usage` + `poller` streams): only the incremental stream's *first* pulse writes both `last_id` and the coverage watermark W together; the steady-state incremental path must not touch W. `schemaVersion = 4` (mirrored to `PRAGMA user_version`); migrations are in `store.go`. SQLite is opened `SetMaxOpenConns(1)` + WAL to serialize writes.
- **`qpcgo` build tag is load-bearing.** `capi.go` compiles only under `-tags qpcgo`; without it an empty `main()` stub keeps `go build/vet ./...` green with no C toolchain.
- **macOS is intentionally non-sandboxed** (`app-sandbox=false` in both entitlements) so `autostart.dart` can write `~/Library/LaunchAgents`. Do not re-add `app-sandbox`.
- **Windows needs mingw-w64 gcc** for `libqp.dll` (Go `c-shared` needs an external compiler; MSVC builds only the Flutter runner). The two toolchains cooperate; the DLL just has to sit next to `quota_pulse.exe`.
- **Go 1.25 is required** (not 1.24): `modernc.org/sqlite v1.52.0`'s go.mod floor forces it, so `core/go.mod` is `go 1.25.0`. Building on 1.24 fails under `GOTOOLCHAIN=local` (`auto` silently downloads 1.25); CI (`setup-go`), README, and both `SETUP.md` are pinned to 1.25 to match. Don't lower the `go` directive — `go mod tidy` will re-bump it.

## Conventions

- Commit messages are **Chinese**, Conventional-Commits style with a scope: `fix(ui):`, `refactor(sync):`, `feat(chart):`, `perf(chart):`. Match the surrounding style.
- The canonical alert/tray window set is `kAlertWindows` (currently 5h/7d) in `settings_store` — change it in one place and chips, tray text, and the alerter all follow.
- Cold-start first pull is called **"初始化" (initialize), not "播种/seed"**.
- Settings page tabs: 实例 / 显示 / 托盘 / 通知 / 高级. Platform-specific blocks render via `theme.platform` (macOS menu-bar ticker vs Windows floating window + MiSans credit).
