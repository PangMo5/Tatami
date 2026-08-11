# Changelog

All notable changes to Tatami. This file is the source of truth for the release
notes shown on the website and on GitHub Releases (the release workflow appends
an Install / Update section when publishing). Sparkle's in-app update dialog
accumulates every patch in a release's minor series, so each section here only
needs its own version's changes.

## 1.11.4 (2026-08-11)

### Fixes
- **Shared apps preserve each workspace's last-used window:** Returning to a workspace now restores the window you last focused there, instead of a shared tiled app that was focused while switching through another workspace.

## 1.11.3 (2026-08-07)

### New
- **The cursor follows an app-driven switch:** With Mouse follows focus on, activating an app from the Dock, Spotlight, or the app switcher now moves the cursor to the window that was actually raised, not just to the workspace. Landing on a workspace holding several windows of that app no longer leaves it ambiguous which one took focus.

### Improvements
- **Recent workspace spans displays by default:** New installs treat "the workspace I was just in" as one idea across the whole desk rather than one per monitor. Existing configurations keep whatever they already had.
- **The cursor follows layout commands that reshape the focused window:** Toggling a split's orientation or entering and leaving fullscreen zoom now carries the cursor with the focused window, which previously stayed on the tile the window no longer occupied.

### Fixes
- **Dynamic workspaces follow the mouse again:** A workspace set to Dynamic (follows mouse) stopped moving once it had been shown anywhere, so it stayed on whichever monitor it last landed on. Activating one now brings it to the display under the pointer, while a workspace already on the pointer's display still keeps a live Borrow composition intact.
- **Workspaces restore correctly after unlocking with several displays:** macOS drops and re-adds monitors behind the lock shield, and Tatami reconciled every intermediate report. That tore down the display assignment, sometimes switched profiles through a display-count rule, and saved the result. Reconciliation now waits for the topology to settle, so a monitor that merely blinked out and back changes nothing and a real unplug is handled exactly once.
- **The cursor stays where you release a drag:** Dragging a window to a new tile could teleport the cursor moments after the drop, because repairing the frame some apps restore behind the drag counted as a layout change worth following. A layout the pointer caused no longer moves the pointer, inside a Borrow composition as well.
- **A summoned Borrow always focuses its block:** Summoning a scratchpad sometimes left the borrowed block on screen with focus and cursor still on the host, depending on whether an unrelated layout write superseded the one carrying the Borrow.
- **A borrowed workspace is returned when its host moves:** Pulling a Borrow host to another monitor left the borrowed windows behind on the display it came from until something else happened to redraw that display.
- **Switching to a workspace with no window works:** A workspace whose windows were all closed could swallow the switch entirely, with no app activation, no hide pass, and no HUD.
- **Refilling a vacated display no longer steals focus:** When a dynamic workspace leaves a monitor and another takes its place, that background switch no longer pulls keyboard focus (and the cursor with it) away from the workspace the user just moved to.
- **Check for Updates responds to the first click:** Choosing it from the menu bar opened its window behind whatever was frontmost, so it read as nothing happening until the second click.
- **The window switcher no longer clips its shadow:** The switcher panel is sized from its shadow, so the drop shadow renders fully at every width.

## 1.11.2 (2026-08-04)

### Fixes
- **Layouts preserved through screen lock:** Locking the screen no longer lets temporary Accessibility or WindowServer snapshots remove windows from the active BSP layout. Tatami freezes destructive membership changes before the lock shield appears, waits for every overlapping sleep or session transition to finish, then reconnects the complete layout after unlock.
- **Complete workspace feedback across displays:** Moving focus to a workspace already visible on another display once again shows its workspace HUD without disturbing a live Borrow composition. The display being left now names both the destination workspace and monitor, so every cross-display switch makes the result clear.

## 1.11.1 (2026-08-02)

### Fixes
- **Stable layouts during native tab changes:** Creating, closing, or switching native tabs no longer lets transient WindowServer surface identities enter the BSP tree as separate windows. Tatami preserves the existing tile, focus history, zoom state, and presentation state while the real window surface changes, even during rapid tab churn.

## 1.11.0 (2026-07-31)

### New
- **Resume the last workspace on every display:** Tatami now restores the last eligible profile, each display's workspace history, and the global workspace recency order after relaunch. A manually selected profile stays selected; a display-conditioned profile is restored only while its rule still matches, then Tatami falls back to the best profile for the connected displays.

### Improvements
- **More responsive window tracking:** Window identity, capabilities, geometry, focus, mirrors, and markers now share cache-first, coalesced update paths instead of repeating synchronous Accessibility work. Per-app operations preserve their order without letting one busy app stall unrelated apps, and superseded scans or focus requests can no longer publish stale results.
- **A clearer, more precise window switcher:** The held-shortcut switcher now shows focused, Borrowed, Shared Apps, Always on Top, and fullscreen status on each app icon. Pointer hover updates the real selection, so Return or modifier release commits the exact highlighted window even when one app has several windows; the refreshed layout is more compact and honors Reduce Motion.
- **Balance that follows the layout setting:** The Balance command now applies the configured Auto-balance axes. With Auto-balance off, it rebuilds the canonical BSP tree instead of only equalizing ratios inside an already uneven topology.

### Fixes
- **Reliable late, hidden, and reappearing windows:** Tatami reacts to WindowServer visibility changes immediately, removes a hidden surface without forgetting its identity, and keeps converging a reappearing app back to its tile if the app restores an older frame later. First windows from slow apps now recover their intended focus, fullscreen slot, and frame as soon as observation becomes ready.
- **Stable Borrow completion and focus:** A cold app whose first window appears after Borrow starts is tiled and focused immediately. Borrow now preserves exact host focus and window badges while settling, clears stale badges before a full activation, and remains composed when focus moves to another display or back to an already visible host.
- **Layouts preserved through sleep and wake:** WindowServer teardown during system sleep no longer erases the live BSP tree. On wake, Tatami reconnects surviving windows or replaces recycled surfaces as one completed layout, without persisting a transient half-restored state.
- **Last-used profile restored safely:** Relaunching Tatami no longer falls back to the first profile when the previous manual profile is still valid, and it no longer restores a conditioned profile whose display rule stopped matching.
- **Settings steppers save every click:** Gap, duration, marker-size, gesture-threshold, and Borrow-fraction changes now commit after each macOS Stepper update instead of relying on an editing-ended callback that ordinary clicks may never send.
- **Guided Setup fullscreen matches the app:** The virtual layout editor now tracks fullscreen windows as a set, supports more than one fullscreen window across the practice workspaces, and preserves that state when resuming a saved or legacy setup draft.

## 1.10.0 (2026-07-27)

### New
- **Five interface languages:** Tatami is now available in English, Korean, Japanese, Simplified Chinese, and Traditional Chinese across Settings, Guided Setup, the menu bar, on-screen feedback, errors, and confirmations. Tatami follows the macOS language preference selected for the app.

### Improvements
- **Writing designed for each locale:** Every translation is written around the task and next action instead of following English word for word, with terminology and tone reviewed for each supported locale.
- **Clearer feature names:** User-facing copy now uses **Always on Top**, **Leave As Is**, **Window Switching**, and **On-Screen Feedback** in place of internal implementation terms. Existing `config.toml` keys remain compatible.
- **Fully localized dynamic feedback:** Workspace and profile names, app actions, Borrow results, layout changes, errors, and other runtime messages now use locale-aware formatting without changing user-entered names.

## 1.9.2 (2026-07-27)

### Fixes
- **Stable MFF and FFM interaction:** When both focus modes are enabled, pointer-driven focus no longer feeds its Accessibility notification back into mouse-follows-focus and snaps the pointer again. Tatami ignores synthetic movement from its own cursor warps, drops stale focus echoes, and lets Borrow repair its layout without reclaiming a pointer the user already moved.

## 1.9.1 (2026-07-23)

### Fixes
- **Borrow layout after notification activation:** Clicking a notification for an app already visible in Borrow no longer lets the app restore a shorter saved frame and leave empty space below it. Tatami reasserts the complete borrowed block after the focused window settles.

## 1.9.0 (2026-07-23)

### New
- **Interactive Guided Setup:** First launch now builds a draft from this Mac's running-app metadata and connected displays, then teaches Workspaces, switching and gestures, BSP tiling, Borrow and scratchpads, Float / Ignore, MFF / FFM, and app / window cycling in order. Every lesson runs in a safe virtual display, earlier shortcuts keep working in later lessons, and nothing touches real windows or `config.toml` until **Apply Setup**. Run it again at any time from **Settings → General**.
- **AI-assisted workspace planning:** Describe your role and a typical week, then review a task-oriented workspace proposal before it changes the draft. Tatami can prepare a privacy-labelled prompt for ChatGPT, Claude, Gemini, or another AI, or use the on-device Apple Intelligence model on supported Macs. Recommendations account for app metadata, display count and usable geometry, keep one-app scratchpads deliberate, and never inspect screen contents.
- **Interactive app / window switcher:** The held-shortcut HUD is now a compact switcher that fades in and out without interrupting cycling. Continue with the configured shortcut or arrow keys, commit with Return or modifier release, cancel with Escape, or point and click an item. Keyboard selection and pointer hover remain visually distinct; quick presses still switch immediately without flashing the HUD.

### Improvements
- **One cumulative practice surface:** Guided Setup reuses the workspaces, app assignments, layout modes, shortcuts, and gestures in the user's draft. Later labs preserve MRU behavior and every command learned earlier, so the final Focus & Cycling lesson rehearses the complete setup rather than an isolated mock.
- **Borrow-aware focus and cycling:** Host and borrowed tiled windows form one visible cycling context until the borrow is dismissed. App-level cycling recalls each app's most-recent window, window-level cycling preserves same-app windows, and focus plus MFF can cross the host / Borrow boundary.
- **Faster Borrow and menu-bar interaction:** Borrow now lays out its blocks before transferring focus, then orders keyboard focus and MFF pointer movement against the resulting live frame. It also skips redundant Accessibility frame writes, reuses a known hidden scratchpad window instead of reopening it, and keeps the menu-bar runtime latency-sensitive under App Nap.
- **Adaptive action HUDs:** Action feedback now enters and leaves with a compact spring transition, resizes around its content, and updates an already-visible HUD without replaying the whole presentation.

### Fixes
- **MFF for non-tiled cycle targets:** Cycling to a Floating, Shared Floating, or Ignore-mode window now reads that window's live frame after focus and moves the pointer to its center instead of leaving it behind.

## 1.8.1 (2026-07-20)

### Fixes
- **Cross-profile transient app tiling:** Apps assigned only to an inactive profile now tile normally when opened in the current profile, instead of being treated as owned by an unreachable workspace.

## 1.8.0 (2026-07-20)

### New
- **Native-style window switcher:** The next / previous-window shortcuts now behave like macOS Command-Tab: a quick press switches without flashing a HUD, holding the shortcut shows a centered app or window strip that stays up while the modifier is down, and releasing the modifier commits focus before the HUD fades away. App-level cycling restores that app's most-recent window, while the existing every-window option keeps each same-app window separate.
- **Fully configurable trackpad gestures:** Bind left, right, up, and down swipes independently for both three and four fingers to any Tatami shortcut action. The picker includes profile and workspace submenus for switching profiles, activating or assigning to a workspace, and borrowing from the active profile. Existing `fingerCount` configurations migrate to equivalent horizontal bindings automatically.

### Improvements
- **Optional global recent workspace:** Recent-workspace actions can now use one MRU history across every display, focusing a workspace where it already lives instead of pulling it onto the pointer display. The existing per-display behavior remains the default.
- **Borrow again to dismiss:** Summoning a workspace that is already borrowed on the current display dismisses it and restores the host workspace by default. Turn the option off to keep re-docking the borrow instead.

### Fixes
- **Exact same-app window restoration:** Before leaving a workspace, Tatami reconciles the exact focused window against the visible layout. Returning now restores the window you actually used even when another window from the same app had the older MRU position or a focus notification was missed.

## 1.7.3 (2026-07-20)

### Improvements
- **Dynamic workspaces follow the pointer:** Activating a dynamic workspace from a Tatami shortcut or an external launcher now opens it on the display under the mouse. Background reflows stay on the display that already owns the workspace instead of pulling it elsewhere.
- **Pointer-scoped borrowing:** Borrow, recent / next / previous borrow, direction selection, and dismiss now consistently operate on the display under the mouse. Direction selection also remembers the display where it began.
- **Lower workspace activation overhead:** Tatami skips redundant Accessibility frame writes, immediately drops cached windows when their process or window disappears, and cancels activation, focus, and mirror work that has already been superseded.

### Fixes
- **Cross-app focus-follows-mouse:** Moving focus between windows owned by different apps now transfers the frontmost application as well as raising the window, including when the windows are on different displays.
- **Correct close refocus and cursor centering:** Closing the focused window now selects the intended most-recent window after the window list has settled and centers the cursor on its live frame.
- **Stable multi-display lifecycle:** Window creation, destruction, synchronization, display reconnects, and background layout work now stay scoped to the owning display, preventing unrelated displays from stealing focus or changing workspace order.
- **Stable workspace reopening:** Reopening a workspace after one of its windows was closed no longer briefly reserves space for the missing window or temporarily squeezes the remaining windows.

## 1.7.2 (2026-07-15)

### Fixes
- **Cross-display window cycling:** The window-cycle shortcut (alt/opt+tab by default, on since 1.7.0) could get stuck cycling between the same two windows or operate on the wrong monitor's workspace. Focus now transfers the frontmost application via the window server (not just an Accessibility raise), so cycling between apps and across displays lands correctly.
- **Display-reconfiguration coalescing:** A burst of identical screen-parameter notifications from the OS is now coalesced, so Tatami no longer spins re-evaluating an unchanged display setup.
- **Deep-sleep fullscreen-zoom restoration:** A zoomed window whose surface the system recycles on wake no longer loses its zoom.
- **Trackpad gesture stability:** A fast multi-finger swipe no longer crashes the app.
- **Correct monitor targeting for keyboard tiling:** Resize / move / rotate / balance and drag edits on a workspace shown on a non-cursor display now compute against that display.

## 1.7.1 (2026-07-14)

### Improvements
- **Three-column profile sidebar:** Settings now show your profiles, then the selected profile's contents, then the detail, so you can inspect and edit **any** profile (its workspaces, layouts, shortcuts) without switching to it first. The running profile is still marked with a green dot, distinct from the one you're viewing. Activating a workspace from a non-active profile switches to that profile and lands on it in one step.
- **Global Shared Apps sidebar:** Shared apps join every workspace of every profile, so they moved out from under a single profile into an **Everywhere** section in the sidebar.
- **Per-display profile switch HUD:** Switching a profile now shows, on each monitor, the workspace that lands there, instead of one HUD listing everything.

### Fixes
- **Pinned-workspace retention for disconnected displays:** Activating a workspace whose pinned monitor is not connected, then switching profiles away and back, no longer reverts it to a different workspace. Tatami keeps it where you last had it and returns it to its own monitor when that display reconnects.

## 1.7.0 (2026-07-14)

### New
- **Profiles:** Group your workspaces into named profiles and switch the whole set at once. Each profile has its own workspaces, app assignments, shortcuts, and SF Symbol icon, shown in the sidebar, menu bar, and switch HUD. Switch by hotkey or from the menu bar, reorder profiles by dragging, and re-tile every display for the new profile.
- **Display-based profile auto-activation:** Switch profiles automatically based on monitor count or specific displays being connected or unplugged. Tatami flags ambiguous rules so it is clear which profile wins and why another did not activate.
- **Cross-profile workspace copying:** Profiles keep independent workspaces, so their apps and settings can drift apart. Open **Copy from…** in a profile or workspace detail to review each app, layout, auto-open, and settings difference, then copy only the checked changes.

### Improvements
- **Customizable menu bar:** Pick what the menu-bar item shows under **Settings → Appearance → Menu Bar:** the active workspace's icon and name, and, when you have more than one profile, the active profile's icon and name.
- **Reorganized settings:** Workspace key equivalents moved to their own **Workspace Keys** pane and trackpad gestures to a **Gestures** pane. Window-cycling settings and shortcuts are grouped together. A workspace's derived shortcuts link straight to Workspace Keys, and those derived combos now render as plain read-only text so it is clear they are configured elsewhere.
- **Friendlier new-install defaults:** A brand-new config is seeded with a recommended set of shortcuts, and *follow app focus* (activating an app switches to the workspace that owns it) is on by default. Existing configs are left as-is.

### Fixes
- **Stable focus for multi-membership apps:** If an app belongs to several workspaces, clicking it while you're already in one of them no longer jumps you to a different workspace.
- **Reliable main-window foregrounding:** Opening Tatami's window no longer lets it sink behind other apps' windows.

## 1.6.1 (2026-07-10)

### Fixes
- **Fullscreen-zoom restoration after display reconnection:** Closing and reopening a display no longer drops a workspace's fullscreen-zoom. Display churn briefly hid the window and used to clear its zoom for good. Now the same window returns and stays zoomed. Genuinely closing a zoomed window still un-zooms the workspace, and reopening one starts fresh.

## 1.6.0 (2026-07-09)

### ⚠️ Breaking Changes
- **Persistent layouts:** The per-workspace "session only" tiling-memory option has been removed. Every workspace now keeps its layout across restarts. Existing configs that set it still load, but the setting is ignored and no longer appears in Settings or the config schema.

### New
- **Workspace layout preview and editor:** Each workspace's settings now open with a live tile-layout editor. Drag dividers to resize, move a tile onto an edge to split, drop it in the center to swap, or rotate, mirror, balance, and change split orientation. A separate band holds fullscreen-zoomed windows. The editor also works for **inactive** workspaces, shows scratchpad borrow docks, and groups floating, ignored, and shared apps under "Not tiled."
- **Workspace restoration after display reconnection:** Replug an external display and the workspace that lived on it comes back: a workspace pinned to that monitor reclaims it (and the display it was borrowed onto falls back to what it last showed), otherwise the monitor restores its own most-recent workspace. Moving a workspace to another monitor now also refills the one it left.

### Improvements
- **Distinct tiles for same-app windows:** Layouts track each window by its position among the app's windows, so multiple windows keep distinct, arrangeable spots and remember which one was fullscreen. Layout memory is also hardened: one unreadable entry no longer wipes every workspace, and older layouts migrate automatically.
- **Workspace reordering and destructive-action confirmation:** Reorder workspaces by dragging them in the sidebar. Deleting a workspace or removing an app now prompts for confirmation.

### Fixes
- **Most-recently-used window restoration:** Switching back to an app with several windows using `⌥Tab` now lands on its most recently focused one instead of an arbitrary window.
- **Correct foreground app on workspace activation:** When activating an app pulls its workspace forward, an always-open app in that workspace no longer steals the foreground.
- **Preserved minimized windows:** Switching workspaces keeps minimized windows minimized instead of restoring them.
- **Correct cross-display window sizing:** Moving a workspace to another monitor no longer leaves its windows short or at the wrong ratio. If macOS clamps a window to its old display mid-move, Tatami now reapplies the frame for the destination monitor.

## 1.5.1 (2026-06-30)

### Improvements
- **Faster busy-workspace tiling:** The re-tile triggered by window and workspace changes now does less work. Its merge step dropped from quadratic to linear in the number of windows, with fewer layout-walk allocations. Tatami also avoids republishing an unchanged managed-window set, reducing steady-state CPU use.
- **Source-display focus announcements:** Cross-monitor focus moves are announced on the monitor you left, so it is now clear where focus went on multi-display setups.
- **Smoother gesture-sensitivity slider:** Dragging it in Settings no longer re-renders the whole form on every tick.

### Fixes
- **More reliable window focus tracking:** Focus now follows to newly opened and refocused windows, to the surviving tile when a window closes, and, with focus-follows-mouse, to the window actually under the cursor even when the machine is busy. Windows that briefly flap their accessibility role are kept instead of dropped.
- **First-window tiling for slow-launching apps:** Heavy apps (e.g. Electron) whose accessibility layer comes up late now have their first window picked up and tiled instead of missed.
- **Workspace-switch cleanup:** Unregistered apps no longer linger across a workspace switch, and the cursor warps to the focused tile when a window closes even if that tile had expanded over the pointer.
- **Borrow lifecycle fixes:** Returning a borrow refocuses the block you were last using, releasing a borrow re-tiles the host's own windows, and unregistered floating apps stay visible while a borrow is docked.
- **Native fullscreen and fullscreen-zoom stability:** Entering native fullscreen no longer bounces back to the Desktop, fullscreen-zoom carries across a native-tab window swap, and a fullscreen-zoomed window's stale tile is no longer a drag drop-target.
- **Unified permission prompts:** The startup HUD shows whenever Accessibility is missing, and Accessibility and Screen Recording are surfaced together.

## 1.5.0 (2026-06-19)

### New
- **Side-by-side workspace borrowing:** Pull another workspace in beside the current one, docked to a screen edge (top / bottom / left / right) and tiled next to it. Each block keeps its own BSP layout, and windows cannot cross the boundary. The borrowed block is the *real* workspace, so edits there persist back to it. Hold the borrow modifier with a workspace's key (or `dismissBorrow` to return it), then steer the direction with `h` / `j` / `k` / `l` / arrows, or set a default edge and size, globally or per workspace. Directional focus crosses the boundary, activating a borrowed workspace fully switches to it, re-borrowing re-docks, and `esc` cancels the direction pick.
- **Single-key workspace controls:** Give a workspace a single **key equivalent** and hold it with the switch (⌃⌥), assign (⌃⌥⇧), or borrow (⌃⌥⌘) modifier to switch to it, assign the focused app to it, or borrow it. The same keys drive the recent / next / previous targets, and every action still takes an explicit shortcut override. The modifier combos are configurable.
- **Scratchpad workspaces:** A borrow-only workspace kind, excluded from cycling, never activated on its own, summoned beside another workspace with a borrow (its apps auto-open when you do). Pick the kind in a workspace's settings. Scratchpads get their own menu-bar section.
- **Borrowed-window badges:** The borrowed workspace's icon makes what is on loan clear at a glance. Configure its color and visibility under **Settings → Appearance → Window Markers**.

### Improvements
- **Feature-based settings organization:** The separate Shortcuts pane is gone. Each shortcut now lives in the pane for the feature it controls (Tiling, Focus & Mouse, Workspaces), and the panes and sections are ordered by how often you reach for them.
- **Tidier menu bar:** Scratchpads list under their own section, and the rarely-used "Pause Tiling" item was removed (pause/resume is still on the `toggleSpaceActivated` shortcut).

## 1.4.2 (2026-06-19)

### Fixes
- **Most-recently-used focus after window closure:** When the focused window closed, focus could jump to the first tile instead of the window you were last on, most noticeably right after creating a second window and quickly toggling another app's tiling on and off. Refocus-on-close now follows per-workspace most-recently-used order, falling back through it to the next on-screen window.

## 1.4.1 (2026-06-18)

### Improvements
- **App-level or window-level cycling:** Next/previous-window now steps app-by-app by default, one representative window per app, so a press lands on the next app. For the previous behavior (every window individually, including multiple windows of the same app), turn on "Cycle through every window" in Settings → Workspace Switching.

## 1.4.0 (2026-06-18)

### ⚠️ Breaking Changes
- **Per-app layout modes:** Assigned apps and shared apps carry a `layout` of `tiled` / `floating` / `unmanaged` instead of `floating = true/false`. Existing configs (including a pre-1.4 `floating` bool and legacy `[[floatingApps]]`) migrate automatically on load. Once saved, the config uses the new `layout` key, so **downgrading to an older Tatami reads every app as tiled**. Hand-edited configs should switch to `layout = "…"`.

### Improvements
- **Ignore-tiling layout mode:** A third per-app mode beside tiled and floating lets an *unmanaged* app stay a full workspace member. Auto-open, show/hide, focus, focus-follows-mouse, and window cycling all apply, but its window is never tiled into the BSP tree nor mirrored onto an on-top panel, and it needs no Screen Recording. Set it per workspace and per shared app with the Tiled / Float / Ignore picker.
- **Last-used window restoration:** Activating a workspace with no pinned focus app now returns focus to the exact window you last used there, instead of a fixed app.
- **Per-window cycling:** The next/previous-window shortcuts walk all visible windows in the active workspace, tiled, floating, and unmanaged, cycling multiple windows of the same app individually.
- **Searchable app picker:** The app picker searches running apps, and you can add one straight from a file.
- **Reworked shortcut recording:** The recorder shows layout-independent glyphs (⌘S regardless of your keyboard layout), records on a single click, flags conflicts with another binding by name, and suspends global hotkeys while you're recording, so the combo you press lands in the field instead of firing its action. Global hotkeys now run on Magnet (Carbon) under the hood.

### Fixes
- **Stable native-tab workspace switching:** Switching to a workspace no longer bounces back when a native-tab app changes its window id. Apps with macOS native tabs (e.g. ghostty) swap window ids as you switch tabs, which could leave the BSP tree momentarily empty, and "switch to recent" would bounce you to the previous workspace. The active workspace now re-checks its own on-screen windows before switching.
- **Managed-window-only focus following:** Focus-follows-mouse only follows into windows Tatami manages, so notification and HUD panels can no longer steal focus.
- **Hide-on-close window reclamation:** Hide-on-close windows are reclaimed even when they fire no Accessibility destroy event.

## 1.3.3 (2026-06-13)

A patch release that removes the Input Monitoring prompt, prevents empty
workspaces from bouncing back, and shows the HUD on the display you are
actually looking at.

### Improvements
- **Cursor-display workspace HUD:** The workspace HUD now shows on the display your cursor is on. It used to follow the key window, which after a switch could be a different monitor than the one you were looking at.
- **Richer diagnostics:** Behind the Debug logging toggle, hotkey receipt, gesture recognition (including why a swipe *didn't* fire), floating-mirror lifecycle, show/hide summaries, BSP operations, and drag commits now all land in `tatami.log`.

### Fixes
- **Removal of the Input Monitoring requirement:** Tatami no longer asks for Input Monitoring. Its event taps are now gated by the Accessibility permission alone, so the "would like to receive keystrokes from any application" dialog is gone, and a previously denied Input Monitoring entry no longer breaks focus-follows-mouse and swipe gestures. If Tatami still appears under Privacy & Security → Input Monitoring from an older version, you can remove the entry with "−".
- **Stable empty-workspace switching:** Switching to a workspace whose apps aren't running no longer bounces you back. With nothing to focus, hiding the outgoing windows let macOS resurrect the previously active app, and follow-app-focus would chase it straight back to its workspace. An empty workspace now lands on an empty desktop and stays there.
- **No duplicate tiling for shared workspace apps:** An app that is both registered to a workspace and in Shared Apps no longer tiles twice in that workspace's layout.

## 1.3.2 (2026-06-11)

A maintenance release with faster, steadier workspace switching and a batch of
stability fixes on top of a large internal hardening pass.

### Improvements
- **Faster workspace switching:** Activations now read window identities from a cache instead of querying every window over Accessibility on the hot path, and a switch that arrives mid-activation supersedes the one still in flight, so rapid next/previous presses advance past a slow-to-settle workspace instead of stalling on it.
- **Busy-app retention:** When an app is too loaded to answer an Accessibility query in time, Tatami keeps its last-known windows instead of reading the timeout as "no windows", so a momentarily-busy app no longer drops out of its tile, floating mirror, or marker dot. A single hung app can also no longer freeze the main thread for several seconds during a tiling pass.

### Fixes
- **Timely floating-mirror capture shutdown:** Several races left ScreenCaptureKit streams (and the screen-recording indicator) running longer than intended. Capture now starts and stops in a strict order.
- **Reliable Electron window observation:** Some windows missed their resize/close events when the first attempt to observe them failed. Those subscriptions now retry like the rest, so a phantom tile no longer lingers.
- **Corrupt-config protection:** A broken top-level section in `config.toml` (profiles, shared apps, settings) now keeps your previous config instead of resetting it (which the next write would have made permanent, taking your workspaces with it), and an unparsable settings field is surfaced instead of silently ignored.
- **Reliable relaunch failure handling:** When the relauncher fails to start, Tatami stays running and logs the failure instead of turning "Relaunch" into a plain quit.

## 1.3.1 (2026-06-07)

A quick follow-up to 1.3.0.

### New
- **Automatic return from empty workspaces:** With `settings.switching.switchToRecentWhenEmpty` enabled (off by default), closing the active workspace's last window switches to the recent workspace instead of leaving an empty desktop. Shared apps do not count as content because they join every workspace. A deliberately empty workspace never bounces you out. Only an actual close triggers the switch.
- **In-app failure reporting:** A broken `config.toml` (syntax error, invalid shortcut string), a `layouts.json` that will not read or write, a CLI server that fails to start, unavailable floating mirrors, or a failed Launch-at-Login registration now shows a warning HUD with error details and a ⚠️ in the menu bar (with a Problems section). Fixing the problem clears the badge with a confirmation HUD.

### Fixes
- **Focus-follows-mouse behavior for floating mirrors:** With focus-follows-mouse off, hovering a mirror no longer steals focus. Scrolls, clicks, and drags on a mirror now forward to the real window, and focus moves on click. With focus-follows-mouse on, hover keeps handing focus over as before.
- **Floating-window blink fixes:** With focus-follows-mouse off, two blinks are fixed: a sibling float dipped behind a clicked tile for a beat, and the focused float dipped behind an overlapping sibling when the cursor left it.
- **Immediate marker removal after app quit:** Quitting a floating app now removes its marker dot immediately instead of on the next focus change.

## 1.3.0 (2026-06-06)

### ⚠️ Breaking Changes
- **`[[sharedApps]]` config key:** `[[floatingApps]]` is now `[[sharedApps]]`. Configs migrate automatically on first launch: each floating entry becomes a shared app with `floating = true`. Shared apps are part of *every* workspace, tiled into each layout by default, or floating everywhere. Manage them in **Workspaces → Shared Apps**. Dotfiles that template the config should switch to the new key.
- **Screen Recording permission for floating windows:** Floating windows now need the Screen Recording permission. They stay above the tiles via ScreenCaptureKit mirrors, and without the grant they will not stay on top. Grant it in **Settings → General → Permissions**, then relaunch.

### New
- **SIP-safe floating windows above tiles:** Mark any app as floating per workspace (the Float toggle next to Auto-open, or the `toggleFloating` hotkey): its windows stay untiled and are kept on top by mirroring them onto Tatami-owned ScreenCaptureKit panels. Reach for a floating window and the real one is handed back to you. While a floating app has focus, the mirrors (and the screen-recording indicator) get out of the way. Multiple floating windows stack by focus recency.
- **Shared Apps editor:** Add or remove shared apps and flip their Float toggle from a special workspace in the Workspaces sidebar.
- **System Settings-style sidebar:** A System Settings-style sidebar (General, Tiling, Focus & Mouse, Workspaces, Shortcuts, Appearance) now includes a Screen Recording row under Permissions.
- **Shared app hotkeys:** `toggleSharedFloating` floats the focused app everywhere, joining Shared Apps as floating if needed and changing it to shared tiled when toggled off. `toggleAppInSharedApps` adds or removes the focused app in Shared Apps.
- **Per-action HUD:** Floating changes, app membership, tiling pause, fullscreen zoom, and balance now show a brief overlay, each individually toggleable in **Settings → Appearance → Overlay** (plus the master switch and a configurable duration). Un-floating an app that stays in its workspace / Shared Apps shows a follow-up hint with the shortcut that removes it entirely.
- **Post-update What's New window:** A one-time window summarizes setup-affecting changes (with a Screen Recording grant button when needed) and feature highlights. The full changelog is also viewable from **About → View Changelog**.
- **Visible Screen Recording prompts:** Missing Screen Recording no longer fails silently. The first activation that needs floating mirrors shows the system prompt and a warning HUD pointing at the Settings row.
- **Auto-open on workspace re-entry:** Auto-open apps reopen on workspace re-entry when their window was closed, not just on first activation.
- **Floating support for fixed-size windows:** Fixed-size windows (e.g. the iOS **Simulator**) can float. Resizability is only required for tiling.
- **Persistent floating-window markers:** Floating windows' marker dots are always visible (not just on the focused window), and dots follow window drags with a smooth glide.

### Fixes
- **Reliable HUD fade-out:** The panel's window-alpha animation only ran reliably once per launch, so overlays sometimes vanished instantly instead of fading out. The fade now runs on the content view.

## 1.2.1 (2026-06-02)

### Fixes
- **Hide-on-close window detection:** Electron apps like Discord hide their window on close (no Accessibility destroy event), which left a phantom tile slot. Tatami now prunes a tiled window once it leaves the screen and re-tiles the survivors.

## 1.2.0 (2026-06-02)

### New
- **Refocus after window closure:** When the focused window closes and focus would otherwise be stranded on a now-windowless app (e.g. KakaoTalk, Notion Calendar, which keep running with no window), focus moves to a remaining window in the workspace. Toggle in **Settings → Mouse & Focus**.
- **Full-screen exclusion from focus-follows-mouse:** An option (on by default) keeps focus-follows-mouse from grabbing a window that fills the whole display as the cursor skims across it.

## 1.1.0 (2026-06-02)

### New
- **Per-display multi-monitor workspaces:** Each display tracks its own active and recent workspaces. Activation, "recent workspace", and next/previous cycling all act on the display under the cursor, and new workspaces start pinned to the current display.
  - **Focus next / previous display:** move focus to the active workspace on the next monitor, looping around (`focusNextDisplay` / `focusPreviousDisplay`).
  - **Cycle across all displays:** option to make next/previous workspace span every display's workspaces instead of only the one under the cursor (`settings.switching.cycleAcrossDisplays`).
  - Displays are identified by a stable UUID (with a name fallback), so reconnecting the same monitor keeps its assignments. Everything falls back to the primary display when a monitor is absent.
  - Per-display dot colors in the sidebar show which monitor each workspace is active on.
- **Adjacent-workspace app moves:** Relocate the focused app one workspace over and follow it there (`moveToNextWorkspace` / `moveToPreviousWorkspace`).
- **Focused-app workspace assignment:** A per-workspace shortcut adds the focused app (keeping its other memberships) and switches there.
- **Activation focus selection:** Choose which assigned app gets focus when a workspace activates (defaults to most-recently-used).
- **Bundled CLI installer:** Install or uninstall the `tatami` CLI from **Settings → Command Line** (Homebrew installs are detected). Accessibility permission status and a one-click grant now live in **Settings → Permissions**.
- **In-app shortcut and display guidance:** In-app descriptions explain the non-obvious shortcuts, and a Pinned-vs-Dynamic explainer appears in a workspace's Display section.

### Fixes
- **Full-screen gap focus protection:** Focus-follows-mouse no longer grabs a full-screen window showing through the gaps between tiled windows.
- **Immediate Assign hotkey registration:** Hot keys re-register immediately after recording a workspace's **Assign** shortcut (previously needed a relaunch).
- **Distinct fullscreen-zoom restoration:** Persistent layouts restore each fullscreen-zoomed window of the *same* app to a distinct window instead of collapsing them onto one.
- **Multi-process app window discovery:** Apps that run one process per window under a shared bundle id (e.g. **Neovide**) now tile. Window discovery scans every process, not just the first.
- **App metadata retention during workspace moves:** Moving an app to another workspace keeps its name, icon, and auto-open setting instead of relabeling it with the bundle id.
- **Complete Display picker:** The workspace **Display picker** now lists every connected display when switching between workspaces.
- **Accurate CLI version reporting:** `tatami version` reports the running app's real version.

## 1.0.0 (2026-05-29)

The first stable release. Here's what changed since v0.1.3.

### New
- **Drag-to-rearrange preview:** Drag a window and a live overlay previews the drop: the center **swaps** the two windows, while an edge **inserts** the dragged one on that side (left / right / top / bottom).
- **Window markers:** A small corner dot marks zoomed / floating windows. Configure its color, size, corner, and hover-fade.
- **Multi-window zoom and layout memory:** Multi-window zoom is supported alongside per-workspace **layout memory** (`session` / `persistent`).
- **New shortcuts:** Balance the tree or toggle the focused app's workspace membership, plus a toolbar **Activate** button.
- **Optional debug logging:** Debug logging to `~/.config/tatami/tatami.log` helps diagnose tiling.

### Improvements
- **Manual resizing:** Manual resize now drags any window edge and re-tiles against the correct join. Height resizes work even when the immediate split is vertical. A drag that changes nothing snaps the window back to its tile.
- **Mouse-up move and resize commits:** Manual move / resize commits on **mouse-up** (not a timer), so dragging stays smooth and never fights you mid-drag.
- **Event-driven marker tracking:** Window markers track their windows **event-driven** (no polling timer), with ~zero idle CPU.
- **Reworked concurrency:** AX window hit-testing, the CLI socket server, and the mouse / gesture event taps no longer block the main thread or the Swift cooperative pool.
- **Faster focus and tiling response:** Focus-follows-mouse and tiling-debounce timings are snappier.
- **Overhauled BSP operations:** BSP insert / swap / warp / balance semantics have been overhauled.

### Fixes
- **Working tiling hotkeys:** `grow` / `shrink` / `balance` now work in common layouts.
- **Stable Settings steppers:** Gap and dot-size steppers no longer run away on a single click.
- **Shortcut parsing and horizontal resizing fixes:** Shortcut strings now parse `-` (minus), and horizontal splits resize correctly.

### Removed / config change
- **Removal of `fresh` tiling memory:** The `fresh` tiling-memory mode has been dropped. It rebuilt layouts from a focus-dependent order and reshuffled them on every workspace switch. Workspaces now use `session` (default) or `persistent`. Existing configs set to `"fresh"` fall back to `session`.

## 0.1.3 (2026-05-28)

### Changed
- **Tiling-only pause:** Toggling pause from the menu bar (or the `toggleSpaceActivated` hotkey) used to block workspace switching too. It now suspends only the BSP tile pass while workspace switches, show/hide, and focus keep working. The pause flag is also no longer persisted to config. It is runtime-only, and every launch starts unpaused.

## 0.1.2 (2026-05-28)

### Added
- **Launch at Login:** Tatami can start automatically when you log in. Toggle in **Settings → General → Launch at login**.
- **Sparkle release notes:** the in-app update dialog links to each release's notes page starting with this version.

## 0.1.1 (2026-05-28)

### Added
- **End-to-end software updates:** Sparkle is fully wired up. Tatami checks for and installs updates in the background. Pick the frequency (hourly / daily / weekly) or check manually from Settings or the menu bar.
- **About tab:** version, creator, and open-source credits (FlashSpace, yabai, and the libraries Tatami is built with).

### Changed
- **Internal architecture cleanup:** Settings now use Perception's observation, dependency clients adopt `@DependencyClient`, and an unused `autoFocusBlacklist` setting was removed.

## 0.1.0 (2026-05-27)

First public release. A macOS workspace manager with yabai-style window tiling.
Group your apps into virtual workspaces, switch with a keystroke or trackpad
swipe, and tile their windows automatically. No SIP changes, no shell scripting.

### Tiling (yabai-style BSP)
- **Automatic BSP tiling:** Windows use automatic binary space partitioning with a dwindle (spiral) layout.
- **Directional window controls:** Focus, swap, and resize windows with vim-like `h` `j` `k` `l` controls.
- **Workspace-filling zoom and split controls:** Zoom a window to fill the workspace and toggle split orientation.
- **Advanced layout operations:** Rotate, mirror, balance, drag-to-swap, and synchronize live resizes.
- **Configurable gaps:** Configure inner and outer gaps.

### Workspaces
- **Workspace app assignments:** Assign apps per workspace and switch by hotkey, swipe, or "recent".
- **Flexible workspace cycling:** Use loop-around, skip-empty, and follow-app-focus options.
- **Automatic app launching:** Auto-open assigned apps on activation.
- **Multi-display placement:** Pin a workspace to a display or follow apps dynamically.
- **Untiled floating apps:** Floating apps never tile.

### Focus & interface
- **Mouse-driven focus controls:** Use focus-follows-mouse, mouse-follows-focus, and optional cursor hiding.
- **Active-workspace menu bar item:** Show the active workspace with its icon and name in the menu bar.
- **Workspace switch HUD:** Show an on-screen HUD when switching, with per-workspace SF Symbol icons.
- **Configuration and automation:** Use skhd-style shortcut syntax, a plain-TOML config, and a scripting CLI.
