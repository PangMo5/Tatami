import AppKit
import ApplicationServices
import Dependencies
import DependenciesMacros
import Foundation
import OSLog

/// Mouse-driven focus: while enabled, the app under the cursor becomes
/// frontmost. Mirrors yabai's `focus_follows_mouse` with a configurable
/// modifier that temporarily suspends the behavior.
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

/// Owns the NSEvent global monitor + throttle state for the lifetime
/// of the process. Replacing the config tears down and reinstalls the
/// monitor; disabling stops it.
/// Lives for the lifetime of the process. All mutation hops to the main
/// thread because NSEvent monitors must be installed there.
private final class LiveFocusFollowsMouseController: @unchecked Sendable {
  private var monitor: Any?
  private var config = FocusFollowsMouseConfig(enabled: false, disableModifier: .option)
  private var lastFireAt = Date.distantPast
  private let throttleInterval: TimeInterval = 0.08
  private var lastFocusedWindowID: CGWindowID = 0

  init() {}

  func configure(_ next: FocusFollowsMouseConfig) async {
    await MainActor.run {
      self.installOrTearDown(next)
    }
  }

  @MainActor
  private func installOrTearDown(_ next: FocusFollowsMouseConfig) {
    config = next
    if next.enabled, monitor == nil {
      monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
        self?.handle(event)
      }
      logger.info("focus-follows-mouse: monitor installed")
    } else if !next.enabled, let m = monitor {
      NSEvent.removeMonitor(m)
      monitor = nil
      logger.info("focus-follows-mouse: monitor removed")
    }
  }

  @MainActor
  private func handle(_ event: NSEvent) {
    guard event.type == .mouseMoved else { return }
    if modifiersIndicateDisable(event.modifierFlags) { return }
    let now = Date()
    guard now.timeIntervalSince(lastFireAt) >= throttleInterval else { return }
    lastFireAt = now

    let location = flippedCursorLocation()
    guard let info = topmostWindow(at: location) else { return }
    // Dedup on the window, not the app — moving between two windows of
    // the same app (e.g. two Ghostty windows) must still move focus.
    if info.windowID == lastFocusedWindowID { return }
    lastFocusedWindowID = info.windowID

    // Raise the specific window under the cursor so focus lands on the
    // right one even within the same app (shared helper in WindowKey).
    focusWindow(pid: info.pid, windowID: info.windowID)
  }

  private func modifiersIndicateDisable(_ flags: NSEvent.ModifierFlags) -> Bool {
    switch config.disableModifier {
    case .none: return false
    case .option: return flags.contains(.option)
    case .command: return flags.contains(.command)
    case .control: return flags.contains(.control)
    case .shift: return flags.contains(.shift)
    }
  }

  /// macOS mouse events are bottom-origin Cocoa coordinates anchored to
  /// the primary screen. CGWindowListCopyWindowInfo bounds are
  /// top-origin Quartz coordinates anchored the same way. Flip the y
  /// before comparing.
  private func flippedCursorLocation() -> CGPoint {
    let cocoa = NSEvent.mouseLocation
    guard let primary = NSScreen.screens.first else { return cocoa }
    return CGPoint(x: cocoa.x, y: primary.frame.height - cocoa.y)
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

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "FocusFollowsMouse")
