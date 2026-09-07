<!-- LANGUAGE-LINKS:START -->
[English](README.md) · [한국어](docs/ko/README.md) · [日本語](docs/ja/README.md) · [简体中文](docs/zh-Hans/README.md) · [繁體中文](docs/zh-Hant/README.md)
<!-- LANGUAGE-LINKS:END -->

# Tatami Demo Lab

Record the real Tatami, export a consistent set of marketing videos, and place
those videos beside the product promises they demonstrate. The apps and their
contents are fixtures; workspace switches, tiling, Borrow and window focus are
performed by the installed Tatami.

## Publication contract

[`publication.json`](publication.json) is the inventory and editorial budget.
It maps each scene to its website section and limits duration and delivery size.

The introduction is a complete design → writing → review → Borrow → automation
workflow, ending with a real display-topology change. Focused collections cover
workspaces, profiles and displays, tiling and focus, Borrow, window modes,
CLI/hooks, and Guided Setup. The inventory is generated from `publication.json`;
there is no separate hard-coded list to keep in sync.

The hero teaches the central promise: **switch contexts and keep your place**.
Feature scenes demonstrate different activities instead of replaying the hero.
See [coverage and evidence boundaries](docs/COVERAGE.md) for the complete map.

## Capture → export → review → install locally

Use the existing dedicated Tart VM, not your everyday desktop. `reset` and
`seed` quit Tatami and change its preferences in whichever machine runs them.
Config and layout files are isolated under `.build/lab/`; the preferences domain
is backed up separately and can be restored with `democtl restore`.

```sh
# Host: run from the repository root.
swift build --package-path Tools -c release
TOOL=Tools/.build/release/tatami-tools
"$TOOL" vm-sync

# Guest: a fresh seed for every scene. Existing takes are never overwritten.
tart exec tatami-demo /Users/admin/DemoLab/.build/tools/tatami-tools capture \
  --root /Users/admin/DemoLab --output /Users/admin/DemoLab/recordings/publish

# Host: fetch that exact batch, including originals, metadata and scene snapshots.
GUEST_DIR=DemoLab/recordings/publish "$TOOL" vm-fetch-recordings DemoLab/recordings/publish

# Host: new output directory; no ambiguous “latest take” selection.
"$TOOL" export --takes DemoLab/recordings/publish --output ~/Downloads/TatamiDemoLab-review

# Open index.html and inspect playback, opening frames, actions and every feature.
# Install the verified bundle into this checkout only; this does not push or deploy.
"$TOOL" install-assets ~/Downloads/TatamiDemoLab-review
```

Host requirements: Swift 6.2+, `tart`, `mpv` with libass/libx264, `ffmpeg` and
`ffprobe`. Run host commands from the repository root. The guest needs Xcode
Command Line Tools. Source sync carries the compiled automation executable, so
the guest does not download packages. The recorder remains an independent
SwiftPM package outside Tatami's Tuist graph.

Automation uses `swift-subprocess`, ArgumentParser, SwiftSoup, Hummingbird,
`swift-markdown`, `swift-cmark` and Swift Crypto. Foundation handles JSON and
property lists. Capture acceptance, localization units and editorial budgets
remain Tatami-specific rules. `Tools/Package.resolved` pins the dependency graph.

The export host also needs Fontconfig. Before encoding, the lab verifies the requested font family and coverage of every caption character. The OCR audit separately compares overlaid narration with the narration timeline.

## A small set of useful apps

| Workspace | Apps | Actual work |
| --- | --- | --- |
| Design | Canvas + Docs | Change the visual theme, inspect the saved draft, export a PNG. |
| Write | Editor + Docs | Read the brief, edit the headline, save the draft. |
| Review | Review + Docs | Read saved copy, run checks, comment and approve. |
| Chat | Chat | Type and send a local demo reply. |
| Build | Terminal | Execute the real Tatami CLI and bundled automation scripts. |
| Notes (Borrow only) | Notes | Add a follow-up and complete a checklist item. |
| Focus | Canvas + Notes | Work with a per-workspace Always on Top note. |
| Shared | Monitor | Observe saved project state or real workspace/HUD hook events. |

All eight apps use persisted local data. Saving changes what Review and Canvas
read. The Canvas export writes an actual image. Notes and messages survive
workspace switches. Terminal executes an explicit command allowlist and bundled
scripts; hooks receive Tatami's real environment. No fixture connects to a chat
service, and the AI proposal demonstration uses a clearly labelled local example.

## What changed in the capture contract

A scene has two phases:

- `setup` runs **before** recording: teardown, app launches, workspace warm-up,
  fixture state and layout preparation.
- `steps` are the visible demonstration. `openingApps` must have visible windows
  with stable geometry before the recorder starts. `autoopen` is the deliberate
  exception: a short empty opening is the point of that feature.

The capture gate checks system permission/settings windows before recording and
around every action. It also sees a permission dialog that is behind another
window. Resolve that dialog; do not crop it out or suppress the error.

**Recorder access is not Tatami access.** Earlier takes contained a stale
Tatami Screen Recording request despite the recorder passing `doctor`.
Tatami's Always on Top uses its own ScreenCaptureKit stream. A throwaway recorder
warm-up alone cannot validate that path. Warm up the `shared` scene and inspect
its actual monitor before accepting it. The default shared Monitor no longer
auto-opens in every scene; `shared` explicitly launches it off camera.

`waitWindows` waits for the named apps and stable window geometry.
`saveLayout` / `assertLayout` compare the same window IDs and their bounds after
workspace switches, Borrow returns, and zoom restoration. Missing or additional
windows and coordinate changes beyond 4 points fail the take.

`key` and `hold` generate their own keycasts from the actual input. Published
scenes may not use a `keys` label to pretend a CLI operation was a keystroke.
The recorder refuses startup without an encoded frame, and gives the scene its
first-frame monotonic timestamp so subtitles share the movie's clock.

## Presentation

Original MOV files contain the full captured desktop. Exports keep that image at
1920×1200, or 1920×600 for two screens. Narration appears over the lower part of
the image, with a chapter label at the upper left and actual keystrokes at the
upper right. Translucent backgrounds keep text readable over light and dark apps.
The colors come from the website palette; changing presentation needs no new capture.

Poster frames use `posterSeconds` or `posterCaptionIndex` from `publication.json`. Choose a frame after the feature has taken effect. Poster URLs use the image hash so replacing a still does not require re-encoding its video.

Caption edits may reuse an original only when every recorded action, typed input,
assertion and delay is unchanged. The exporter verifies the frozen scene hash and
compares those actions before replacing narration on the original timeline.
Original and edited scenes and timelines are both included in the evidence.

Every take has:

- `.mov`: clean camera original.
- `.ass`: editable narration and actual keycast timing.
- `.timeline.json`: all events with start/end times.
- `.take.json`: pass/fail, scene hash, Tatami version, locale, per-output frame/drop counts, capture epochs and overlay mode.
- `.scene.json`: the exact scene bytes frozen when recording began.

A failed take stays available for diagnosis but cannot enter the exporter.
Exports require a verified capture contract, clean narration, less than 1%
dropped frames, timely opening captions and matching movie/timeline duration.
The output must fit its time/size budget, use H.264/yuv420p, and survive a complete
FFmpeg decode. `faststart` places the MP4 header before the media payload.

The export bundle includes a playback gallery, posters, sampled evidence frames,
source/delivery hashes and all sidecars. Automated acceptance does not replace
watching the action: in particular, shared-window mirroring and focus targets
still need visible verification. Website players use native controls and
`preload="none"`; playback is deliberate and only one video plays at a time.
Every collection exposes its thumbnail playlist, count and previous/next buttons.
Each film links to its related configuration keys.
Arrow keys, Home/End and per-film links work without opening a disclosure.

For two-screen capture, the suite connects a real guest-side virtual display,
records each display independently, and aligns them by first-frame timestamps.
See [the verified VM setup](docs/MULTI-DISPLAY.md).

## Work on one scene

Run the capture commands inside the dedicated guest:

```sh
.build/DemoLab/bin/democtl doctor
.build/DemoLab/bin/democtl reset
.build/DemoLab/bin/democtl seed
.build/DemoLab/bin/democtl scene tour --dry-run    # prints setup and visible steps
.build/DemoLab/bin/democtl take tour --output recordings/iteration/tour.mov
# Host: after fetching that batch; run from the repository root.
Tools/.build/release/tatami-tools export --takes DemoLab/recordings/iteration \
  --output ~/Downloads/TatamiDemoLab-iteration --scenes tour
```

`democtl scene` rehearses with a live overlay. Recorded `take` defaults to
`--overlay off`; only that mode is accepted for publication. The live rehearsal
panel is not the export design. `subtitle burn` can render the sidecar into a
viewing copy, but use `tatami-tools export` for budget checks, web encoding and evidence.

Finish a session with `democtl quit` and `democtl restore` in the guest.
Original host preferences and host Tatami are not involved in the VM workflow.

## Development and reference

```sh
swift test --package-path Tools
swift run --package-path Tools tatami-tools build-tool-notices --check
swift run --package-path Tools tatami-tools bundle-apps
DEMOLAB_LOCALIZATION_DIR="$PWD/DemoLab/.build/DemoLab/Localization" \
  swift test --package-path DemoLab
```

- [Scene vocabulary](docs/SCENES.md)
- [VM setup](docs/VM-TART.md)
- [Permissions](docs/PERMISSIONS.md)
- [Real multi-display capture](docs/MULTI-DISPLAY.md)

## Five-language production

The supported languages are `en`, `ko`, `ja`, `zh-Hans` and `zh-Hant`.
`Localization/Localizable.xcstrings` owns fixture UI and seeded content;
`Localization/Films.json` owns film titles, narration and scripted human input.
`Localization/Interface.json` owns the review gallery. The product's existing
catalog supplies native Tatami AX labels when a stable control identifier is
not available. User-chosen app, workspace and profile names remain unchanged.

```sh
Tools/.build/release/tatami-tools localize-scenes
Tools/.build/release/tatami-tools vm-sync
# Inside the guest:
.build/tools/tatami-tools capture --locale ko --output recordings/ko-batch
# After fetching that explicit batch to the host:
Tools/.build/release/tatami-tools export --locale ko --takes DemoLab/recordings/ko-batch --output ~/Downloads/Tatami-ko
```

Each recording seeds the fixture and Tatami language together. Human input and
its assertions come from the same reviewed text. CLI commands and their actual
machine output remain unchanged. The final delivery is 30 fps, so the batch
also captures at 30 fps without unnecessary 60 fps sampling.

`tatami-tools record-locales` identifies missing or rejected takes for each locale.
It never treats an English capture as proof of a translated UI. A failed scene
stays available for diagnosis; another language can continue independently.

Small utility windows start near the lower-right corner. The hero moves the
status window to the lower-left corner as a visible action. Keep the document's
main reading area clear when adjusting a scenario.

For a local website preview that outlives the terminal command, run
`Tools/.build/release/tatami-tools preview-site --background` from the repository root.
