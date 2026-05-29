import AppKit
import ApplicationServices
import Dependencies
import DependenciesMacros
import Foundation
import OSLog

/// Applies a precomputed set of `(WindowKey → frame)` assignments via
/// Accessibility. BSP tree math lives in the reducer; this dependency
/// just talks to AX, handles the macOS-fullscreen exit dance, and
/// suppresses system animations with the `AXEnhancedUserInterface`
/// toggle so frames snap into place without animation. No custom
/// animation pipeline — frames are written directly.
@DependencyClient
public struct WindowTilerClient: Sendable {
  public var apply: @Sendable (FrameApplication) async -> Void
}

public struct FrameApplication: Sendable, Hashable {
  public var windowFrames: [WindowKey: CGRect]
  public var targetDisplay: DisplayName?

  public init(
    windowFrames: [WindowKey: CGRect],
    targetDisplay: DisplayName?
  ) {
    self.windowFrames = windowFrames
    self.targetDisplay = targetDisplay
  }
}

extension WindowTilerClient: DependencyKey {
  public static let liveValue = WindowTilerClient { request in
    guard !request.windowFrames.isEmpty else {
      logger.debug("apply: no frames to apply")
      return
    }
    let trusted = await MainActor.run { ensureAccessibilityTrust() }
    guard trusted else {
      logger.warning(
        """
        Accessibility permission not granted — open System Settings → \
        Privacy & Security → Accessibility and enable Tatami.
        """
      )
      return
    }
    await MainActor.run {
      logger.info("apply: \(request.windowFrames.count) frames")
      // Group frames by pid so we can toggle EnhancedUserInterface
      // once per app instead of once per window.
      let grouped = Dictionary(grouping: request.windowFrames, by: { $0.key.pid })
      for (pid, entries) in grouped {
        applyForApp(pid: pid, entries: entries)
      }
    }
  }

  public static let testValue = WindowTilerClient(apply: { _ in })
  public static let previewValue = testValue

  @MainActor
  private static func applyForApp(
    pid: pid_t,
    entries: [(key: WindowKey, value: CGRect)]
  ) {
    let axApp = AXUIElementCreateApplication(pid)
    // Cap how long any single AX write can block the main thread. The
    // default has no practical ceiling, so one unresponsive app could
    // wedge the whole tile pass (and the UI) indefinitely.
    AXUIElementSetMessagingTimeout(axApp, 1.0)

    // Discover every window once + map CGWindowID → AXUIElement.
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      axApp,
      kAXWindowsAttribute as CFString,
      &raw
    ) == .success,
      let windows = raw as? [AXUIElement]
    else { return }

    var lookup: [CGWindowID: AXUIElement] = [:]
    for window in windows {
      var wid: CGWindowID = 0
      if _AXUIElementGetWindow(window, &wid) == .success, wid != 0 {
        lookup[wid] = window
      }
    }

    // AXEnhancedUserInterface workaround. With the attribute ON,
    // AppKit animates every AX frame change (Chrome/Electron
    // especially) — the "windows slide into place" effect. If it's on,
    // turn it OFF for the duration of the move/resize, then restore.
    // We do NOT turn it on otherwise — doing so causes stray
    // animations.
    let enhanced = "AXEnhancedUserInterface" as CFString
    var enhancedWasOn = false
    var enhancedRaw: CFTypeRef?
    if AXUIElementCopyAttributeValue(axApp, enhanced, &enhancedRaw) == .success,
       let value = enhancedRaw as? Bool
    {
      enhancedWasOn = value
    }
    if enhancedWasOn {
      _ = AXUIElementSetAttributeValue(axApp, enhanced, kCFBooleanFalse)
    }
    defer {
      if enhancedWasOn {
        _ = AXUIElementSetAttributeValue(axApp, enhanced, kCFBooleanTrue)
      }
    }

    for (key, frame) in entries {
      guard let window = lookup[key.windowID] else {
        logger.info("apply \(key.bundleId, privacy: .public)#\(key.windowID) → missing-window")
        continue
      }
      let outcome = applyFrame(frame, to: window)
      logger.info(
        "apply \(key.bundleId, privacy: .public)#\(key.windowID) → \(frame.debugDescription, privacy: .public) = \(outcome, privacy: .public)"
      )
    }
  }

  @MainActor
  private static func applyFrame(_ frame: CGRect, to window: AXUIElement) -> String {
    if isFullScreen(window) {
      _ = AXUIElementSetAttributeValue(
        window,
        "AXFullScreen" as CFString,
        false as CFTypeRef
      )
    }

    var posError = AXError.success
    var position = CGPoint(x: frame.minX, y: frame.minY)
    if let posValue = AXValueCreate(.cgPoint, &position) {
      posError = AXUIElementSetAttributeValue(
        window, kAXPositionAttribute as CFString, posValue
      )
    }
    var sizeError = AXError.success
    var size = CGSize(width: frame.width, height: frame.height)
    if let sizeValue = AXValueCreate(.cgSize, &size) {
      sizeError = AXUIElementSetAttributeValue(
        window, kAXSizeAttribute as CFString, sizeValue
      )
    }

    if posError == .success, sizeError == .success { return "ok" }
    return "pos=\(posError.rawValue) size=\(sizeError.rawValue)"
  }

  @MainActor
  private static func isFullScreen(_ window: AXUIElement) -> Bool {
    var raw: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(
      window,
      "AXFullScreen" as CFString,
      &raw
    )
    guard result == .success, let value = raw as? Bool else { return false }
    return value
  }
}

extension DependencyValues {
  public var windowTiler: WindowTilerClient {
    get { self[WindowTilerClient.self] }
    set { self[WindowTilerClient.self] = newValue }
  }
}

/// Resolve the AX work area of the named screen (or the main screen
/// if `name` is nil). Top-origin, anchored to the primary screen —
/// same convention as `kAXPositionAttribute`.
public enum ScreenGeometry {
  @MainActor
  public static func workArea(for name: DisplayName?) -> CGRect {
    let screen: NSScreen?
    if let name {
      screen = NSScreen.screens.first(where: { $0.localizedName == name.rawValue })
        ?? NSScreen.main
    } else {
      screen = NSScreen.main
    }
    guard let screen, let primary = NSScreen.screens.first else { return .zero }
    let primaryHeight = primary.frame.height
    let v = screen.visibleFrame
    let axY = primaryHeight - v.origin.y - v.height
    return CGRect(x: v.origin.x, y: axY, width: v.width, height: v.height)
  }
}

@MainActor
@discardableResult
public func ensureAccessibilityTrust() -> Bool {
  if AXIsProcessTrusted() { return true }
  let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
  return AXIsProcessTrustedWithOptions(options)
}

/// All visible, regular, tile-able windows that belong to the given
/// bundle identifiers, paired with their `WindowKey`s. Used by the
/// activation reducer to compute the BSP target set.
///
/// Sticky-window filtering uses the provided `SLSClient` (a window
/// that lives in more than one Space is "pinned to all desktops" and
/// must not be tiled). Windows AX cannot enumerate are *not* recovered
/// via remote-token brute-force — that fallback was removed for
/// being too brittle. Windows the OS hides from AX (e.g. some apps'
/// Notification-Center popups) will simply not be tiled.
@MainActor
public func discoverWindowKeys(
  forBundleIds bundleIds: [String],
  sls: SLSClient
) -> [WindowKey] {
  guard !bundleIds.isEmpty else { return [] }
  @Dependency(\.debugLog) var debugLog

  // Resolve all running app pids in one pass.
  var pidByBundle: [String: pid_t] = [:]
  for app in NSWorkspace.shared.runningApplications
  where !app.isTerminated && app.activationPolicy == .regular {
    if let bid = app.bundleIdentifier, pidByBundle[bid] == nil {
      pidByBundle[bid] = app.processIdentifier
    }
  }

  var result: [WindowKey] = []
  let attrs = [
    kAXMinimizedAttribute,
    kAXSubroleAttribute,
  ] as CFArray
  for bundleId in bundleIds {
    guard let pid = pidByBundle[bundleId] else {
      debugLog.log("Tiler", "discover \(bundleId): no running pid")
      continue
    }
    let axApp = AXUIElementCreateApplication(pid)
    // Same rationale as the tile pass: bound the per-message wait so a
    // hung app can't stall discovery (and the main thread) indefinitely.
    AXUIElementSetMessagingTimeout(axApp, 1.0)
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      axApp,
      kAXWindowsAttribute as CFString,
      &raw
    ) == .success, let windows = raw as? [AXUIElement] else {
      debugLog.log("Tiler", "discover \(bundleId) pid=\(pid): AX kAXWindowsAttribute empty/failed")
      continue
    }
    let before = result.count
    var rejected: [String] = []
    for window in windows {
      var widProbe: CGWindowID = 0
      _ = _AXUIElementGetWindow(window, &widProbe)
      var valuesRef: CFArray?
      var minimized = false
      var subrole: String?
      if AXUIElementCopyMultipleAttributeValues(
        window, attrs, AXCopyMultipleAttributeOptions(), &valuesRef
      ) == .success, let values = valuesRef as? [Any], values.count == 2 {
        minimized = (values[0] as? Bool) ?? false
        subrole = values[1] as? String
      }
      if minimized {
        rejected.append("\(widProbe):minimized")
        continue
      }
      // Standard windows only. Dialogs / IME indicators / tooltips
      // fall outside this set, so they never enter the tree.
      if let subrole, subrole != kAXStandardWindowSubrole as String {
        rejected.append("\(widProbe):subrole=\(subrole)")
        continue
      }
      // Position + size must be settable, else we'd write to a window
      // the host app rejects.
      var movable: DarwinBoolean = false
      var resizable: DarwinBoolean = false
      AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &movable)
      AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &resizable)
      if !movable.boolValue || !resizable.boolValue {
        rejected.append("\(widProbe):notSettable(mov=\(movable.boolValue),res=\(resizable.boolValue))")
        continue
      }
      if let key = WindowKey.from(axWindow: window, pid: pid, bundleId: bundleId) {
        // Sticky windows (pinned to all Spaces) must not be tiled —
        // they'd duplicate into every workspace's tree.
        if sls.spacesForWindow(key.windowID).count > 1 {
          rejected.append("\(widProbe):sticky")
          continue
        }
        result.append(key)
      } else {
        rejected.append("\(widProbe):noWid")
      }
    }
    let kept = result[before...].map { $0.windowID }
    debugLog.log(
      "Tiler",
      "discover \(bundleId) pid=\(pid) axCount=\(windows.count) kept=\(kept) rejected=\(rejected)"
    )
  }
  return result
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "WindowTiler")
