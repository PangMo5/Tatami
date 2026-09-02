# Configuration

Tatami reads its configuration from:

```
~/.config/tatami/config.toml
```

The path is XDG-aware. If `$XDG_CONFIG_HOME` is set, the file lives at
`$XDG_CONFIG_HOME/tatami/config.toml`. The file is created on first launch and
written back whenever you change something in the app. Hand edits are picked up
live, so you can keep it in your dotfiles and edit it in your editor.

External writers must either participate in `NSFileCoordinator` or write a
temporary file and atomically replace `config.toml`. Tatami detects and rejects
an atomic replacement that races one of its own configuration transactions.
In-place writers that keep the live file descriptor open across a rename (for
example, opening `config.toml`, then continuing to truncate or write that same
descriptor while another process replaces the path) are not supported: POSIX
rename cannot redirect future writes on an already-open descriptor to the new
file. Editors that save through a temporary file and atomic replace satisfy the
supported contract.

Prefer a guided start? Tatami's first launch opens **Guided Setup**, which
builds a draft from app metadata and connected displays and teaches each major
feature in a safe virtual display. It writes this file only when you choose
**Apply Setup**. Run it again from **Settings → General → Run Guided Setup**.

The file has four top-level parts:

- **`[settings.*]`:** Global preferences described below
- **`[[sharedApps]]`:** Apps that are part of every workspace, either tiled or kept on top
- **`[[profiles]]`:** Workspaces and their app assignments
- **`[[hooks]]`:** Programs triggered by Tatami, profile, and workspace lifecycle events

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

## `[settings.visibility]`

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `overlayAwareApps` | string[] | `[]` | Bundle IDs of apps that own persistent elevated controls. When a registered process has an on-screen top-level AX window on a nonzero WindowServer layer, Tatami leaves the process unhidden but excludes its ordinary windows from focus, cycling, layout, drag, and membership actions. The windows can still appear in Mission Control. |

This is an explicit per-app exception, not a blanket floating-window rule. A
registered app follows normal hide behavior whenever no matching elevated
top-level window is present. Tatami re-evaluates it during each workspace or
Borrow visibility transaction.

```toml
[settings.visibility]
overlayAwareApps = ["notion.id"]
```

For symptoms, app examples, and the Settings UI workflow, see
[Troubleshooting](TROUBLESHOOTING.md#a-floating-control-disappears-or-brings-its-app-back).

## `[settings.menuBar]`

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `showWorkspaceIcon` | bool | `true` | Show the active workspace's icon in the menu bar. |
| `showWorkspaceName` | bool | `true` | Show the active workspace's name in the menu bar. |
| `showProfileIcon` | bool | `true` | Show the active profile's icon (only when more than one profile exists). |
| `showProfileName` | bool | `false` | Show the active profile's name (only when more than one profile exists). |

## `[settings.hud]`

Brief on-screen feedback confirming actions. The configuration table keeps its
historical `hud` name for compatibility; the app calls this **On-Screen
Feedback**. `enabled` is the master switch, and the remaining keys choose which
actions show feedback.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | bool | `true` | Master switch for all on-screen feedback. |
| `workspaceSwitch` | bool | `true` | Workspace name when switching. |
| `windowCycle` | bool | `true` | Compact app/window switcher while holding the window-switch shortcut modifier. Continue with the shortcut or arrow keys; commit with Return, modifier release, or a click; cancel with Escape. A quick press does not show it. |
| `profileSwitch` | bool | `true` | Profile name when switching profiles (manual or auto). |
| `floating` | bool | `true` | Always-on-top state changes for both workspace apps and Shared Apps. The key name is retained for compatibility. |
| `appMembership` | bool | `true` | App added to / removed from a workspace or Shared Apps. |
| `tilingPaused` | bool | `true` | Tiling paused / resumed. |
| `fullscreen` | bool | `true` | Fullscreen zoom entered / exited. |
| `borrow` | bool | `true` | Borrow or return a workspace, plus the direction-pick hint. |
| `layout` | bool | `true` | Layout commands without a visual cue of their own (balance). |
| `durationMs` | int | `900` | How long feedback stays visible, in milliseconds. Feedback with a follow-up hint stays twice as long. |

## `[settings.layout]`

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `gapInner` | int | `8` | Pixels between adjacent tiled windows. |
| `gapOuter` | int | `8` | Pixels between the tiles and the screen edge. |
| `autoBalance` | string | `"none"` | Re-equalize splits after every insert/remove. One of `none`, `horizontal`, `vertical`, `both`. (Legacy bool values still decode: `true` → `both`, `false` → `none`.) |
| `splitType` | string | `"auto"` | Default split axis when a new window splits a tile: `auto` (aspect-based), `horizontal`, `vertical`. |
| `windowPlacement` | string | `"second"` | Which child of the new split holds the inserted window: `first` (top/left) or `second` (bottom/right). |

Workspaces always remember their layout. Split axes and ratios are persisted
to disk and restored on the next launch. System sleep preserves the live tree;
if macOS recreates a window surface on wake, Tatami reconnects it to the saved
layout without writing the temporary wake-up state back to disk.

## `[settings.focus]`

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `mouseFollowsFocus` | bool | `false` | Move the cursor to the window Tatami focuses. Directional focus, app/window switching, workspace changes, close refocus, Swap, toggling a split's orientation, and fullscreen zoom in either direction carry it to the new position. Always on Top and Leave As Is targets use their live window frame. When the switch came from activating an app outside Tatami, such as from the Dock or Spotlight, the cursor goes to the window the system actually raised rather than the workspace's most recently used one. The pointer is left alone whenever the pointer itself caused the change: clicking a window, releasing a drag, a drag that swaps or splits, and a drag that snaps back. Grow/shrink and Balance stay out too, so holding a key down does not re-center on every repeat. |
| `mouseHidesOnFocus` | bool | `false` | Hide the cursor on a workspace switch until the mouse moves. |
| `focusFollowsMouse` | bool | `false` | Focus whatever window sits under the cursor as it moves. |
| `refocusOnClose` | bool | `true` | When the focused window closes and focus would be stranded on a now-windowless app, move focus to the most recently used remaining window in the workspace (falling back through recency). |
| `focusFollowsMouseIgnoreFullscreen` | bool | `true` | While focus-follows-mouse is on, don't shift focus to a window that fills the whole display (full-screen / maximized). |
| `focusFollowsMouseDisableHotkey` | string | `"Alt"` | Modifier that temporarily suspends focus-follows-mouse: `None`, `Alt`, `Cmd`, `Ctrl`, `Shift`. |

## `[settings.switching]`

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `loop` | bool | `true` | Wrap from the last workspace back to the first (and vice versa). |
| `skipEmpty` | bool | `false` | Skip workspaces with no running app when switching next/previous. |
| `followAppFocus` | bool | `true` | Activating an app switches to the workspace that owns it. |
| `cycleAcrossDisplays` | bool | `false` | Switch next/previous workspace across every display instead of only the display under the cursor. The key name is retained for compatibility. |
| `recentAcrossDisplays` | bool | `true` | Use one global recent-workspace history across every display. If the target is already visible on another display, focus it there instead of moving it. Set it to `false` for a strict per-display history. |
| `switchToRecentWhenEmpty` | bool | `false` | When the active workspace's last window closes with nothing tiled and no workspace-specific always-on-top window, switch to the recent workspace. Shared apps do not count because they join every workspace. |
| `cycleSameAppWindows` | bool | `false` | Next/previous-window switching granularity. `false` (default) switches app-by-app and recalls each app's most-recent window. `true` visits every window, including multiple windows of the same app. The active workspace's Tiled, Always on Top, and Leave As Is windows participate; while Borrow is active, the host and borrowed tiled blocks form one switching order. The key name is retained for compatibility. |
| `includeSharedAppsInWindowSwitcher` | bool | `true` | Include Shared Apps in the app/window switcher. During Borrow, shared non-tiled windows join the host and borrowed tiled blocks; `false` excludes every Shared App from switching everywhere. |
| `toggleBorrowOnRepeat` | bool | `true` | Borrowing a workspace already beside the current one returns it and restores the host. `false` moves the borrowed workspace instead. |
| `borrowDefaultEdge` | string? | _(unset)_ | Where a borrow docks by default: `top`, `bottom`, `left`, `right`. Unset → the borrow combo waits for a direction key (h/j/k/l or arrows). A workspace's `borrowEdge` overrides this. |
| `borrowFraction` | double | `0.4` | The borrowed block's share of the screen along the split axis (0.1…0.9). A workspace's `borrowFraction` overrides this. |

## `[settings.gestures]`

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | bool | `false` | Recognize configured three- and four-finger trackpad swipes. |
| `threshold` | double | `0.3` | Swipe distance required before the bound action runs (lower = more sensitive). Kept to two decimal places. |
| `threeFinger` | table | left → `nextWorkspace`, right → `previousWorkspace` | Actions for three-finger `left`, `right`, `up`, and `down` swipes. Missing directions are `none`. |
| `fourFinger` | table | all directions → `none` | Actions for four-finger `left`, `right`, `up`, and `down` swipes. |

Each direction stores one action string. The app's nested action menu is the
easiest way to configure profile/workspace actions because it writes their
stable UUIDs for you.

```toml
[settings.gestures]
enabled = true
threshold = 0.3

[settings.gestures.threeFinger]
left = "nextWorkspace"
right = "previousWorkspace"
up = "toggleFullscreen"
down = "none"

[settings.gestures.fourFinger]
left = "focusPreviousDisplay"
right = "focusNextDisplay"
up = "activateProfile:00000000-0000-0000-0000-000000000001"
down = "activateWorkspace:00000000-0000-0000-0000-000000000010"
```

Available fixed action strings:

- **Workspaces:** `nextWorkspace`, `previousWorkspace`, `recentWorkspace`, `moveAppToNextWorkspace`, `moveAppToPreviousWorkspace`, `assignAppToRecentWorkspace`, `assignAppToNextWorkspace`, `assignAppToPreviousWorkspace`
- **Focus and displays:** `focusNextDisplay`, `focusPreviousDisplay`, `focusLeft`, `focusRight`, `focusUp`, `focusDown`
- **Window switching:** `cycleNextWindow`, `cyclePreviousWindow`
- **Layout:** `growWindow`, `shrinkWindow`, `swapLeft`, `swapRight`, `swapUp`, `swapDown`, `toggleOrientation`, `toggleFullscreen`, `balanceLayout`
- **Apps and tiling:** `toggleFloating`, `toggleSharedFloating`, `toggleTiling`, `toggleAppInWorkspace`, `toggleAppInSharedApps` (`floating` remains the stable configuration identifier for **Always on Top**)
- **Borrow:** `borrowRecentWorkspace`, `borrowNextWorkspace`, `borrowPreviousWorkspace`, `dismissBorrow`
- **Unbound:** `none`

Target-specific actions append a stable identifier:
`activateWorkspace:<workspace UUID>`, `assignAppToWorkspace:<workspace UUID>`,
`borrowWorkspace:<workspace UUID>`, or `activateProfile:<profile UUID>`.
Borrowing a specific workspace is available while its profile is active;
activating or assigning to a workspace can switch to its owning profile first.

Legacy configurations with `fingerCount = 3` or `4` migrate automatically:
left/right keep their previous next/previous-workspace behavior on that finger
count, and the other directions and finger count remain unbound.

## `[settings.marker]`

Small corner dots that identify zoomed, always-on-top, and borrowed windows.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `fullscreenEnabled` | bool | `true` | Dot on the workspace's fullscreen-zoomed window (shown while it's focused). |
| `fullscreenColorHex` | string | `"#007AFF"` | Fullscreen dot color (`#RRGGBB`). |
| `floatingEnabled` | bool | `true` | Dot on always-on-top windows, always visible so their state is clear at a glance. |
| `floatingColorHex` | string | `"#FF9500"` | Always-on-top dot color (`#RRGGBB`). |
| `borrowEnabled` | bool | `true` | Badge each borrowed window with its workspace icon while the borrow is on screen. |
| `borrowColorHex` | string | `"#AF52DE"` | Borrow badge color (`#RRGGBB`). |
| `size` | double | `14` | Dot diameter in points. The borrow badge is drawn larger so its glyph stays legible. |
| `corner` | string | `"bottomTrailing"` | Window corner the dot anchors to: `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`. |
| `hideOnHover` | bool | `true` | Fade the dot while the cursor is over it. |

## `[settings.shortcuts]`

Most values are skhd-style shortcut strings (see above). Omitting a key leaves
that action unbound. A brand-new config (no `config.toml` yet) is seeded with a
recommended starter set. See [Recommended defaults](#recommended-defaults).
You can freely re-record or clear every shortcut. The exceptions are the three
`*Modifiers` arrays below, which drive the per-workspace **key equivalent** model.

### Workspace keys (switch / assign / borrow)

Instead of binding three separate shortcuts per workspace, give each workspace a
single one-character **key equivalent** (`keyEquivalent` on the workspace) and
hold it with one of three global modifier combos to choose the action:

| Key | Type | Default | Action |
| --- | --- | --- | --- |
| `keyEquivalentModifiers` | string[] | `["ctrl", "alt"]` | + a workspace's key → **switch** to it |
| `assignModifiers` | string[] | `["ctrl", "alt", "shift"]` | + a workspace's key → **assign** the focused app to it and switch there |
| `borrowModifiers` | string[] | `["ctrl", "alt", "cmd"]` | + a workspace's key → **borrow** it into the current screen |

Modifier tokens are `ctrl`, `alt`, `shift`, `cmd`. An empty array disables that
action's key-equivalent combo (so a bare key can't hijack typing).

The **Default** column above is the fallback used when the key is missing from
an *existing* config. A fresh install instead seeds the recommended combos
`keyEquivalentModifiers = ["ctrl", "alt", "shift"]` and
`assignModifiers = ["alt", "shift", "cmd"]` (see [Recommended defaults](#recommended-defaults)).

The same three modifiers also drive the **recent / next / previous** navigation
targets, each with its own key:

| Key | Type | Description |
| --- | --- | --- |
| `recentWorkspaceKey` | string? | Key for the recent workspace (held with the switch / assign / borrow modifier). |
| `nextWorkspaceKey` | string? | Key for the next workspace. |
| `previousWorkspaceKey` | string? | Key for the previous workspace. |

Any action above can be given an **explicit override** shortcut, which wins over
the modifier + key combo:

- Per workspace: `activateShortcut`, `assignAppShortcut`, `borrowShortcut` (see workspaces below).
- **Per navigation target:** `switchTo{Recent,Next,Previous}Workspace`, `assign{Recent,Next,Previous}Workspace`, and `borrow{Recent,Next,Previous}Workspace`. All use skhd strings.

Workspace key equivalents and explicit workspace shortcuts are active only in
their profile, so different profiles may reuse the same keys. Global shortcuts
remain global and are checked against every profile. Copy and Duplicate also
validate the selected shortcut changes before saving them into the target
profile.

Borrowing waits for a direction key (h/j/k/l or arrows) to place the workspace,
unless a default edge is set (`settings.switching.borrowDefaultEdge` or the
workspace's `borrowEdge`). `dismissBorrow` returns a borrowed workspace and
restores the host to full screen.

### Action shortcuts

| Key | Action |
| --- | --- |
| `focusLeft` / `focusRight` / `focusUp` / `focusDown` | Move focus to the tile in that direction (crosses into a borrowed block at the edge) |
| `swapLeft` / `swapRight` / `swapUp` / `swapDown` | Swap the focused tile in that direction |
| `resizeGrow` / `resizeShrink` | Resize the focused tile |
| `toggleOrientation` | Toggle the focused split's orientation |
| `toggleFullscreen` | Zoom the focused window to fill the workspace |
| `balance` | Apply the configured `autoBalance` axes. With Auto-balance off, rebuild the canonical BSP topology and ratios from the current window order. |
| `cycleNextWindow` / `cyclePreviousWindow` | Switch apps or windows inside the visible Tatami workspace. Unlike Command-Tab, this excludes unrelated running apps; unlike Command-backtick, it can cross between apps. |
| `moveToNextWorkspace` / `moveToPreviousWorkspace` | Move the focused app to the next/previous workspace and follow it there |
| `dismissBorrow` | Return the borrowed workspace and restore the host to full screen |
| `focusNextDisplay` / `focusPreviousDisplay` | Focus the active workspace on the next/previous display (loops around) |
| `toggleFloating` | Keep the focused app on top in the active workspace, adding it there if needed. Use the action again to return it to Tiled. |
| `toggleSharedFloating` | Keep the focused app on top everywhere, adding it to Shared Apps if needed. Turning it off changes it to shared *Tiled*. Use `toggleAppInSharedApps` to remove membership. |
| `toggleFocusedAppInActiveWorkspace` | Add the focused window's app to the active workspace (or remove it if already a member) |
| `toggleAppInSharedApps` | Add the focused app to Shared Apps (tiled into every workspace), or remove it if already shared |
| `toggleSpaceActivated` | Pause/resume tiling |

### Recommended defaults

A brand-new config (no `config.toml` yet) is seeded with a usable starter
scheme so actions work out of the box. `⌃⌥` drives the window/tile operations.
workspace **switch** moves to `⌃⌥⇧` and **assign** to `⌥⇧⌘`, so a workspace's
one-key equivalent never collides with a `⌃⌥` focus key. Anything here can be
re-recorded or cleared.

| Action | Shortcut |
| --- | --- |
| Focus left / down / up / right | `⌃⌥H` · `⌃⌥J` · `⌃⌥K` · `⌃⌥L` |
| Swap left / down / up / right | `⌃⌥←` · `⌃⌥↓` · `⌃⌥↑` · `⌃⌥→` |
| Grow / shrink | `⌃⌥=` · `⌃⌥-` |
| Toggle orientation | `⌃⌥S` |
| Toggle fullscreen | `⌃⌥⏎` |
| Balance | `⌃⌥E` |
| Switch to next / previous window | `⌥⇥` · `⌥⇧⇥` |
| Toggle Always on Top | `⌥⌘⏎` |
| Toggle Shared Always on Top | `⌥⇧⌘⏎` |
| Toggle tiling (pause) | `⌃⌥⇧⌘Z` |
| Toggle app in workspace | `⌃⌥/` |
| Toggle app in Shared Apps | `⌃⌥⇧/` |
| Move app to previous / next workspace | `⌃⌥⇧[` · `⌃⌥⇧]` |
| Focus previous / next display | `⌃⌥⇧←` · `⌃⌥⇧→` |
| Return Borrowed Workspace | `⌃⌥⌘/` |
| Recent / next / previous workspace key | `\` · `.` · `,` |

Workspace **switch / assign / borrow** combine the modifiers above with each
workspace's key equivalent and with the recent / next / previous keys.

## `[[sharedApps]]`

Apps listed here are part of **every** workspace. Each carries a `layout`:
`tiled` (the default, tiles into each workspace's layout), `floating` (shown as
**Always on Top** in the app; untiled and kept above the tiles everywhere via a
mirror), or `unmanaged` (shown as **Leave As Is**; left exactly where it is
while remaining a member, but never tiled or mirrored). Each also has an
optional `autoOpen` (bool, default `false`) that launches or reopens the app
on workspace activation when it has no on-screen window, and an auto-written
`iconPath` (string, machine-managed and not meant to be set by hand).

```toml
[[sharedApps]]
bundleIdentifier = "com.apple.iphonesimulator"
name = "Simulator"
layout = "floating"      # untiled, always on top, available in every workspace

[[sharedApps]]
bundleIdentifier = "com.apple.Music"
name = "Music"
layout = "tiled"         # tiled into every workspace's layout (default)

[[sharedApps]]
bundleIdentifier = "com.colliderli.iina"
name = "IINA"
layout = "unmanaged"     # left alone as a member, but never tiled or mirrored
```

Always-on-top windows stay above the layout without disabling SIP: Tatami mirrors them
onto its own always-on-top panels via ScreenCaptureKit, which needs the
**Screen Recording** permission (Settings → General → Permissions). The mirror
hides and capture stops whenever the always-on-top app itself has focus.
`unmanaged` apps need no such permission because the real window is never touched.

Editable in the app under **Workspaces → Shared Apps** (Tiled / Always on Top / Leave As Is).

Legacy configs with `[[floatingApps]]` migrate automatically on first load:
each entry becomes a shared app with `layout = "floating"`. A pre-1.4 `floating`
bool on any app or shared app also migrates (`true` → `floating`, else `tiled`).

## `[[hooks]]`

Hooks run a program when Tatami publishes one of these lifecycle events:

- `tatamiLaunched`: published once per Tatami process after startup has
  resolved the active profile. Matching hooks receive that profile;
  `previousProfile`, `workspace`, and `display` are absent. The event is not
  replayed for hooks added later in the same process.
- `profileChanged`: the active profile selection changed. On startup,
  `previousProfile` is absent.
- `workspaceActivated`: a workspace activation published its visible state on
  a display. Failed or timed-out activations do not emit it.

The startup `tatamiLaunched` and `profileChanged` events are separate. Configure
either or both depending on whether the hook needs process startup or profile
lifecycle changes.

Open **Settings → Hooks** to add, edit, delete, enable, or disable hooks. The
editor exposes the executable, each argument, working directory, timeout, and
environment variables as separate fields. It writes the same `[[hooks]]`
entries documented below, so editing `config.toml` by hand remains fully
supported and external changes are still picked up live.

**Run Test** validates and executes the current editor draft once with a sample
event. It does not add or update the hook and does not write `config.toml`;
choose **Save** separately to keep the draft.

```toml
[[hooks]]
id = "notify-context"
event = "workspaceActivated"
enabled = true
command = ["/Users/me/.config/tatami/hooks/notify-context", "--compact"]
timeoutMs = 5000
workingDirectory = "/Users/me"
environment = { MODE = "desktop" }
```

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `id` | string | _(required)_ | Unique diagnostic identifier using ASCII letters, numbers, `.`, `_`, or `-` (up to 64 characters). |
| `event` | string | _(required)_ | `tatamiLaunched`, `profileChanged`, or `workspaceActivated`. |
| `enabled` | bool | `true` | Whether this hook runs. Disabled hooks remain visible to `tatami hook list`. |
| `command` | string[] | _(required)_ | Executable followed by its arguments. Each element is one argv value. |
| `timeoutMs` | int | `5000` | Runtime limit from 100 through 300000 milliseconds. |
| `workingDirectory` | string? | Tatami config directory | Absolute path, or a path beginning with `~/`. |
| `environment` | table | `{}` | Values added to the app's inherited environment. Tatami context values below take precedence. |

Tatami executes `command` directly; it does not invoke a shell, split words,
interpret quotes, or expand variables. The Settings editor preserves the same
contract: the executable is `command[0]`, and every argument row becomes one
subsequent argv value. To use shell syntax, opt in explicitly, for example
`command = ["/bin/zsh", "-lc", "your pipeline"]`. With fish, use the path from
`which fish` and keep the flag and command separate, such as
`command = ["/opt/homebrew/bin/fish", "-c", "command ls"]`. Tatami sends the
event JSON on standard input, so a command that reads standard input receives
that event. An executable containing `/` is treated as a path (with leading
`~/` expanded); a bare name is resolved from the app's inherited `PATH`. An
absolute executable path is the most predictable choice when Tatami was opened
from Finder.

Each hook receives one versioned JSON object on standard input. The object has
`schemaVersion`, `event`, `occurredAt`, `profile`, and, when applicable,
`previousProfile`, `workspace`, and `display`. Tatami also sets these convenience
variables:

- `TATAMI_HOOK_ID`, `TATAMI_HOOK_EVENT`
- `TATAMI_PROFILE_ID`, `TATAMI_PROFILE_NAME`
- `TATAMI_WORKSPACE_ID`, `TATAMI_WORKSPACE_NAME`, `TATAMI_WORKSPACE_KIND`
  for a workspace event
- `TATAMI_DISPLAY_UUID`, `TATAMI_DISPLAY_NAME` when a display is known

Standard output and error are each limited to 64 KiB. A nonzero exit, signal,
spawn error, excessive output, or timeout is reported under Problems and in the
debug log when debug logging is enabled. Hook failures never roll back or block
the profile/workspace change. Hook commands run in an isolated process session.
On timeout or app shutdown, Tatami first sends a graceful termination and then
force-kills remaining descendants, including shell background-job groups. A
hook must not detach itself into a new process session. If a newer event arrives
while the same hook `id` is still running, both published events run
independently; only the newest invocation updates that hook's standing Problem.
Changing, disabling, or removing a hook cancels executions of the old definition
and clears its standing Problem.

## `[[profiles]]` and workspaces

A profile is a named bundle of workspaces. You can define several and switch
between them (a switch re-tiles every display for the new profile), and a
profile can **auto-activate** based on which monitors are connected. Which
profile is currently active, the workspace history for each display, and the
global workspace recency order are session state stored in
`profile-session.json` next to `config.toml`, never written into `config.toml`
itself. On launch, Tatami restores the last manual profile unconditionally. A
profile with display conditions is restored only while those conditions still
match; otherwise the normal auto-activation resolver chooses the best match.

Profiles keep independent workspaces, so their apps and settings can drift
apart. The app can reconcile them without hand-editing: **Copy from…** in a
profile's or workspace's detail shows a reviewable diff of the apps and
settings that differ and copies only the changes you keep checked.

```toml
[[profiles]]
id = "00000000-0000-0000-0000-000000000001"
name = "Default"
symbolIconName = "rectangle.stack"     # optional: SF Symbol (sidebar / menu bar / switch feedback)
shortcut = "ctrl + alt + cmd - 1"      # optional: hotkey to switch to this profile

# Optional: auto-activate this profile when the connected displays match. All
# set conditions apply together (AND). Omit the table for manual switching only.
[profiles.autoActivation]
displayCount = ">=2"                        # "==N" | ">=N" | "<=N"
whenConnectedMatch = "contains"             # "contains" (present) | "exactly" (set ==)
whenConnected = ["37D8832A-…::IP1640"]      # these must be connected
whenDisconnected = ["0E769C72-…::Projector"] # these must be unplugged

[[profiles.workspaces]]
id = "00000000-0000-0000-0000-000000000010"
name = "Browser"
symbolIconName = "safari.fill"        # any SF Symbol name
kind = "normal"                        # "normal" | "scratchpad" (borrow-only)
keyEquivalent = "b"                    # switch/assign/borrow modifier + this key
borrowEdge = "right"                   # optional: dock to this edge when borrowed
displayHint = "Built-in Retina Display"           # optional: pin to a display ("<uuid>::<name>" or "<name>")
appToFocusBundleId = "app.zen-browser.zen"        # optional: focus this app on activation

[[profiles.workspaces.apps]]
bundleIdentifier = "app.zen-browser.zen"
name = "Zen Browser"
autoOpen = false                       # launch on activation if not running
layout = "tiled"                       # "tiled" | "floating" | "unmanaged"
```

Profile fields:

| Key | Type | Description |
| --- | --- | --- |
| `id` | UUID | Stable identifier. |
| `name` | string | Display name. |
| `symbolIconName` | string? | SF Symbol shown for the profile in the sidebar, menu bar, and profile-switch feedback. Omit for the default `rectangle.stack`. |
| `shortcut` | string? | skhd-style hotkey that switches to this profile. |
| `autoActivation` | table? | Auto-activate when the connected displays match (keys below). Omit for manual only. A present table with no conditions is a catch-all that matches any configuration. |

**`[profiles.autoActivation]`:** All keys are optional and combined with AND. When several
profiles match, the most specific wins. `exactly` outranks `contains`, more
conditions rank higher, and ties go to the earlier profile:

| Key | Type | Description |
| --- | --- | --- |
| `displayCount` | string? | Connected-monitor count: `"==1"`, `">=2"`, `"<=1"`. |
| `whenConnected` | string[]? | Displays that must be connected (`"<uuid>::<name>"` or `"<name>"`). |
| `whenConnectedMatch` | string | `"contains"` by default, where listed displays must be present and extras are allowed, or `"exactly"`, where the connected set equals the list. |
| `whenDisconnected` | string[]? | Displays that must be unplugged. |

Workspace fields:

| Key | Type | Description |
| --- | --- | --- |
| `id` | UUID | Stable identifier. |
| `name` | string | Display name. |
| `symbolIconName` | string? | SF Symbol used in the menu bar / sidebar. |
| `kind` | string | `normal` (default) or `scratchpad`. A scratchpad is **borrow-only**: it is excluded from regular switching, never activates alone, and auto-opens its apps when borrowed beside another workspace. |
| `keyEquivalent` | string? | One-character key for this workspace, held with the switch / assign / borrow modifiers (see `[settings.shortcuts]`). Omit to disable key-equivalent actions for it. |
| `activateShortcut` | string? | Explicit override for the switch combo. |
| `assignAppShortcut` | string? | Explicit override for the assign combo (add the focused app, keeping its other memberships, and switch here). |
| `borrowShortcut` | string? | Explicit override for the borrow combo. |
| `borrowEdge` | string? | Override the default borrow edge for this workspace: `top`, `bottom`, `left`, `right`. Omit to use `settings.switching.borrowDefaultEdge` (or the direction-pick when that's unset). |
| `borrowFraction` | double? | Override the borrowed-block size for this workspace (0.1…0.9). Omit to use `settings.switching.borrowFraction`. |
| `appToFocusBundleId` | string? | Bundle ID of the assigned app to focus on activation. Omit for most-recently-used. |
| `displayHint` | string? | Pin the workspace to a display using `"<uuid>::<name>"` or just `"<name>"`. Omit to open the workspace on the display under the mouse. Falls back to the primary display when the pinned monitor is absent. When a dynamic workspace leaves a display, Tatami refills that display from its own history, but only with a workspace pinned to it or a dynamic one no other display is using. A workspace pinned to a monitor that is currently disconnected is never pulled in. When nothing qualifies, the display is left empty on purpose. |

App assignment fields:

| Key | Type | Description |
| --- | --- | --- |
| `bundleIdentifier` | string | The app's bundle ID. |
| `name` | string | Display name. |
| `autoOpen` | bool | Launch the app when the workspace activates and reopen it on re-entry if its window was closed. |
| `layout` | string | `tiled` (**Tiled** in the app), `floating` (**Always on Top**; untiled and mirrored above the tiles), or `unmanaged` (**Leave As Is**; left in place and still a member, with no tiling, mirroring, or Screen Recording). Migrated from the pre-1.4 `floating` bool. |
| `iconPath` | string? | Cached path to the app's icon, written automatically. You don't set this by hand. |
