# Tatami <img src="Resources/Marketing/app-icon.png" align="right" height="128" />

[![Latest release](https://img.shields.io/github/v/release/PangMo5/Tatami?sort=semver)](https://github.com/PangMo5/Tatami/releases/latest)
[![Download](https://img.shields.io/github/downloads/PangMo5/Tatami/total)](https://github.com/PangMo5/Tatami/releases)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL%203.0-blue)](LICENSE)

A macOS workspace manager with yabai-style window tiling.

Tatami groups your apps into virtual workspaces you switch between with a
keystroke or a trackpad swipe, and tiles their windows automatically with a
yabai-style BSP engine — no SIP changes and no shell scripting required.

> **Status:** In active development. Config format and shortcuts may still change.

## Demo

<p align="center">
  <a href="https://pangmo5.dev/Tatami#demo">
    <img src="web/tatami-demo-poster.jpg" alt="Tatami demo — click to watch" width="760" />
  </a>
</p>

<p align="center"><a href="https://pangmo5.dev/Tatami#demo">▶ Watch the demo</a></p>

## Features

### Workspaces

- Group apps into virtual workspaces with per-workspace app assignments
- Switch by hotkey, trackpad swipe, or "recent workspace"
- One **key equivalent** per workspace: hold the switch / assign / borrow modifier with it to switch to it, assign the focused app to it, or borrow it — the same keys drive the recent / next / previous targets, and any action takes an explicit override
- Optional loop-around, skip-empty, and follow-app-focus behaviors
- Auto-open assigned apps when a workspace activates — and reopen them on re-entry if their window was closed
- Per-display workspaces — pin one to a display or follow apps dynamically; each display keeps its own active workspace, and you can cycle per-display or across every display
- Jump focus between displays, or move the focused app to another workspace
- Shared apps that join every workspace

### Profiles

- Group workspaces into **profiles** and switch the whole set at once — each profile has its own workspaces, app assignments, and shortcuts
- Switch by hotkey or from the menu bar; switching re-tiles every display for the new profile
- **Auto-activate** a profile by display setup — monitor count, or specific displays connected / disconnected — with a warning when two profiles' rules overlap at the same priority
- Per-profile SF Symbol icon, shown in the sidebar, menu bar, and switch HUD
- **Copy from** another profile or workspace with a reviewable, per-change diff — apps and settings, keep or skip each change (profiles stay independent)

### Borrow — compose two workspaces

- **Pull another workspace in beside the current one**, docked to a screen edge (top / bottom / left / right) and tiled side by side — each keeps its own BSP layout, and windows can't cross the boundary
- **Live and bidirectional**: the borrowed block is the real workspace, so edits there persist back to it
- Press the borrow modifier + a workspace's key, then a direction (`h` / `j` / `k` / `l` or arrows) to place it — or set a default edge and size, globally or per workspace
- **Directional focus crosses the boundary**; activating a borrowed workspace fully switches to it; re-borrowing re-docks; `esc` cancels the direction pick
- Borrowed windows are badged with the borrowed workspace's icon so what's on loan is clear at a glance
- **Scratchpad workspaces** are borrow-only — excluded from cycling, never activated on their own, and their apps auto-open when summoned

### Window tiling (yabai-style BSP)

- Automatic binary space partitioning that inserts at the shallowest tile
- Directional focus, swap, and resize (vim-like `h` / `j` / `k` / `l`)
- Zoom a window to fill the workspace; toggle split orientation
- Rotate, mirror, and balance the layout tree
- Drag a window to swap or re-insert it next to another — a live overlay previews where it'll land (center = swap, edges = insert that side); manual edge-resize syncs back into the tree
- Configurable inner / outer gaps

### Floating windows

- Float an app in a single workspace, or add it to Shared Apps to float it everywhere — one toggle in the GUI, one hotkey anywhere
- Floats stay above the tiles **without disabling SIP** — Tatami mirrors them onto its own always-on-top ScreenCaptureKit panels, and hands you the real window the moment you reach for it
- Multiple floating windows stack by focus recency; needs the Screen Recording permission
- Or set an app to **Ignore** (unmanaged) — it stays a workspace member (auto-open, focus, focus-follows-mouse, window cycling) but Tatami leaves its window exactly where it is: no tiling, no mirror, no Screen Recording

### Focus & cursor

- focus-follows-mouse and mouse-follows-focus (yabai-style)
- Refocus the most recently used remaining window when the focused one closes
- Optionally hide the cursor on a workspace switch

### Interface & config

- Customizable menu bar item — toggle the active workspace's icon / name and (with more than one profile) the active profile's icon / name
- On-screen HUD confirming switches, float toggles, membership changes, and more — each individually toggleable, with follow-up hints (e.g. the shortcut that fully removes a just-unfloated app)
- Per-workspace SF Symbol icons
- Native SwiftUI settings
- skhd-style shortcut syntax (e.g. `ctrl + alt - h`)
- Plain-TOML config at `~/.config/tatami/config.toml` (XDG-aware), hot-reloaded
- CLI for scripting (`tatami activate <workspace>`, `tatami list-workspaces`, …)
- Sparkle auto-updates

## Requirements

- macOS 14.0 or later
- Accessibility permission
  (System Settings → Privacy & Security → Accessibility)
- Screen Recording permission, only if you use floating windows — their
  always-on-top mirrors are ScreenCaptureKit captures
  (System Settings → Privacy & Security → Screen Recording)

## Installation

### Homebrew

```sh
brew install --cask pangmo5/tap/tatami
```

Or download the signed & notarized `.dmg` from the
[latest release](https://github.com/PangMo5/Tatami/releases/latest).

### Build from source

```sh
brew install tuist                     # or: mise install
tuist install && tuist generate --no-open
open Tatami.xcworkspace
```

## Command line

Tatami ships a `tatami` CLI inside the app bundle. Install it from
**Settings → General → Command Line → Install** — this symlinks `tatami` into
`/usr/local/bin` (you'll be asked for your password once). Then:

```sh
tatami list-workspaces          # workspace names in the active profile
tatami list-apps <workspace>    # bundle IDs assigned to a workspace
tatami activate <workspace>     # activate a workspace
tatami version                  # version of the running app
```

The CLI talks to the running app over a local socket, so Tatami must be
running. (Homebrew installs are detected automatically.)

## Configuration

Settings live in `~/.config/tatami/config.toml`, grouped into tables —
`[settings.layout]`, `[settings.focus]`, `[settings.gestures]`,
`[settings.shortcuts]`, and so on. Workspaces, their app assignments, and
shared apps are stored in the same file. Edits made in the app or by hand are
picked up live.

See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for the full reference —
every key, its default, and the shortcut syntax.

## Tech stack

- **Tuist** — project generation
- **The Composable Architecture (TCA)** — app architecture
- **swift-sharing** — cross-feature state sharing
- **swift-collections** — ordered sets/dictionaries and deques on the tiling hot paths
- **swift-toml** — config persistence
- **swift-yyjson** — fast JSON for the layout store and CLI protocol
- **Magnet** — Carbon-based global hotkeys
- **SFSafeSymbols** — type-safe SF Symbol catalog
- **Sparkle** — app updates

## Acknowledgements

Tatami is inspired by [FlashSpace] by Wojciech Kulik (the virtual
workspace-switching concept) and [yabai] by koekeishiya (the window-tiling
model). See [NOTICE.md](NOTICE.md) for attribution.

## License

[GPL-3.0](LICENSE).

[FlashSpace]: https://github.com/wojciech-kulik/FlashSpace
[yabai]: https://github.com/koekeishiya/yabai
