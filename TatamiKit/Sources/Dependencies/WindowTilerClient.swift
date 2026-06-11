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
struct WindowTilerClient: Sendable {
  var apply: @Sendable (FrameApplication) async -> Void
}

struct FrameApplication: Sendable, Hashable {
  var windowFrames: [WindowKey: CGRect]
  var targetDisplay: DisplayName?

  init(
    windowFrames: [WindowKey: CGRect],
    targetDisplay: DisplayName?
  ) {
    self.windowFrames = windowFrames
    self.targetDisplay = targetDisplay
  }
}

extension WindowTilerClient: DependencyKey {
  static let liveValue = WindowTilerClient { request in
    guard !request.windowFrames.isEmpty else {
      logger.debug("apply: no frames to apply")
      return
    }
    // Non-prompting check: prompting here would re-pop the system dialog on
    // every tile pass while ungranted. The single startup prompt + the
    // Settings → General → Permissions UI own the prompting.
    let trusted = await MainActor.run { isAccessibilityTrusted() }
    guard trusted else {
      logger.warning(
        """
        Accessibility permission not granted — open System Settings → \
        Privacy & Security → Accessibility and enable Tatami.
        """
      )
      return
    }
    logger.info("apply: \(request.windowFrames.count) frames")
    // Group frames by pid so we can toggle EnhancedUserInterface
    // once per app instead of once per window.
    let grouped = Dictionary(grouping: request.windowFrames, by: { $0.key.pid })
    // Hop to the main actor once per app, not once for the whole pass.
    // Every AX write blocks on the target app's run loop (up to the 1 s
    // cap), so a single block would hold the main thread for the *sum*
    // of every busy app's stalls — HUD and mirrors freeze with it.
    // The cancellation check is what makes a superseding pass's
    // `cancelInFlight` effective mid-apply: without it a cancelled apply
    // would keep writing stale frames between the newer pass's hops.
    for (pid, entries) in grouped {
      guard !Task.isCancelled else { return }
      await MainActor.run { applyForApp(pid: pid, entries: entries) }
    }
  }

  static let testValue = WindowTilerClient(apply: { _ in })
  static let previewValue = testValue

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
  var windowTiler: WindowTilerClient {
    get { self[WindowTilerClient.self] }
    set { self[WindowTilerClient.self] = newValue }
  }
}

/// Resolve the AX work area of the named screen (or the main screen
/// if `name` is nil). Top-origin, anchored to the primary screen —
/// same convention as `kAXPositionAttribute`.
enum ScreenGeometry {
  @MainActor
  static func workArea(for name: DisplayName?) -> CGRect {
    // Resolve UUID → name → primary; the primary display also anchors the
    // AX (top-left) coordinate flip.
    guard let screen = DisplayResolver.screenOrPrimary(for: name),
          let primary = DisplayResolver.primaryScreen() else { return .zero }
    let primaryHeight = primary.frame.height
    let v = screen.visibleFrame
    let axY = primaryHeight - v.origin.y - v.height
    return CGRect(x: v.origin.x, y: axY, width: v.width, height: v.height)
  }
}

/// Bound every AX message this process sends (call once at startup).
///
/// The per-app-element `AXUIElementSetMessagingTimeout(axApp, …)` calls
/// only cover messages to that app element itself — the *window* elements
/// pulled out of `kAXWindowsAttribute` keep the system default (~6 s), so
/// one beachballing app (Electron mid-GC, a paused-in-debugger app) could
/// wedge the main thread for 6 s × per-window calls per tile pass. Setting
/// the timeout on the system-wide element makes it the process-global
/// default for all elements; per-element values still override it.
@MainActor
func boundGlobalAXMessagingTimeout() {
  AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
}

@MainActor
@discardableResult
func ensureAccessibilityTrust() -> Bool {
  if AXIsProcessTrusted() { return true }
  let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
  return AXIsProcessTrustedWithOptions(options)
}

/// Non-prompting check of the current Accessibility trust state. Use for
/// status display; use `ensureAccessibilityTrust()` to also prompt.
@MainActor
func isAccessibilityTrusted() -> Bool {
  AXIsProcessTrusted()
}

/// Result of an AX window-discovery pass.
struct WindowDiscovery: Sendable {
  var keys: [WindowKey] = []
  /// Bundles where an AX read failed outright (messaging timeout — a
  /// busy, hung, or dying app): "couldn't ask", as opposed to "asked and
  /// there were no windows". Their keys are *omitted* from `keys`;
  /// consumers must preserve last-known state for them instead of
  /// treating the app as windowless — otherwise one slow app under
  /// system load reads as "all windows closed" and gets dropped from
  /// trees, mirrors, and markers.
  var unreachable: Set<String> = []
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
///
/// `requireResizable` is the tiling default: the BSP pass must be able to
/// write the window's size. Floating discovery passes `false` — a mirror
/// only needs the window to be movable, and fixed-size windows (the iOS
/// Simulator's device windows report `AXSize` as not settable) float fine.
@MainActor
func discoverWindowKeys(
  forBundleIds bundleIds: [String],
  sls: SLSClient,
  requireResizable: Bool = true
) -> WindowDiscovery {
  guard !bundleIds.isEmpty else { return WindowDiscovery() }
  @Dependency(\.debugLog) var debugLog
  // Per-window reject/keep bookkeeping exists only for the log line —
  // don't pay for the strings and arrays while logging is off.
  let logging = debugLog.isEnabled()

  // Resolve *every* running pid per bundle id. Some apps (e.g. Neovide)
  // run one process per window under a shared bundle id, so keying by
  // bundle id alone — taking only the first pid — misses every window
  // owned by a sibling process. Scan them all.
  var pidsByBundle: [String: [pid_t]] = [:]
  for app in NSWorkspace.shared.runningApplications
  where !app.isTerminated && app.activationPolicy == .regular {
    if let bid = app.bundleIdentifier {
      pidsByBundle[bid, default: []].append(app.processIdentifier)
    }
  }

  var result: [WindowKey] = []
  var unreachable: Set<String> = []
  let attrs = [
    kAXMinimizedAttribute,
    kAXSubroleAttribute,
  ] as CFArray
  for bundleId in bundleIds {
    let pids = pidsByBundle[bundleId] ?? []
    guard !pids.isEmpty else {
      debugLog.log("Tiler", "discover \(bundleId): no running pid")
      continue
    }
    for pid in pids {
      let axApp = AXUIElementCreateApplication(pid)
      // Same rationale as the tile pass: bound the per-message wait so a
      // hung app can't stall discovery (and the main thread) indefinitely.
      AXUIElementSetMessagingTimeout(axApp, 1.0)
      var raw: CFTypeRef?
      let windowsError = AXUIElementCopyAttributeValue(
        axApp,
        kAXWindowsAttribute as CFString,
        &raw
      )
      guard windowsError == .success, let windows = raw as? [AXUIElement] else {
        // `.noValue` / `.attributeUnsupported` are real answers ("no
        // windows"); anything else means the app never replied — a
        // timeout must not read as "all windows closed".
        if windowsError != .noValue, windowsError != .attributeUnsupported {
          unreachable.insert(bundleId)
        }
        debugLog.log(
          "Tiler",
          "discover \(bundleId) pid=\(pid): AX kAXWindowsAttribute err=\(windowsError.rawValue)"
        )
        continue
      }
      let before = result.count
      var rejected: [String] = []
      func reject(_ widProbe: CGWindowID, _ reason: @autoclosure () -> String) {
        if logging { rejected.append("\(widProbe):\(reason())") }
      }
      for window in windows {
        var widProbe: CGWindowID = 0
        _ = _AXUIElementGetWindow(window, &widProbe)
        var valuesRef: CFArray?
        var minimized = false
        var subrole: String?
        let attrsError = AXUIElementCopyMultipleAttributeValues(
          window, attrs, AXCopyMultipleAttributeOptions(), &valuesRef
        )
        // An app that stops replying mid-enumeration would make every
        // remaining window wait out the full timeout too — mark it
        // unreachable and stop asking.
        if attrsError == .cannotComplete {
          unreachable.insert(bundleId)
          reject(widProbe, "timeout")
          break
        }
        if attrsError == .success, let values = valuesRef as? [Any], values.count == 2 {
          minimized = (values[0] as? Bool) ?? false
          subrole = values[1] as? String
        }
        if minimized {
          reject(widProbe, "minimized")
          continue
        }
        // Standard windows only. Dialogs / IME indicators / tooltips
        // fall outside this set, so they never enter the tree.
        if let subrole, subrole != kAXStandardWindowSubrole as String {
          reject(widProbe, "subrole=\(subrole)")
          continue
        }
        // Position must be settable, else we'd write to a window the host
        // app rejects; size additionally for tiling (see `requireResizable`).
        var movable: DarwinBoolean = false
        var resizable: DarwinBoolean = false
        let movError = AXUIElementIsAttributeSettable(
          window, kAXPositionAttribute as CFString, &movable
        )
        let resError = AXUIElementIsAttributeSettable(
          window, kAXSizeAttribute as CFString, &resizable
        )
        if movError == .cannotComplete || resError == .cannotComplete {
          unreachable.insert(bundleId)
          reject(widProbe, "timeout")
          break
        }
        if !movable.boolValue || (requireResizable && !resizable.boolValue) {
          reject(widProbe, "notSettable(mov=\(movable.boolValue),res=\(resizable.boolValue))")
          continue
        }
        if let key = WindowKey(axWindow: window, pid: pid, bundleId: bundleId) {
          // Sticky windows (pinned to all Spaces) must not be tiled —
          // they'd duplicate into every workspace's tree.
          if sls.spacesForWindow(key.windowID).count > 1 {
            reject(widProbe, "sticky")
            continue
          }
          result.append(key)
        } else {
          reject(widProbe, "noWid")
        }
      }
      if logging {
        let kept = result[before...].map { $0.windowID }
        debugLog.log(
          "Tiler",
          "discover \(bundleId) pid=\(pid) axCount=\(windows.count) kept=\(kept) rejected=\(rejected)"
        )
      }
    }
  }
  // An unreachable bundle contributes no keys at all — a partial list
  // (the windows validated before the timeout hit) would read as "the
  // other windows closed". Consumers substitute last-known state.
  if !unreachable.isEmpty {
    result.removeAll { unreachable.contains($0.bundleId) }
  }
  return WindowDiscovery(keys: result, unreachable: unreachable)
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "WindowTiler")
