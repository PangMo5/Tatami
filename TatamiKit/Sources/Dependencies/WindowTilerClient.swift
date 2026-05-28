import AppKit
import ApplicationServices
import Dependencies
import DependenciesMacros
import Foundation
import OSLog

/// Applies a precomputed set of `(WindowKey → frame)` assignments via
/// Accessibility. BSP tree maths live in the reducer; this dependency
/// just talks to AX, handles the macOS-fullscreen exit dance, and
/// suppresses system animations with the `AXEnhancedUserInterface`
/// toggle so frames snap into place without animation.
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
    // Record expected frames so the observer can ignore the AX
    // resize/move notifications that our own setAttribute calls fire.
    WindowTilerSuppression.shared.record(request.windowFrames)
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

    // With AXEnhancedUserInterface ON, AppKit animates every AX frame
    // change (Chrome/Electron especially) — the "windows slide into
    // place" effect. If it's on, turn it OFF for the duration of the
    // move/resize, then restore. If it's already off, don't touch it.
    // (We do NOT turn it on — doing so is what caused the stray
    // animations.)
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
@MainActor
public func discoverWindowKeys(forBundleIds bundleIds: [String]) -> [WindowKey] {
  guard !bundleIds.isEmpty else { return [] }

  // Resolve all running app pids in one pass instead of querying
  // NSRunningApplication per bundle id.
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
    guard let pid = pidByBundle[bundleId] else { continue }
    let axApp = AXUIElementCreateApplication(pid)
    var raw: CFTypeRef?
    var axWindowIDs: Set<CGWindowID> = []
    if AXUIElementCopyAttributeValue(
      axApp,
      kAXWindowsAttribute as CFString,
      &raw
    ) == .success, let windows = raw as? [AXUIElement] {
      for window in windows {
        // Record every AX-visible window's CGWindowID up front (before
        // user filters) so the CG-vs-AX diff below correctly excludes
        // dialogs/sheets that AX already exposed. Otherwise a window
        // we explicitly chose to skip would re-enter via remote-token
        // recovery — defeating the filter.
        var rawID: CGWindowID = 0
        if _AXUIElementGetWindow(window, &rawID) == .success, rawID != 0 {
          axWindowIDs.insert(rawID)
        }
        // One AX round-trip for both filters (minimized + subrole)
        // instead of two, then one more for the CGWindowID bridge.
        var valuesRef: CFArray?
        var minimized = false
        var subrole: String?
        if AXUIElementCopyMultipleAttributeValues(
          window, attrs, AXCopyMultipleAttributeOptions(), &valuesRef
        ) == .success, let values = valuesRef as? [Any], values.count == 2 {
          minimized = (values[0] as? Bool) ?? false
          subrole = values[1] as? String
        }
        if minimized { continue }
        // Standard windows only. Dialogs / IME indicators / tooltips
        // fall outside this set, so they never enter the tree. Apps
        // whose "real" windows arrive hidden from AX (KakaoTalk chats
        // opened via the Notification Center, etc.) are caught by the
        // remote-token recovery pass below.
        if let subrole, subrole != kAXStandardWindowSubrole as String { continue }
        // Position + size must be settable, else we'd write to a window
        // the host app rejects.
        var movable: DarwinBoolean = false
        var resizable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &movable)
        AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &resizable)
        if !movable.boolValue || !resizable.boolValue { continue }
        if let key = WindowKey.from(axWindow: window, pid: pid, bundleId: bundleId) {
          // Sticky windows (pinned to all Spaces) must not be tiled —
          // they'd duplicate into every workspace's tree.
          if isStickyWindow(key.windowID) { continue }
          result.append(key)
        }
      }
    }

    // Recover windows on screen that AX failed to enumerate (KakaoTalk,
    // inactive-Space windows) via the remote-token workaround.
    let missing = onScreenWindowIDs(pid: pid).subtracting(axWindowIDs)
    result.append(
      contentsOf: recoverWindowKeys(pid: pid, missing: missing, bundleId: bundleId)
    )
  }
  return result
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "WindowTiler")

/// Bookkeeping for tiler-driven frame writes so the AX observer can
/// distinguish notifications we caused from genuine user resize/move
/// events.
///
/// AX delivers resize/move notifications on the main thread within a
/// few hundred microseconds of `AXUIElementSetAttributeValue`, so a
/// last-write cache without explicit expiry is enough — user drags
/// trail the apply call by orders of magnitude. The lookup is
/// "consume": once an alert matches the recorded frame it's cleared,
/// so a real user drag that lands on the same coordinates later is
/// still surfaced.
public final class WindowTilerSuppression: @unchecked Sendable {
  public static let shared = WindowTilerSuppression()

  private let lock = NSLock()
  private var pending: [WindowKey: CGRect] = [:]

  public func record(_ frames: [WindowKey: CGRect]) {
    lock.lock(); defer { lock.unlock() }
    for (key, frame) in frames {
      pending[key] = frame
    }
  }

  public func shouldIgnore(key: WindowKey, frame: CGRect) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard let expected = pending[key] else { return false }
    let tolerance: CGFloat = 2.0
    let close =
      abs(expected.minX - frame.minX) <= tolerance
      && abs(expected.minY - frame.minY) <= tolerance
      && abs(expected.width - frame.width) <= tolerance
      && abs(expected.height - frame.height) <= tolerance
    if close { pending[key] = nil }
    return close
  }
}
