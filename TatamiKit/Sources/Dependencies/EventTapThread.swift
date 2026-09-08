// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreFoundation
import Foundation

/// A single, process-lifetime background thread that runs its own
/// `CFRunLoop`. `CGEventTap` run-loop sources are attached here instead of
/// to the main run loop, so the per-event work the taps do — window
/// input capture and latest-sample bookkeeping —
/// runs off the main thread. Only AppKit identity and UI state hop back via
/// `MainActor`; timeout-prone Accessibility focus messaging stays on its own
/// worker. This mirrors how yabai isolates its event tap from the UI.
///
/// One shared thread (rather than one per tap) keeps every tap callback
/// serialized on a single run loop — which is exactly the isolation each
/// tap controller relied on when its source lived on the main run loop, so
/// a controller's mutable state can stay lock-free as long as it is only
/// touched from this thread (install/teardown via `perform`, plus the tap
/// callback itself).
final class EventTapThread: @unchecked Sendable {

  // MARK: Lifecycle

  private init() {
    let thread = Thread { [self] in
      let workerRunLoop = CFRunLoopGetCurrent()
      // A CFRunLoop with no input sources returns immediately from `run`.
      // Keep it alive with a no-op Mach port for the process lifetime.
      RunLoop.current.add(NSMachPort(), forMode: .common)
      schedulingLock.withLock {
        for operation in pendingOperations {
          CFRunLoopPerformBlock(workerRunLoop, CFRunLoopMode.commonModes.rawValue, operation)
        }
        pendingOperations.removeAll(keepingCapacity: true)
        runLoop = workerRunLoop
      }
      RunLoop.current.run()
    }
    thread.name = "dev.PangMo5.Tatami.event-tap"
    thread.qualityOfService = .userInteractive
    thread.start()
  }

  // MARK: Internal

  static let shared = EventTapThread()

  /// Attach a run-loop source (e.g. a `CGEventTap`'s) to this thread.
  func addSource(_ source: CFRunLoopSource) {
    let transfer = SourceTransfer(source: source)
    perform { CFRunLoopAddSource(CFRunLoopGetCurrent(), transfer.source, .commonModes) }
  }

  /// Detach a previously attached run-loop source.
  func removeSource(_ source: CFRunLoopSource) {
    let transfer = SourceTransfer(source: source)
    perform { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), transfer.source, .commonModes) }
  }

  /// Schedule `work` to run on the event-tap thread. Tap install/teardown
  /// is routed through here so it mutates controller state from the same
  /// isolation as the tap callback (this thread) — no locks needed.
  func perform(_ work: @escaping @Sendable () -> Void) {
    let workerRunLoop = schedulingLock.withLock { () -> CFRunLoop? in
      guard let runLoop else {
        pendingOperations.append(work)
        return nil
      }
      CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, work)
      return runLoop
    }
    if let workerRunLoop { CFRunLoopWakeUp(workerRunLoop) }
  }

  // MARK: Private

  /// Retains a CF source across admission; attachment and removal both execute
  /// on the event thread, and the wrapper never mutates its reference.
  private struct SourceTransfer: @unchecked Sendable {
    let source: CFRunLoopSource
  }

  /// Startup admission is buffered; UI callers never wait for thread creation.
  private let schedulingLock = NSLock()
  private var runLoop: CFRunLoop?
  private var pendingOperations = [@Sendable () -> Void]()

}
