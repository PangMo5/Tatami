<!-- LANGUAGE-LINKS:START -->
[English](SCENES.md) · [한국어](ko/SCENES.md) · [日本語](ja/SCENES.md) · [简体中文](zh-Hans/SCENES.md) · [繁體中文](zh-Hant/SCENES.md)
<!-- LANGUAGE-LINKS:END -->

# Scenes and acceptance

A scene requires `name`, `title`, and `steps`. Optional fields are `summary`,
`requires`, `setup`, `openingApps`, and `captureSecondary`. `setup` executes
before recording; `steps` are the visible story. Their actions drive the
installed Tatami and native fixture apps.

Set `captureSecondary` to `true` for a hotplug scene that records the main
display continuously and captures the second display only while it is connected.

```sh
.build/DemoLab/bin/democtl scene tour --dry-run
.build/DemoLab/bin/democtl take tour --output recordings/iteration/tour.mov
```

## Preparation

Declare the apps that must be visible at frame zero in `openingApps`. The declared app multiset must
match ordinary visible windows, including intentional duplicate references.
`autoopen` declares an empty array because its first action opens the workspace.
The recording gate checks this after the geometry has settled for 400 ms.

Warm up workspaces through Tatami before rolling. Do not combine pending
Auto-open launches with manual relaunches of the same apps: that can create two
processes and two windows with one bundle identifier. A failed opening check is
a reason to correct preparation, not to trim away the unexpected window later.

## Real actions

| Kind | Fields | Effect |
| --- | --- | --- |
| `click` | `app`, `identifier` | Resolve a native AX control; move the pointer and click. |
| `typeText` | `app`, `text`, `ms?` | Type one character at a time into the expected focused app. |
| `hover` | `app`, `identifier` | Reveal a native control in its scroll viewport and move the pointer to it. |
| `scroll` | `app`, `identifier`, `pixels` | Move to a native control and scroll. |
| `key` | `chord`, `repeats?`, `holdMs?` | Press a real shortcut and generate its own keycast. |
| `hold` | `modifiers`, `keys`, `gapMs?`, `releaseAfterMs?` | Hold the real modifier through a switcher interaction. |
| `activateApp` | `app` | Click the visible title bar, then verify the focused app through AX. A covered window needs a real switching action. |
| `activateWorkspace` | `workspace`, `profile?` | Run Tatami's blocking activation command. |
| `activateProfile` | `profile` | Run Tatami's blocking profile command. |
| `cli` | `args`, `expect?` | Run another Tatami command; `accepted` only means enqueued. |
| `borrow` | `workspace`, `expectApps?`, `timeoutMs?` | CLI Borrow for specialist rehearsals. Published Borrow uses real keys. |
| `dismissBorrow` | `settleMs?` | CLI return for specialist rehearsals. |
| `pointer` | `display`, `x`, `y` | Park the pointer using normalized display coordinates. |
| `launch` | `apps`, `windows?` | Explicitly launch fixtures, primarily off camera. |
| `quitApps` | `apps?` | Quit named fixtures or the entire fixture set. |
| `dragWindow` | `app`, `target`, `x`, `y` | Drag a real title bar toward a normalized target-window point. |
| `restoreWindow` | `app` | Resize and move the saved window with real pointer drags, then verify its original frame. |
| `rightClick` | `app`, `identifier` | Open the native context menu for a control. |
| `resizeWindow` | `app`, `x`, `y?` | Drag a native window edge. |
| `virtualDisplay` | `connected` | Connect or disconnect the real guest virtual display helper. |
| `configure` | `field`, `value` | Atomically edit an allowed live setting in the lab TOML. |
| `clipboard` | `text` | Provide local example text, preserving and restoring all clipboard item types. |
| `closeSettings` | No fields | Close the native settings window after authoring. |
| `prepareSettings` | No fields | Size and position the native Tatami settings window before its controls are used. |
| `appWindows` | `app`, `count` | Set native window count, primarily for preparation. |

There is no `appState` command. Views cannot be jumped to a pre-rendered success
state. They use normal controls and share saved work through `StoryRepository`.
The launch copy, review, checks, tasks and messages are persisted together under
the lab's control directory. `seed` resets the story; switching workspaces does
not. The chat is a local fixture and has no network transport.

## Assertions and pacing

| Kind | Fields | Acceptance |
| --- | --- | --- |
| `expectPlacement` | `app`, `target`, `value` | Require every source window to be left, right, above or below the target windows. |
| `expectProfileCount` | `count` | Verify the profile count through the real CLI. |
| `expectAssignment` | `app`, `workspace`, `profile` | Verify that a copied app belongs to the target workspace. |
| `expectValue` | `app`, `identifier`, `value` | Read the actual native input value back. |
| `expectStory` | `field`, `value` | Verify saved headline, approval, comment, last task/message, checks or completed tasks. |
| `expectFront` | `app` | Verify the actual focused app through Accessibility. |
| `expectPointer` | `app` | Require the pointer inside the target window. |
| `expectCommand` | `text`, `code` | Verify an actual fixture Terminal process result. |
| `expectHook` | `field`, `value` | Inspect the payload written by a real Tatami hook. |
| `saveWindow` / `assertWindow` | `app` | Save and compare one window across changing workspace memberships. |
| `saveControlFrame` / `expectControlMoved` | `app`, `identifier`, `text` | Verify that a native layout-editor operation changed its preview. |
| `waitWindows` | `apps`, `timeoutMs?` | Wait for visible windows and stable geometry. |
| `waitWorkspace` | `workspace`, `timeoutMs?` | Observe the activation hook from the immediately preceding step. |
| `waitProfile` | `profile`, `timeoutMs?` | Observe the profile hook. |
| `saveLayout` | `text` | Save visible demo window IDs and bounds under a checkpoint name. |
| `expectLayoutChanged` | `text` | Require the visible layout to differ from the named saved checkpoint. |
| `assertLayout` | `text` | Require that exact window set and bounds to return, within 4 points. |
| `beat` | `ms`, `note?` | A declared reading pause; no hidden startup sleep. |
| `note` | `text` | Log-only explanation. |

Every step is surrounded by checks for permission/settings windows. Failure
aborts the take and writes a failed manifest. The exporter refuses failed takes.

## Narration

`chapter` and `caption` carry `text`; a caption can use `headline | explanation`.
Empty text clears a track. `clearOverlay` clears all narration. `key` and `hold`
create their own keycasts. A standalone `keys` label remains available for manual
rehearsals but is forbidden in publication scenes, because it would imply a
keyboard action that did not occur.

`take` defaults to `--overlay off`: text is recorded in editable ASS and JSON
sidecars. Exports place captions over the lower part of the captured image,
with the chapter at the upper left and actual keycasts at the upper right.
Translucent backgrounds keep text readable, but it can cover app content;
keep important controls clear of those areas. `scene` uses a live rehearsal
panel, which is separate from the final export design.

Use [publication.json](../publication.json) for placement and duration/size
budgets, and [README.md](../README.md) for capture, export and review commands.
