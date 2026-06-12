import AppKit
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
    let recognizer = HorizontalSwipeRecognizer()
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
/// The tap source lives on the main run loop, so all mutable state is
/// touched only from the main actor. The C callback receives `self` via
/// the tap's `userInfo` pointer (no global shared instance).
///
/// Deliberately NOT moved to `EventTapThread`: decoding the touches
/// requires `NSEvent(cgEvent:)` + `allTouches()`, and AppKit gives no
/// off-main-thread guarantee for either — the main-thread cost is only
/// paid while the (off-by-default) gesture setting is on.
private final class HorizontalSwipeRecognizer: @unchecked Sendable {
  let directions: AsyncStream<SwipeDirection>
  private let emit: AsyncStream<SwipeDirection>.Continuation

  /// Per-touch horizontal travel measured from the gesture's first sample.
  private struct Travel {
    let origin: CGFloat
    var current: CGFloat
    var displacement: CGFloat { current - origin }
  }

  private var tap: CFMachPort?
  private var requiredFingers = 3
  private var threshold = 0.3

  private var travelByTouch: [ObjectIdentifier: Travel] = [:]
  private var didFireForCurrentGesture = false
  private var lastSampleAt = Date.distantPast

  /// A new gesture starts once the touchpad has been quiet this long.
  private let restGap: TimeInterval = 0.8

  init() {
    var continuation: AsyncStream<SwipeDirection>.Continuation!
    self.directions = AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation = $0 }
    self.emit = continuation
  }

  @MainActor
  func start(fingers: Int, threshold: Double) {
    self.requiredFingers = min(max(fingers, 2), 4)
    self.threshold = threshold
    guard tap == nil else { return }

    let context = Unmanaged.passUnretained(self).toOpaque()
    // ACTIVE tap (`.defaultTap`), deliberately not `.listenOnly`: TCC
    // gates active taps on Accessibility but listen-only taps on Input
    // Monitoring — any listen-only tapCreate (regardless of mask or tap
    // location) pops the "receive keystrokes from any application"
    // warning and lists the app under Privacy → Input Monitoring; once
    // that entry exists *denied*, listen-only taps fail even with
    // Accessibility granted (FFM died with it). Active taps are the
    // skhd / yabai model. The callback passes every event through
    // unmodified, and the mask is gesture-only, so a stalled callback
    // can at worst delay gesture events — clicks and keys never route
    // through here.
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
      return
    }
    tap = created
    let source = CFMachPortCreateRunLoopSource(nil, created, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: created, enable: true)
    logger.info("gesture tap started")
  }

  @MainActor
  func stop() {
    guard let tap else { return }
    CGEvent.tapEnable(tap: tap, enable: false)
    CFMachPortInvalidate(tap)
    self.tap = nil
    reset()
    logger.info("gesture tap stopped")
  }

  /// C-callback entry point. Re-enables the tap if the system disabled it,
  /// otherwise hops to the main actor to fold the gesture event in.
  fileprivate func consume(type: CGEventType, event: CGEvent) {
    if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return
    }
    guard type.rawValue == NSEvent.EventType.gesture.rawValue,
          let nsEvent = NSEvent(cgEvent: event)
    else { return }
    let boxed = Unchecked(nsEvent)
    MainActor.assumeIsolated { ingest(boxed.value) }
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
    travelByTouch.removeAll(keepingCapacity: true)
    didFireForCurrentGesture = false
  }

  /// Ferries a non-Sendable `NSEvent` across the (already main-bound)
  /// isolation hop from the C callback.
  private struct Unchecked: @unchecked Sendable {
    let value: NSEvent
    init(_ value: NSEvent) { self.value = value }
  }
}
