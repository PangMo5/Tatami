// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ApplicationServices
import Dependencies
import OSLog

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "FloatingOverlay")

// MARK: - MirrorInputEventOrigin

/// Carries source-window identity through replay without stamping a stale
/// WindowServer route. Consumers can identify the gesture even after its lease
/// ended; live registry state and mouse-up hit-testing are not its origin.
enum MirrorInputEventOrigin {
  static func tag(windowID: CGWindowID?) -> Int64 {
    prefix | Int64(windowID ?? 0)
  }

  static func isReplay(_ event: CGEvent) -> Bool {
    event.getIntegerValueField(.eventSourceUserData) & mask == prefix
  }

  static func windowID(_ event: CGEvent) -> CGWindowID? {
    guard isReplay(event) else { return nil }
    let id = CGWindowID(truncatingIfNeeded: event.getIntegerValueField(.eventSourceUserData))
    return id == 0 ? nil : id
  }

  private static let prefix: Int64 = 0x5441544100000000
  private static let mask: Int64 = -0x100000000
}

// MARK: - MirrorInputBuffer

/// FIFO input retained while a mirror gives its native window the gesture.
/// Events and button ownership stay on EventTapThread, including replay echoes.
struct MirrorInputBuffer {

  // MARK: Internal

  private(set) var pressedButtons = Set<Int64>()
  private(set) var buttonEventNumbers = [Int64: Int64]()
  private(set) var pressedKeys = Set<CGKeyCode>()

  var isEmpty: Bool {
    head == events.count
  }

  var count: Int {
    events.count - head
  }

  mutating func append(_ event: CGEvent) -> Bool {
    guard count < 4096, let copy = event.copy() else { return false }
    events.append(copy)
    return true
  }

  mutating func popFirst() -> CGEvent? {
    guard !isEmpty else { return nil }
    let event = events[head]
    head += 1
    if isEmpty {
      events.removeAll(keepingCapacity: true)
      head = 0
    } else if head >= 256 {
      events.removeFirst(head)
      head = 0
    }
    return event
  }

  mutating func delivered(_ event: CGEvent) {
    let button = event.getIntegerValueField(.mouseEventButtonNumber)
    switch event.type {
    case .leftMouseDown,
         .rightMouseDown,
         .otherMouseDown:
      pressedButtons.insert(button)
      buttonEventNumbers[button] = event.getIntegerValueField(.mouseEventNumber)

    case .leftMouseUp,
         .rightMouseUp,
         .otherMouseUp:
      pressedButtons.remove(button)
      buttonEventNumbers[button] = nil

    case .keyDown:
      pressedKeys.insert(CGKeyCode(clamping: event.getIntegerValueField(.keyboardEventKeycode)))

    case .keyUp:
      pressedKeys.remove(CGKeyCode(clamping: event.getIntegerValueField(.keyboardEventKeycode)))

    default:
      break
    }
  }

  mutating func releaseKeyboardTracking() {
    pressedKeys.removeAll()
  }

  mutating func reset() {
    events.removeAll(keepingCapacity: true)
    head = 0
    pressedButtons.removeAll()
    buttonEventNumbers.removeAll()
    pressedKeys.removeAll()
  }

  // MARK: Private

  private var events = [CGEvent]()
  private var head = 0

}

/// Retain the complete HID packet, including its native event number, device
/// provenance, and opaque input metadata. Reconstructing a CG mouse event from
/// selected public fields loses information used by native window chrome.
/// Only recipient annotations are cleared after the real window is exposed.
func nativeMirrorReplayEvent(_ original: CGEvent, tag: Int64) -> CGEvent? {
  guard let replay = original.copy() else { return nil }
  replay.setIntegerValueField(.eventTargetUnixProcessID, value: 0)
  replay.setIntegerValueField(.eventTargetProcessSerialNumber, value: 0)
  replay.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: 0)
  replay.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: 0)
  replay.setIntegerValueField(CGEventField(rawValue: 51)!, value: 0)
  replay.setIntegerValueField(.eventSourceUserData, value: tag)
  return replay
}

// MARK: - MirrorClickTap

/// Intercepts a mirror's first mouse-down before WindowServer chooses a drag
/// target. A downstream session tap acknowledges forwarded packets. Native
/// preparation is asynchronous; the tap never waits for AX or WindowServer IPC.
/// Every mutable field is confined to EventTapThread, except immutable callbacks.
final class MirrorClickTap: @unchecked Sendable {

  // MARK: Lifecycle

  init(
    hitTestWindow: @escaping @Sendable (CGPoint) -> CGWindowID?,
    prepareNativeWindow: @escaping @Sendable (UUID, MirrorWindowRegistry.Target) async -> Bool,
    finishNativeInput: @escaping @Sendable (UUID) -> Void,
    onFailure: @escaping @Sendable (String) -> Void,
    onOutsideClick: @escaping @Sendable () -> Void,
  ) {
    self.hitTestWindow = hitTestWindow
    self.prepareNativeWindow = prepareNativeWindow
    self.finishNativeInput = finishNativeInput
    self.onFailure = onFailure
    self.onOutsideClick = onOutsideClick
  }

  // MARK: Internal

  func setEnabled(_ enabled: Bool) {
    EventTapThread.shared.perform { [self] in
      if enabled, eventTap == nil { install() }
      else if !enabled, eventTap != nil { teardown() }
    }
  }

  // MARK: Fileprivate

  fileprivate static func isWake(_ event: CGEvent) -> Bool {
    event.getIntegerValueField(.eventSourceUserData) & -0x100000000 == wakePrefix
  }

  fileprivate func reEnable(acknowledgment: Bool = false) {
    if let tap = acknowledgment ? acknowledgmentTap : eventTap {
      cancelInput(reason: "The system interrupted native window input delivery.")
      CGEvent.tapEnable(tap: tap, enable: true)
    }
  }

  /// Acknowledge at the downstream session stage. The HID capture tap must
  /// not consume its own replay or treat its earlier echo as downstream delivery.
  fileprivate func acknowledge(_ event: CGEvent) {
    guard MirrorInputEventOrigin.isReplay(event), inFlight != nil else { return }
    deadlineGeneration &+= 1
    inFlight = nil
    inFlightWasPosted = false
    input.delivered(event)
    if event.type == .leftMouseDown, let windowID = MirrorInputEventOrigin.windowID(event) {
      // Publish native ownership before WindowServer/AppKit can emit AX move
      // notifications. The later global monitor reads the same annotation.
      WindowPointerDragTracker.shared.pointerDown(windowID: windowID, location: event.location)
    }
    if Self.isMouseDown(event.type) {
      debugLog.log(
        "Mirror",
        "native input down wid=\(MirrorInputEventOrigin.windowID(event) ?? 0) number=\(event.getIntegerValueField(.mouseEventNumber))",
      )
    }
    if [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(event.type) {
      debugLog.log(
        "Mirror",
        "native input replay up wid=\(MirrorInputEventOrigin.windowID(event) ?? 0) number=\(event.getIntegerValueField(.mouseEventNumber))",
      )
    }
    deliveredCount += 1
    EventTapThread.shared.perform { [weak self] in self?.pump() }
  }

  /// The HID filter holds originals before native titlebar/resize handling.
  /// Replayed packets pass here and are acknowledged by the session observer.
  fileprivate func handle(_ event: CGEvent) -> Bool {
    if MirrorInputEventOrigin.isReplay(event) { return true }

    if inFlight != nil || preparingID != nil || !input.isEmpty {
      if !input.append(event) { cancelInput(reason: "Native window input exceeded its pending event capacity.") }
      return false
    }
    if !input.pressedButtons.isEmpty {
      // Keep the buffered gesture in order through one relay. Its original
      // HID packets now enter WindowServer only after the source is ready.
      guard input.append(event) else {
        cancelInput(reason: "Native window input exceeded its pending event capacity.")
        return false
      }
      pump()
      return false
    }
    if Self.isMouseDown(event.type), MirrorWindowRegistry.shared.mayContainMirror(at: event.location) {
      guard let copy = event.copy() else { return true }
      inFlight = copy
      startedAt = DispatchTime.now().uptimeNanoseconds
      deliveredCount = 0
      resolveClickTarget()
      return false
    }
    if Self.isMouseDown(event.type) {
      let frames = MirrorWindowRegistry.shared.suppressedWindowFrames()
      if !frames.isEmpty, !frames.contains(where: { $0.contains(event.location) }) { onOutsideClick() }
    }
    return true
  }

  fileprivate func forwardPendingInput(using proxy: CGEventTapProxy, wakeTag: Int64) {
    guard pendingWakeTag == wakeTag, let inFlight else { return }
    pendingWakeTag = nil
    guard let replay = nativeMirrorReplayEvent(inFlight, tag: MirrorInputEventOrigin.tag(windowID: lease?.target.windowID)) else {
      cancelInput(reason: "Could not copy the buffered native window input.")
      return
    }
    if Self.isMouseDown(inFlight.type) {
      debugLog.log(
        "Mirror",
        "native input relay number=\(inFlight.getIntegerValueField(.mouseEventNumber)) sourceState=\(inFlight.getIntegerValueField(.eventSourceStateID)) sourcePID=\(inFlight.getIntegerValueField(.eventSourceUnixProcessID))",
      )
    }
    inFlightWasPosted = true
    replay.tapPostEvent(proxy)
  }

  // MARK: Private

  private static let wakePrefix: Int64 = 0x5441544200000000

  @Dependency(\.debugLog) private var debugLog

  private let hitTestWindow: @Sendable (CGPoint) -> CGWindowID?
  private let hitTestQueue = DispatchQueue(label: "dev.PangMo5.Tatami.mirror-input-hit-test", qos: .userInteractive)
  private let prepareNativeWindow: @Sendable (UUID, MirrorWindowRegistry.Target) async -> Bool
  private let finishNativeInput: @Sendable (UUID) -> Void
  private let onFailure: @Sendable (String) -> Void
  private let onOutsideClick: @Sendable () -> Void
  private var transportSource: CGEventSource?
  private var eventTap: CFMachPort?
  private var acknowledgmentTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var acknowledgmentSource: CFRunLoopSource?
  private var input = MirrorInputBuffer()
  private var inFlight: CGEvent?
  private var inFlightWasPosted = false
  private var pendingWakeTag: Int64?
  private var wakeSequence: UInt32 = 0
  private var preparationTask: Task<Void, Never>?
  private var preparingID: UUID?
  private var lease: (id: UUID, target: MirrorWindowRegistry.Target)?
  private var deadlineGeneration: UInt64 = 0
  private var deliveredCount = 0
  private var startedAt: UInt64 = 0

  private static func isMouseDown(_ type: CGEventType) -> Bool {
    type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
  }

  private func install() {
    guard let source = CGEventSource(stateID: .combinedSessionState) else {
      onFailure("Could not create the native window input source.")
      return
    }
    source.localEventsSuppressionInterval = 0
    transportSource = source
    let types: [CGEventType] = [
      .leftMouseDown,
      .leftMouseUp,
      .leftMouseDragged,
      .rightMouseDown,
      .rightMouseUp,
      .rightMouseDragged,
      .otherMouseDown,
      .otherMouseUp,
      .otherMouseDragged,
      .mouseMoved,
      .scrollWheel,
      .keyDown,
      .keyUp,
      .flagsChanged,
    ]
    let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    guard
      let tap = CGEvent.tapCreate(
        tap: .cghidEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: mirrorClickTapCallback,
        userInfo: Unmanaged.passUnretained(self).toOpaque(),
      )
    else {
      logger.error("mirror HID input tap installation failed")
      onFailure("Could not install the native window input tap. Check Accessibility access.")
      return
    }
    CGEvent.tapEnable(tap: tap, enable: false)
    guard
      let acknowledgmentTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .tailAppendEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: mirrorInputAcknowledgmentCallback,
        userInfo: Unmanaged.passUnretained(self).toOpaque(),
      ), let captureSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0),
      let acknowledgmentSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, acknowledgmentTap, 0)
    else {
      CFMachPortInvalidate(tap)
      onFailure("Could not observe native window input delivery.")
      return
    }
    eventTap = tap
    self.acknowledgmentTap = acknowledgmentTap
    runLoopSource = captureSource
    self.acknowledgmentSource = acknowledgmentSource
    EventTapThread.shared.addSource(captureSource)
    EventTapThread.shared.addSource(acknowledgmentSource)
    CGEvent.tapEnable(tap: acknowledgmentTap, enable: true)
    CGEvent.tapEnable(tap: tap, enable: true)
    debugLog.log("Mirror", "native input taps installed capture=HID acknowledge=session")
  }

  private func teardown() {
    cancelInput(reason: nil)
    let taps = [eventTap, acknowledgmentTap].compactMap { $0 }
    let sources = [runLoopSource, acknowledgmentSource].compactMap { $0 }
    eventTap = nil
    acknowledgmentTap = nil
    runLoopSource = nil
    acknowledgmentSource = nil
    for tap in taps {
      CGEvent.tapEnable(tap: tap, enable: false)
      CFMachPortInvalidate(tap)
    }
    for source in sources { EventTapThread.shared.removeSource(source) }
    transportSource = nil
    debugLog.log("Mirror", "native input taps removed")
  }

  private func resolveClickTarget() {
    guard let inFlight else { return }
    let id = UUID()
    preparingID = id
    MirrorWindowRegistry.shared.setNativeInputActive(true)
    let point = inFlight.location
    let candidates = MirrorWindowRegistry.shared.allTargets()
    let hitTestWindow = hitTestWindow
    debugLog.log("Mirror", "native input hit-test at=(\(Int(point.x)),\(Int(point.y)))")
    armDeadline("Native window input hit testing timed out.")
    hitTestQueue.async { [weak self] in
      let windowID = hitTestWindow(point)
      EventTapThread.shared.perform { [weak self] in
        guard let self, preparingID == id else { return }
        preparingID = nil
        guard let windowID else {
          cancelInput(reason: "Could not identify the window receiving this click.")
          return
        }
        let targets = MirrorWindowRegistry.shared.allTargets()
        if candidates[windowID] != nil, targets[windowID] == nil {
          cancelInput(reason: "The floating window changed before input could be delivered.")
          return
        }
        guard let target = targets[windowID] else {
          // A native window or menu covers the candidate rectangle. Replay
          // normally; don't focus the mirror that happens to lie beneath it.
          debugLog.log("Mirror", "native input hit-test ordinary window=\(windowID)")
          postInFlight()
          return
        }
        guard lease?.target != target else {
          cancelInput(reason: "The mirror still intercepted input after native window preparation.")
          return
        }
        debugLog.log("Mirror", "native input hit-test mirror=\(windowID) -> \(target.pid)#\(target.windowID)")
        prepare(target)
      }
    }
  }

  private func prepare(_ target: MirrorWindowRegistry.Target) {
    if let lease { finishNativeInput(lease.id) }
    let id = UUID()
    lease = (id, target)
    preparingID = id
    MirrorWindowRegistry.shared.setNativeInputActive(true)
    debugLog.log("Mirror", "native input prepare \(target.pid)#\(target.windowID)")
    armDeadline("Native window input preparation timed out.")
    let prepareNativeWindow = prepareNativeWindow
    preparationTask = Task { [weak self] in
      let ready = await prepareNativeWindow(id, target)
      EventTapThread.shared.perform { [weak self] in
        guard let self, preparingID == id else { return }
        preparingID = nil
        preparationTask = nil
        guard ready else {
          cancelInput(reason: "The original window could not be prepared for native input.")
          return
        }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        debugLog.log("Mirror", "native input ready \(target.pid)#\(target.windowID) ms=\(milliseconds)")
        postInFlight()
      }
    }
  }

  private func pump() {
    guard preparingID == nil, inFlight == nil else { return }
    if let event = input.popFirst() {
      inFlight = event
      // Resolve every new queued click before entering WindowServer. Holding
      // it at the downstream acknowledgment tap would be too late for chrome.
      if
        Self.isMouseDown(event.type), input.pressedButtons.isEmpty,
        MirrorWindowRegistry.shared.mayContainMirror(at: event.location)
      {
        resolveClickTarget()
      } else {
        postInFlight()
      }
    } else if input.pressedButtons.isEmpty {
      input.releaseKeyboardTracking()
      deadlineGeneration &+= 1
      if let lease {
        debugLog.log(
          "Mirror",
          "native input delivered \(lease.target.pid)#\(lease.target.windowID) bufferedEvents=\(deliveredCount)",
        )
        finishNativeInput(lease.id)
        self.lease = nil
      }
      MirrorWindowRegistry.shared.setNativeInputActive(false)
    }
  }

  /// Schedule delivery through a live HID callback. A CGEventTapProxy is not
  /// retained outside its callback; the wake packet is swallowed before it can
  /// move the pointer or reach an application.
  private func postInFlight() {
    guard
      let inFlight, let transportSource,
      let wake = CGEvent(
        mouseEventSource: transportSource,
        mouseType: .mouseMoved,
        mouseCursorPosition: inFlight.location,
        mouseButton: .left,
      )
    else {
      cancelInput(reason: "Could not schedule native window input delivery.")
      return
    }
    wakeSequence &+= 1
    let tag = Self.wakePrefix | Int64(wakeSequence)
    pendingWakeTag = tag
    wake.setIntegerValueField(.eventSourceUserData, value: tag)
    armDeadline("Native window input relay was not acknowledged.")
    wake.post(tap: .cghidEventTap)
  }

  /// Failure deadline only: no delay is added to successful preparation/replay.
  /// A missing event echo must never leave global input captured indefinitely.
  private func armDeadline(_ reason: String) {
    deadlineGeneration &+= 1
    let generation = deadlineGeneration
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) { [weak self] in
      EventTapThread.shared.perform { [weak self] in
        guard let self, deadlineGeneration == generation else { return }
        cancelInput(reason: reason)
      }
    }
  }

  private func cancelInput(reason: String?) {
    let hadInput = lease != nil || inFlight != nil
    deadlineGeneration &+= 1
    preparationTask?.cancel()
    preparationTask = nil
    preparingID = nil
    pendingWakeTag = nil
    var buttonsToRelease = input.pressedButtons
    var keysToRelease = input.pressedKeys
    if inFlightWasPosted, let inFlight {
      if Self.isMouseDown(inFlight.type) {
        buttonsToRelease.insert(inFlight.getIntegerValueField(.mouseEventButtonNumber))
      } else if inFlight.type == .keyDown {
        keysToRelease.insert(CGKeyCode(clamping: inFlight.getIntegerValueField(.keyboardEventKeycode)))
      }
    }
    inFlight = nil
    inFlightWasPosted = false
    // Balance any native downs already delivered before a teardown. Buffered
    // clicks that never reached the source are discarded, never sent elsewhere.
    for number in buttonsToRelease {
      let button = CGMouseButton(rawValue: UInt32(clamping: number)) ?? .left
      let type: CGEventType = number == 0 ? .leftMouseUp : number == 1 ? .rightMouseUp : .otherMouseUp
      let location = CGEvent(source: nil)?.location ?? .zero
      if
        let up = CGEvent(
          mouseEventSource: transportSource,
          mouseType: type,
          mouseCursorPosition: location,
          mouseButton: button,
        )
      {
        if let eventNumber = input.buttonEventNumbers[number] { up.setIntegerValueField(.mouseEventNumber, value: eventNumber) }
        up.setIntegerValueField(.eventSourceUserData, value: MirrorInputEventOrigin.tag(windowID: lease?.target.windowID))
        up.post(tap: .cghidEventTap)
      }
    }
    for key in keysToRelease {
      if let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) {
        up.setIntegerValueField(.eventSourceUserData, value: MirrorInputEventOrigin.tag(windowID: lease?.target.windowID))
        up.post(tap: .cghidEventTap)
      }
    }
    input.reset()
    if let lease { finishNativeInput(lease.id) }
    lease = nil
    MirrorWindowRegistry.shared.setNativeInputActive(false)
    if hadInput, let reason {
      debugLog.log("Mirror", "native input cancelled: \(reason)")
      onFailure(reason)
    }
  }

}

private func mirrorClickTapCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  refcon: UnsafeMutableRawPointer?,
) -> Unmanaged<CGEvent>? {
  guard let refcon else { return Unmanaged.passUnretained(event) }
  let tap = Unmanaged<MirrorClickTap>.fromOpaque(refcon).takeUnretainedValue()
  switch type {
  case .tapDisabledByTimeout,
       .tapDisabledByUserInput:
    tap.reEnable()
    return Unmanaged.passUnretained(event)

  default:
    if MirrorClickTap.isWake(event) {
      tap.forwardPendingInput(using: proxy, wakeTag: event.getIntegerValueField(.eventSourceUserData))
      return nil
    }
    return tap.handle(event) ? Unmanaged.passUnretained(event) : nil
  }
}

/// Observes only packets that passed the HID filter and WindowServer handling.
/// Never drops, modifies, or reorders the session stream itself.
private func mirrorInputAcknowledgmentCallback(
  proxy _: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  refcon: UnsafeMutableRawPointer?,
) -> Unmanaged<CGEvent>? {
  guard let refcon else { return Unmanaged.passUnretained(event) }
  let tap = Unmanaged<MirrorClickTap>.fromOpaque(refcon).takeUnretainedValue()
  switch type {
  case .tapDisabledByTimeout,
       .tapDisabledByUserInput:
    tap.reEnable(acknowledgment: true)
  default:
    tap.acknowledge(event)
  }
  return Unmanaged.passUnretained(event)
}
