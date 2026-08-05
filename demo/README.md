# Tatami Demo

Throwaway helper apps for recording Tatami promo footage. They put clean,
themed mock windows on screen so a recording shows Tatami tiling *real* windows
with a controlled, branded look (matching the website's demo animation) instead
of your actual desktop.

Not part of the Tatami product: separate directory, their own bundle ids, no
wiring into the app's Tuist project.

## The apps

Ten apps, covering the website demo's workspaces plus Shared Apps and a
scratchpad. They're **separate
apps** (one binary, distinct bundle ids `dev.PangMo5.TatamiDemo.<kind>`) so
Tatami can assign each to a workspace, keep it always on top, and so on.

| Workspace | Apps |
| --- | --- |
| **Code** | Terminal · Code · Safari |
| **Design** | Figma · Photos |
| **Chat** | Messages · Mail · Calendar |
| **Shared Always on Top** | Notes |
| **AI Assistant scratchpad** | Assistant |

## Build & run

```sh
./demo/build.sh
open demo/build/Terminal.app demo/build/Code.app demo/build/Safari.app
```

(Builds with `swiftc` into hand-assembled `.app` bundles — no Xcode/Tuist
project. `build/` is git-ignored.)

## Config (keeps YOUR settings)

`use-demo-config.sh apply` backs up your config, then writes **your real
settings** with the controlled Shared Apps and profiles from
`demo-workspaces.toml`. Your gaps, shortcuts, markers, etc. are unchanged;
existing Shared Apps and profiles return on restore. Tatami hot-reloads, no
relaunch.

```sh
./demo/use-demo-config.sh apply     # backs up ~/.config/tatami/config.toml, swaps in demo workspaces
# … record …
./demo/use-demo-config.sh restore   # puts your config back
```

Workspace activate shortcuts: **⌃⌥⇧1** Code · **⌃⌥⇧2** Design · **⌃⌥⇧3** Chat
(everything else uses your own keybindings).

Borrow **Chat** with **⌃⌥⌘3**. Summon the **AI Assistant** scratchpad with
**⌃⌥⌘A**. Notes is a shared **Always on Top** app and opens with Code.

## Recording the demo (mirrors the website animation)

1. **Tiling reveal** — on **Code**, open the apps one at a time
   (`open …/Terminal.app`, then Code, Safari). Each new window splits off
   the focused tile — the dwindle layout keeps the first window largest.
   (**⌘N** in an app adds another of its own windows; **⌘W** closes one and the
   rest re-tile.)
2. **Manipulate** — directional focus, swap into a bigger tile, zoom to fill,
   rotate — with your own Tatami keybindings.
3. **Borrow** — borrow **Chat** on the right. Its three-window BSP stays separate
   from Code while directional focus crosses the shared edge.
4. **Shared + scratchpad** — keep Notes above both layouts, then summon and
   dismiss the **AI Assistant** without replacing Code.
5. **Workspaces** — switch to **Design** (Figma, Photos), then show the Work and
   Personal profiles in Tatami's settings.

Open each workspace's apps (above) before switching to it so there's something
to tile.
