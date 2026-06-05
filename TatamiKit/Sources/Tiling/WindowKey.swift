import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Stable, hashable identifier for a single macOS window.
///
/// Composed of the owning process pid and the system-wide
/// `CGWindowID`. Bound to a particular window for its lifetime — when
/// the user closes it, the same id never recurs, so it's safe to use
/// as the BSP tree leaf key.
public struct WindowKey: Hashable, Sendable, Codable {
  public var pid: pid_t
  public var windowID: CGWindowID
  public var bundleId: String

  public init(pid: pid_t, windowID: CGWindowID, bundleId: String) {
    self.pid = pid
    self.windowID = windowID
    self.bundleId = bundleId
  }
}

/// Private Accessibility bridge that maps an `AXUIElement` to its
/// `CGWindowID`. Apple has shipped this symbol since 10.10; every
/// common macOS tiling tool relies on it because the public AX API
/// has no other way to correlate an AX window handle with a CGS
/// window record.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(
  _ element: AXUIElement,
  _ identifier: UnsafeMutablePointer<CGWindowID>
) -> AXError

/// Standard-window check combined with movability + resizability. Only
/// true if the AX element claims standard subrole AND its position/size
/// attributes are settable. Non-tileable utility windows fail one of
/// these.
@MainActor
func isStandardTileable(window: AXUIElement) -> Bool {
  var subroleRaw: CFTypeRef?
  guard AXUIElementCopyAttributeValue(
    window, kAXSubroleAttribute as CFString, &subroleRaw
  ) == .success,
        (subroleRaw as? String) == kAXStandardWindowSubrole as String
  else { return false }
  var movable: DarwinBoolean = false
  var resizable: DarwinBoolean = false
  AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &movable)
  AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &resizable)
  return movable.boolValue && resizable.boolValue
}

extension WindowKey {
  /// Resolve a window's `WindowKey` from its `AXUIElement`. Returns
  /// nil if the bridge fails (usually means the window has already
  /// been destroyed).
  @MainActor
  public static func from(
    axWindow: AXUIElement,
    pid: pid_t,
    bundleId: String
  ) -> WindowKey? {
    var wid: CGWindowID = 0
    guard _AXUIElementGetWindow(axWindow, &wid) == .success, wid != 0 else {
      return nil
    }
    return WindowKey(pid: pid, windowID: wid, bundleId: bundleId)
  }
}

/// Raise + focus a specific window using public AX only. Used by
/// focus-follows-mouse where we don't need the full SLPS event
/// annotation — the OS already considers the click that produced the
/// move event as user-driven. For activation-time focus that has to
/// override existing layering, route through `SLSClient.focusWindow`.
@MainActor
public func focusWindow(pid: pid_t, windowID: CGWindowID) {
  // Let the floating overlay put its mirrors back up *before* the focus
  // moves, so a floating window never visibly drops behind the newly
  // focused tile (see MirrorWindowRegistry.setWillFocusHandler). When a
  // mirror was actually restored in this turn, give the window server one
  // beat (~a frame) to commit it before activating — issuing both in the
  // same runloop turn intermittently let the target's raise win the frame
  // race, which showed as the floating window dipping behind for an
  // instant. The focus-follows-mouse throttle (50 ms) dwarfs the delay.
  let restoredMirrors = MirrorWindowRegistry.shared.notifyWillFocus(pid: pid)
  if restoredMirrors {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
      MainActor.assumeIsolated { performFocus(pid: pid, windowID: windowID) }
    }
  } else {
    performFocus(pid: pid, windowID: windowID)
  }
}

@MainActor
private func performFocus(pid: pid_t, windowID: CGWindowID) {
  if let app = NSRunningApplication(processIdentifier: pid) {
    app.activate(options: [.activateIgnoringOtherApps])
  }
  let axApp = AXUIElementCreateApplication(pid)
  var raw: CFTypeRef?
  guard AXUIElementCopyAttributeValue(
    axApp, kAXWindowsAttribute as CFString, &raw
  ) == .success,
    let windows = raw as? [AXUIElement]
  else { return }
  for window in windows {
    var wid: CGWindowID = 0
    guard _AXUIElementGetWindow(window, &wid) == .success, wid == windowID else { continue }
    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    break
  }
}
