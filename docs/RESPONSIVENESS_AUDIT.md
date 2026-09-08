<!-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors -->
<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Responsiveness audit — 2026-09-08

The audit covers the 112 production Swift files under `Tatami/Sources` and
`TatamiKit/Sources`. Static searches identified blocking calls and timing controls;
manual review followed their input, reducer, worker, publication, and cancellation
paths. This is an evidence-bounded audit, not a formal proof that every operation
is nonblocking. Local traces, logs, inventories, and measurements are retained in
`DerivedData/Diagnostics/ResponsivenessAudit/` and are not release artifacts.

## Changes

| Area | Problem | Result |
| --- | --- | --- |
| Configuration | Initial TOML reads and writes ran synchronously; durable transactions held the shared-state lock across disk work. | One serial I/O lane owns reads, watches, saves, and compare-and-swap. Main-thread publication is brief and rejects obsolete state. Startup waits for successful loading before constructing dependent views. |
| Configuration races | A delayed load could replace a newer edit; failed publication needed to restore disk safely. | Load/publication generations, serialized write admission, raw-revision checks, and identity-aware rollback preserve UI and external writers. Unverified recovery bytes are retained. |
| Duplicate work | Initial load requests and serialization repeated; session-only profile changes rewrote TOML. | Concurrent load requests share one read, transactions encode once, and unchanged persisted content avoids a write. Normal quit drains admitted configuration writes and surfaces a failed save before offering an explicit discard choice. |
| Resources | First icon loads, app metadata, CLI status, and application URL lookup could perform filesystem work on UI paths. | Workers resolve metadata and immutable icon bitmaps. Resource actors use Dispatch serial executors. AppKit panel presentation remains on main. |
| Session/layout persistence | Blocking actors occupied the cooperative pool; session caching advanced even after a failed write. | Dispatch serial executors retain whole read/modify/write ordering. A failed session write remains retryable. |
| AX and event infrastructure | Main could wait on an AX mutation lock or worker startup semaphore. | Generation invalidation is nonblocking, visibility transactions await a worker fence, and startup queues operations without blocking the caller. Dependency context crosses Dispatch boundaries. |
| Floating windows | Mirror focus used a separate activation path; hover and FFM competed for keyboard focus. | Click uses the common focus pipeline. Hover reveals without independently moving keyboard focus; FFM owns its policy. |
| Mirror presentation | A fixed 30 ms pre-focus wait guessed when a restored panel was visible; first-app focus omitted mirror preparation. | Both focus paths prepare mirrors and verify WindowServer identity, geometry, layer, and opacity. Handover verifies the real window before fading; stream/request ownership rejects stale callbacks. |
| FFM | A 50 ms throttle could discard the last move into a window. WindowServer reads ran inside the event callback. | A worker reads windows while the event thread retains one latest sample. Completion consumes that sample without waiting for more movement. Native event identity avoids repeat scans within the selected window. Modifier changes and obsolete input revoke pending work. |
| Overlay-aware apps | Hide acknowledgement cleared exclusion before an app recreated its floating control and unhid ordinary windows. | Background ownership survives hide/unhide until explicit target activation, verified native foreground adoption, or process termination. |

Earlier commits in this audit also corrected live process identity recovery,
foreground work-window adoption, shared-window cycle order, per-launch debug-log
retention, and background capture/rendering boundaries. Durable contributor rules
are in `AGENTS.md`; execution contracts are in `docs/CONCURRENCY.md`.

## Configuration measurement

Four Debug runs compare the retained synchronous `FileStorage` path with the new
store using identical 76,951-byte synthetic configurations and temporary files.
Each contains eight profiles, 128 workspaces, and 512 app assignments. These are
local configuration-path measurements, not physical input-to-photon timings.

| Median duration | Synchronous path | Worker path |
| --- | ---: | ---: |
| Initial load call on main | 12.030 ms | 0.479 ms |
| Initial load fully available | 12.032 ms | 12.496 ms |
| Save call on main | 8.467 ms | 0.451 ms |
| Save durable on disk | 8.471 ms | 9.949 ms |

The improvement is main-thread availability. Durable completion includes queueing,
coordination, and ownership validation and is not claimed to be faster. An earlier
measurement exposed duplicate reads/encoding; those were removed before these
results. See `config-benchmark-final.json` for all samples. Blocked-worker tests
separately prove that main-actor work can progress while the I/O lane is occupied.
The live configuration was byte-identical before and after the initial runtime
migration.

## Runtime evidence

The old process log and a WindowServer metadata sample showed a specific Notion
lifecycle: leaving its workspace briefly removed the elevated control; Tatami hid
the app; Notion recreated the control and unhid both ordinary windows. The old hide
acknowledgement released their exclusion before this reopen. This was direct
evidence of a state gap, not proof of every reported Terminal misactivation.

With the changed runtime, the same control-recreation sequence produced explicit
background exclusion for both ordinary windows. Terminal activation selected cmux
window 76 and subsequent metadata confirmed cmux above the Notion windows. The
meeting control remained visible. Native foreground-work-window adoption remains
covered by regression tests so this exclusion does not require a particular launcher.

The final runtime sequence `Notion → Terminal → Slack → Terminal → AI` was
verified against both the frontmost application and the first normal WindowServer
surface. All five reached the requested app. CLI response times were 146–196 ms;
first observed foreground/order confirmation was 208–522 ms, including probe
startup and sampling overhead. This is not keyboard input-to-photon latency.
See `final-workspace-transitions.json` for individual observations.

The 45.88 s settings/document trace and 30.84 s transition trace each reported
zero detected hangs and zero hitches. Sampled CPU weight was 1.207 s and 1.093 s,
respectively. The settings trace also contains an unresolved 102.6 ms SwiftUI
record; it is not attributed to a specific source view and must not be erased
from the evidence by the zero-hitch count. These are Debug traces, not a paired
release performance comparison.

Settings and the bundled CLI reference were opened through the actual app. CLI
install/uninstall was not executed: validation did not require changing the host's
installation or invoking an administrator prompt.

## Validation and limits

The final Debug test run passed **680 tests**, with no test failures, build
errors, or warnings. Coverage includes stalled-worker main-actor progress,
dependency propagation, repeated atomic file replacement, session-only no-write,
stale loads, UI/transaction ordering, external-writer rollback, failed-save flush,
session retry, mirror visibility, and FFM latest-input cancellation.

Changed-file SwiftFormat, `git diff --check`, the five-locale string catalog, and
a changed-file `gitleaks@8.30.1` scan passed. The final persistence build was
launched, quit through the actual application menu, confirmed stopped, and
launched again. This idle-quit runtime check complements the queued-write tests;
it is not a forced-shutdown guarantee. The two traces precede the final
quit-error and transaction-acknowledgement refinements; their input/rendering
paths are unchanged, and the final source is covered by the final test run.

- The source inventory and final blocking/timing call-site lists distinguish UI
  presentation, worker IPC/I/O, short state locks, and intentional socket waits.
- Remaining timing controls include user-visible HUD/recorder lifetimes, failure
  deadlines, evidence polling, and display-topology settling. They are not all
  interchangeable with input delays. The 150 ms display observer debounce and
  deliberate window-cycle HUD dwell remain; reconnect behavior needs its own
  paired display-topology measurement before changing those policies.
- The release baseline trace contained no detected hangs/hitches, but did not
  prove that the reported interaction occurred during recording. It is not used
  as a paired before/after speed claim.
- WindowServer metadata confirms visibility and ordering, not final scanout,
  scroll/drag feel, or the complete absence of visible flicker. The user confirmed
  the earlier Notes mirror click fix. FFM-disabled hover and rapid hover/exit
  presentation still need direct pointer/display confirmation; the Notes windows
  were intentionally closed during later runtime checks.
- Multi-display reconnects, physical-device feel, forced termination, and an
  exhaustive reproduction of the intermittent Notion misactivation are outside
  the confirmed runtime evidence. No release or push is implied by these results.
