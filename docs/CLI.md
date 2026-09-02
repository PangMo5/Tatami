# Tatami command-line reference

Tatami ships a `tatami` executable inside the app bundle. The CLI talks to the
running app, so launch Tatami before sending commands.

## Install

Open **Settings → General → Command Line → Install**. Tatami creates a symlink
at `/usr/local/bin/tatami`; macOS asks for an administrator password when the
link is installed or removed. The link points into the app bundle, so replacing
Tatami at the same path also updates the CLI. Reinstall the link after moving
or renaming the app.

Verify both the executable and the running app:

```sh
tatami --version     # bundled CLI version, no app connection required
tatami version       # version reported by the running Tatami app
```

## Command overview

```text
tatami version [--json]

tatami profile list [--json]
tatami profile activate <profile> [--json]
tatami profile rename <profile> <new-name> [--json]
tatami profile duplicate <profile> [--name <new-name>] [--json]

tatami workspace list [--profile <profile>] [--json]
tatami workspace apps <workspace> [--profile <profile>] [--json]
tatami workspace activate <workspace> [--profile <profile>] [--json]
tatami workspace rename <workspace> <new-name> [--profile <profile>] [--json]
tatami workspace duplicate <workspace> [--profile <profile>] [--name <new-name>] [--json]
tatami workspace next|previous|recent [--json]
tatami workspace move-app next|previous [--json]
tatami workspace assign-app to <workspace> [--profile <profile>] [--json]
tatami workspace assign-app next|previous|recent [--json]
tatami workspace borrow from <workspace> [--json]
tatami workspace borrow next|previous|recent [--json]
tatami workspace dismiss-borrow [--json]

tatami window focus left|right|up|down [--json]
tatami window cycle next|previous [--json]
tatami window resize grow|shrink [--json]
tatami window swap left|right|up|down [--json]
tatami window toggle-fullscreen|toggle-floating|toggle-shared-floating [--json]
tatami display focus next|previous [--json]

tatami layout toggle-orientation|balance|toggle-tiling [--json]

tatami app toggle-workspace|toggle-shared [--json]

tatami hook list [--json]
```

Run `tatami help`, `tatami help <command>`, or append `--help` to a command for
ArgumentParser's current usage text.

## Select profiles and workspaces

Every `<profile>` and `<workspace>` selector accepts either its current name or
UUID. A workspace name is resolved inside the active profile unless
`--profile` is supplied. A workspace UUID is globally unique and can therefore
select an inactive profile without `--profile`. `workspace borrow from` is the
exception: Borrow only accepts a workspace in the active profile, so switch
profiles first when necessary.

If a name is duplicated in the search scope, Tatami fails without changing
anything and prints every candidate UUID. Use one of those UUIDs to retry.

The original flat commands remain available as compatibility aliases for
existing scripts. They are intentionally hidden from root help so new usage is
organized by domain:

- `tatami list-workspaces` is `tatami workspace list` for the active profile.
- `tatami list-apps <workspace>` is `tatami workspace apps <workspace>` for the
  active profile.
- `tatami activate <workspace>` is `tatami workspace activate <workspace>` for
  the active profile.

Profile/workspace rename and duplicate commands update `config.toml`
transactionally. Duplication also copies saved layouts before publishing the
new config; a layout-copy failure leaves the configuration unchanged.

CLI duplication copies the complete item rather than opening the app's
selection sheet. `workspace duplicate` clears the new workspace's key
equivalent and explicit activate/assign/borrow shortcuts because the copy lives
in the same profile. `profile duplicate` clears the new profile's switch
shortcut and auto-activation rule, but keeps its workspaces' shortcuts because
workspace bindings are isolated by profile. Use Duplicate in the app when you
want to choose individual workspaces, apps, settings, or saved layouts.

## Run dispatcher commands by domain

The `profile`, `workspace`, `window`, `display`, `layout`, and `app` domains
cover every executable capability available to three- and four-finger gesture
bindings. Non-activation operational leaves map through `GestureAction` and use
the same `HotKeyAction` dispatcher as gestures and global shortcuts; there is no
generic `action` escape hatch.

Most operational commands return status `accepted`. This means the running app
validated the command and handed it to the shared reducer dispatcher. It does
not claim that a later Accessibility or window-manager operation changed a
window: for example, `window focus left` can have no neighbor and a workspace
app command can arrive when no app is focused.

`profile activate` and `workspace activate` instead wait for the full activation
pipeline and return status `completed`, or report terminal failure. Scratchpads
are Borrow-only, so use `workspace borrow from <workspace>` for them.

Toggle commands are non-idempotent. Do not blindly retry one after an
interrupted or unknown client-side result; inspect state first or the retry may
undo the first invocation.

### Profiles and workspaces

| Command | Behavior |
| --- | --- |
| `profile activate <profile>` | Activate the profile and wait for terminal completion. |
| `workspace activate <workspace> [--profile …]` | Activate the workspace and its owning profile when necessary, then wait for completion. |
| `workspace next` / `previous` / `recent` | Switch relative to workspace history/order. |
| `workspace move-app next` / `previous` | Move the focused app to an adjacent workspace and switch. |
| `workspace assign-app to <workspace> [--profile …]` | Add the focused app without removing its existing workspace memberships, switch profiles when necessary, and activate the target. |
| `workspace assign-app next` / `previous` / `recent` | Add the focused app without removing existing memberships, then switch to the relative workspace. |
| `workspace borrow from <workspace>` | Start the interactive Borrow direction picker for a workspace in the active profile. |
| `workspace borrow next` / `previous` / `recent` | Borrow a relative workspace. |
| `workspace dismiss-borrow` | Dismiss Borrow on the pointer display. |

### Windows and displays

| Command | Behavior |
| --- | --- |
| `window focus left` / `right` / `up` / `down` | Focus a neighboring tiled window. |
| `window cycle next` / `previous` | Cycle inside the visible Tatami workspace. |
| `window resize grow` / `shrink` | Adjust the focused BSP split by one step. |
| `window swap left` / `right` / `up` / `down` | Swap the focused tiled window directionally. |
| `window toggle-fullscreen` | Toggle Tatami's layout fullscreen for the focused window. |
| `window toggle-floating` / `toggle-shared-floating` | Toggle the focused app's tiled/floating layout in its workspace or Shared Apps. |
| `display focus next` / `previous` | Focus the workspace on an adjacent display. |

CLI and gesture window cycling is immediate. The held-modifier switcher session
is specific to a real global shortcut.

### Layout and tiling

| Command | Behavior |
| --- | --- |
| `layout toggle-orientation` | Toggle the focused split orientation. |
| `layout balance` | Rebalance the active layout. |
| `layout toggle-tiling` | Pause or resume Tatami tiling globally. |

### Focused app

| Command | Behavior |
| --- | --- |
| `app toggle-workspace` | Remove the focused app if it is already in the active workspace. Otherwise move it from any other workspace in the active profile into this one as Tiled. |
| `app toggle-shared` | Add the focused app to Shared Apps as Tiled, or remove it if it is already shared. |

### Hooks

`tatami hook list` reports every configured hook, including disabled and
invalid entries. Add, edit, delete, enable, or disable hooks from
**Settings → Hooks**, or edit `[[hooks]]` directly in `config.toml`. Hand edits
remain supported and are picked up live.

Supported events are `tatamiLaunched`, `profileChanged`, `workspaceActivated`,
and `hud`. `tatamiLaunched` is published once per Tatami process after startup
has resolved the active profile. Its payload contains that profile and omits
`previousProfile`, `workspace`, `display`, and `hud`. It is separate from the
startup `profileChanged` event, so hooks can subscribe to either or both. The
`hud` event mirrors compact action-feedback content for integrations such as
SketchyBar.

The Settings editor keeps the executable and every argument in separate
fields. They map directly to `command[0]` and its remaining argv values. Tatami
does not combine them into a shell command, split arguments on spaces,
interpret quotes, or expand variables. Choose a shell explicitly when shell
syntax is required, such as an executable of `/bin/zsh` with separate `-lc`
and script arguments. For fish, use the path returned by `which fish`, then add
`-c` and the command text as separate arguments. For example, `command ls`
bypasses a user-defined `ls` function. Tatami sends the hook event on standard
input, so a command that consumes standard input receives that JSON event.

The full event, standard-input, environment, working-directory, and timeout
contracts are documented in the
[configuration reference](https://pangmo5.dev/Tatami/configuration.html#hooks).

## JSON output and exit status

Append `--json` to a leaf command. The option belongs after that command; parent
positions such as `tatami --json profile list` are not accepted.

Examples:

```sh
tatami profile list --json
tatami workspace apps "Coding" --profile "Dual" --json
tatami window focus left --json
```

Successful JSON is written to standard output. A dispatcher result has this
shape:

```json
{
  "command": "window.focus.left",
  "title": "Focus left",
  "status": "accepted"
}
```

`command` and `status` are stable scripting fields; `title` follows the running
app's language and is for display.
Profile, workspace, app, hook, and mutation commands return structured objects
with their identifiers and relevant metadata rather than wrapping plain text.

After arguments have parsed, failures use `{"error":"…"}` on standard error
and exit nonzero. ArgumentParser usage/help diagnostics remain plain text. A new
CLI also rejects plain output from an older running Tatami when `--json` was
requested, instead of silently treating it as machine-readable data.

## Socket and development isolation

By default both processes use `tatami.socket` in the current user's Darwin
temporary directory. Set `TATAMI_SOCKET_PATH` to an absolute path to isolate a
development app/CLI pair; the app and CLI must receive exactly the same value.

```sh
socket="${TMPDIR%/}/tatami-example.socket"
TATAMI_SOCKET_PATH="$socket" /path/to/Tatami.app/Contents/MacOS/Tatami &
TATAMI_SOCKET_PATH="$socket" /path/to/tatami workspace list
```

The app owns the socket. If it is not running, the CLI exits nonzero and asks
whether Tatami is running.

## Scripting examples

Select by UUID and let `jq` validate the JSON contract:

```sh
profile_id="$(tatami profile list --json | jq -r '.[] | select(.isActive).id')"
tatami workspace list --profile "$profile_id" --json \
  | jq -r '.[] | [.id, .name, .kind] | @tsv'
```

Fail fast when an accepted dispatcher command cannot be submitted:

```sh
if ! result="$(tatami layout balance --json)"; then
  printf 'Tatami layout command failed\n' >&2
  exit 1
fi
printf '%s\n' "$result" | jq -e '.status == "accepted"' >/dev/null
```
