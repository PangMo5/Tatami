import AppKit
import ApplicationServices
import Dependencies
import DependenciesMacros
import Foundation
import OSLog

/// Mouse-driven focus: while enabled, the app under the cursor becomes
/// frontmost. A configurable modifier temporarily suspends the
/// behavior.
@DependencyClient
public struct FocusFollowsMouseClient: Sendable {
  /// Apply new settings. Pass `enabled = false` to tear the monitor down.
  public var configure: @Sendable (FocusFollowsMouseConfig) async -> Void
}

public struct FocusFollowsMouseConfig: Sendable, Hashable {
  public var enabled: Bool
  public var disableModifier: FocusFollowsMouseModifier

  public init(enabled: Bool, disableModifier: FocusFollowsMouseModifier) {
    self.enabled = enabled
    self.disableModifier = disableModifier
  }
}

extension FocusFollowsMouseClient: DependencyKey {
  public static let liveValue: FocusFollowsMouseClient = {
    let controller = LiveFocusFollowsMouseController()
    return FocusFollowsMouseClient { config in
      await controller.configure(config)
    }
  }()

  public static let testValue = FocusFollowsMouseClient(configure: { _ in })
  public static let previewValue = testValue
}

extension DependencyValues {
  public var focusFollowsMouse: FocusFollowsMouseClient {
    get { self[FocusFollowsMouseClient.self] }
    set { self[FocusFollowsMouseClient.self] = newValue }
  }
}

/// Owns the system-wide event tap + throttle state for the lifetime
/// of the process. Reconfiguring tears the tap down and reinstalls it;
/// disabling stops it. We use a `CGEventTap` (session-level, listen-
/// only) rather than `NSEvent.addGlobalMonitorForEvents` so mouse
/// movement still reaches us while other apps are mid-drag — global
/// monitors miss events whenever the active drag target owns the
/// mouse-tracking session.
private final class LiveFocusFollowsMouseController: @unchecked Sendable {
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  fileprivate var config = FocusFollowsMouseConfig(enabled: false, disableModifier: .option)
  fileprivate var lastFireAt = Date.distantPast
  fileprivate let throttleInterval: TimeInterval = 0.08
  fileprivate var lastFocusedWindowID: CGWindowID = 0

  init() {}

  func configure(_ next: FocusFollowsMouseConfig) async {
    // Tap install/teardown runs on the shared event-tap thread so the tap
    // callback (a `CGWindowListCopyWindowInfo` hit-test on every throttled
    // mouse-move) executes off the main thread. The controller's state is
    // only ever touched from that thread, so it stays lock-free.
    EventTapThread.shared.perform { [self] in
      installOrTearDown(next)
    }
  }

  /// Runs on the event-tap thread (via `configure` / the tap callback).
  private func installOrTearDown(_ next: FocusFollowsMouseConfig) {
    config = next
    if next.enabled, eventTap == nil {
      install()
    } else if !next.enabled, eventTap != nil {
      teardown()
    }
  }

  private func install() {
    // Listen for mouseMoved + the two tap-disabled signals so we can
    // re-enable if the system hangs the tap.
    let mask =
      (1 << CGEventType.mouseMoved.rawValue) |
      (1 << CGEventType.tapDisabledByTimeout.rawValue) |
      (1 << CGEventType.tapDisabledByUserInput.rawValue)
    let info = Unmanaged.passUnretained(self).toOpaque()
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .listenOnly,
      eventsOfInterest: CGEventMask(mask),
      callback: focusFollowsMouseCallback,
      userInfo: info
    ) else {
      logger.error("CGEvent.tapCreate failed — check Accessibility permission")
      return
    }
    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
      logger.error("focus-follows-mouse: failed to create run loop source")
      return
    }
    EventTapThread.shared.addSource(source)
    CGEvent.tapEnable(tap: tap, enable: true)
    eventTap = tap
    runLoopSource = source
    logger.info("focus-follows-mouse: event tap installed")
  }

  private func teardown() {
    if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
    if let src = runLoopSource {
      EventTapThread.shared.removeSource(src)
    }
    eventTap = nil
    runLoopSource = nil
    logger.info("focus-follows-mouse: event tap removed")
  }

  /// Macros / heavy work in some apps can starve the tap; macOS responds
  /// by sending a `tapDisabledByTimeout` event and turning the tap off.
  /// Flip it back on so focus-follows-mouse keeps working.
  fileprivate func reEnableTap() {
    if let tap = eventTap {
      CGEvent.tapEnable(tap: tap, enable: true)
    }
  }

  /// Runs on the event-tap thread. The hit-test (`CGWindowListCopyWindowInfo`)
  /// and throttle bookkeeping stay off the main thread; only the actual
  /// focus change — which touches AppKit + Accessibility — hops to the main
  /// actor.
  fileprivate func handle(location: CGPoint, flags: CGEventFlags) {
    if modifiersIndicateDisable(flags) { return }
    let now = Date()
    guard now.timeIntervalSince(lastFireAt) >= throttleInterval else { return }
    lastFireAt = now

    // CGEvent locations and CGWindowList bounds are both top-origin
    // Quartz coords anchored to the primary screen, so no flip needed.
    guard let info = topmostWindow(at: location) else { return }
    // Dedup on the window, not the app — moving between two windows of
    // the same app (e.g. two Ghostty windows) must still move focus.
    if info.windowID == lastFocusedWindowID { return }
    lastFocusedWindowID = info.windowID

    // Raise the specific window under the cursor so focus lands on the
    // right one even within the same app (shared helper in WindowKey).
    // `focusWindow` is `@MainActor` (AppKit activate + AX raise), so hop.
    let pid = info.pid
    let windowID = info.windowID
    Task { @MainActor in focusWindow(pid: pid, windowID: windowID) }
  }

  private func modifiersIndicateDisable(_ flags: CGEventFlags) -> Bool {
    switch config.disableModifier {
    case .none: return false
    case .option: return flags.contains(.maskAlternate)
    case .command: return flags.contains(.maskCommand)
    case .control: return flags.contains(.maskControl)
    case .shift: return flags.contains(.maskShift)
    }
  }

  private func topmostWindow(at point: CGPoint) -> (pid: pid_t, windowID: CGWindowID, bounds: CGRect)? {
    let raw = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[String: Any]] ?? []
    for entry in raw {
      guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
      guard let pidNumber = entry[kCGWindowOwnerPID as String] as? pid_t else { continue }
      guard let windowNumber = entry[kCGWindowNumber as String] as? CGWindowID else { continue }
      guard let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
            let x = boundsDict["X"],
            let y = boundsDict["Y"],
            let w = boundsDict["Width"],
            let h = boundsDict["Height"]
      else { continue }
      let rect = CGRect(x: x, y: y, width: w, height: h)
      if rect.contains(point) {
        return (pidNumber, windowNumber, rect)
      }
    }
    return nil
  }
}

/// CGEventTap C callback. Hops onto the controller via the retained-
/// unmanaged pointer in `userInfo`. Returns the event unmodified —
/// listen-only.
private func focusFollowsMouseCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let refcon else { return Unmanaged.passUnretained(event) }
  let controller = Unmanaged<LiveFocusFollowsMouseController>
    .fromOpaque(refcon).takeUnretainedValue()
  // The run-loop source lives on the shared event-tap thread, so this
  // callback already runs there — the controller's state is touched only
  // from this thread, so we call straight in. Extract the event's Sendable
  // scalars (location + flags) so we never retain the non-Sendable
  // `CGEvent` beyond the callback.
  switch type {
  case .mouseMoved:
    let location = event.location
    let flags = event.flags
    controller.handle(location: location, flags: flags)
  case .tapDisabledByTimeout, .tapDisabledByUserInput:
    controller.reEnableTap()
  default:
    break
  }
  return Unmanaged.passUnretained(event)
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "FocusFollowsMouse")
