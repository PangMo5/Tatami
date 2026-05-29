import CoreFoundation
import Foundation

/// A single, process-lifetime background thread that runs its own
/// `CFRunLoop`. `CGEventTap` run-loop sources are attached here instead of
/// to the main run loop, so the per-event work the taps do — window
/// hit-testing via `CGWindowListCopyWindowInfo`, throttle bookkeeping —
/// runs off the main thread. Only the side effects that genuinely require
/// the main actor (AppKit / Accessibility focus changes) hop back via
/// `MainActor`. This mirrors how yabai isolates its event tap from the UI.
///
/// One shared thread (rather than one per tap) keeps every tap callback
/// serialized on a single run loop — which is exactly the isolation each
/// tap controller relied on when its source lived on the main run loop, so
/// a controller's mutable state can stay lock-free as long as it is only
/// touched from this thread (install/teardown via `perform`, plus the tap
/// callback itself).
final class EventTapThread: @unchecked Sendable {
  static let shared = EventTapThread()

  /// The thread's run loop, captured once the thread is up. Written once
  /// during startup and only read afterwards (readers wait on `ready`),
  /// so the unsynchronized access is sound.
  private nonisolated(unsafe) var runLoop: CFRunLoop!
  private let ready = DispatchSemaphore(value: 0)

  private init() {
    let thread = Thread { [self] in
      runLoop = CFRunLoopGetCurrent()
      // A CFRunLoop with no input sources returns immediately from `run`.
      // Keep it alive with a no-op Mach port for the process lifetime.
      RunLoop.current.add(NSMachPort(), forMode: .common)
      ready.signal()
      RunLoop.current.run()
    }
    thread.name = "dev.PangMo5.Tatami.event-tap"
    thread.qualityOfService = .userInteractive
    thread.start()
    // One-time, sub-millisecond wait at first tap install so `addSource` /
    // `perform` can't race the run loop coming up.
    ready.wait()
  }

  /// Attach a run-loop source (e.g. a `CGEventTap`'s) to this thread.
  func addSource(_ source: CFRunLoopSource) {
    CFRunLoopAddSource(runLoop, source, .commonModes)
    CFRunLoopWakeUp(runLoop)
  }

  /// Detach a previously attached run-loop source.
  func removeSource(_ source: CFRunLoopSource) {
    CFRunLoopRemoveSource(runLoop, source, .commonModes)
    CFRunLoopWakeUp(runLoop)
  }

  /// Schedule `work` to run on the event-tap thread. Tap install/teardown
  /// is routed through here so it mutates controller state from the same
  /// isolation as the tap callback (this thread) — no locks needed.
  func perform(_ work: @escaping @Sendable () -> Void) {
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, work)
    CFRunLoopWakeUp(runLoop)
  }
}
