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

An asynchronous `hide()` acknowledgement releases temporary suppression when
`didHideApplication` confirms the app is hidden. A pending hide must not turn
into a permanent exclusion for an app that had no elevated controls.

## Audit boundary

The window interaction paths use worker-based reads: process resolution,
workspace visibility, AX discovery/focus/geometry, visibility reconciliation,
window cycling, HUD titles, floating-mirror verification, and changelog loading.
Layout/session persistence and debug logging already have isolated writers.

Configuration persistence still has a separate ownership constraint:
`TatamiConfigKey` initial loading/saving and durable `ConfigPersistenceClient`
transactions are synchronous. The transaction holds the shared configuration
lock while performing an atomic compare-and-swap. Moving that function to a
worker alone would still make main-actor readers wait for the shared lock.
Changing this requires coordinating **all** config writers and testing
concurrent UI edits, CLI commits, external file writes, and rollback behavior;
do not weaken those guarantees just to label the function asynchronous.

## Validation

Verify both isolation and behavior. A blocked-worker test must allow the main
actor to progress. Exercise workspace switches, native app invocation,
window cycling, native tabs, and floating mirrors. Use Instruments for main
thread stalls; a CLI completion measurement does not measure final rendering.
