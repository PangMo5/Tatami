import AppKit
import ApplicationServices
import Dependencies
import DependenciesMacros
import OSLog

/// Horizontal trackpad swipes, surfaced as a stream of directions.
///
/// Built on the public `NSEvent.gesture` event tap. The recognizer tracks
/// each active touch's displacement from where the gesture began and fires
/// once the combined horizontal movement crosses a threshold while every
/// finger agrees on direction.
@DependencyClient
struct GestureClient: Sendable {
  var start: @Sendable (_ fingerCount: Int, _ threshold: Double) async -> Void
  var stop: @Sendable () async -> Void
  var events: @Sendable () -> AsyncStream<SwipeDirection> = { AsyncStream { _ in } }
}

public enum SwipeDirection: Sendable, Hashable {
  case left, right
}

extension GestureClient: DependencyKey {
  static let liveValue: GestureClient = {
    @Dependency(\.debugLog) var debugLog
    let recognizer = HorizontalSwipeRecognizer(debugLog: debugLog)
    return GestureClient(
      start: { fingers, threshold in
        await recognizer.start(fingers: fingers, threshold: threshold)
      },
      stop: { await recognizer.stop() },
      events: { recognizer.directions }
    )
  }()

  static let testValue = GestureClient(
    start: { _, _ in },
    stop: {},
    events: { AsyncStream { _ in } }
  )
  static let previewValue = testValue
}

extension DependencyValues {
  var gestures: GestureClient {
    get { self[GestureClient.self] }
    set { self[GestureClient.self] = newValue }
  }
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "Gestures")

/// Recognizes multi-finger horizontal swipes from the HID gesture tap.
///
/// The active tap is serviced on `EventTapThread`, not the main run loop: an
/// active `.defaultTap` sits in-line in the shared HID stream, so if the run
/// loop servicing it ever stalls the kernel holds *all* system input until the
/// tap watchdog fires (seconds) — and Tatami's main thread does block on
/// Accessibility IPC (notably right after AX is revoked at runtime, where the
/// blocking call outlives the stale `AXIsProcessTrusted` cache). Servicing the
/// tap off-main means a blocked main thread can never freeze system input. The
/// AppKit decode (`NSEvent(cgEvent:)` + `allTouches()`) still hops to the main
/// actor, where it's safe. `tap`/`runLoopSource` are touched only on the tap
/// thread and the recognizer state only on the main actor, so both stay
/// lock-free with no shared mutable access.
private final class HorizontalSwipeRecognizer: @unchecked Sendable {
  let directions: AsyncStream<SwipeDirection>
  private let emit: AsyncStream<SwipeDirection>.Continuation

  /// Per-touch horizontal travel measured from the gesture's first sample.
  private struct Travel {
    let origin: CGFloat
    var current: CGFloat
    var displacement: CGFloat { current - origin }
  }

  private let debugLog: DebugLogClient

  /// Tap state — touched only on `EventTapThread` (install / teardown / the
  /// re-enable inside the callback).
  private var tap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?

  /// Recognizer config + state — touched only on the main actor.
  private var requiredFingers = 3
  private var threshold = 0.3
  private var travelByTouch: [ObjectIdentifier: Travel] = [:]
  private var didFireForCurrentGesture = false
  private var lastSampleAt = Date.distantPast

  /// A new gesture starts once the touchpad has been quiet this long.
  private let restGap: TimeInterval = 0.8

  init(debugLog: DebugLogClient) {
    self.debugLog = debugLog
    var continuation: AsyncStream<SwipeDirection>.Continuation!
    self.directions = AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation = $0 }
    self.emit = continuation
  }

  @MainActor
  func start(fingers: Int, threshold: Double) {
    self.requiredFingers = min(max(fingers, 2), 4)
    self.threshold = threshold
    debugLog.log("Gesture", "start fingers=\(requiredFingers) threshold=\(self.threshold)")
    EventTapThread.shared.perform { [self] in installTap() }
  }

  @MainActor
  func stop() {
    EventTapThread.shared.perform { [self] in teardownTap() }
    reset()
  }

  /// Runs on `EventTapThread`. Creates the active gesture tap and attaches its
  /// source to that thread's run loop so the shared HID stream is serviced
  /// off-main.
  private func installTap() {
    guard tap == nil else { return }
    let context = Unmanaged.passUnretained(self).toOpaque()
    // ACTIVE tap (`.defaultTap`), deliberately not `.listenOnly`: TCC gates
    // active taps on Accessibility but listen-only taps on Input Monitoring —
    // any listen-only tapCreate (regardless of mask or location) pops the
    // "receive keystrokes from any application" warning and, once that entry
    // exists denied, fails even with Accessibility granted. Active taps are the
    // skhd / yabai model. The callback passes every event through unmodified
    // and the mask is gesture-only, so it never touches clicks or keys.
    let created = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: NSEvent.EventTypeMask.gesture.rawValue,
      callback: { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let recognizer = Unmanaged<HorizontalSwipeRecognizer>
          .fromOpaque(context)
          .takeUnretainedValue()
        recognizer.consume(type: type, event: event)
        return Unmanaged.passUnretained(event)
      },
      userInfo: context
    )
    guard let created else {
      logger.warning("gesture tap creation failed (accessibility?)")
      debugLog.log("Gesture", "tap create FAILED (accessibility?)")
      return
    }
    guard let source = CFMachPortCreateRunLoopSource(nil, created, 0) else { return }
    tap = created
    runLoopSource = source
    EventTapThread.shared.addSource(source)
    CGEvent.tapEnable(tap: created, enable: true)
    debugLog.log("Gesture", "tap installed (active, on event-tap thread)")
  }

  /// Runs on `EventTapThread`. Disables + detaches the tap.
  private func teardownTap() {
    guard let tap else { return }
    CGEvent.tapEnable(tap: tap, enable: false)
    if let runLoopSource { EventTapThread.shared.removeSource(runLoopSource) }
    CFMachPortInvalidate(tap)
    self.tap = nil
    self.runLoopSource = nil
    debugLog.log("Gesture", "tap stopped")
  }

  /// C-callback entry point, invoked on `EventTapThread`. Re-enables the tap if
  /// the system disabled it; otherwise hops the AppKit decode + fold onto the
  /// main actor. The hop is async so the callback returns the event
  /// immediately — a stalled main thread just queues these, it never holds the
  /// shared HID stream.
  fileprivate func consume(type: CGEventType, event: CGEvent) {
    if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
      // After an AX revoke the system disables active taps; re-enabling fights
      // it and the oscillation wedges the shared HID stream (system-wide input
      // freeze — see #8). Re-enable only while still trusted, else tear down.
      guard AXIsProcessTrusted() else {
        debugLog.log("Gesture", "tap disabled + AX untrusted — tearing down")
        teardownTap()
        return
      }
      debugLog.log("Gesture", "tap disabled by system (\(type.rawValue)) — re-enabling")
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return
    }
    guard type.rawValue == NSEvent.EventType.gesture.rawValue,
          let copy = event.copy()
    else { return }
    let boxed = UncheckedCGEvent(copy)
    DispatchQueue.main.async { [weak self] in
      guard let self, let nsEvent = NSEvent(cgEvent: boxed.value) else { return }
      MainActor.assumeIsolated { self.ingest(nsEvent) }
    }
  }

  @MainActor
  private func ingest(_ event: NSEvent) {
    let touches = event.allTouches().filter {
      !$0.isResting && $0.phase != .stationary
    }

    // No fingers down (or a long pause) ends the current gesture.
    if touches.isEmpty || Date().timeIntervalSince(lastSampleAt) > restGap {
      reset()
    }
    guard touches.count >= requiredFingers else { return }
    lastSampleAt = Date()

    for touch in touches {
      let id = ObjectIdentifier(touch.identity)
      let x = touch.normalizedPosition.x
      if travelByTouch[id] == nil {
        travelByTouch[id] = Travel(origin: x, current: x)
      } else {
        travelByTouch[id]?.current = x
      }
    }

    guard !didFireForCurrentGesture,
          travelByTouch.count == requiredFingers,
          let direction = resolveDirection()
    else { return }

    didFireForCurrentGesture = true
    debugLog.log("Gesture", "swipe \(direction) fired (fingers=\(travelByTouch.count))")
    emit.yield(direction)
  }

  /// Returns a direction only when every finger has moved the same way and
  /// the summed travel clears the threshold. A small per-finger floor
  /// rejects incidental jitter where one finger barely drifts.
  @MainActor
  private func resolveDirection() -> SwipeDirection? {
    let displacements = travelByTouch.values.map(\.displacement)
    let perFingerFloor = threshold * 0.3
    let total = displacements.reduce(0, +)

    if displacements.allSatisfy({ $0 > perFingerFloor }), total >= threshold {
      return .right
    }
    if displacements.allSatisfy({ $0 < -perFingerFloor }), -total >= threshold {
      return .left
    }
    return nil
  }

  @MainActor
  private func reset() {
    // "Why didn't my swipe fire" tell: a gesture that tracked touches but
    // never fired logs what the recognizer saw — wrong finger count or a
    // total that fell short of the threshold. Gated: per-gesture, but the
    // summary string is only worth building while a trace is being taken.
    if !travelByTouch.isEmpty, !didFireForCurrentGesture, debugLog.isEnabled() {
      let total = travelByTouch.values.map(\.displacement).reduce(0, +)
      debugLog.log(
        "Gesture",
        "gesture ended without fire: fingers=\(travelByTouch.count)/\(requiredFingers) "
          + "total=\(String(format: "%.3f", total)) threshold=\(threshold)"
      )
    }
    travelByTouch.removeAll(keepingCapacity: true)
    didFireForCurrentGesture = false
  }

  /// Ferries a non-Sendable `CGEvent` from the tap-thread callback onto the
  /// main actor, where it's decoded into an `NSEvent`.
  private struct UncheckedCGEvent: @unchecked Sendable {
    let value: CGEvent
    init(_ value: CGEvent) { self.value = value }
  }
}
