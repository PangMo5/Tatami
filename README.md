# Tatami <img src="Resources/Marketing/app-icon.png" align="right" height="128" />

A macOS workspace manager with yabai-style window tiling.

Tatami groups your apps into virtual workspaces you switch between with a
keystroke or a trackpad swipe, and tiles their windows automatically with a
yabai-style BSP engine — no SIP changes and no shell scripting required.

> **Status:** In active development. Config format and shortcuts may still change.

## Features

### Tiling (yabai-style BSP)

- Automatic binary space partitioning with a dwindle (spiral) layout
- Directional focus, swap, and resize (vim-like `h` / `j` / `k` / `l`)
- Zoom a window to fill the workspace; toggle split orientation
- Rotate, mirror, and balance the layout tree
- Drag-to-swap, plus manual resize that syncs back into the layout
- Configurable inner / outer gaps

### Workspaces

- Group apps into virtual workspaces with per-workspace app assignments
- Switch by hotkey, trackpad swipe, or "recent workspace"
- Optional loop-around, skip-empty, and follow-app-focus behaviors
- Auto-open assigned apps when a workspace activates
- Pin a workspace to a display or follow apps dynamically (multi-display)
- Floating apps that never tile

### Focus & cursor

- focus-follows-mouse and mouse-follows-focus (yabai-style)
- Optionally hide the cursor on a workspace switch

### Interface & config

- Menu bar item showing the active workspace (icon + name)
- On-screen HUD when switching workspaces
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

## Installation

### Homebrew

_Coming soon:_

```sh
brew install --cask pangmo5/tap/tatami
```

### Build from source

```sh
brew install tuist                     # or: mise install
tuist install && tuist generate --no-open
open Tatami.xcworkspace
```

## Configuration

Settings live in `~/.config/tatami/config.toml`, grouped into tables —
`[settings.layout]`, `[settings.focus]`, `[settings.gestures]`,
`[settings.shortcuts]`, and so on. Workspaces, their app assignments, and
floating apps are stored in the same file. Edits made in the app or by hand are
picked up live.

See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for the full reference —
every key, its default, and the shortcut syntax.

## Tech stack

- **Tuist** — project generation
- **The Composable Architecture (TCA)** — app architecture
- **swift-sharing** — cross-feature state sharing
- **swift-toml** — config persistence
- **KeyboardShortcuts** — global hotkey recording
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
