<!-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors -->
<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Concurrency and responsiveness

Keep the main actor available for input and presentation. Preserve correctness
before changing execution order: an asynchronous implementation that applies an
obsolete focus, frame, or configuration is not an improvement.

## Execution boundaries

- Reducers and AppKit window presentation own their state on the main actor.
- Accessibility IPC, WindowServer queries, and file reading/parsing belong on
  workers. An `async` declaration or a `Task` created on the main actor does not
  by itself move synchronous work off that actor.
- Use `BlockingWorkQueue` for blocking operations. Do not occupy a cooperative
  executor with synchronous waits, or use `DispatchQueue.sync` to make the main
  actor wait for a worker.
- Synchronous dependency accessors may return cached/value state. Live
  `WindowSnapshotClient` IPC accessors reject synchronous use; the synchronous
  overrides remain only as lightweight test seams.
- Do not hold a lock needed by the main actor while a worker performs IPC or
  I/O. The process resolver has a separate published identity snapshot so a
  cache read cannot wait for its WindowServer scan.

`NSRunningApplication` and `NSWorkspace.runningApplications` support atomic
reads from other threads. Their time-varying properties still follow the main
run loop, and several property reads are not a transaction. Revalidate the
application identity before using a result.

## Ordering and cancellation

- Capture request ownership before suspension. Check it again before applying
  a result: activation generation, profile, visible workspaces, layout state,
  process identity, and presentation generation as applicable.
- Keep the distinction between unavailable evidence and an authoritative empty
  result. Never remove windows because an app timed out.
- Restore floating mirrors before moving focus. Preparation may await worker
  evidence; superseded preparation must cancel the focus transfer itself.
- A cancelled await does not undo an already-started write. Retain the existing
  transaction and late-result rules for writes.
- Freeze a window-switcher session's geometry snapshot rather than querying
  WindowServer again on every repeated key press.
- Keep non-tiled windows within each app in a stable process/window-ID order.
  AX window lists can move the focused window to the front; using that order
  directly can trap repeated cycling inside one shared app.

Capture callbacks use `AVSampleBufferVideoRenderer`, whose API supports
background access, while layer presentation stays on the main actor. Retire
old stream identities before accepting callbacks from a replacement stream.
GPU still-image readback runs on a worker and revalidates the mirror before
applying its result.

Debug logs use a unique file per process launch. `tatami.log` points to the
current session; replacing that pointer must not erase earlier session data.

## Foreground ownership and preserved overlays

Background overlay preservation excludes ordinary windows from automatic
focus and tiling. It is not permission to ignore a real foreground work window.

Use the observed focused window and WindowServer ordering, not a guessed
activation origin. A normal-level focused window must be visible, and its app
must own the frontmost normal surface at that window's center. An elevated
recording control, a stale AX focus on a document behind another workspace, or
an obsolete app identity cannot reclaim the workspace. This applies equally to
external links, launchers, Dock, keyboard switching, and application actions.

Validate off-main, then recheck profile/activation ownership and the frontmost
app before clearing background suppression. During Tatami's own activation,
defer the check until all focus/layout work finishes and inspect the current
foreground rather than replaying the historical event. Window-focus events
also trigger validation, so an already-active app can open its main document.

A hide acknowledgement changes visibility, not workspace ownership. An
allowlisted app may recreate an elevated control and unhide its normal windows
immediately afterward. Retain its background exclusion across this edge until
a target/shared/borrowed activation or a verified native foreground work window
adopts it. Termination revokes the exact process; after allowlist removal, a
confirmed hide can release its remaining exclusion.

## Persistence and resource loading

`AsyncConfigStore` owns initial reading, TOML decoding, file/directory watches,
ordinary saves, and durable GUI/CLI transactions on one serial Dispatch lane.
The UI admits an edit without waiting for disk. A load or watch publication
checks the admitted edit generation before changing shared state. Startup gates
configuration-dependent views and effects until loading succeeds; a parse error
must not normalize an empty seed over the user's file.

Durable changes retain the raw revision through asynchronous preparation. They
perform the coordinated compare-and-swap off-main, then publish under a short
shared-state lock on the main actor if the reviewed value is still current.
Failed publication restores the displaced file using inode/revision ownership;
unverified recovery bytes must never be deleted. No UI reader waits on the I/O
lock. The worker may synchronously request a short main-actor publication, so
main-actor code must never synchronously wait for the persistence lane.

Session-only profile changes do not rewrite TOML. Normal application termination
awaits already-admitted configuration writes and reports a failed write before
allowing an explicit quit-without-saving choice. This does not cover crashes,
forced termination, or writes not yet submitted by an effect.

Layout and session actors use `DispatchSerialQueue` executors so their complete
read/modify/write operations remain serial without occupying the cooperative
pool. A failed write does not advance the successful-write cache. App icon
loading, application metadata, bundled documents, and CLI filesystem/admin
operations also use blocking workers; AppKit panels remain on the main actor.
Only immutable icon bitmaps cross into SwiftUI.

## Pointer input

FFM captures events without a timed throttle. One WindowServer read may be in
flight while one latest pointer sample is retained; completion hit-tests that
latest sample even if movement has stopped. A native event window ID skips
repeat scans within the already-selected normal window. Modifier suspension,
teardown, returning to the current window, and programmatic cursor warps revoke
obsolete work. WindowServer/display reads never run inside the event callback.

## Floating presentation

Hover reveals the real always-on-top window without independently requesting
keyboard focus. The FFM event path owns mouse-driven focus policy; clicking uses
the common focus pipeline. Both window-specific and first-app focus preparation
restore mirrors before moving focus. WindowServer identity, geometry, layer, and
opacity evidence replaces a fixed pre-focus delay. This is presentation-state
evidence, not proof of the user's final display scanout.

A source handover fades the mirror only after the real window is visible at the
matching frame above overlapping normal surfaces. Capture restart completions
belong to one stream instance and request token. Superseded callbacks must not
show or hide a replacement mirror with the same window key.

## Validation

Verify both isolation and behavior. A blocked-worker test must allow the main
actor to progress. Exercise workspace switches, native app invocation,
window cycling, native tabs, and floating mirrors. Use Instruments for main
thread stalls; a CLI completion measurement does not measure final rendering.
