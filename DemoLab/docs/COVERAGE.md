# Demo coverage and verification

The v4 delivery contains 27 real recordings: an approximately 80-second complete
workflow and 26 focused films. The website places them in seven always-visible
collections beside the feature they demonstrate. Total video duration is 7:48;
H.264 deliveries total approximately 18 MiB, with media loaded on demand.

## Captured coverage

| Collection | Films | Demonstrated behavior |
| --- | --- | --- |
| Workspaces | 3 | Direct/recent/ordered switching, auto-open/reopen, app membership moves. |
| Profiles and displays | 4 | Profile switching, profile/workspace duplication, two-screen chains, cross-display focus, automatic profile activation on connect/disconnect. |
| Tiling and focus | 8 | Insert/close, swap, split orientation, resize/balance, drag, workspace zoom, pause/resume, directional focus, MFF/FFM, held/quick window switcher, native visual layout editor. |
| Borrow | 3 | Conversation alongside work, persistent scratchpad, edge selection, cross-block focus, full activation and return. |
| Window modes | 3 | Per-workspace Always on Top, Shared Always on Top, interactive mirrors, Leave As Is and its inclusion in the window switcher. |
| Automation | 3 | Real CLI output, a multi-command focus-session script, lifecycle/HUD hooks, atomic TOML edits with live reload. |
| Guided Setup | 2 | Built-in gesture previews and real keyboard practice; validation and application of an example AI proposal to the draft. |

The hero ties design/theme selection, actual PNG export, saved writing, review
checks/approval, Borrow, shared status, CLI automation and display-aware profile
changes into one continuous task. Canvas, Editor, Docs, Review, Chat, Notes,
Terminal and Monitor are interactive local fixtures. Tatami performs the window
management; hook and CLI outputs are produced by actual processes.

## Evidence

- Every accepted take passed its real action/state/layout assertions and matches
  the current scene SHA256. Failed attempts remain in separate recording batches.
- The recorder reports per-display frame drops and first-frame timestamps.
  All accepted outputs are below the 1% drop threshold.
- All 27 delivered MP4s passed full FFmpeg decode, duration/size budgets,
  opening-caption timing, H.264/yuv420p format and source/timeline clock checks.
- Offline OCR inspected 482 one-second samples across all videos. No configured
  permission-request or macOS-first-run phrases were detected. This is a sampled
  check, supplemented by the live permission gate and visual frame review.
- Swift: 55 tests passed. Python export rejection/acceptance: 6 tests passed.
- Browser: native playback, single-video playback, visible thumbnail choices,
  keyboard selection, per-film links and a 390px responsive layout verified.
- Film colors are generated from the website dark palette. HTML uses a content
  hash for both video and poster URLs, preventing mixed generations in cache.

The delivery's `evidence/` folder contains frozen scene JSON, take metadata,
timing, captions, sample/contact frames and the OCR report. `selection.json`
records the exact raw batch chosen for each film. The original v3 review and
original user-provided output remain separate.

## Boundaries and an unresolved reproduction

- **Native macOS fullscreen return:** the original test left Canvas and Docs at
  full-workspace bounds after exiting native fullscreen. Cause is not isolated.
  `scenes/native-fullscreen.json` and the failed `recordings/v4-edge1/fullscreen*`
  preserve the reproduction. It is excluded from publication. The film named
  `fullscreen` demonstrates Tatami workspace zoom/restore, which passed.
- **Physical gestures:** Guided Setup uses its explicit gesture-preview buttons
  and real keyboard shortcuts. Physical three/four-finger recognition is not
  claimed from the VM.
- **AI:** the proposal is a labelled local example. No external AI request is
  made. The live TOML was checked after the take and still contained the original
  workspace names; the example was applied only to the draft.
- **Multiple monitors:** two guest-side CoreGraphics displays were enumerated,
  managed and independently captured, then aligned by timestamp. This does not
  establish physical dock, mixed-DPI, HDR or cable behavior. The private helper
  lives only in Demo Lab and needs validation on another guest OS version.
- **Coverage:** the collection covers the main interactions above. It is not
  exhaustive QA for every preference, language, update flow or hardware variant.

## Capture defects corrected

The driver now preserves numeric-pad/function identity on arrow events. An A/B
probe on the same registered hotkey isolated that missing input metadata.
[Apple's numericPad documentation](https://developer.apple.com/documentation/appkit/nsevent/modifierflags-swift.struct/numericpad)
describes arrow-key identity. Native controls are scrolled into view before
clicks; covered normal-stacking windows are selected through Tatami's real
switcher. Source sync and fetch use unique archives to remove virtiofs filename
reuse, and fetch verifies guest/host hashes.

The old claim that a macOS VM could never have a second display was incorrect.
The working guest-side API is documented in
[DeskPad's CoreGraphics interface](https://github.com/Stengo/DeskPad/blob/main/DeskPad/CGVirtualDisplayPrivate.h).
See [MULTI-DISPLAY.md](MULTI-DISPLAY.md) for the actual setup and reproduction.
