# Changelog

All notable changes to Tatami. This file is the source of truth for the release
notes shown on the website and on GitHub Releases (the release workflow appends
an Install / Update section when publishing).

## 1.3.2 — 2026-06-11

A maintenance release — faster, steadier workspace switching and a batch of
stability fixes, on top of a large internal hardening pass. Updating from
1.2.x? The 1.3.0–1.3.1 notes included below apply to you too.

### Improvements
- **Snappier workspace switching.** Activations now read window identities from a cache instead of querying every window over Accessibility on the hot path, and a switch that arrives mid-activation supersedes the one still in flight — so rapid next/previous presses advance past a slow-to-settle workspace instead of stalling on it.
- **A busy app no longer disappears.** When an app is too loaded to answer an Accessibility query in time, Tatami keeps its last-known windows instead of reading the timeout as "no windows" — so a momentarily-busy app no longer drops out of its tile, floating mirror, or marker dot. A single hung app can also no longer freeze the main thread for several seconds during a tiling pass.

### Fixes
- **Floating mirrors could keep recording after they should have stopped** — several races left ScreenCaptureKit streams (and the screen-recording indicator) running longer than intended; capture now starts and stops in a strict order.
- **Freshly-launched Electron windows** sometimes missed their resize/close events when the first attempt to observe them failed; those subscriptions now retry like the rest, so a phantom tile no longer lingers.
- **A corrupt `config.toml` no longer wipes your setup** — a broken top-level section (profiles, shared apps, settings) now keeps your previous config instead of resetting it (which the next write would have made permanent, taking your workspaces with it), and an unparsable settings field is surfaced instead of silently ignored.
- **"Relaunch" no longer turns into a plain quit** when the relauncher fails to start — Tatami stays running and logs the failure.

---

*Updating from 1.2.x? Everything in 1.3.0–1.3.1 applies to you too:*

### ⚠️ Breaking Changes (since 1.3.0)
- **`[[floatingApps]]` is now `[[sharedApps]]`** — configs migrate automatically on first launch: each floating entry becomes a shared app with `floating = true`. Shared apps are part of *every* workspace — tiled into each layout by default, or floating everywhere. Manage them in **Workspaces → Shared Apps**; dotfiles that template the config should switch to the new key.
- **Floating windows now need the Screen Recording permission** — they stay above the tiles via ScreenCaptureKit mirrors, and without the grant they won't stay on top. Grant it in **Settings → General → Permissions**, then relaunch.

### New since 1.3.0
- **Floating windows that stay above the tiles — without disabling SIP.** Mark any app as floating per workspace (the Float toggle next to Auto-open, or the `toggleFloating` hotkey): its windows stay untiled and are kept on top by mirroring them onto Tatami-owned ScreenCaptureKit panels. Reach for a floating window and the real one is handed back to you; while a floating app has focus the mirrors get out of the way. Multiple floating windows stack by focus recency.
- **Shared Apps editor** in the Workspaces sidebar — add/remove shared apps and flip their Float toggle, presented like a special workspace.
- **Settings reorganized** into a System Settings-style sidebar (General, Tiling, Focus & Mouse, Workspaces, Shortcuts, Appearance), with a Screen Recording row under Permissions.
- **Shared hotkeys** — `toggleSharedFloating` floats the focused app everywhere, and `toggleAppInSharedApps` adds/removes the focused app in Shared Apps.
- **Per-action HUD** — floating changes, app membership, tiling pause, fullscreen zoom, and balance now show a brief overlay, each individually toggleable in **Settings → Appearance → Overlay**.
- **What's New on first launch after an update**, with the full changelog viewable from **About → View Changelog**.
- **Back to recent when empty** (`settings.switching.switchToRecentWhenEmpty`, off by default) — when the active workspace's last window closes, switch to the recent workspace instead of staring at an empty desktop.
- **Internal failures now surface in the UI** — a broken `config.toml`, an unreadable `layouts.json`, a CLI server that won't start, unavailable floating mirrors, or a failed Launch-at-Login registration show a warning HUD and a ⚠️ in the menu bar (with a Problems section) until fixed.

## 1.3.1 — 2026-06-07

A quick follow-up to 1.3.0 — updating from 1.2.x? The 1.3.0 notes included
below apply to you too.

### New
- **Back to recent when empty** (`settings.switching.switchToRecentWhenEmpty`, off by default) — when the active workspace's last window closes, switch to the recent workspace instead of staring at an empty desktop. Shared apps don't count as content (they join every workspace), and a deliberately empty workspace never bounces you out — only an actual close triggers the switch.
- **Internal failures now show up in the UI** instead of dying in a log: a broken `config.toml` (syntax error, invalid shortcut string), a `layouts.json` that won't read or write, a CLI server that fails to start, unavailable floating mirrors, or a failed Launch-at-Login registration all show a warning HUD with the error detail and a ⚠️ in the menu bar (with a Problems section) until the problem is fixed — fixing it (e.g. correcting the config) clears the badge with a confirmation HUD.

### Fixes
- **Floating mirrors with focus-follows-mouse off**: hovering a mirror no longer steals focus (that was FFM in disguise) — scrolls, clicks, and drags on a mirror now forward to the real window, and focus moves on click. With FFM on, hover keeps handing focus over as before.
- Two floating-window blinks with focus-follows-mouse off: a sibling float dipped behind a clicked tile for a beat, and the focused float dipped behind an overlapping sibling when the cursor left it.
- Quitting a floating app now removes its marker dot immediately instead of on the next focus change.

---

*Included from **1.3.0** (released the day before), for everyone updating from 1.2.x:*

### ⚠️ Breaking Changes (1.3.0)
- **`[[floatingApps]]` is now `[[sharedApps]]`** — configs migrate automatically on first launch: each floating entry becomes a shared app with `floating = true`. Shared apps are part of *every* workspace — tiled into each layout by default, or floating everywhere. Manage them in **Workspaces → Shared Apps**; dotfiles that template the config should switch to the new key.
- **Floating windows now need the Screen Recording permission** — they stay above the tiles via ScreenCaptureKit mirrors, and without the grant they won't stay on top. Grant it in **Settings → General → Permissions**, then relaunch.

### New in 1.3.0
- **Floating windows that stay above the tiles — without disabling SIP.** Mark any app as floating per workspace (the Float toggle next to Auto-open, or the `toggleFloating` hotkey): its windows stay untiled and are kept on top by mirroring them onto Tatami-owned ScreenCaptureKit panels. Reach for a floating window and the real one is handed back to you; while a floating app has focus the mirrors (and the screen-recording indicator) get out of the way. Multiple floating windows stack by focus recency.
- **Shared Apps editor** in the Workspaces sidebar — add/remove shared apps and flip their Float toggle, presented like a special workspace.
- **Settings reorganized** into a System Settings-style sidebar (General, Tiling, Focus & Mouse, Workspaces, Shortcuts, Appearance), with a new Screen Recording row under Permissions.
- **Shared hotkeys** — `toggleSharedFloating` floats the focused app everywhere (joins Shared Apps as floating if needed; toggling off flips it to shared tiled), and `toggleAppInSharedApps` adds/removes the focused app in Shared Apps.
- **Per-action HUD** — floating changes, app membership, tiling pause, fullscreen zoom, and balance now show a brief overlay, each individually toggleable in **Settings → Appearance → Overlay** (plus the master switch and a configurable duration). Un-floating an app that stays in its workspace / Shared Apps shows a follow-up hint with the shortcut that removes it entirely.
- **What's New on first launch after an update** — a one-time window summarizing setup-affecting changes (with a Screen Recording grant button when needed) and feature highlights; the full changelog is also viewable from **About → View Changelog**.
- Missing Screen Recording no longer fails silently: the first activation that needs floating mirrors shows the system prompt and a warning HUD pointing at the Settings row.
- Auto-open apps **reopen on workspace re-entry** when their window was closed, not just on first activation.
- Fixed-size windows (e.g. the iOS **Simulator**) can float — resizability is only required for tiling.
- Floating windows' marker dots are always visible (not just on the focused window), and dots follow window drags with a smooth glide.

## 1.3.0 — 2026-06-06

### ⚠️ Breaking Changes
- **`[[floatingApps]]` is now `[[sharedApps]]`** — configs migrate automatically on first launch: each floating entry becomes a shared app with `floating = true`. Shared apps are part of *every* workspace — tiled into each layout by default, or floating everywhere. Manage them in **Workspaces → Shared Apps**; dotfiles that template the config should switch to the new key.
- **Floating windows now need the Screen Recording permission** — they stay above the tiles via ScreenCaptureKit mirrors, and without the grant they won't stay on top. Grant it in **Settings → General → Permissions**, then relaunch.

### New
- **Floating windows that stay above the tiles — without disabling SIP.** Mark any app as floating per workspace (the Float toggle next to Auto-open, or the `toggleFloating` hotkey): its windows stay untiled and are kept on top by mirroring them onto Tatami-owned ScreenCaptureKit panels. Reach for a floating window and the real one is handed back to you; while a floating app has focus the mirrors (and the screen-recording indicator) get out of the way. Multiple floating windows stack by focus recency.
- **Shared Apps editor** in the Workspaces sidebar — add/remove shared apps and flip their Float toggle, presented like a special workspace.
- **Settings reorganized** into a System Settings-style sidebar (General, Tiling, Focus & Mouse, Workspaces, Shortcuts, Appearance), with a new Screen Recording row under Permissions.
- **Shared hotkeys** — `toggleSharedFloating` floats the focused app everywhere (joins Shared Apps as floating if needed; toggling off flips it to shared tiled), and `toggleAppInSharedApps` adds/removes the focused app in Shared Apps.
- **Per-action HUD** — floating changes, app membership, tiling pause, fullscreen zoom, and balance now show a brief overlay, each individually toggleable in **Settings → Appearance → Overlay** (plus the master switch and a configurable duration). Un-floating an app that stays in its workspace / Shared Apps shows a follow-up hint with the shortcut that removes it entirely.
- **What's New on first launch after an update** — a one-time window summarizing setup-affecting changes (with a Screen Recording grant button when needed) and feature highlights; the full changelog is also viewable from **About → View Changelog**.
- Missing Screen Recording no longer fails silently: the first activation that needs floating mirrors shows the system prompt and a warning HUD pointing at the Settings row.
- Auto-open apps **reopen on workspace re-entry** when their window was closed, not just on first activation.
- Fixed-size windows (e.g. the iOS **Simulator**) can float — resizability is only required for tiling.
- Floating windows' marker dots are always visible (not just on the focused window), and dots follow window drags with a smooth glide.

### Fixes
- HUD overlays sometimes vanished instantly instead of fading out — the panel's window-alpha animation only ran reliably once per launch; the fade now runs on the content view.

## 1.2.1 — 2026-06-02

### Fixes
- Detect windows that **hide instead of close** — Electron apps like Discord hide their window on close (no Accessibility destroy event), which left a phantom tile slot. Tatami now prunes a tiled window once it leaves the screen and re-tiles the survivors.

## 1.2.0 — 2026-06-02

### New
- **Refocus when a window closes** — when the focused window closes and focus would otherwise be stranded on a now-windowless app (e.g. KakaoTalk, Notion Calendar, which keep running with no window), focus moves to a remaining window in the workspace. Toggle in **Settings → Mouse & Focus**.
- **Ignore full-screen windows in focus-follows-mouse** — an option (on by default) to keep focus-follows-mouse from grabbing a window that fills the whole display as the cursor skims across it.

## 1.1.0 — 2026-06-02

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
