import AppKit
import ApplicationServices
import CoreGraphics
import Dependencies
import Foundation

// MARK: - WindowKey

/// Stable, hashable identifier for a single macOS window.
///
/// Composed of the owning process pid and the system-wide
/// `CGWindowID`. Bound to a particular window for its lifetime — when
/// the user closes it, the same id never recurs, so it's safe to use
/// as the BSP tree leaf key.
public struct WindowKey: Hashable, Sendable, Codable {

  // MARK: Lifecycle

  public init(pid: pid_t, windowID: CGWindowID, bundleId: String) {
    self.pid = pid
    self.windowID = windowID
    self.bundleId = bundleId
  }

  // MARK: Public

  public var pid: pid_t
  public var windowID: CGWindowID
  public var bundleId: String

  /// Identity is `(pid, windowID)` — both are fixed for the window's lifetime
  /// and the pair never recurs. `bundleId` is a non-identifying payload
  /// (functionally determined by the window), so excluding it from equality
  /// and hashing keeps every Set / dictionary / BSP-leaf-key semantics
  /// identical while dropping per-key String hashing from every tree walk,
  /// frames lookup, and membership pass.
  public static func ==(lhs: WindowKey, rhs: WindowKey) -> Bool {
    lhs.pid == rhs.pid && lhs.windowID == rhs.windowID
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(pid)
    hasher.combine(windowID)
  }

}

// MARK: - SlotID

/// Occurrence-stable slot identity for a persisted layout leaf.
///
/// A saved layout can't reference a live `WindowKey` (pid/windowID are
/// reassigned across sessions), and a bare bundle id can't tell two windows of
/// one app apart. `SlotID` closes the gap: `occurrence` is the window's rank
/// among its app's windows sorted by `windowID` ascending. Within a session
/// windowIDs are stable, so a given window keeps its slot and a swap of two
/// same-app leaves persists which occurrence sits where. Across a full restart
/// windowIDs are reassigned, so the mapping is best-effort then.
public struct SlotID: Hashable, Sendable, Codable {
  public init(bundleId: String, occurrence: Int) {
    self.bundleId = bundleId
    self.occurrence = occurrence
  }

  public var bundleId: String
  public var occurrence: Int
}

/// Assign each live window its `SlotID` — occurrence = windowID-ascending rank
/// within its bundle. The Accessibility window order is unstable (and can drop
/// fullscreen windows), so windowID is the deterministic anchor.
public func slotAssignment(_ keys: [WindowKey]) -> [WindowKey: SlotID] {
  var byBundle = [String: [WindowKey]]()
  for key in keys { byBundle[key.bundleId, default: []].append(key) }
  var out = [WindowKey: SlotID]()
  for (bundleId, group) in byBundle {
    for (idx, key) in group.sorted(by: { $0.windowID < $1.windowID }).enumerated() {
      out[key] = SlotID(bundleId: bundleId, occurrence: idx)
    }
  }
  return out
}

/// Inverse of `slotAssignment` — the live window for each slot.
public func slotToKey(_ keys: [WindowKey]) -> [SlotID: WindowKey] {
  var out = [SlotID: WindowKey]()
  for (key, slot) in slotAssignment(keys) { out[slot] = key }
  return out
}

/// Private Accessibility bridge that maps an `AXUIElement` to its
/// `CGWindowID`. Apple has shipped this symbol since 10.10; every
/// common macOS tiling tool relies on it because the public AX API
/// has no other way to correlate an AX window handle with a CGS
/// window record.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(
  _ element: AXUIElement,
  _ identifier: UnsafeMutablePointer<CGWindowID>,
) -> AXError

extension WindowKey {
  /// Resolve a window's `WindowKey` from its `AXUIElement`. Fails if
  /// the bridge does (usually means the window has already been
  /// destroyed).
  @MainActor
  public init?(axWindow: AXUIElement, pid: pid_t, bundleId: String) {
    var wid: CGWindowID = 0
    guard _AXUIElementGetWindow(axWindow, &wid) == .success, wid != 0 else {
      return nil
    }
    self.init(pid: pid, windowID: wid, bundleId: bundleId)
  }
}

/// Raise + focus a specific window. The gentle path uses public AX; the
/// force-front path routes through `SLSClient.focusWindow`.
/// `forceFront` (deliberate switches: window cycling, directional focus,
/// activation) makes the target the frontmost *application* via SLPS, so a
/// cross-app switch actually moves keyboard focus. Focus-follows-mouse selects
/// between these paths by comparing the current and target processes below.
@MainActor
public func focusWindow(pid: pid_t, windowID: CGWindowID, forceFront: Bool = false) {
  // Let the floating overlay put its mirrors back up *before* the focus
  // moves, so a floating window never visibly drops behind the newly
  // focused tile (see MirrorWindowRegistry.setWillFocusHandler). When a
  // mirror was actually restored in this turn, give the window server one
  // beat (~a frame) to commit it before activating — issuing both in the
  // same runloop turn intermittently let the target's raise win the frame
  // race, which showed as the floating window dipping behind for an
  // instant. The focus-follows-mouse throttle (50 ms) dwarfs the delay.
  let restoredMirrors = MirrorWindowRegistry.shared.notifyWillFocus(pid: pid)
  @Dependency(\.debugLog) var debugLog
  debugLog.log(
    "FocusDiag",
    "focusWindow pid=\(pid) wid=\(windowID) deferred=\(restoredMirrors) front=\(forceFront)",
  )
  if restoredMirrors {
    DispatchQueue.main.asyncAfter(deadline: .now() + mirrorCommitBeat) {
      MainActor.assumeIsolated { performFocus(pid: pid, windowID: windowID, forceFront: forceFront) }
    }
  } else {
    performFocus(pid: pid, windowID: windowID, forceFront: forceFront)
  }
}

/// Focus policy for a hover target. AX raise is sufficient within one app, but
/// a different app must become the WindowServer front process; otherwise the
/// window can raise visually while keyboard focus stays in the old app. Treat
/// an unknown frontmost process as a required transfer too.
func focusFollowsMouseNeedsFrontmostTransfer(
  frontmostPID: pid_t?,
  targetPID: pid_t,
) -> Bool {
  frontmostPID != targetPID
}

/// Focus a hover target using the least forceful path that satisfies FFM's
/// contract. Same-app window changes remain a plain AX raise; cross-app changes
/// use the same synthesized user-generated SLS focus as other reliable window
/// switches, including on a secondary display.
@MainActor
func focusWindowFollowingMouse(pid: pid_t, windowID: CGWindowID) {
  let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
  focusWindow(
    pid: pid,
    windowID: windowID,
    forceFront: focusFollowsMouseNeedsFrontmostTransfer(
      frontmostPID: frontmostPID,
      targetPID: pid,
    ),
  )
}

/// Force an app to the front when we don't have a specific target window (a
/// workspace switch whose focus target has no MRU / pinned window — e.g. first
/// visit to a workspace). Resolves the app's main window (else its first) and
/// routes through the same SLPS force-front path, so an accessory app actually
/// transfers the frontmost application even on a secondary display. Falls back
/// to a best-effort `activate()` only if no AX window can be resolved.
@MainActor
public func focusAppFront(pid: pid_t) {
  let axApp = AXUIElementCreateApplication(pid)
  var raw: CFTypeRef?
  var candidates = [AXUIElement]()
  if
    AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &raw) == .success,
    let value = raw, CFGetTypeID(value) == AXUIElementGetTypeID()
  {
    candidates.append(value as! AXUIElement)
  }
  if
    AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &raw) == .success,
    let windows = raw as? [AXUIElement]
  {
    candidates.append(contentsOf: windows)
  }
  for element in candidates where !axWindowIsMinimized(element) {
    var wid: CGWindowID = 0
    guard _AXUIElementGetWindow(element, &wid) == .success, wid != 0 else { continue }
    // Resolve once and disallow another fallback from this best-effort path,
    // avoiding recursion if the AX window list changes between the reads.
    performFocus(
      pid: pid,
      windowID: wid,
      forceFront: true,
      fallbackToAppFront: false,
    )
    return
  }
  NSRunningApplication(processIdentifier: pid)?.activate()
}

/// How long a just-restored mirror gets to commit to the window server
/// before the activation raises the target — roughly two display frames.
/// Issuing both in the same runloop turn intermittently let the raise win
/// the frame race; the focus-follows-mouse throttle (50 ms) dwarfs this.
private let mirrorCommitBeat: TimeInterval = 0.03

@MainActor
private func performFocus(
  pid: pid_t,
  windowID: CGWindowID,
  forceFront: Bool = false,
  fallbackToAppFront: Bool = true,
) {
  // Gentle same-app focus activates up front. Cross-app FFM and deliberate
  // switches defer to SLPS below, which transfers frontmost itself.
  if !forceFront, let app = NSRunningApplication(processIdentifier: pid) {
    app.activate()
  }
  let axApp = AXUIElementCreateApplication(pid)
  var raw: CFTypeRef?
  guard
    AXUIElementCopyAttributeValue(
      axApp,
      kAXWindowsAttribute as CFString,
      &raw,
    ) == .success,
    let windows = raw as? [AXUIElement]
  else {
    // Window list unreadable — for a deliberate switch still bring the app up.
    if forceFront { NSRunningApplication(processIdentifier: pid)?.activate() }
    return
  }
  for window in windows {
    var wid: CGWindowID = 0
    guard _AXUIElementGetWindow(window, &wid) == .success, wid == windowID else { continue }
    // Never de-minimize a window the user minimized: raising a minimized
    // window restores it. Auto-open is the only intended restore path.
    if axWindowIsMinimized(window) { return }
    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    if forceFront {
      // A deliberate switch must make `pid` the frontmost *application* so
      // keyboard focus follows and the focus resolver (frontmost-app based)
      // observes the change — otherwise cross-app window cycling stalls, the
      // window raising but the front app never changing. NSRunningApplication
      // .activate() from an accessory app can't do this reliably (esp. on a
      // secondary display); SLPS can (and does the AX raise itself).
      @Dependency(\.sls) var sls
      sls.focusWindow(pid, windowID, window)
    } else {
      AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
    return
  }
  // An MRU key can go stale between the reducer's last sync and activation.
  // Deliberate focus then fronts the app's current main/first non-minimized
  // window instead of silently leaving keyboard focus in the old workspace.
  if forceFront, fallbackToAppFront { focusAppFront(pid: pid) }
}

/// Whether an AX window element is minimized. Missing/unreadable attribute
/// reads as not-minimized (raise proceeds) — the conservative default.
func axWindowIsMinimized(_ window: AXUIElement) -> Bool {
  var raw: CFTypeRef?
  guard
    AXUIElementCopyAttributeValue(
      window,
      kAXMinimizedAttribute as CFString,
      &raw,
    ) == .success, let value = raw as? Bool
  else { return false }
  return value
}
