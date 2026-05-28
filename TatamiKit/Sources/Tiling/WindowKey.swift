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
/// common macOS tiling tool relies on it because the public AX API
/// has no other way to correlate an AX window handle with a CGS
/// window record.
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
/// every common macOS tiling tool relies on); the magic and field
/// offsets below are dictated by the OS, not by any one project. The
/// technique was first written up publicly by decodism.
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
/// Recovered windows go through the same eligibility checks as the AX
/// walk: standard subrole + movable + resizable. Without that, a
/// dialog/sheet that AX had hidden could slip into the tree.
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
    guard isStandardTileable(window: element) else {
      remaining.remove(wid)
      continue
    }
    if isStickyWindow(wid) {
      remaining.remove(wid)
      continue
    }
    remaining.remove(wid)
    result.append(WindowKey(pid: pid, windowID: wid, bundleId: bundleId))
  }
  return result
}

/// Standard-window check combined with movability and resizability:
/// only true if the AX element claims standard subrole AND its
/// position/size attributes are settable. Non-tileable utility windows
/// (palettes, fixed-size HUDs) fail one of these.
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

// MARK: - Sticky (cross-Space) detection via private SkyLight API

private typealias SLSMainConnectionIDFn = @convention(c) () -> Int32
private typealias SLSCopySpacesForWindowsFn =
  @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

/// Loaded once at module init; `nil` if the private SkyLight framework
/// can't be opened (defensive — would only happen on a heavily-modified
/// system). Without it we just disable sticky filtering.
private nonisolated(unsafe) let _skyLightHandle: UnsafeMutableRawPointer? = dlopen(
  "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
  RTLD_NOW
)

private nonisolated(unsafe) let _SLSMainConnectionID: SLSMainConnectionIDFn? = {
  guard let h = _skyLightHandle, let sym = dlsym(h, "SLSMainConnectionID")
  else { return nil }
  return unsafeBitCast(sym, to: SLSMainConnectionIDFn.self)
}()

private nonisolated(unsafe) let _SLSCopySpacesForWindows: SLSCopySpacesForWindowsFn? = {
  guard let h = _skyLightHandle, let sym = dlsym(h, "SLSCopySpacesForWindows")
  else { return nil }
  return unsafeBitCast(sym, to: SLSCopySpacesForWindowsFn.self)
}()

/// True when the OS reports `windowID` as living in more than one
/// Space — i.e. it's pinned to "all desktops". Sticky windows must not
/// be tiled: they'd duplicate themselves into every workspace's tree
/// and the BSP layout would fight the OS over their position.
///
/// Mask `0x7` selects user + system + fullscreen-tile spaces, matching
/// the upstream sticky-window check.
@MainActor
func isStickyWindow(_ windowID: CGWindowID) -> Bool {
  guard let getConn = _SLSMainConnectionID,
        let getSpaces = _SLSCopySpacesForWindows
  else { return false }
  let cid = getConn()
  let ids: [CGWindowID] = [windowID]
  guard let spacesRaw = getSpaces(cid, 0x7, ids as CFArray)?.takeRetainedValue(),
        let spaces = spacesRaw as? [Any]
  else { return false }
  return spaces.count > 1
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
