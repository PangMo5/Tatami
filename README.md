# Tatami <img src="Resources/Marketing/app-icon.png" align="right" height="128" />

[![Latest release](https://img.shields.io/github/v/release/PangMo5/Tatami?sort=semver)](https://github.com/PangMo5/Tatami/releases/latest)
[![Download](https://img.shields.io/github/downloads/PangMo5/Tatami/total)](https://github.com/PangMo5/Tatami/releases)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL%203.0-blue)](LICENSE)

A macOS workspace manager with yabai-style window tiling.

Tatami groups your apps into virtual workspaces you switch between with a
keystroke or a configurable trackpad gesture, and tiles their windows
automatically with a yabai-style BSP engine. No SIP changes and no shell
scripting required.

## Demo

<p align="center">
  <a href="https://pangmo5.dev/Tatami#demo">
    <img src="web/tatami-demo-poster.jpg" alt="Tatami demo. Click to watch." width="760" />
  </a>
</p>

<p align="center"><a href="https://pangmo5.dev/Tatami#demo">▶ Watch the demo</a></p>

## Features

### Workspaces

- **Virtual workspaces:** Group apps with per-workspace assignments.
- **Flexible switching:** Use a hotkey, trackpad gesture, or recent-workspace action.
- **Configurable gestures:** Bind every direction of a three- or four-finger swipe to any shortcut action, including profile- and workspace-specific commands.
- **One key per workspace:** Hold the switch, assign, or borrow modifier with a **key equivalent**. The same keys also drive recent, next, and previous targets, while any action can take an explicit override.
- **Optional switching behaviors:** Enable loop-around, skip-empty, or follow-app-focus.
- **Auto-open:** Launch assigned apps when a workspace activates and reopen them on re-entry if their window was closed.
- **Per-display workspaces:** Pin a workspace to a display or have dynamic workspaces open under the mouse. Each display keeps its own active and recent workspace, while cycling and recent navigation can independently stay local or span every display.
- **Cross-display control:** Jump focus between displays or move the focused app to another workspace.
- **Shared apps:** Add apps that should join every workspace.

### Profiles

- **Independent profiles:** Group workspaces and switch the whole set at once. Each profile keeps its own workspaces, app assignments, and shortcuts.
- **Fast profile switching:** Switch by hotkey or from the menu bar. Every display re-tiles for the new profile.
- **Display-aware activation:** Auto-activate a profile by monitor count or by specific displays being connected or disconnected. Tatami warns when rules overlap at the same priority.
- **Profile identity:** Give each profile an SF Symbol shown in the sidebar, menu bar, and switch HUD.
- **Reviewable copying:** Use **Copy from** to compare another profile or workspace, then keep or skip each app and settings change.

### Borrow: compose two workspaces

- **Side-by-side composition:** Pull another workspace beside the current one, dock it to any screen edge, and tile both blocks independently. Windows cannot cross the boundary.
- **Live and bidirectional:** The borrowed block is the real workspace, so edits persist back to it.
- **Directional placement:** Press the borrow modifier with a workspace key, then use `h`, `j`, `k`, `l`, or an arrow. You can also set a default edge and size globally or per workspace.
- **Cross-boundary focus:** Directional focus moves between blocks. Activating a borrowed workspace switches to it fully, summoning the same borrow again dismisses it by default, and `esc` cancels placement.
- **Visible ownership:** Borrowed windows show the borrowed workspace's icon.
- **Scratchpads:** Borrow-only workspaces stay out of cycling, never activate alone, and auto-open their apps when summoned.

### Window tiling (yabai-style BSP)

- **Automatic BSP layout:** Insert new windows at the shallowest tile.
- **Keyboard operations:** Focus, swap, and resize directionally with vim-like `h`, `j`, `k`, and `l` keys.
- **Native-style window cycling:** Tap the window-cycle shortcut for an immediate switch, or hold its modifier to choose from a centered app or window HUD and commit on release.
- **Zoom and splits:** Fill the workspace with one window or toggle split orientation.
- **Tree transforms:** Rotate, mirror, and balance the layout.
- **Drag editing:** Swap or re-insert a window with a live placement preview. Manual edge resizing synchronizes back into the tree.
- **Configurable spacing:** Set inner and outer gaps.

### Floating windows

- **Local or global floating:** Float an app in one workspace or add it to Shared Apps to float it everywhere.
- **No SIP changes:** Tatami mirrors floats onto always-on-top ScreenCaptureKit panels, then hands you the real window when you interact with it.
- **Predictable stacking:** Multiple floating windows stack by focus recency. This requires Screen Recording permission.
- **Ignore mode:** Keep an app as a workspace member for auto-open, focus, focus-follows-mouse, and cycling while leaving its window untouched. Ignore mode needs no mirroring or Screen Recording.

### Focus & cursor

- **Focus follows mouse:** Use yabai-style focus-follows-mouse and mouse-follows-focus.
- **Close-window refocus:** Return to the most recently used remaining window.
- **Cursor control:** Optionally hide the cursor during a workspace switch.

### Interface & config

- **Customizable menu bar:** Show the active workspace icon or name and, when relevant, the active profile icon or name.
- **On-screen HUD:** Confirm workspace and profile switches, cycle through apps or windows, and see float, membership, layout, and borrow actions. Each notification is individually configurable.
- **Workspace icons:** Choose a per-workspace SF Symbol.
- **Native settings:** Configure Tatami in SwiftUI.
- **skhd-style shortcuts:** For example, `ctrl + alt - h`.
- **Plain TOML:** Edit `~/.config/tatami/config.toml` with XDG support and live reloads.
- **Scriptable CLI:** Run commands such as `tatami activate <workspace>` and `tatami list-workspaces`.
- **Automatic updates:** Receive releases through Sparkle.

## Requirements

- macOS 14.0 or later
- Accessibility permission
  (System Settings → Privacy & Security → Accessibility)
- Screen Recording permission, only if you use floating windows. Their
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
**Settings → General → Command Line → Install**. This symlinks `tatami` into
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

Settings live in `~/.config/tatami/config.toml`, grouped into tables such as
`[settings.layout]`, `[settings.focus]`, `[settings.gestures]`,
`[settings.shortcuts]`, and so on. Workspaces, their app assignments, and
shared apps are stored in the same file. Edits made in the app or by hand are
picked up live.

See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for the full reference:
every key, its default, and the shortcut syntax.

## Tech stack

- **Tuist:** Project generation
- **The Composable Architecture (TCA):** App architecture
- **swift-sharing:** Cross-feature state sharing
- **swift-collections:** Ordered sets, dictionaries, and deques on tiling hot paths
- **swift-toml:** Config persistence
- **swift-yyjson:** Fast JSON for the layout store and CLI protocol
- **Magnet:** Carbon-based global hotkeys
- **SFSafeSymbols:** Type-safe SF Symbol catalog
- **Sparkle:** App updates

## Acknowledgements

Tatami is inspired by [FlashSpace] by Wojciech Kulik (the virtual
workspace-switching concept) and [yabai] by koekeishiya (the window-tiling
model). See [NOTICE.md](NOTICE.md) for attribution.

## License

[GPL-3.0](LICENSE).

[FlashSpace]: https://github.com/wojciech-kulik/FlashSpace
[yabai]: https://github.com/koekeishiya/yabai
