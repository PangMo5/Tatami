import ApplicationServices
import CoreGraphics
import Dependencies
import DependenciesMacros
import Foundation
import OSLog

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "BorrowChord")

/// One decoded keystroke from the borrow direction pick.
public enum BorrowChordKey: Sendable, Equatable {
  /// A direction key (h/j/k/l or an arrow) → dock edge, commits the borrow.
  case edge(BorrowEdge)
  /// Escape or any other key → cancel the pending borrow.
  case cancel
}

/// Transient global key capture for placing a borrow: after the borrow combo
/// selects a workspace, a `CGEventTap` consumes the next direction (or escape)
/// keystroke and reports it, so the key never leaks into the focused app. The
/// tap is only installed while armed.
@DependencyClient
public struct BorrowChordClient: Sendable {
  /// Process-long stream of decoded direction keys (emits only while armed).
  public var events: @Sendable () -> AsyncStream<BorrowChordKey> = { .finished }
  /// Install (`armed`) / remove the direction-capture tap.
  public var setArmed: @Sendable (_ armed: Bool) async -> Void
}

extension BorrowChordClient: DependencyKey {
  public static var liveValue: BorrowChordClient {
    let (stream, continuation) = AsyncStream<BorrowChordKey>.makeStream()
    let tap = BorrowChordTap { continuation.yield($0) }
    return BorrowChordClient(
      events: { stream },
      setArmed: { armed in tap.setArmed(armed) }
    )
  }

  public static var testValue: BorrowChordClient { BorrowChordClient() }
}

extension DependencyValues {
  public var borrowChord: BorrowChordClient {
    get { self[BorrowChordClient.self] }
    set { self[BorrowChordClient.self] = newValue }
  }
}

/// Owns the keyDown `CGEventTap`. Mirrors `MirrorClickTap`: same shared
/// `EventTapThread`, same re-enable dance, install/teardown routed through the
/// tap thread.
final class BorrowChordTap: @unchecked Sendable {
  @Dependency(\.debugLog) private var debugLog

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private let emit: @Sendable (BorrowChordKey) -> Void

  init(emit: @escaping @Sendable (BorrowChordKey) -> Void) {
    self.emit = emit
  }

  func setArmed(_ armed: Bool) {
    EventTapThread.shared.perform { [self] in
      if armed, eventTap == nil {
        install()
      } else if !armed, eventTap != nil {
        teardown()
      }
    }
  }

  /// Runs on the event-tap thread.
  private func install() {
    let mask =
      (1 << CGEventType.keyDown.rawValue) |
      (1 << CGEventType.tapDisabledByTimeout.rawValue) |
      (1 << CGEventType.tapDisabledByUserInput.rawValue)
    let info = Unmanaged.passUnretained(self).toOpaque()
    // `.defaultTap` (active) so recognized keys can be consumed; rides the
    // Accessibility grant like the other taps (see MirrorClickTap).
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: CGEventMask(mask),
      callback: borrowChordTapCallback,
      userInfo: info
    ) else {
      logger.error("borrow chord tap: CGEvent.tapCreate failed")
      debugLog.log("BorrowChord", "tap create FAILED (accessibility?)")
      return
    }
    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
      logger.error("borrow chord tap: failed to create run loop source")
      return
    }
    EventTapThread.shared.addSource(source)
    CGEvent.tapEnable(tap: tap, enable: true)
    eventTap = tap
    runLoopSource = source
    debugLog.log("BorrowChord", "direction tap armed")
  }

  private func teardown() {
    if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
    if let source = runLoopSource { EventTapThread.shared.removeSource(source) }
    eventTap = nil
    runLoopSource = nil
    debugLog.log("BorrowChord", "tap disarmed")
  }

  fileprivate func reEnable() {
    if let tap = eventTap {
      debugLog.log("BorrowChord", "tap disabled by system — re-enabling")
      CGEvent.tapEnable(tap: tap, enable: true)
    }
  }

  /// Runs on the event-tap thread. Returns `true` to consume the keystroke.
  /// Only direction keys (h/j/k/l + arrows) and escape are recognized; a
  /// keystroke with ⌘/⌃/⌥ held (e.g. the borrow combo's own release, app
  /// switching) or any other key cancels and passes through so it isn't eaten.
  fileprivate func handle(keyCode: Int, hasCommandModifiers: Bool) -> Bool {
    guard !hasCommandModifiers, let name = HotKey.keyName(for: keyCode) else {
      emit(.cancel)
      return false
    }
    switch name {
    case "escape": emit(.cancel); return true
    case "h", "left": emit(.edge(.left)); return true
    case "l", "right": emit(.edge(.right)); return true
    case "k", "up": emit(.edge(.top)); return true
    case "j", "down": emit(.edge(.bottom)); return true
    default:
      emit(.cancel)
      return false
    }
  }
}

/// CGEventTap C callback for the borrow chord — decodes keyDown, consumes
/// recognized keys, passes the rest through.
private func borrowChordTapCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let refcon else { return Unmanaged.passUnretained(event) }
  let tap = Unmanaged<BorrowChordTap>.fromOpaque(refcon).takeUnretainedValue()
  switch type {
  case .keyDown:
    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let hasCommandModifiers = !event.flags
      .intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
    return tap.handle(keyCode: keyCode, hasCommandModifiers: hasCommandModifiers)
      ? nil : Unmanaged.passUnretained(event)
  case .tapDisabledByTimeout, .tapDisabledByUserInput:
    tap.reEnable()
    return Unmanaged.passUnretained(event)
  default:
    return Unmanaged.passUnretained(event)
  }
}
