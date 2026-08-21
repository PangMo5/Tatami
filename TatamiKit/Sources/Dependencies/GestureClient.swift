// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Dependencies
import DependenciesMacros
import OSLog

/// Three- and four-finger trackpad swipes, surfaced as a stream of gestures.
///
/// Built on the public `NSEvent.gesture` event tap. The recognizer tracks
/// each active touch's displacement from where the gesture began and fires
/// once the dominant-axis movement crosses a threshold while every finger
/// agrees on direction.
@DependencyClient
struct GestureClient: Sendable {
  var start: @Sendable (_ threshold: Double) async -> Void
  var stop: @Sendable () async -> Void
  var events: @Sendable () -> AsyncStream<TrackpadGesture> = { AsyncStream { _ in } }
}

extension GestureClient: DependencyKey {
  static let liveValue: GestureClient = {
    let recognizer = TrackpadSwipeRecognizer()
    return GestureClient(
      start: { threshold in
        await recognizer.start(threshold: threshold)
      },
      stop: { await recognizer.stop() },
      events: { recognizer.gestures }
    )
  }()

  static let testValue = GestureClient(
    start: { _ in },
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
private final class TrackpadSwipeRecognizer: @unchecked Sendable {
  let gestures: AsyncStream<TrackpadGesture>
  private let emit: AsyncStream<TrackpadGesture>.Continuation

  /// Per-touch travel measured from the gesture's first coherent sample.
  private struct Travel {
    let origin: CGPoint
    var current: CGPoint
    var displacement: CGVector {
      CGVector(dx: current.x - origin.x, dy: current.y - origin.y)
    }
  }

  @Dependency(\.debugLog) private var debugLog

  private var tap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var threshold = 0.3

  private var travelByTouch: [ObjectIdentifier: Travel] = [:]
  private var activeFingerCount: Int?
  private var didFireForCurrentGesture = false
  private var lastSampleAt = Date.distantPast

  /// A new gesture starts once the touchpad has been quiet this long.
  private let restGap: TimeInterval = 0.8

  init() {
    var continuation: AsyncStream<TrackpadGesture>.Continuation!
    self.gestures = AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation = $0 }
    self.emit = continuation
  }

  @MainActor
  func start(threshold: Double) {
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
        let recognizer = Unmanaged<TrackpadSwipeRecognizer>
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
    tap = created
    let source = CFMachPortCreateRunLoopSource(nil, created, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    runLoopSource = source
    CGEvent.tapEnable(tap: created, enable: true)
    debugLog.log(
      "Gesture",
      "tap started fingers=3,4 threshold=\(threshold)"
    )
  }

  @MainActor
  func stop() {
    guard let tap else { return }
    CGEvent.tapEnable(tap: tap, enable: false)
    // Remove the source explicitly (matches BorrowChordTap/MirrorClickTap);
    // relying on `CFMachPortInvalidate` to implicitly drop it left the run
    // loop holding the source until its next prune.
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }
    CFMachPortInvalidate(tap)
    self.tap = nil
    runLoopSource = nil
    reset()
    debugLog.log("Gesture", "tap stopped")
  }

  /// C-callback entry point. Re-enables the tap if the system disabled it,
  /// otherwise folds the gesture event in — directly, on the caller's thread.
  ///
  /// The tap source is added to `CFRunLoopGetMain()` (see `start`), so this
  /// callout already runs on the main thread and `ingest` (incl. AppKit's
  /// `allTouches()`, which is main-only) is safe. We deliberately do NOT wrap
  /// it in `MainActor.assumeIsolated`: evaluated 60–120×/sec under a fast swipe
  /// that executor-identity check faulted (`swift_task_isCurrentExecutor`) on
  /// macOS 26. The other CGEvent taps (BorrowChordClient/MirrorClickTap) also
  /// handle events straight in the callout with no actor hop.
  fileprivate func consume(type: CGEventType, event: CGEvent) {
    if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
      debugLog.log("Gesture", "tap disabled by system (\(type.rawValue)) — re-enabling")
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return
    }
    guard type.rawValue == NSEvent.EventType.gesture.rawValue,
          let nsEvent = NSEvent(cgEvent: event)
    else { return }
    ingest(nsEvent)
  }

  private func ingest(_ event: NSEvent) {
    let touches = event.allTouches().filter {
      !$0.isResting && $0.phase != .ended && $0.phase != .cancelled
    }

    // No fingers down (or a long pause) ends the current gesture.
    if touches.isEmpty || Date().timeIntervalSince(lastSampleAt) > restGap {
      reset()
    }
    // After firing, wait for the entire touch sequence to end. Finger lift
    // samples must not turn one physical swipe into a second gesture.
    lastSampleAt = Date()
    guard !didFireForCurrentGesture else { return }
    guard touches.count == 3 || touches.count == 4 else {
      clearTracking()
      return
    }

    let touchIDs = Set(touches.map { ObjectIdentifier($0.identity) })
    let trackedIDs = Set(travelByTouch.keys)
    if activeFingerCount != touches.count || (!trackedIDs.isEmpty && trackedIDs != touchIDs) {
      beginTracking(touches)
      return
    }

    for touch in touches {
      let id = ObjectIdentifier(touch.identity)
      let position = touch.normalizedPosition
      if travelByTouch[id] == nil {
        travelByTouch[id] = Travel(origin: position, current: position)
      } else {
        travelByTouch[id]?.current = position
      }
    }

    guard let fingerCount = activeFingerCount,
          travelByTouch.count == fingerCount,
          let direction = GestureDirection.resolve(
            displacements: travelByTouch.values.map(\.displacement),
            threshold: threshold
          )
    else { return }

    didFireForCurrentGesture = true
    debugLog.log("Gesture", "swipe \(direction) fired (fingers=\(fingerCount))")
    emit.yield(TrackpadGesture(fingerCount: fingerCount, direction: direction))
  }

  private func beginTracking(_ touches: Set<NSTouch>) {
    clearTracking()
    activeFingerCount = touches.count
    for touch in touches {
      let position = touch.normalizedPosition
      travelByTouch[ObjectIdentifier(touch.identity)] = Travel(
        origin: position,
        current: position
      )
    }
  }

  private func clearTracking() {
    travelByTouch.removeAll(keepingCapacity: true)
    activeFingerCount = nil
  }

  private func reset() {
    // "Why didn't my swipe fire" tell: a gesture that tracked touches but
    // never fired logs what the recognizer saw — wrong finger count or a
    // total that fell short of the threshold. Gated: per-gesture, but the
    // summary string is only worth building while a trace is being taken.
    if !travelByTouch.isEmpty, !didFireForCurrentGesture, debugLog.isEnabled() {
      let total = travelByTouch.values.map(\.displacement).reduce(CGVector.zero) {
        CGVector(dx: $0.dx + $1.dx, dy: $0.dy + $1.dy)
      }
      debugLog.log(
        "Gesture",
        "gesture ended without fire: fingers=\(travelByTouch.count) "
          + "total=(\(String(format: "%.3f", total.dx)),"
          + "\(String(format: "%.3f", total.dy))) threshold=\(threshold)"
      )
    }
    clearTracking()
    didFireForCurrentGesture = false
  }
}

extension GestureDirection {
  /// Pure dominant-axis resolution shared by the live recognizer and tests.
  /// Requiring every finger to clear a small same-direction floor rejects
  /// palms/jitter without making diagonal swipes fire twice.
  static func resolve(
    displacements: [CGVector],
    threshold: Double
  ) -> Self? {
    guard !displacements.isEmpty else { return nil }
    let floor = CGFloat(threshold * 0.3)
    let total = displacements.reduce(CGVector.zero) {
      CGVector(dx: $0.dx + $1.dx, dy: $0.dy + $1.dy)
    }

    if abs(total.dx) >= abs(total.dy) {
      if displacements.allSatisfy({ $0.dx > floor }), total.dx >= threshold {
        return .right
      }
      if displacements.allSatisfy({ $0.dx < -floor }), -total.dx >= threshold {
        return .left
      }
    } else {
      if displacements.allSatisfy({ $0.dy > floor }), total.dy >= threshold {
        return .up
      }
      if displacements.allSatisfy({ $0.dy < -floor }), -total.dy >= threshold {
        return .down
      }
    }
    return nil
  }
}
