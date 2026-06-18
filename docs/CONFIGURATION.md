# Configuration

Tatami reads its configuration from:

```
~/.config/tatami/config.toml
```

The path is XDG-aware — if `$XDG_CONFIG_HOME` is set, the file lives at
`$XDG_CONFIG_HOME/tatami/config.toml`. The file is created on first launch and
written back whenever you change something in the app. Hand edits are picked up
live, so you can keep it in your dotfiles and edit it in your editor.

The file has three top-level parts:

- `[settings.*]` — global preferences (below)
- `[[sharedApps]]` — apps that are part of every workspace (tiled or floating)
- `[[profiles]]` — workspaces and their app assignments

## Shortcut syntax

Shortcuts use an skhd-style string: zero or more modifiers joined by `+`, then
` - `, then the key.

```
ctrl + alt - h
alt + shift - tab
ctrl + alt + shift + cmd - z
```

Modifiers: `ctrl`, `alt` (option), `shift`, `cmd`. Keys are letters, digits,
`tab`, `return`, arrow keys (`left`/`right`/`up`/`down`), punctuation, etc.

## `[settings.general]`

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `launchAtLogin` | bool | `false` | Register Tatami as a login item so it starts at login. |
| `checkForUpdatesAutomatically` | bool | `true` | Periodically check for new releases. |
| `checkInterval` | string | `"daily"` | Background update-check frequency: `hourly`, `daily`, or `weekly`. |
| `debugLogging` | bool | `false` | Append diagnostic events to `~/.config/tatami/tatami.log`. Truncated when first enabled. |

## `[settings.menuBar]`

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `showWorkspaceName` | bool | `true` | Show the active workspace's name next to its icon in the menu bar. |

## `[settings.hud]`

A brief on-screen overlay confirming actions. `enabled` is the master switch;
the rest pick which actions show one.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | bool | `true` | Master switch for every overlay. |
| `workspaceSwitch` | bool | `true` | Workspace name when switching. |
| `floating` | bool | `true` | Float state changes — per-workspace and shared. |
| `appMembership` | bool | `true` | App added to / removed from a workspace or Shared Apps. |
| `tilingPaused` | bool | `true` | Tiling paused / resumed. |
| `fullscreen` | bool | `true` | Fullscreen zoom entered / exited. |
| `layout` | bool | `true` | Layout commands without a visual cue of their own (balance). |
| `durationMs` | int | `900` | How long the overlay stays up, in milliseconds. HUDs carrying a follow-up hint stay twice as long. |

## `[settings.layout]`

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `gapInner` | int | `8` | Pixels between adjacent tiled windows. |
| `gapOuter` | int | `8` | Pixels between the tiles and the screen edge. |
| `autoBalance` | string | `"none"` | Re-equalize splits after every insert/remove. One of `none`, `horizontal`, `vertical`, `both`. (Legacy bool values still decode: `true` → `both`, `false` → `none`.) |
| `splitType` | string | `"auto"` | Default split axis when a new window splits a tile: `auto` (aspect-based), `horizontal`, `vertical`. |
| `windowPlacement` | string | `"second"` | Which child of the new split holds the inserted window: `first` (top/left) or `second` (bottom/right). |
| `defaultTilingMemory` | string | `"session"` | How workspaces remember their layout: `session` or `persistent`. A workspace can override this. |

`defaultTilingMemory` values:

- `session` — keep the layout (split axes + ratios) while the app runs; reset on restart
- `persistent` — remember the layout across app restarts (saved to disk)

## `[settings.focus]`

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `mouseFollowsFocus` | bool | `false` | Warp the cursor to the focused window's tiled position. |
| `mouseHidesOnFocus` | bool | `false` | Hide the cursor on a workspace switch until the mouse moves. |
| `focusFollowsMouse` | bool | `false` | Focus whatever window sits under the cursor as it moves. |
| `refocusOnClose` | bool | `true` | When the focused window closes and focus would be stranded on a now-windowless app, move focus to a remaining window in the workspace. |
| `focusFollowsMouseIgnoreFullscreen` | bool | `true` | While focus-follows-mouse is on, don't shift focus to a window that fills the whole display (full-screen / maximized). |
| `focusFollowsMouseDisableHotkey` | string | `"Alt"` | Modifier that temporarily suspends focus-follows-mouse: `None`, `Alt`, `Cmd`, `Ctrl`, `Shift`. |

## `[settings.switching]`

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `loop` | bool | `true` | Wrap from the last workspace back to the first (and vice versa). |
| `skipEmpty` | bool | `false` | Skip workspaces with no running app when cycling next/previous. |
| `followAppFocus` | bool | `false` | Activating an app switches to the workspace that owns it. |
| `cycleAcrossDisplays` | bool | `false` | Cycle next/previous workspace across every display's workspaces instead of only the display under the cursor. |
| `switchToRecentWhenEmpty` | bool | `false` | When the active workspace's last window closes (nothing tiled, no workspace-specific floating window), switch to the recent workspace. Shared apps don't count — they join every workspace anyway. |
| `cycleSameAppWindows` | bool | `false` | Next/previous-window cycling granularity. `false` (default) steps app-by-app (one representative window per app); `true` visits every window, including multiple windows of the same app. |

## `[settings.gestures]`

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | bool | `false` | Switch workspaces with a horizontal trackpad swipe. |
| `fingerCount` | int | `3` | Number of fingers for the swipe (`3` or `4`). |
| `threshold` | double | `0.3` | Swipe distance required to trigger a switch (lower = more sensitive). Kept to two decimal places. |

## `[settings.marker]`

Small corner dots that identify zoomed and floating windows.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `fullscreenEnabled` | bool | `true` | Dot on the workspace's fullscreen-zoomed window (shown while it's focused). |
| `fullscreenColorHex` | string | `"#007AFF"` | Fullscreen dot color (`#RRGGBB`). |
| `floatingEnabled` | bool | `true` | Dot on floating windows — always visible, so a mirror reads as floating at a glance. |
| `floatingColorHex` | string | `"#FF9500"` | Floating dot color (`#RRGGBB`). |
| `size` | double | `14` | Dot diameter in points. |
| `corner` | string | `"bottomTrailing"` | Window corner the dot anchors to: `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`. |
| `hideOnHover` | bool | `true` | Fade the dot while the cursor is over it. |

## `[settings.shortcuts]`

All values are skhd-style shortcut strings (see above). Omit a key to leave that
action unbound.

| Key | Action |
| --- | --- |
| `focusLeft` / `focusRight` / `focusUp` / `focusDown` | Move focus to the tile in that direction |
| `swapLeft` / `swapRight` / `swapUp` / `swapDown` | Swap the focused tile in that direction |
| `resizeGrow` / `resizeShrink` | Resize the focused tile |
| `toggleOrientation` | Toggle the focused split's orientation |
| `toggleFullscreen` | Zoom the focused window to fill the workspace |
| `balance` | Re-equalize every split so siblings share their space evenly |
| `cycleNextWindow` / `cyclePreviousWindow` | Cycle focus across the workspace's windows |
| `switchToNextWorkspace` / `switchToPreviousWorkspace` | Cycle workspaces |
| `switchToRecentWorkspace` | Jump to the previously active workspace |
| `moveToNextWorkspace` / `moveToPreviousWorkspace` | Move the focused app to the next/previous workspace and follow it there |
| `focusNextDisplay` / `focusPreviousDisplay` | Focus the active workspace on the next/previous display (loops around) |
| `toggleFloating` | Float the focused app in the active workspace (added here as floating if it wasn't assigned) — toggle again to re-tile |
| `toggleSharedFloating` | Float the focused app everywhere — joins Shared Apps as floating if it isn't shared yet; toggling off flips it to shared *tiled* (membership stays; removing is `toggleAppInSharedApps`) |
| `toggleFocusedAppInActiveWorkspace` | Add the focused window's app to the active workspace (or remove it if already a member) |
| `toggleAppInSharedApps` | Add the focused app to Shared Apps (tiled into every workspace), or remove it if already shared |
| `toggleSpaceActivated` | Pause/resume tiling |

## `[[sharedApps]]`

Apps listed here are part of **every** workspace. Each carries a `layout`:
`tiled` (the default — tiles into each workspace's layout), `floating` (untiled,
kept **above the tiles everywhere** via a mirror), or `unmanaged` (left exactly
where it is — still a member, but never tiled or mirrored).

```toml
[[sharedApps]]
bundleIdentifier = "com.apple.iphonesimulator"
name = "Simulator"
layout = "floating"      # untiled, always on top, drifts across workspaces

[[sharedApps]]
bundleIdentifier = "com.apple.Music"
name = "Music"
layout = "tiled"         # tiled into every workspace's layout (default)

[[sharedApps]]
bundleIdentifier = "com.colliderli.iina"
name = "IINA"
layout = "unmanaged"     # left alone — a member, but never tiled or mirrored
```

Floating windows are kept on top without disabling SIP: Tatami mirrors them
onto its own always-on-top panels via ScreenCaptureKit, which needs the
**Screen Recording** permission (Settings → General → Permissions). The mirror
hides — and the capture stops — whenever the floating app itself has focus.
`unmanaged` apps need no such permission — the real window is never touched.

Editable in the app under **Workspaces → Shared Apps** (Tiled / Float / Ignore).

Legacy configs with `[[floatingApps]]` migrate automatically on first load:
each entry becomes a shared app with `layout = "floating"`. A pre-1.4 `floating`
bool on any app or shared app also migrates (`true` → `floating`, else `tiled`).

## `[[profiles]]` and workspaces

A profile holds a set of workspaces. Each workspace assigns apps and optional
per-workspace overrides.

```toml
[[profiles]]
id = "00000000-0000-0000-0000-000000000001"
name = "Default"

[[profiles.workspaces]]
id = "00000000-0000-0000-0000-000000000010"
name = "Browser"
symbolIconName = "safari.fill"        # any SF Symbol name
activateShortcut = "ctrl + alt + shift - b"
assignAppShortcut = "alt + shift + cmd - b"
tilingMemory = "session"               # optional: overrides defaultTilingMemory
displayHint = "Built-in Retina Display"           # optional: pin to a display ("<uuid>::<name>" or "<name>")
appToFocusBundleId = "app.zen-browser.zen"        # optional: focus this app on activation

[[profiles.workspaces.apps]]
bundleIdentifier = "app.zen-browser.zen"
name = "Zen Browser"
autoOpen = false                       # launch on activation if not running
layout = "tiled"                       # "tiled" | "floating" | "unmanaged"
```

Workspace fields:

| Key | Type | Description |
| --- | --- | --- |
| `id` | UUID | Stable identifier. |
| `name` | string | Display name. |
| `symbolIconName` | string? | SF Symbol used in the menu bar / sidebar. |
| `activateShortcut` | string? | Shortcut to activate this workspace. |
| `assignAppShortcut` | string? | Shortcut to add the focused app to this workspace (keeping its other memberships) and switch here. |
| `appToFocusBundleId` | string? | Bundle ID of the assigned app to focus on activation; omit for most-recently-used. |
| `tilingMemory` | string? | `session` / `persistent`; omit to use the global default. |
| `displayHint` | string? | Pin the workspace to a display — `"<uuid>::<name>"` or just `"<name>"`. Omit to follow apps dynamically. Falls back to the primary display when the pinned monitor is absent. |

App assignment fields:

| Key | Type | Description |
| --- | --- | --- |
| `bundleIdentifier` | string | The app's bundle ID. |
| `name` | string | Display name. |
| `autoOpen` | bool | Launch the app when the workspace activates — and reopen it on re-entry if its window was closed. |
| `layout` | string | `tiled` (BSP layout), `floating` (untiled, mirrored above the tiles — see `[[sharedApps]]`), or `unmanaged` (left where it is; still a member, no tiling/mirror/Screen Recording). Migrated from the pre-1.4 `floating` bool. |
