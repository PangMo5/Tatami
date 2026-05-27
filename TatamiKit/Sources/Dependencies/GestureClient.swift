import AppKit
import Dependencies
import OSLog

/// Three-finger horizontal trackpad swipes, surfaced as a stream of
/// directions. Ported from FlashSpace's SwipeManager (itself based on
/// SwipeAeroSpace): a CGEvent tap on gesture events accumulates per-touch
/// distance and fires when the combined movement crosses a threshold.
public struct GestureClient: Sendable {
  public var start: @Sendable (_ fingerCount: Int, _ threshold: Double) async -> Void
  public var stop: @Sendable () async -> Void
  public var events: @Sendable () -> AsyncStream<SwipeDirection>

  public init(
    start: @escaping @Sendable (_ fingerCount: Int, _ threshold: Double) async -> Void,
    stop: @escaping @Sendable () async -> Void,
    events: @escaping @Sendable () -> AsyncStream<SwipeDirection>
  ) {
    self.start = start
    self.stop = stop
    self.events = events
  }
}

public enum SwipeDirection: Sendable, Hashable {
  case left, right
}

extension GestureClient: DependencyKey {
  public static let liveValue: GestureClient = {
    let center = SwipeCenter()
    return GestureClient(
      start: { fingers, threshold in await center.start(fingerCount: fingers, threshold: threshold) },
      stop: { await center.stop() },
      events: { center.events }
    )
  }()

  public static let testValue = GestureClient(
    start: { _, _ in },
    stop: {},
    events: { AsyncStream { _ in } }
  )
  public static let previewValue = testValue
}

extension DependencyValues {
  public var gestures: GestureClient {
    get { self[GestureClient.self] }
    set { self[GestureClient.self] = newValue }
  }
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "Gestures")

private struct UncheckedEvent: @unchecked Sendable {
  let value: NSEvent
}

/// Owns the CGEvent tap + per-touch accumulation. Lives on the main run
/// loop (the tap source is added there).
private final class SwipeCenter: @unchecked Sendable {
  let events: AsyncStream<SwipeDirection>
  private let continuation: AsyncStream<SwipeDirection>.Continuation

  private enum State { case idle, inProgress, ended }

  private var eventTap: CFMachPort?
  private var threshold: Double = 0.3
  private var fingerCount = 3
  private var state: State = .ended
  private var xDistance: [ObjectIdentifier: CGFloat] = [:]
  private var prevPositions: [ObjectIdentifier: NSPoint] = [:]
  private var lastTouchDate = Date.distantPast

  init() {
    var c: AsyncStream<SwipeDirection>.Continuation!
    self.events = AsyncStream(bufferingPolicy: .bufferingNewest(4)) { c = $0 }
    self.continuation = c
  }

  @MainActor
  func start(fingerCount: Int, threshold: Double) {
    self.threshold = threshold
    self.fingerCount = max(2, min(4, fingerCount))
    guard eventTap == nil else { return }

    let mask = NSEvent.EventTypeMask.gesture.rawValue
    let tap = CGEvent.tapCreate(
      tap: .cghidEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: mask,
      callback: { _, type, cgEvent, _ in
        SwipeCenter.shared?.handle(type: type, event: cgEvent)
        return Unmanaged.passUnretained(cgEvent)
      },
      userInfo: nil
    )
    guard let tap else {
      logger.warning("gesture tap creation failed (accessibility?)")
      return
    }
    eventTap = tap
    SwipeCenter.shared = self
    let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    logger.info("gesture tap started")
  }

  @MainActor
  func stop() {
    guard let tap = eventTap else { return }
    CGEvent.tapEnable(tap: tap, enable: false)
    CFMachPortInvalidate(tap)
    eventTap = nil
    if SwipeCenter.shared === self { SwipeCenter.shared = nil }
    logger.info("gesture tap stopped")
  }

  // C callbacks can't capture context cleanly; route through a shared
  // pointer (only one tap exists at a time). The tap fires on the main
  // run loop, so access is effectively main-isolated. Mirrors FlashSpace.
  nonisolated(unsafe) static weak var shared: SwipeCenter?

  fileprivate func handle(type: CGEventType, event: CGEvent) {
    if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
      if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
      return
    }
    guard type.rawValue == NSEvent.EventType.gesture.rawValue,
          let nsEvent = NSEvent(cgEvent: event)
    else { return }
    // The tap fires on the main run loop, so it's safe to hop isolation
    // with the event; box it to satisfy strict concurrency.
    let boxed = UncheckedEvent(value: nsEvent)
    MainActor.assumeIsolated { handleGesture(boxed.value) }
  }

  @MainActor
  private func handleGesture(_ nsEvent: NSEvent) {
    let touches = nsEvent.allTouches()
      .filter { !$0.isResting && $0.phase != .stationary }

    if touches.isEmpty || Date().timeIntervalSince(lastTouchDate) > 0.8 {
      state = .idle
    }
    guard touches.count >= fingerCount else { return }

    if state == .idle {
      state = .inProgress
      xDistance = [:]
      prevPositions = [:]
    }
    guard state == .inProgress else { return }
    lastTouchDate = Date()

    for touch in touches {
      let id = ObjectIdentifier(touch.identity)
      if let prev = prevPositions[id] {
        xDistance[id, default: 0] += touch.normalizedPosition.x - prev.x
      }
      prevPositions[id] = touch.normalizedPosition
    }

    let swipes = xDistance.values
    guard swipes.count == fingerCount else { return }
    let allRight = swipes.allSatisfy { $0 > 0 }
    let allLeft = swipes.allSatisfy { $0 < 0 }
    let perFinger = threshold / (Double(swipes.count) + 2.0)
    guard swipes.allSatisfy({ abs($0) > perFinger }),
          abs(swipes.reduce(0, +)) >= threshold,
          allLeft || allRight
    else { return }

    state = .ended
    continuation.yield(allRight ? .right : .left)
  }
}
