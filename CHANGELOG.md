# Changelog

All notable changes to Tatami. This file is the source of truth for the release
notes shown on the website and on GitHub Releases (the release workflow appends
an Install / Update section when publishing).

## Unreleased

### New
- **Multi-monitor, per display.** Each display tracks its own active and recent workspaces. Activation, "recent workspace", and next/previous cycling all act on the display under the cursor, and new workspaces start pinned to the current display.
  - **Focus next / previous display** — move focus to the active workspace on the next monitor, looping around (`focusNextDisplay` / `focusPreviousDisplay`).
  - **Cycle across all displays** — option to make next/previous workspace span every display's workspaces instead of only the one under the cursor (`settings.switching.cycleAcrossDisplays`).
  - Displays are identified by a stable UUID (with a name fallback), so reconnecting the same monitor keeps its assignments; everything falls back to the primary display when a monitor is absent.
  - Per-display dot colors in the sidebar show which monitor each workspace is active on.
- **Move app to next / previous workspace** — relocate the focused app one workspace over and follow it there (`moveToNextWorkspace` / `moveToPreviousWorkspace`).
- **Assign focused app to a workspace** — a per-workspace shortcut that adds the focused app (keeping its other memberships) and switches there.
- **Focus app on activation** — choose which assigned app gets focus when a workspace activates (defaults to most-recently-used).
- **Bundled CLI installer** — install / uninstall the `tatami` CLI from **Settings → Command Line** (Homebrew installs are detected). Accessibility permission status and a one-click grant now live in **Settings → Permissions**.
- In-app descriptions for the non-obvious shortcuts, plus a Pinned-vs-Dynamic explainer in a workspace's Display section.

### Fixes
- **focus-follows-mouse** no longer grabs a full-screen window showing through the gaps between tiled windows.
- Hot keys re-register immediately after recording a workspace's **Assign** shortcut (previously needed a relaunch).
- **Persistent layouts** restore each fullscreen-zoomed window of the *same* app to a distinct window instead of collapsing them onto one.
- Apps that run one process per window under a shared bundle id (e.g. **Neovide**) now tile — window discovery scans every process, not just the first.
- Moving an app to another workspace keeps its name, icon, and auto-open setting instead of relabeling it with the bundle id.
- The workspace **Display picker** now lists every connected display when switching between workspaces.
- `tatami version` reports the running app's real version.

## 1.0.0 — 2026-05-29

The first stable release. Here's what changed since v0.1.3.

### New
- **Drag to rearrange** — drag a window and a live overlay previews the drop: the center **swaps** the two windows, an edge **inserts** the dragged one on that side (left / right / top / bottom).
- **Window markers** — a small corner dot marks zoomed / floating windows; configurable color, size, corner, and hover-fade.
- **Multi-window zoom** and per-workspace **layout memory** (`session` / `persistent`).
- New shortcuts: **balance** the tree, toggle the focused app's workspace membership; plus a toolbar **Activate** button.
- Optional **debug logging** to `~/.config/tatami/tatami.log` for diagnosing tiling.

### Improvements
- **Manual resize** now drags any window edge and re-tiles against the correct join — height resizes work even when the immediate split is vertical; a drag that changes nothing snaps the window back to its tile.
- Manual move / resize commits on **mouse-up** (not a timer), so dragging stays smooth and never fights you mid-drag.
- Window markers track their windows **event-driven** (no polling timer) — ~zero idle CPU.
- **Reworked concurrency**: AX window hit-testing, the CLI socket server, and the mouse / gesture event taps no longer block the main thread or the Swift cooperative pool.
- Snappier focus-follows-mouse and tiling-debounce timings.
- Overhauled BSP insert / swap / warp / balance semantics.

### Fixes
- `grow` / `shrink` / `balance` hotkeys did nothing in common layouts — fixed.
- Gap and dot-size **steppers** in Settings ran away on a single click — fixed.
- Parse `-` (minus) in shortcut strings; resize horizontal splits correctly.

### Removed / config change
- Dropped the `fresh` tiling-memory mode — it rebuilt layouts from a focus-dependent order and reshuffled them on every workspace switch. Workspaces now use `session` (default) or `persistent`; existing configs set to `"fresh"` fall back to `session`.

## 0.1.3 — 2026-05-28

### Changed
- **Pause now means "pause tiling" only.** Toggling pause from the menu bar (or the `toggleSpaceActivated` hotkey) used to block workspace switching too — now it suspends only the BSP tile pass while workspace switches, show/hide, and focus keep working. The pause flag is also no longer persisted to config (runtime-only; every launch starts unpaused).

## 0.1.2 — 2026-05-28

### Added
- **Launch at Login** — Tatami can start automatically when you log in. Toggle in **Settings → General → Launch at login**.
- **Sparkle release notes** — the in-app update dialog links to each release's notes page starting with this version.

## 0.1.1 — 2026-05-28

### Added
- **Software updates now work end to end.** Sparkle is fully wired up — Tatami checks for and installs updates in the background. Pick the frequency (hourly / daily / weekly) or check manually from Settings or the menu bar.
- **About tab** — version, creator, and open-source credits (FlashSpace, yabai, and the libraries Tatami is built with).

### Changed
- Settings now use Perception's observation, dependency clients adopt `@DependencyClient`, and an unused `autoFocusBlacklist` setting was removed.

## 0.1.0 — 2026-05-27

First public release. A macOS workspace manager with yabai-style window tiling —
group your apps into virtual workspaces, switch with a keystroke or trackpad
swipe, and tile their windows automatically. No SIP changes, no shell scripting.

### Tiling (yabai-style BSP)
- Automatic binary space partitioning with a dwindle (spiral) layout
- Directional focus / swap / resize (vim-like `h` `j` `k` `l`)
- Zoom a window to fill the workspace, toggle split orientation
- Rotate, mirror, balance; drag-to-swap and live resize sync
- Configurable inner / outer gaps

### Workspaces
- Per-workspace app assignments; switch by hotkey, swipe, or "recent"
- Loop-around, skip-empty, and follow-app-focus options
- Auto-open assigned apps on activation
- Multi-display (pin a workspace or follow apps dynamically)
- Floating apps that never tile

### Focus & interface
- focus-follows-mouse / mouse-follows-focus, optional cursor hide
- Menu bar item with the active workspace (icon + name)
- On-screen HUD on switch, per-workspace SF Symbol icons
- skhd-style shortcut syntax, plain-TOML config, scripting CLI
