# quota-pulse

**A cross-platform "usage pulse" bar for your menu bar / system tray.**
Glance at your [sub2api](https://github.com/Wei-Shaw/sub2api) account usage windows (5h / 7d, Gemini daily/minute, …) without opening a browser. Read-only — it never changes anything upstream.

English · [中文](README.zh-CN.md)

> macOS lives in the **menu bar**, Windows lives in the **system tray**. One click opens a frosted-glass popover with every account's usage. The heavy lifting is a shared **Go** engine; the UI is a shared **Flutter** package; each platform is a thin shell.

---

## Features

### 📊 Usage at a glance
- **Rolling-window meters** mapped from sub2api: Claude **5h / 7d / 7d-Sonnet**, Gemini **daily / minute** variants — each as a color-coded bar (green ≤ 80%, amber 80–99%, red ≥ 100%).
- **Per-window detail**: utilization %, reset time, and request / token / cost stats (e.g. `1.2M tok · $3.4`).
- **Account status at a glance** via colored dots + emoji: 🟢 ok · 🟡 warning · 🔴 rate-limited · ⛔ forbidden · 🚫 banned · 🔑 needs re-auth · ⚪ error.
- **Subscription tier** badge (FREE / PRO / ULTRA …) per account.
- **Rate-limited accounts stay visible** — accounts that sub2api auto-disables on rate limit are still fetched and shown (state reflected by the status dot), not silently dropped.
- **Reset time, your way**: show a **countdown** (`2d 3h`, `3h 13m`; day-level, drops the day part when 0) or an **absolute** timestamp (`MM-dd HH:mm`). The choice applies to the main page *and* the tray/menu bar.

### 🖥️ Menu bar / tray
- **macOS**: a custom `NSStatusItem` with a **fixed icon** + **smoothly scrolling text** (pixel-level, 60 fps) when content overflows; static when it fits. Scroll **width** and **speed** are configurable.
- **Windows**: a **two-line-per-account tooltip** (status emoji + `instance·account` on line 1, usage + reset on line 2), folding to `…and N more` past the tooltip's length budget.
- **Always shows the 5h window** (remaining + reset) regardless of the chosen display mode.
- Show **usage** or **remaining** percentage — your pick.
- Tray content scope is configurable: **all accounts** (default) or a **multi-select pinned subset**.

### 🔔 Usage alerts
- **Two notification types, each independently configurable** — and for each you pick which windows trigger it (**5h** / **7d**):
  - **Over threshold** (default **on**, 5h + 7d) — fires when usage crosses your threshold (default **90%**), escalating from 🚨 *usage alert* to 🛑 *quota full* at ≥ 100% (rate-limited).
  - **Quota recovered** (default **off**) — ✅ fires when a window falls back below the threshold (a window reset is the typical case).
- **Once per reset cycle, per type** — de-duplicated by the window's reset time, compared with a ±10s tolerance so jitter in the raw value isn't mistaken for a new cycle (which would otherwise spam you each poll). A real reset starts a new cycle; the recovery notice fires when usage falls back below the threshold.
- **Silent on first snapshot** (and after re-enabling) so startup doesn't fire a burst for already-high accounts.
- System sound on each notification; a **Test button** in settings fires a sample of every notification type (🚨 / 🛑 / ✅) so you can verify delivery and preview each, without waiting to hit a threshold.

### 🗂️ Multiple sub2api backends
- Configure **any number of instances** (name + base URL + API key); add / edit / remove in settings.
- View them **grouped** (per-instance headers) or as **tabs** — your choice.
- Each instance's accounts are keyed as `instance|accountId`, so the **same account ID across two backends never collides**.
- **Instance name is a hyperlink** — click it to open that backend in your system browser.
- Per-instance **refresh** button to force a fresh fetch.

### 🎨 Appearance & interaction
- **Frosted-glass** popover with a transparent, frameless window (`flutter_acrylic` + `window_manager`).
- **Inline expand** a row to reveal all of an account's windows; **hover** reveals a refresh action (desktop).
- **System-native look**: system font (SF Pro on macOS; embedded MiSans on Windows) and **system accent color**.
- **Light / dark / follow-system** theme.
- Clear **empty / loading / error** states.
- App **version** shown at the bottom of the settings page (injected at build time from the git tag).

### ⚙️ Configuration (with defaults)

| Setting | Options | Default |
|---|---|---|
| sub2api instances | name + base URL + API key (multiple) | — |
| List layout | grouped · tabs | **grouped** |
| Theme | system · light · dark | **system** |
| Tray scope | all accounts · pinned (multi-select) | **all accounts** |
| Tray metric | usage % · remaining % | **usage** |
| Reset display | countdown · absolute | **countdown** |
| Menu-bar scroll width *(macOS)* | characters | **10** |
| Menu-bar scroll speed *(macOS)* | ms per step (lower = faster) | **300** |
| Usage alerts (master) | on / off | **on** |
| Alert threshold | 50–100% | **90%** |
| Over-threshold windows | 5h · 7d (multi-select) | **5h + 7d** |
| Quota-recovered windows | 5h · 7d (multi-select) | **none (off)** |
| Start at login | on / off | off |

Settings persist to a single JSON blob in `SharedPreferences` (`qp.settings`); a legacy single-instance config is migrated automatically.

### 🚀 Start at login
- **macOS**: a user `LaunchAgent` plist (`~/Library/LaunchAgents`) — pure Dart, no helper. (The app is intentionally **non-sandboxed** so it can write this.)
- **Windows**: an `HKCU\…\Run` registry value pointing at the executable.

### 🧩 Engine internals (Go core)
- **Adaptive passive/active polling** — cheap cached reads (default **60s**) with periodic forced refreshes (default **10m**); the engine accepts foreground / on-battery / asleep signals to modulate cadence.
- **ETag / `If-None-Match` 304** conditional requests to save upstream bandwidth.
- **Anti-regression cache guard** — an empty passive response never overwrites good data already fetched (no flicker / data loss); real errors still write through.
- **Bounded concurrency** — accounts polled in parallel (≤ 6) with per-account timeouts; one failing account keeps its previous snapshot.
- **Provider plugin architecture** — providers self-register; sub2api is implemented today, with the model designed so one-api / new-api can be added by writing only a mapper (no UI changes).
- **Native bindings** — compiled to a C-shared library (`libqp.dylib` / `.dll` / `.so`) called over `dart:ffi`; a `gomobile` binding is also present for future iOS/Android.
- **`qpctl`** debug CLI — run one polling round against a config and dump the snapshot JSON.

---

## Architecture

```
core/          Platform-agnostic Go engine (provider abstraction · polling · cache · C-ABI/gomobile bridge)
ui/            Shared Flutter package  package:quota_pulse_ui  (models / widgets / state / FFI bridge)
apps/macos/    macOS menu-bar shell + packaging (.dmg)   — custom Swift NSStatusItem runner
apps/windows/  Windows tray shell + packaging (.zip)     — tray_manager
DESIGN.md      Full design: stack choice · architecture · provider abstraction · milestones
```

> **Reuse boundary:** `core/` + `ui/` are 100% shared across platforms; `apps/<platform>/` are thin shells (tray/window/packaging) only.

**Stack:** Go engine ↔ Flutter UI via `dart:ffi`, with a sprinkle of native Swift for the macOS menu bar. Key Flutter plugins: `window_manager`, `flutter_acrylic`, `screen_retriever`, `tray_manager` (Windows), `url_launcher`, `local_notifier`, `shared_preferences`, `system_theme`, `win32_registry` (Windows).

---

## Install

Grab the latest build from [**Releases**](https://github.com/lureiny/quota-pulse/releases):

- **macOS** — `quota_pulse.dmg`, drag to Applications. It's ad-hoc signed (no paid Apple account), so on first launch **right-click → Open** to get past Gatekeeper.
- **Windows** — `quota_pulse-windows.zip`, unzip anywhere and run `quota_pulse.exe`. Portable (no installer). SmartScreen may warn on first run → **More info → Run anyway**.

Then open **Settings**, add a sub2api instance (its **Base URL** + an **admin API key**), and hit **Save & Connect**.

---

## Build from source

You'll need the **Flutter SDK** (≥ 3.4) and **Go 1.24**. Each platform must be built on its own OS.

**macOS** → `.dmg`
```bash
cd apps/macos
./setup_macos.sh     # one-time: generate runner, apply patches, set deploy target
./build_app.sh       # builds libqp.dylib (universal) + the .app, ad-hoc signs, packs the .dmg
```

**Windows** → portable `.zip` (PowerShell)
```powershell
cd apps\windows
./setup_windows.ps1  # one-time: generate runner, pub get
./build_app.ps1      # builds libqp.dll (mingw-w64), the .exe, then zips the folder
```

**Go core** (verify on any OS)
```bash
cd core
go build ./... && go vet ./... && go test ./...
```

The app version is injected at compile time via `--dart-define=QP_VERSION=$(git describe --tags --always --dirty)` — exactly on a tag → `v0.4.0`; past a tag → `v0.4.0-2-gabc1234`; otherwise the short SHA (or `dev` for a plain `flutter run`).

See [`apps/macos/SETUP.md`](apps/macos/SETUP.md), [`apps/windows/SETUP.md`](apps/windows/SETUP.md), and [`core/README.md`](core/README.md) for details.

---

## Releases (GitHub Actions)

Push a `v*` tag and the cloud macOS / Windows runners build and publish to Releases automatically:

```bash
git tag v0.4.0 && git push origin v0.4.0
```

A manual **`workflow_dispatch`** run (Actions tab) builds the same artifacts **without** creating a Release — handy for verifying a commit before tagging. Workflow: [`.github/workflows/release-desktop.yml`](.github/workflows/release-desktop.yml).

> Builds are **not** paid-signed/notarized: macOS needs the first-run right-click→open, Windows the first-run SmartScreen bypass.

---

## Fonts

The **Windows** build embeds [MiSans](https://hyperos.mi.com/font/download) (Xiaomi, free for commercial use): the system Chinese face lacks Medium/Semibold, so `w500/w600` snap to Regular/Bold and weights look uneven — bundling MiSans fixes it. **macOS** uses the system **SF Pro** (full weight range already, no bloat). MiSans is © Xiaomi; license in [`ui/lib/fonts/MiSans-LICENSE.txt`](ui/lib/fonts/MiSans-LICENSE.txt).

---

## Status

Both platforms ship from CI as `.dmg` / `.zip` (latest: **v0.4.0**). sub2api is the only provider implemented today; the model and engine are built so one-api / new-api drop in with just a mapper. Design rationale and milestones live in [DESIGN.md](DESIGN.md).
