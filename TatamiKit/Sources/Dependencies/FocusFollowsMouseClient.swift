import AppKit
import ApplicationServices
import Dependencies
import DependenciesMacros
import Foundation
import OSLog

// MARK: - FocusFollowsMouseClient

/// Mouse-driven focus: while enabled, the app under the cursor becomes
/// frontmost. A configurable modifier temporarily suspends the
/// behavior.
@DependencyClient
struct FocusFollowsMouseClient: Sendable {
  /// Apply new settings. Pass `enabled = false` to tear the monitor down.
  var configure: @Sendable (FocusFollowsMouseConfig) async -> Void
}

// MARK: - FocusFollowsMouseConfig

struct FocusFollowsMouseConfig: Sendable, Hashable {
  init(
    enabled: Bool,
    disableModifier: FocusFollowsMouseModifier,
    ignoreFullscreen: Bool = true,
  ) {
    self.enabled = enabled
    self.disableModifier = disableModifier
    self.ignoreFullscreen = ignoreFullscreen
  }

  var enabled: Bool
  var disableModifier: FocusFollowsMouseModifier
  /// Skip windows that fill the whole display (full-screen / maximized).
  var ignoreFullscreen: Bool
}

// MARK: - FocusFollowsMouseClient + DependencyKey

extension FocusFollowsMouseClient: DependencyKey {
  static let liveValue: FocusFollowsMouseClient = {
    @Dependency(\.debugLog) var debugLog
    @Dependency(\.focusEventOrigin) var focusEventOrigin
    @Dependency(\.managedWindows) var managedWindows
    let controller = LiveFocusFollowsMouseController(
      debugLog: debugLog,
      focusEventOrigin: focusEventOrigin,
      managedWindows: managedWindows,
    )
    return FocusFollowsMouseClient { config in
      await controller.configure(config)
    }
  }()

  static let testValue = FocusFollowsMouseClient(configure: { _ in })
  static let previewValue = testValue
}

extension DependencyValues {
  var focusFollowsMouse: FocusFollowsMouseClient {
    get { self[FocusFollowsMouseClient.self] }
    set { self[FocusFollowsMouseClient.self] = newValue }
  }
}

// MARK: - LiveFocusFollowsMouseController

/// Owns the system-wide event tap + throttle state for the lifetime
/// of the process. Reconfiguring tears the tap down and reinstalls it;
/// disabling stops it. We use a `CGEventTap` (session-level, listen-
/// only) rather than `NSEvent.addGlobalMonitorForEvents` so mouse
/// movement still reaches us while other apps are mid-drag — global
/// monitors miss events whenever the active drag target owns the
/// mouse-tracking session.
private final class LiveFocusFollowsMouseController: @unchecked Sendable {

  // MARK: Lifecycle

  init(
    debugLog: DebugLogClient,
    focusEventOrigin: FocusEventOriginClient,
    managedWindows: ManagedWindowsClient,
  ) {
    self.debugLog = debugLog
    self.focusEventOrigin = focusEventOrigin
    self.managedWindows = managedWindows
  }

  // MARK: Internal

  func configure(_ next: FocusFollowsMouseConfig) async {
    // Tap install/teardown runs on the shared event-tap thread so the tap
    // callback (a `CGWindowListCopyWindowInfo` hit-test on every throttled
    // mouse-move) executes off the main thread. The controller's state is
    // only ever touched from that thread, so it stays lock-free.
    EventTapThread.shared.perform { [self] in
      installOrTearDown(next)
    }
  }

  // MARK: Fileprivate

  fileprivate var config = FocusFollowsMouseConfig(enabled: false, disableModifier: .option)
  fileprivate var lastFireAt = Date.distantPast
  fileprivate let throttleInterval: TimeInterval = 0.05
  fileprivate var lastFocusedWindowID: CGWindowID = 0
  fileprivate let debugLog: DebugLogClient

  /// Macros / heavy work in some apps can starve the tap; macOS responds
  /// by sending a `tapDisabledByTimeout` event and turning the tap off.
  /// Flip it back on so focus-follows-mouse keeps working.
  fileprivate func reEnableTap() {
    if let tap = eventTap {
      debugLog.log("FocusDiag", "ffm tap disabled by system — re-enabling")
      CGEvent.tapEnable(tap: tap, enable: true)
    }
  }

  /// Runs on the event-tap thread. The hit-test (`CGWindowListCopyWindowInfo`)
  /// and throttle bookkeeping stay off the main thread. The focus task hops
  /// briefly to the main actor for AppKit identity + mirror handoff, while its
  /// timeout-prone Accessibility lookup/read/write runs on the focus worker.
  fileprivate func handle(
    location: CGPoint,
    flags: CGEventFlags,
    timestamp: CGEventTimestamp,
  ) {
    if modifiersIndicateDisable(flags) { return }

    let warpEvaluation = ProgrammaticPointerWarpGate.shared.evaluateMouseMove(
      at: location,
      timestamp: timestamp,
    )
    if warpEvaluation.generation != lastObservedWarpGeneration {
      lastObservedWarpGeneration = warpEvaluation.generation
      lastLoggedSuppressedWarpGeneration = nil
      lastFocusedWindowID = 0
      focusTask?.cancel()
      focusTask = nil
    }
    guard warpEvaluation.allowsFocus else {
      if
        debugLog.isEnabled(),
        lastLoggedSuppressedWarpGeneration != warpEvaluation.generation
      {
        lastLoggedSuppressedWarpGeneration = warpEvaluation.generation
        debugLog.log(
          "FocusDiag",
          "ffm suppress programmatic move generation=\(warpEvaluation.generation) at=(\(Int(location.x)),\(Int(location.y)))",
        )
      }
      return
    }

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
    if debugLog.isEnabled() {
      debugLog.log(
        "FocusDiag",
        "ffm fire pid=\(info.pid) wid=\(info.windowID) at=(\(Int(location.x)),\(Int(location.y)))",
      )
    }

    // Focus the specific window under the cursor so same-app movement lands on
    // the right window and cross-app movement transfers the frontmost process.
    // The latter needs the SLS user-generated focus path: plain
    // `NSRunningApplication.activate()` can leave keyboard focus in the old app,
    // especially with a secondary display connected.
    let pid = info.pid
    let windowID = info.windowID
    // Coalesce: cancel any still-pending hop so a burst of moves under
    // main-thread contention applies only the latest target — a queued hop
    // for a window the cursor has already left would land focus on the wrong
    // window. Latest-fire-wins.
    focusTask?.cancel()
    focusTask = Task { @MainActor in
      guard
        !Task.isCancelled,
        ProgrammaticPointerWarpGate.shared.isCurrent(
          generation: warpEvaluation.generation
        )
      else { return }
      await focusWindowFollowingMouse(
        pid: pid,
        windowID: windowID,
        willPerformAXFocus: {
          self.focusEventOrigin.recordPointerDrivenFocus(windowID)
        },
      )
    }
  }

  // MARK: Private

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  /// The in-flight focus hop. A newer fire cancels it so only the latest
  /// cursor target is applied — touched only on the event-tap thread, like
  /// the rest of this controller's lock-free state.
  private var focusTask: Task<Void, Never>?
  /// Last MFF warp generation observed on the event-tap thread. A generation
  /// change invalidates both the FFM window dedup and any queued focus hop.
  private var lastObservedWarpGeneration: UInt64 = 0
  private var lastLoggedSuppressedWarpGeneration: UInt64?
  private let focusEventOrigin: FocusEventOriginClient
  private let managedWindows: ManagedWindowsClient

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
    // `.defaultTap`, not `.listenOnly`: TCC gates active taps on
    // Accessibility but listen-only taps on Input Monitoring — every
    // listen-only tapCreate (even mouse-only, even with Accessibility
    // granted) pops the "receive keystrokes from any application"
    // warning and lists the app under Privacy → Input Monitoring. The
    // callback passes events through unmodified.
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask(mask),
        callback: focusFollowsMouseCallback,
        userInfo: info,
      )
    else {
      logger.error("CGEvent.tapCreate failed — check Accessibility permission")
      debugLog.log("FocusDiag", "ffm tap create FAILED (accessibility?)")
      return
    }
    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
      logger.error("focus-follows-mouse: failed to create run loop source")
      debugLog.log("FocusDiag", "ffm tap: run loop source FAILED")
      return
    }
    EventTapThread.shared.addSource(source)
    CGEvent.tapEnable(tap: tap, enable: true)
    eventTap = tap
    runLoopSource = source
    debugLog.log("FocusDiag", "ffm tap installed")
  }

  private func teardown() {
    if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
    if let src = runLoopSource {
      EventTapThread.shared.removeSource(src)
    }
    eventTap = nil
    runLoopSource = nil
    // Drop any pending focus hop so a move captured just before disable
    // can't move focus after FFM was turned off.
    focusTask?.cancel()
    focusTask = nil
    debugLog.log("FocusDiag", "ffm tap removed")
  }

  private func modifiersIndicateDisable(_ flags: CGEventFlags) -> Bool {
    switch config.disableModifier {
    case .none: false
    case .option: flags.contains(.maskAlternate)
    case .command: flags.contains(.maskCommand)
    case .control: flags.contains(.maskControl)
    case .shift: flags.contains(.maskShift)
    }
  }

  private func topmostWindow(at point: CGPoint) -> (pid: pid_t, windowID: CGWindowID, bounds: CGRect)? {
    let raw = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID,
    ) as? [[String: Any]] ?? []
    // One lock acquisition for the mirror snapshot instead of one per entry.
    let mirrorTargets = MirrorWindowRegistry.shared.allTargets()
    // Single pass in front-to-back z-order (the list's natural order),
    // stopping at the first hit — materializing the full window array per
    // fire (up to 20 Hz during mouse motion) was pure allocation churn.
    // Only the bounds of the layer-0 windows *in front of* the hit are
    // kept, for the full-screen gap guard below.
    var frontBounds = [CGRect]()
    var candidate: (pid: pid_t, windowID: CGWindowID, bounds: CGRect)?
    for entry in raw {
      guard
        let pidNumber = entry[kCGWindowOwnerPID as String] as? pid_t,
        let windowNumber = entry[kCGWindowNumber as String] as? CGWindowID,
        let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
        let x = boundsDict["X"], let y = boundsDict["Y"],
        let w = boundsDict["Width"], let h = boundsDict["Height"]
      else { continue }
      let bounds = CGRect(x: x, y: y, width: w, height: h)
      // A visible floating-mirror panel stands in for the window it
      // mirrors: hovering the mirror must focus the real floating window,
      // not the tile that happens to sit underneath the panel — otherwise
      // FFM and the overlay fight over focus during the hand-off.
      let alpha = (entry[kCGWindowAlpha as String] as? Double) ?? 1
      if alpha > 0, let target = mirrorTargets[windowNumber] {
        if bounds.contains(point) {
          if debugLog.isEnabled() {
            debugLog.log(
              "FocusDiag",
              "ffm mirror-redirect panel=\(windowNumber) alpha=\(alpha) -> pid=\(target.pid) wid=\(target.windowID)",
            )
          }
          candidate = (target.pid, target.windowID, bounds)
          break
        }
        continue
      }
      guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
      if bounds.contains(point) {
        // Only follow into a window Tatami manages. An unmanaged window on
        // top (notification banner, our own overlay) means leave focus put
        // — don't focus it, don't punch through to what's beneath it.
        if managedWindows.isManaged(windowNumber) {
          candidate = (pidNumber, windowNumber, bounds)
        }
        break
      }
      frontBounds.append(bounds)
    }
    guard let candidate else { return nil }

    // The cursor's frontmost window fills its display (full-screen /
    // maximized).
    if let display = displayBounds(containing: point), covers(candidate.bounds, display) {
      // Opt-in: never hover-focus a full-screen window — you reach those by
      // clicking, not by skimming the cursor across them.
      if config.ignoreFullscreen { return nil }
      // Otherwise, gap guard: only skip when the cursor is wedged in the
      // spacing right next to a smaller window layered in front (a tile) — the
      // full-screen window shows through there, so keep the current focus. A
      // cursor far from every front tile is over the background's own open
      // area and focuses normally.
      let gapMargin: CGFloat = 24
      let inTileGap = frontBounds.contains { bounds in
        display.intersects(bounds)
          && !covers(bounds, display)
          && bounds.insetBy(dx: -gapMargin, dy: -gapMargin).contains(point)
      }
      if inTileGap { return nil }
    }
    return candidate
  }

  /// True when `rect` fills at least 90% of `display` — i.e. a full-screen /
  /// maximized window rather than a tiled region.
  private func covers(_ rect: CGRect, _ display: CGRect) -> Bool {
    let overlap = rect.intersection(display)
    guard !overlap.isNull else { return false }
    let displayArea = display.width * display.height
    guard displayArea > 0 else { return false }
    return (overlap.width * overlap.height) / displayArea >= 0.9
  }

  /// Bounds of the display under `point`, in the global top-left Quartz space
  /// that `CGWindowList` bounds and `CGEvent` locations also use. Uses Core
  /// Graphics display services, which are safe to call off the main thread.
  private func displayBounds(containing point: CGPoint) -> CGRect? {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
    return ids.lazy.map(CGDisplayBounds).first { $0.contains(point) }
  }

}

/// CGEventTap C callback. Hops onto the controller via the retained-
/// unmanaged pointer in `userInfo`. Observes only — returns the event
/// unmodified.
private func focusFollowsMouseCallback(
  proxy _: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  refcon: UnsafeMutableRawPointer?,
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
    let timestamp = event.timestamp
    controller.handle(
      location: location,
      flags: flags,
      timestamp: timestamp,
    )

  case .tapDisabledByTimeout,
       .tapDisabledByUserInput:
    controller.reEnableTap()

  default:
    break
  }
  return Unmanaged.passUnretained(event)
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "FocusFollowsMouse")
