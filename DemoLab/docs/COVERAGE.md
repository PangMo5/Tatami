# Demo coverage and verification

The publication inventory contains 27 scenarios: a complete workflow and 26
focused demonstrations. Every supported locale has its own app language,
fixture content, typed input, captions and capture assertions. Accepted takes
are selected by locale, recorded actions and capture quality, then exported separately.

## Captured coverage

| Collection | Films | Demonstrated behavior |
| --- | --- | --- |
| Workspaces | 3 | Direct/recent/ordered switching, auto-open/reopen, app membership moves. |
| Profiles and displays | 5 | Profile switching, GUI profile duplication, selective workspace copying, two-screen chains, cross-display focus, automatic profile activation on connect/disconnect. |
| Tiling and focus | 7 | Insert/close, swap, split orientation, resize/balance, drag, workspace zoom, directional focus, MFF/FFM, held/quick window switcher, native visual layout editor. |
| Borrow | 3 | Conversation alongside work, persistent scratchpad, edge selection, cross-block focus, full activation and return. |
| Window modes | 3 | Per-workspace Always on Top, Shared Always on Top, interactive mirrors, Leave As Is and its inclusion in the window switcher. |
| Automation | 3 | Real CLI output, a multi-command focus-session script, lifecycle/HUD hooks, atomic TOML edits with live reload. |
| Guided Setup | 2 | Built-in gesture previews and real keyboard practice; validation and application of an example AI proposal to the draft. |

The hero ties design/theme selection, actual PNG export, saved writing, review
checks/approval, Borrow, shared status, CLI automation and display-aware profile
changes into one continuous task. Canvas, Editor, Docs, Review, Chat, Notes,
Terminal and Monitor are interactive local fixtures. Tatami performs the window
management; hook and CLI outputs are produced by actual processes.

## Evidence and acceptance

Every accepted take must pass its real action/state/layout assertions, match the
current localized capture actions and timing, and stay below the 1% frame-drop threshold.
Text-only revisions preserve the source scene hash and add the edited scene hash.
Exports check the whole MP4, H.264/yuv420p encoding, editorial duration/size
budgets, first-caption timing and the shared movie/timeline clock.

The delivery's `evidence/` directory records the actual results: frozen scene
JSON, capture metadata, subtitles, timing, sampled frames, OCR and browser
verification. Use those reports for a specific batch's counts and review status.
Do not treat an old report as evidence for a new language or take.

Film colors come from the website dark palette. Caption fonts are selected for
the recorded language. Media URLs include the delivery hash, so a replacement
movie and its poster cannot silently mix with the previous generation.

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

The membership film cancels one move, verifies the original assignment, then confirms a move and verifies removal from the original workspace. Always on Top receives the first click without preactivation and confirms both layout changes. Workspace copying confirms an overwrite and shows the disabled matching source. The AI example explicitly confirms draft replacement while checking that the desktop layout remains unchanged.

The offline OCR audit accepts `--cpu-only` to select supported CPU compute devices explicitly when hardware acceleration fails. Recognition accuracy, sampling, and pass criteria stay the same; the report records the selected compute mode.

## Graphics corruption reproduction

A September 2026 recording investigation reproduced scrolling-preview corruption with both Tatami 1.13.0 and the 1.14.0 candidate in the same running VM. Separate guest PNG screenshots also contained magenta regions, so final MP4 encoding was not the origin. Guest WindowServer and Tatami logs reported GPU hangs, aborted Metal command buffers, and display-space flushing for GPU recovery.

After restarting only the Tatami VM, the same preview and HUD checks passed in both windowed and headless modes. This does not establish that headless mode, concurrent VMs, or a specific app revision caused the graphics failure. Another project's VM remained running throughout. The older delivered 1.13.0 videos being clean did not prove that the same build would remain clean in a later unhealthy VM session.

The earlier refreshed demo batch passed structural, decoder, and OCR checks but was subsequently rejected by visual review. Treat those automated checks as separate evidence, not a final visual pass. Keep the affected recordings for diagnosis and require renewed visual acceptance before treating replacements as publication-ready. See the VM recording guide for the recovery and review procedure.
