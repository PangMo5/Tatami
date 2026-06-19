import ApplicationServices
import CoreGraphics
import Dependencies
import DependenciesMacros
import Foundation
import OSLog

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "BorrowChord")

/// One decoded keystroke from the borrow-mode key capture.
public enum BorrowChordKey: Sendable, Equatable {
  /// A direction key (h/j/k/l or an arrow) → set the dock edge.
  case edge(BorrowEdge)
  /// A workspace's lowercased initial → summon that workspace.
  case workspace(String)
  /// The reserved recent key (backtick) → summon the recent workspace.
  case recent
  /// Escape or any unrecognized key → leave borrow mode.
  case cancel
}

/// Transient global key capture for "borrow mode": after the leader hotkey
/// fires, a `CGEventTap` consumes the next direction / workspace-initial /
/// recent / escape keystroke and reports it, so the chord never leaks into the
/// focused app. The tap is only installed while armed.
@DependencyClient
public struct BorrowChordClient: Sendable {
  /// Process-long stream of decoded chord keys (emits only while armed).
  public var events: @Sendable () -> AsyncStream<BorrowChordKey> = { .finished }
  /// Install (`armed`) / remove the capture tap; `initials` are the workspace
  /// commit keys the tap should recognize.
  public var setArmed: @Sendable (_ armed: Bool, _ initials: Set<String>) async -> Void
}

extension BorrowChordClient: DependencyKey {
  public static var liveValue: BorrowChordClient {
    let (stream, continuation) = AsyncStream<BorrowChordKey>.makeStream()
    let tap = BorrowChordTap { continuation.yield($0) }
    return BorrowChordClient(
      events: { stream },
      setArmed: { armed, initials in tap.setArmed(armed, initials: initials) }
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
/// tap thread so its `initials` state stays lock-free.
final class BorrowChordTap: @unchecked Sendable {
  @Dependency(\.debugLog) private var debugLog

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var initials: Set<String> = []
  private let emit: @Sendable (BorrowChordKey) -> Void

  init(emit: @escaping @Sendable (BorrowChordKey) -> Void) {
    self.emit = emit
  }

  func setArmed(_ armed: Bool, initials: Set<String>) {
    EventTapThread.shared.perform { [self] in
      self.initials = initials
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
    debugLog.log("BorrowChord", "tap armed (initials=\(initials.sorted()))")
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
  /// Directions (h/j/k/l + arrows) and the recent key (backtick) are fixed;
  /// workspace initials are dynamic. A keystroke with ⌘/⌃/⌥ held (the leader
  /// re-press, app switching, etc.) or any unrecognized key cancels borrow
  /// mode and passes through so the user's keystroke isn't swallowed.
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
    case "`": emit(.recent); return true
    default:
      if initials.contains(name) {
        emit(.workspace(name))
        return true
      }
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
