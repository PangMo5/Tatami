# Changelog

All notable changes to Tatami. This file is the source of truth for the release
notes shown on the website and on GitHub Releases (the release workflow appends
an Install / Update section when publishing). Sparkle's in-app update dialog
accumulates every patch in a release's minor series, so each section here only
needs its own version's changes.

## 1.7.2 (2026-07-15)

### Fixes
- **Window cycling works across displays, and actually switches apps.** The window-cycle shortcut (alt/opt+tab by default, on since 1.7.0) could get stuck cycling between the same two windows or operate on the wrong monitor's workspace. Focus now transfers the frontmost application via the window server (not just an Accessibility raise), so cycling between apps and across displays lands correctly.
- **No more display-reconfigure churn.** A burst of identical screen-parameter notifications from the OS is now coalesced, so Tatami no longer spins re-evaluating an unchanged display setup.
- **Fullscreen-zoom survives deep sleep / clamshell.** A zoomed window whose surface the system recycles on wake no longer loses its zoom.
- **Trackpad-gesture crash fixed.** A fast multi-finger swipe no longer crashes the app.
- **Keyboard tiling ops target the right monitor.** Resize / move / rotate / balance and drag edits on a workspace shown on a non-cursor display now compute against that display.

## 1.7.1 (2026-07-14)

### Improvements
- **Three-column profile sidebar.** Settings now show your profiles, then the selected profile's contents, then the detail, so you can inspect and edit **any** profile (its workspaces, layouts, shortcuts) without switching to it first. The running profile is still marked with a green dot, distinct from the one you're viewing. Activating a workspace from a non-active profile switches to that profile and lands on it in one step.
- **Shared Apps live in the sidebar.** Shared apps join every workspace of every profile, so they moved out from under a single profile into an **Everywhere** section in the sidebar.
- **Per-display switch HUD.** Switching a profile now shows, on each monitor, the workspace that lands there, instead of one HUD listing everything.

### Fixes
- **A workspace pinned to an unplugged display stays put.** Activating a workspace whose pinned monitor is not connected, then switching profiles away and back, no longer reverts it to a different workspace. Tatami keeps it where you last had it and returns it to its own monitor when that display reconnects.

## 1.7.0 (2026-07-14)

### New
- **Profiles.** Group your workspaces into named profiles and switch the whole set at once. Each profile has its own workspaces, app assignments, shortcuts, and SF Symbol icon, shown in the sidebar, menu bar, and switch HUD. Switch by hotkey or from the menu bar, reorder profiles by dragging, and re-tile every display for the new profile.
- **Auto-activate a profile by display setup.** Switch profiles automatically based on monitor count or specific displays being connected or unplugged. Tatami flags ambiguous rules so it is clear which profile wins and why another did not activate.
- **Copy between profiles and workspaces.** Profiles keep independent workspaces, so their apps and settings can drift apart. Open **Copy from…** in a profile or workspace detail to review each app, layout, auto-open, and settings difference, then copy only the checked changes.

### Improvements
- **Customizable menu bar.** Pick what the menu-bar item shows under **Settings → Appearance → Menu Bar:** the active workspace's icon and name, and, when you have more than one profile, the active profile's icon and name.
- **Settings reorganized.** Workspace key equivalents moved to their own **Workspace Keys** pane and trackpad gestures to a **Gestures** pane. Window-cycling settings and shortcuts are grouped together. A workspace's derived shortcuts link straight to Workspace Keys, and those derived combos now render as plain read-only text so it is clear they are configured elsewhere.
- **Friendlier defaults for new installs.** A brand-new config is seeded with a recommended set of shortcuts, and *follow app focus* (activating an app switches to the workspace that owns it) is on by default. Existing configs are left as-is.

### Fixes
- **Focusing a multi-membership app stays put.** If an app belongs to several workspaces, clicking it while you're already in one of them no longer jumps you to a different workspace.
- **The main window comes to the front.** Opening Tatami's window no longer lets it sink behind other apps' windows.

## 1.6.1 (2026-07-10)

### Fixes
- **Fullscreen-zoom survives a monitor unplug/replug.** Closing and reopening a display no longer drops a workspace's fullscreen-zoom. Display churn briefly hid the window and used to clear its zoom for good. Now the same window returns and stays zoomed. Genuinely closing a zoomed window still un-zooms the workspace, and reopening one starts fresh.

## 1.6.0 (2026-07-09)

### ⚠️ Breaking Changes
- **Layouts always persist.** The per-workspace "session only" tiling-memory option has been removed. Every workspace now keeps its layout across restarts. Existing configs that set it still load, but the setting is ignored and no longer appears in Settings or the config schema.

### New
- **Workspace layout preview + editor.** Each workspace's settings now open with a live tile-layout editor. Drag dividers to resize, move a tile onto an edge to split, drop it in the center to swap, or rotate, mirror, balance, and change split orientation. A separate band holds fullscreen-zoomed windows. The editor also works for **inactive** workspaces, shows scratchpad borrow docks, and groups floating, ignored, and shared apps under "Not tiled."
- **Workspaces return to their monitor when you reconnect a display.** Replug an external display and the workspace that lived on it comes back: a workspace pinned to that monitor reclaims it (and the display it was borrowed onto falls back to what it last showed), otherwise the monitor restores its own most-recent workspace. Moving a workspace to another monitor now also refills the one it left.

### Improvements
- **Two windows of the same app keep their own tile.** Layouts track each window by its position among the app's windows, so multiple windows keep distinct, arrangeable spots and remember which one was fullscreen. Layout memory is also hardened: one unreadable entry no longer wipes every workspace, and older layouts migrate automatically.
- **Reorder workspaces by dragging** them in the sidebar, and **destructive actions now ask first:** deleting a workspace or removing an app prompts for confirmation.

### Fixes
- **`⌥Tab` returns to the window you were using.** Switching back to an app with several windows now lands on its most recently focused one instead of an arbitrary window.
- **Switching to an app no longer raises the wrong one.** When activating an app pulls its workspace forward, an always-open app in that workspace no longer steals the foreground.
- **Switching workspaces keeps minimized windows minimized** instead of restoring them.
- **Cross-display moves size correctly.** Moving a workspace to another monitor no longer leaves its windows short or at the wrong ratio. If macOS clamps a window to its old display mid-move, Tatami now reapplies the frame for the destination monitor.

## 1.5.1 (2026-06-30)

### Improvements
- **Faster tiling on busy workspaces.** The re-tile triggered by window and workspace changes now does less work. Its merge step dropped from quadratic to linear in the number of windows, with fewer layout-walk allocations. Tatami also avoids republishing an unchanged managed-window set, reducing steady-state CPU use.
- **Cross-monitor focus moves are announced on the monitor you left.** It is now clear where focus went on multi-display setups.
- **Smoother gesture-sensitivity slider.** Dragging it in Settings no longer re-renders the whole form on every tick.

### Fixes
- **Focus follows windows more reliably.** Focus now follows to newly opened and refocused windows, to the surviving tile when a window closes, and, with focus-follows-mouse, to the window actually under the cursor even when the machine is busy. Windows that briefly flap their accessibility role are kept instead of dropped.
- **Slow-launching apps tile their first window.** Heavy apps (e.g. Electron) whose accessibility layer comes up late now have their first window picked up and tiled instead of missed.
- **Workspace-switch leftovers cleaned up.** Unregistered apps no longer linger across a workspace switch, and the cursor warps to the focused tile when a window closes even if that tile had expanded over the pointer.
- **Borrow fixes.** Returning a borrow refocuses the block you were last using, releasing a borrow re-tiles the host's own windows, and unregistered floating apps stay visible while a borrow is docked.
- **Native fullscreen & zoom.** Entering native fullscreen no longer bounces back to the Desktop, fullscreen-zoom carries across a native-tab window swap, and a fullscreen-zoomed window's stale tile is no longer a drag drop-target.
- **Permission prompts.** The startup HUD shows whenever Accessibility is missing, and Accessibility and Screen Recording are surfaced together.

## 1.5.0 (2026-06-19)

### New
- **Borrow, compose two workspaces side by side.** Pull another workspace in beside the current one, docked to a screen edge (top / bottom / left / right) and tiled next to it. Each block keeps its own BSP layout, and windows cannot cross the boundary. The borrowed block is the *real* workspace, so edits there persist back to it. Hold the borrow modifier with a workspace's key (or `dismissBorrow` to return it), then steer the direction with `h` / `j` / `k` / `l` / arrows, or set a default edge and size, globally or per workspace. Directional focus crosses the boundary, activating a borrowed workspace fully switches to it, re-borrowing re-docks, and `esc` cancels the direction pick.
- **One key per workspace.** Give a workspace a single **key equivalent** and hold it with the switch (⌃⌥), assign (⌃⌥⇧), or borrow (⌃⌥⌘) modifier to switch to it, assign the focused app to it, or borrow it. The same keys drive the recent / next / previous targets, and every action still takes an explicit shortcut override. The modifier combos are configurable.
- **Scratchpad workspaces.** A borrow-only workspace kind, excluded from cycling, never activated on its own, summoned beside another workspace with a borrow (its apps auto-open when you do). Pick the kind in a workspace's settings. Scratchpads get their own menu-bar section.
- **Borrowed windows are badged.** The borrowed workspace's icon makes what is on loan clear at a glance. Configure its color and visibility under **Settings → Appearance → Window Markers**.

### Improvements
- **Settings reorganized.** The separate Shortcuts pane is gone. Each shortcut now lives in the pane for the feature it controls (Tiling, Focus & Mouse, Workspaces), and the panes and sections are ordered by how often you reach for them.
- **Menu bar tidied.** Scratchpads list under their own section, and the rarely-used "Pause Tiling" item was removed (pause/resume is still on the `toggleSpaceActivated` shortcut).

## 1.4.2 (2026-06-19)

### Fixes
- **Closing a window returns focus to your most recently used window.** When the focused window closed, focus could jump to the first tile instead of the window you were last on, most noticeably right after creating a second window and quickly toggling another app's tiling on and off. Refocus-on-close now follows per-workspace most-recently-used order, falling back through it to the next on-screen window.

## 1.4.1 (2026-06-18)

### Improvements
- **Choose app- or window-level window cycling.** Next/previous-window now steps app-by-app by default, one representative window per app, so a press lands on the next app. For the previous behavior (every window individually, including multiple windows of the same app), turn on "Cycle through every window" in Settings → Workspace Switching.

## 1.4.0 (2026-06-18)

### ⚠️ Breaking Changes
- **Per-app layout is now a mode, not a boolean.** Assigned apps and shared apps carry a `layout` of `tiled` / `floating` / `unmanaged` instead of `floating = true/false`. Existing configs (including a pre-1.4 `floating` bool and legacy `[[floatingApps]]`) migrate automatically on load. Once saved, the config uses the new `layout` key, so **downgrading to an older Tatami reads every app as tiled**. Hand-edited configs should switch to `layout = "…"`.

### Improvements
- **Ignore-tiling layout mode.** A third per-app mode beside tiled and floating: an *unmanaged* app stays a full workspace member, auto-open, show/hide, focus, focus-follows-mouse, and window cycling all apply, but its window is never tiled into the BSP tree nor mirrored onto an on-top panel, and it needs no Screen Recording. Set it per workspace and per shared app with the Tiled / Float / Ignore picker.
- **Workspaces restore your last-used window.** Activating a workspace with no pinned focus app now returns focus to the exact window you last used there, instead of a fixed app.
- **Cycle through every window.** The next/previous-window shortcuts walk all visible windows in the active workspace, tiled, floating, and unmanaged, cycling multiple windows of the same app individually.
- **Add apps by search or from disk.** The app picker searches running apps, and you can add one straight from a file.
- **Shortcut recording reworked.** The recorder shows layout-independent glyphs (⌘S regardless of your keyboard layout), records on a single click, flags conflicts with another binding by name, and suspends global hotkeys while you're recording, so the combo you press lands in the field instead of firing its action. Global hotkeys now run on Magnet (Carbon) under the hood.

### Fixes
- **Switching to a workspace no longer bounces back when a native-tab app changes its window id.** Apps with macOS native tabs (e.g. ghostty) swap window ids as you switch tabs, which could leave the BSP tree momentarily empty, and "switch to recent" would bounce you to the previous workspace. The active workspace now re-checks its own on-screen windows before switching.
- **Focus-follows-mouse only follows into windows Tatami manages.** Notification and HUD panels can no longer steal focus.
- **Hide-on-close windows are reclaimed** even when they fire no Accessibility destroy event.

## 1.3.3 (2026-06-13)

A patch release that removes the Input Monitoring prompt, prevents empty
workspaces from bouncing back, and shows the HUD on the display you are
actually looking at.

### Improvements
- **The workspace HUD shows on the display your cursor is on.** It used to follow the key window, which after a switch could be a different monitor than the one you were looking at.
- **Richer diagnostics.** Behind the Debug logging toggle, hotkey receipt, gesture recognition (including why a swipe *didn't* fire), floating-mirror lifecycle, show/hide summaries, BSP operations, and drag commits now all land in `tatami.log`.

### Fixes
- **Tatami no longer asks for Input Monitoring.** Its event taps are now gated by the Accessibility permission alone, so the "would like to receive keystrokes from any application" dialog is gone, and a previously denied Input Monitoring entry no longer breaks focus-follows-mouse and swipe gestures. If Tatami still appears under Privacy & Security → Input Monitoring from an older version, you can remove the entry with "−".
- **Switching to a workspace whose apps aren't running no longer bounces you back.** With nothing to focus, hiding the outgoing windows let macOS resurrect the previously active app, and follow-app-focus would chase it straight back to its workspace. An empty workspace now lands on an empty desktop and stays there.
- **An app that is both registered to a workspace and in Shared Apps no longer tiles twice** in that workspace's layout.

## 1.3.2 (2026-06-11)

A maintenance release with faster, steadier workspace switching and a batch of
stability fixes on top of a large internal hardening pass.

### Improvements
- **Snappier workspace switching.** Activations now read window identities from a cache instead of querying every window over Accessibility on the hot path, and a switch that arrives mid-activation supersedes the one still in flight, so rapid next/previous presses advance past a slow-to-settle workspace instead of stalling on it.
- **A busy app no longer disappears.** When an app is too loaded to answer an Accessibility query in time, Tatami keeps its last-known windows instead of reading the timeout as "no windows", so a momentarily-busy app no longer drops out of its tile, floating mirror, or marker dot. A single hung app can also no longer freeze the main thread for several seconds during a tiling pass.

### Fixes
- **Floating mirrors stop recording when they should.** Several races left ScreenCaptureKit streams (and the screen-recording indicator) running longer than intended. Capture now starts and stops in a strict order.
- **Freshly launched Electron windows are observed reliably.** Some windows missed their resize/close events when the first attempt to observe them failed. Those subscriptions now retry like the rest, so a phantom tile no longer lingers.
- **A corrupt `config.toml` no longer wipes your setup.** A broken top-level section (profiles, shared apps, settings) now keeps your previous config instead of resetting it (which the next write would have made permanent, taking your workspaces with it), and an unparsable settings field is surfaced instead of silently ignored.
- **"Relaunch" no longer turns into a plain quit.** When the relauncher fails to start, Tatami stays running and logs the failure.

## 1.3.1 (2026-06-07)

A quick follow-up to 1.3.0.

### New
- **Back to recent when empty.** With `settings.switching.switchToRecentWhenEmpty` enabled (off by default), closing the active workspace's last window switches to the recent workspace instead of leaving an empty desktop. Shared apps do not count as content because they join every workspace. A deliberately empty workspace never bounces you out. Only an actual close triggers the switch.
- **Internal failures now show up in the UI.** A broken `config.toml` (syntax error, invalid shortcut string), a `layouts.json` that will not read or write, a CLI server that fails to start, unavailable floating mirrors, or a failed Launch-at-Login registration now shows a warning HUD with error details and a ⚠️ in the menu bar (with a Problems section). Fixing the problem clears the badge with a confirmation HUD.

### Fixes
- **Floating mirrors respect focus-follows-mouse.** With focus-follows-mouse off, hovering a mirror no longer steals focus. Scrolls, clicks, and drags on a mirror now forward to the real window, and focus moves on click. With focus-follows-mouse on, hover keeps handing focus over as before.
- Two floating-window blinks with focus-follows-mouse off: a sibling float dipped behind a clicked tile for a beat, and the focused float dipped behind an overlapping sibling when the cursor left it.
- Quitting a floating app now removes its marker dot immediately instead of on the next focus change.

## 1.3.0 (2026-06-06)

### ⚠️ Breaking Changes
- **`[[floatingApps]]` is now `[[sharedApps]]`.** Configs migrate automatically on first launch: each floating entry becomes a shared app with `floating = true`. Shared apps are part of *every* workspace, tiled into each layout by default, or floating everywhere. Manage them in **Workspaces → Shared Apps**. Dotfiles that template the config should switch to the new key.
- **Floating windows now need the Screen Recording permission.** They stay above the tiles via ScreenCaptureKit mirrors, and without the grant they will not stay on top. Grant it in **Settings → General → Permissions**, then relaunch.

### New
- **Floating windows that stay above the tiles, without disabling SIP.** Mark any app as floating per workspace (the Float toggle next to Auto-open, or the `toggleFloating` hotkey): its windows stay untiled and are kept on top by mirroring them onto Tatami-owned ScreenCaptureKit panels. Reach for a floating window and the real one is handed back to you. While a floating app has focus, the mirrors (and the screen-recording indicator) get out of the way. Multiple floating windows stack by focus recency.
- **Shared Apps editor.** Add or remove shared apps and flip their Float toggle from a special workspace in the Workspaces sidebar.
- **Settings reorganized.** A System Settings-style sidebar (General, Tiling, Focus & Mouse, Workspaces, Shortcuts, Appearance) now includes a Screen Recording row under Permissions.
- **Shared hotkeys.** `toggleSharedFloating` floats the focused app everywhere, joining Shared Apps as floating if needed and changing it to shared tiled when toggled off. `toggleAppInSharedApps` adds or removes the focused app in Shared Apps.
- **Per-action HUD.** Floating changes, app membership, tiling pause, fullscreen zoom, and balance now show a brief overlay, each individually toggleable in **Settings → Appearance → Overlay** (plus the master switch and a configurable duration). Un-floating an app that stays in its workspace / Shared Apps shows a follow-up hint with the shortcut that removes it entirely.
- **What's New on first launch after an update.** A one-time window summarizes setup-affecting changes (with a Screen Recording grant button when needed) and feature highlights. The full changelog is also viewable from **About → View Changelog**.
- Missing Screen Recording no longer fails silently: the first activation that needs floating mirrors shows the system prompt and a warning HUD pointing at the Settings row.
- Auto-open apps **reopen on workspace re-entry** when their window was closed, not just on first activation.
- Fixed-size windows (e.g. the iOS **Simulator**) can float, resizability is only required for tiling.
- Floating windows' marker dots are always visible (not just on the focused window), and dots follow window drags with a smooth glide.

### Fixes
- **HUD fade-out fixed.** The panel's window-alpha animation only ran reliably once per launch, so overlays sometimes vanished instantly instead of fading out. The fade now runs on the content view.

## 1.2.1 (2026-06-02)

### Fixes
- **Detect windows that hide instead of close.** Electron apps like Discord hide their window on close (no Accessibility destroy event), which left a phantom tile slot. Tatami now prunes a tiled window once it leaves the screen and re-tiles the survivors.

## 1.2.0 (2026-06-02)

### New
- **Refocus when a window closes.** When the focused window closes and focus would otherwise be stranded on a now-windowless app (e.g. KakaoTalk, Notion Calendar, which keep running with no window), focus moves to a remaining window in the workspace. Toggle in **Settings → Mouse & Focus**.
- **Ignore full-screen windows in focus-follows-mouse.** An option (on by default) keeps focus-follows-mouse from grabbing a window that fills the whole display as the cursor skims across it.

## 1.1.0 (2026-06-02)

### New
- **Multi-monitor, per display.** Each display tracks its own active and recent workspaces. Activation, "recent workspace", and next/previous cycling all act on the display under the cursor, and new workspaces start pinned to the current display.
  - **Focus next / previous display:** move focus to the active workspace on the next monitor, looping around (`focusNextDisplay` / `focusPreviousDisplay`).
  - **Cycle across all displays:** option to make next/previous workspace span every display's workspaces instead of only the one under the cursor (`settings.switching.cycleAcrossDisplays`).
  - Displays are identified by a stable UUID (with a name fallback), so reconnecting the same monitor keeps its assignments. Everything falls back to the primary display when a monitor is absent.
  - Per-display dot colors in the sidebar show which monitor each workspace is active on.
- **Move app to next / previous workspace.** Relocate the focused app one workspace over and follow it there (`moveToNextWorkspace` / `moveToPreviousWorkspace`).
- **Assign focused app to a workspace.** A per-workspace shortcut adds the focused app (keeping its other memberships) and switches there.
- **Focus app on activation.** Choose which assigned app gets focus when a workspace activates (defaults to most-recently-used).
- **Bundled CLI installer.** Install or uninstall the `tatami` CLI from **Settings → Command Line** (Homebrew installs are detected). Accessibility permission status and a one-click grant now live in **Settings → Permissions**.
- In-app descriptions for the non-obvious shortcuts, plus a Pinned-vs-Dynamic explainer in a workspace's Display section.

### Fixes
- **focus-follows-mouse** no longer grabs a full-screen window showing through the gaps between tiled windows.
- Hot keys re-register immediately after recording a workspace's **Assign** shortcut (previously needed a relaunch).
- **Persistent layouts** restore each fullscreen-zoomed window of the *same* app to a distinct window instead of collapsing them onto one.
- Apps that run one process per window under a shared bundle id (e.g. **Neovide**) now tile. Window discovery scans every process, not just the first.
- Moving an app to another workspace keeps its name, icon, and auto-open setting instead of relabeling it with the bundle id.
- The workspace **Display picker** now lists every connected display when switching between workspaces.
- `tatami version` reports the running app's real version.

## 1.0.0 (2026-05-29)

The first stable release. Here's what changed since v0.1.3.

### New
- **Drag to rearrange.** Drag a window and a live overlay previews the drop: the center **swaps** the two windows, while an edge **inserts** the dragged one on that side (left / right / top / bottom).
- **Window markers.** A small corner dot marks zoomed / floating windows. Configure its color, size, corner, and hover-fade.
- **Multi-window zoom** and per-workspace **layout memory** (`session` / `persistent`).
- **New shortcuts.** Balance the tree or toggle the focused app's workspace membership, plus a toolbar **Activate** button.
- Optional **debug logging** to `~/.config/tatami/tatami.log` for diagnosing tiling.

### Improvements
- **Manual resize** now drags any window edge and re-tiles against the correct join. Height resizes work even when the immediate split is vertical. A drag that changes nothing snaps the window back to its tile.
- Manual move / resize commits on **mouse-up** (not a timer), so dragging stays smooth and never fights you mid-drag.
- Window markers track their windows **event-driven** (no polling timer), ~zero idle CPU.
- **Reworked concurrency:** AX window hit-testing, the CLI socket server, and the mouse / gesture event taps no longer block the main thread or the Swift cooperative pool.
- Snappier focus-follows-mouse and tiling-debounce timings.
- Overhauled BSP insert / swap / warp / balance semantics.

### Fixes
- **Tiling hotkeys fixed.** `grow` / `shrink` / `balance` now work in common layouts.
- **Settings steppers fixed.** Gap and dot-size steppers no longer run away on a single click.
- Parse `-` (minus) in shortcut strings and resize horizontal splits correctly.

### Removed / config change
- Dropped the `fresh` tiling-memory mode. It rebuilt layouts from a focus-dependent order and reshuffled them on every workspace switch. Workspaces now use `session` (default) or `persistent`. Existing configs set to `"fresh"` fall back to `session`.

## 0.1.3 (2026-05-28)

### Changed
- **Pause now means "pause tiling" only.** Toggling pause from the menu bar (or the `toggleSpaceActivated` hotkey) used to block workspace switching too. It now suspends only the BSP tile pass while workspace switches, show/hide, and focus keep working. The pause flag is also no longer persisted to config. It is runtime-only, and every launch starts unpaused.

## 0.1.2 (2026-05-28)

### Added
- **Launch at Login:** Tatami can start automatically when you log in. Toggle in **Settings → General → Launch at login**.
- **Sparkle release notes:** the in-app update dialog links to each release's notes page starting with this version.

## 0.1.1 (2026-05-28)

### Added
- **Software updates now work end to end.** Sparkle is fully wired up. Tatami checks for and installs updates in the background. Pick the frequency (hourly / daily / weekly) or check manually from Settings or the menu bar.
- **About tab:** version, creator, and open-source credits (FlashSpace, yabai, and the libraries Tatami is built with).

### Changed
- Settings now use Perception's observation, dependency clients adopt `@DependencyClient`, and an unused `autoFocusBlacklist` setting was removed.

## 0.1.0 (2026-05-27)

First public release. A macOS workspace manager with yabai-style window tiling.
Group your apps into virtual workspaces, switch with a keystroke or trackpad
swipe, and tile their windows automatically. No SIP changes, no shell scripting.

### Tiling (yabai-style BSP)
- Automatic binary space partitioning with a dwindle (spiral) layout
- Directional focus / swap / resize (vim-like `h` `j` `k` `l`)
- Zoom a window to fill the workspace, toggle split orientation
- Rotate, mirror, balance, drag-to-swap, and live resize sync
- Configurable inner / outer gaps

### Workspaces
- Per-workspace app assignments with switching by hotkey, swipe, or "recent"
- Loop-around, skip-empty, and follow-app-focus options
- Auto-open assigned apps on activation
- Multi-display (pin a workspace or follow apps dynamically)
- Floating apps that never tile

### Focus & interface
- focus-follows-mouse / mouse-follows-focus, optional cursor hide
- Menu bar item with the active workspace (icon + name)
- On-screen HUD on switch, per-workspace SF Symbol icons
- skhd-style shortcut syntax, plain-TOML config, scripting CLI
