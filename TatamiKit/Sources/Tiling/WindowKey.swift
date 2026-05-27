import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Stable, hashable identifier for a single macOS window.
///
/// Composed of the owning process pid and the system-wide
/// `CGWindowID`. Bound to a particular window for its lifetime — when
/// the user closes it, the same id never recurs, so it is safe to use
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
/// modern macOS tiling WM (yabai, AeroSpace, Amethyst) relies on it
/// because the public AX API has no other way to correlate an AX
/// window handle with a CGS window record.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(
  _ element: AXUIElement,
  _ identifier: UnsafeMutablePointer<CGWindowID>
) -> AXError

extension WindowKey {
  /// Resolve a window's `WindowKey` from its `AXUIElement`. Returns
  /// nil if the bridge fails (rare — usually means the window has
  /// already been destroyed).
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

/// Raise + focus a specific window by its owning pid and `CGWindowID`.
/// Activates the app and then raises the exact window so focus lands on
/// the right one even when an app owns several (directional focus,
/// focus-follows-mouse, etc.).
@MainActor
public func focusWindow(pid: pid_t, windowID: CGWindowID) {
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
