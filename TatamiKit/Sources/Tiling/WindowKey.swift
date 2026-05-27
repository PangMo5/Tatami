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

/// Private AX bridge that builds an `AXUIElement` from a "remote token"
/// (pid + magic + element id). Used to recover window elements that
/// `kAXWindowsAttribute` omits — some apps (KakaoTalk) and windows on
/// inactive Spaces.
///
/// The token's binary layout is an undocumented macOS ABI (the same one
/// every tiling WM relies on — yabai, AeroSpace, Hammerspoon); the magic
/// and field offsets below are dictated by the OS, not by any one
/// project. The technique was first written up publicly by decodism.
@_silgen_name("_AXUIElementCreateWithRemoteToken")
func _AXUIElementCreateWithRemoteToken(_ data: CFData) -> Unmanaged<AXUIElement>?

/// On-screen, layer-0 window ids owned by `pid` (public SkyLight wrapper).
/// Used to detect windows AX failed to enumerate.
@MainActor
func onScreenWindowIDs(pid: pid_t) -> Set<CGWindowID> {
  let info = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
  ) as? [[String: Any]] ?? []
  var ids: Set<CGWindowID> = []
  for entry in info {
    guard (entry[kCGWindowOwnerPID as String] as? pid_t) == pid,
          (entry[kCGWindowLayer as String] as? Int) == 0,
          let wid = entry[kCGWindowNumber as String] as? CGWindowID
    else { continue }
    ids.insert(wid)
  }
  return ids
}

/// Recover `WindowKey`s for windows present on screen but missing from
/// `kAXWindowsAttribute`, by brute-forcing the AX remote-token element
/// id until each missing CGWindowID resolves to an `AXWindow` element.
@MainActor
func recoverWindowKeys(
  pid: pid_t,
  missing: Set<CGWindowID>,
  bundleId: String
) -> [WindowKey] {
  guard !missing.isEmpty, let data = NSMutableData(length: 0x14) else { return [] }
  let raw = data.mutableBytes
  raw.storeBytes(of: UInt32(pid), toByteOffset: 0x0, as: UInt32.self)
  raw.storeBytes(of: UInt32(0x636f_636f), toByteOffset: 0x8, as: UInt32.self)

  var remaining = missing
  var result: [WindowKey] = []
  var elementId: UInt64 = 0
  while elementId < 0x7fff, !remaining.isEmpty {
    raw.storeBytes(of: elementId, toByteOffset: 0xc, as: UInt64.self)
    elementId += 1
    guard let element = _AXUIElementCreateWithRemoteToken(data as CFData)?
      .takeRetainedValue()
    else { continue }
    var roleRaw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRaw) == .success,
          (roleRaw as? String) == kAXWindowRole as String
    else { continue }
    var wid: CGWindowID = 0
    guard _AXUIElementGetWindow(element, &wid) == .success,
          remaining.contains(wid)
    else { continue }
    remaining.remove(wid)
    result.append(WindowKey(pid: pid, windowID: wid, bundleId: bundleId))
  }
  return result
}

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
