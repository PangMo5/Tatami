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
public func focusWindow(
  pid: pid_t,
  windowID: CGWindowID,
  forceFront: Bool = false,
) async {
  await focusWindow(
    pid: pid,
    windowID: windowID,
    forceFront: forceFront,
    willPerformAXFocus: nil,
  )
}

@MainActor
private func focusWindow(
  pid: pid_t,
  windowID: CGWindowID,
  forceFront: Bool,
  willPerformAXFocus: (@Sendable () -> Void)?,
) async {
  guard !Task.isCancelled else { return }
  // Capture user-intent order on MainActor before the mirror commit suspension
  // or the hop to the generic AX worker. Issuing this token inside the worker
  // lets an older suspended request start later and invalidate a newer focus.
  let request = focusAXLatestRequest.begin()
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
    do {
      try await Task.sleep(for: mirrorCommitBeat)
    } catch {
      return
    }
  }
  guard
    !Task.isCancelled,
    focusAXLatestRequest.isCurrent(request)
  else { return }

  // AppKit activation stays on the main actor. All timeout-prone AX lookup,
  // reads, writes, and raises run on the dedicated focus worker below.
  if !forceFront {
    guard
      !Task.isCancelled,
      focusAXLatestRequest.isCurrent(request)
    else { return }
    NSRunningApplication(processIdentifier: pid)?.activate()
  }
  @Dependency(\.sls) var sls
  let result = await performFocusOffMain(
    pid: pid,
    windowID: windowID,
    forceFront: forceFront,
    fallbackToAppFront: true,
    sls: sls,
    request: request,
    willPerformAXFocus: willPerformAXFocus,
  )
  guard
    !Task.isCancelled,
    focusAXLatestRequest.isCurrent(request)
  else { return }
  if case .activateApp = result {
    NSRunningApplication(processIdentifier: pid)?.activate()
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
func focusWindowFollowingMouse(
  pid: pid_t,
  windowID: CGWindowID,
  willPerformAXFocus: @escaping @Sendable () -> Void,
) async {
  let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
  await focusWindow(
    pid: pid,
    windowID: windowID,
    forceFront: focusFollowsMouseNeedsFrontmostTransfer(
      frontmostPID: frontmostPID,
      targetPID: pid,
    ),
    willPerformAXFocus: willPerformAXFocus,
  )
}

/// Force an app to the front when we don't have a specific target window (a
/// workspace switch whose focus target has no MRU / pinned window — e.g. first
/// visit to a workspace). Resolves the app's main window (else its first) and
/// routes through the same SLPS force-front path, so an accessory app actually
/// transfers the frontmost application even on a secondary display. Falls back
/// to a best-effort `activate()` only if no AX window can be resolved.
@MainActor
public func focusAppFront(pid: pid_t) async {
  guard !Task.isCancelled else { return }
  let request = focusAXLatestRequest.begin()
  @Dependency(\.sls) var sls
  let result = await focusAppFrontOffMain(
    pid: pid,
    sls: sls,
    request: request,
  )
  guard
    !Task.isCancelled,
    focusAXLatestRequest.isCurrent(request)
  else { return }
  if case .activateApp = result {
    NSRunningApplication(processIdentifier: pid)?.activate()
  }
}

/// How long a just-restored mirror gets to commit to the window server
/// before the activation raises the target — roughly two display frames.
/// Issuing both in the same runloop turn intermittently let the raise win
/// the frame race. This is an awaited suspension, so callers do not observe
/// focus completion (or warp the pointer) before the delayed raise actually
/// finishes.
private let mirrorCommitBeat = Duration.milliseconds(30)

// MARK: - FocusAXResult

enum FocusAXResult: Sendable, Equatable {
  case completed
  case activateApp
  case cancelled
}

/// AX calls are synchronous cross-process IPC. Each process gets one serial,
/// user-initiated lane: focus order stays deterministic within an app, while a
/// busy app can no longer hold up focus requests for unrelated processes.
private let focusAXQueues = AXPIDSerialQueueRegistry(
  label: "dev.PangMo5.Tatami.ax-window-focus"
)
private let focusAXLatestRequest = FocusAXLatestRequest()
private let focusAXMutationLock = NSLock()
private let focusAXMessagingTimeout: Float = 0.25

// MARK: - AXPIDSerialQueueRegistry

/// Maps synchronous AX IPC to one serial GCD lane per target process.
///
/// Queue selection is itself synchronous (callers immediately enqueue a GCD
/// block), so a narrow lock protects only the PID-to-queue map. AX work never
/// runs under the lock.
final class AXPIDSerialQueueRegistry: @unchecked Sendable {

  // MARK: Lifecycle

  init(label: String) {
    self.label = label
  }

  // MARK: Internal

  func queue(for pid: pid_t) -> DispatchQueue {
    lock.withLock {
      if let queue = queues[pid] {
        return queue
      }
      let queue = DispatchQueue(
        label: "\(label).pid-\(pid)",
        qos: .userInitiated,
      )
      queues[pid] = queue
      return queue
    }
  }

  // MARK: Private

  private let label: String
  private let lock = NSLock()
  private var queues = [pid_t: DispatchQueue]()

}

// MARK: - FocusAXLatestRequest

/// A process-independent sequence keeps concurrent PID lanes latest-wins.
///
/// Reads and target lookup may overlap across apps, but every blocking step
/// checks this generation before the final mutation. The mutation itself is a
/// short global critical section so an older request cannot pass its last
/// check, pause, and steal focus back after a newer PID has focused.
final class FocusAXLatestRequest: @unchecked Sendable {

  // MARK: Internal

  func begin() -> UInt64 {
    lock.withLock {
      generation &+= 1
      return generation
    }
  }

  func isCurrent(_ candidate: UInt64) -> Bool {
    lock.withLock { generation == candidate }
  }

  // MARK: Private

  private let lock = NSLock()
  private var generation: UInt64 = 0

}

// MARK: - FocusAXCancellationFlag

/// GCD work does not inherit Swift task cancellation. This synchronous flag is
/// checked before and between blocking AX messages so a superseded FFM request
/// can leave the serial lane without applying stale focus.
private final class FocusAXCancellationFlag: @unchecked Sendable {

  // MARK: Internal

  var isCancelled: Bool {
    lock.withLock { cancelled }
  }

  func cancel() {
    lock.withLock { cancelled = true }
  }

  // MARK: Private

  private let lock = NSLock()
  private var cancelled = false

}

private func performFocusOffMain(
  pid: pid_t,
  windowID: CGWindowID,
  forceFront: Bool,
  fallbackToAppFront: Bool,
  sls: SLSClient,
  request: UInt64,
  willPerformAXFocus: (@Sendable () -> Void)?,
) async -> FocusAXResult {
  let cancellation = FocusAXCancellationFlag()
  return await withTaskCancellationHandler {
    await withCheckedContinuation { continuation in
      focusAXQueues.queue(for: pid).async {
        continuation.resume(
          returning: performFocusAX(
            pid: pid,
            windowID: windowID,
            forceFront: forceFront,
            fallbackToAppFront: fallbackToAppFront,
            sls: sls,
            isCancelled: {
              cancellation.isCancelled
                || !focusAXLatestRequest.isCurrent(request)
            },
            willPerformAXFocus: willPerformAXFocus,
          )
        )
      }
    }
  } onCancel: {
    cancellation.cancel()
  }
}

private func focusAppFrontOffMain(
  pid: pid_t,
  sls: SLSClient,
  request: UInt64,
) async -> FocusAXResult {
  let cancellation = FocusAXCancellationFlag()
  return await withTaskCancellationHandler {
    await withCheckedContinuation { continuation in
      focusAXQueues.queue(for: pid).async {
        continuation.resume(
          returning: focusAppFrontAX(
            pid: pid,
            sls: sls,
            isCancelled: {
              cancellation.isCancelled
                || !focusAXLatestRequest.isCurrent(request)
            },
          )
        )
      }
    }
  } onCancel: {
    cancellation.cancel()
  }
}

private func focusAppFrontAX(
  pid: pid_t,
  sls: SLSClient,
  isCancelled: @Sendable () -> Bool,
) -> FocusAXResult {
  guard !isCancelled() else { return .cancelled }
  let axApp = AXUIElementCreateApplication(pid)
  AXUIElementSetMessagingTimeout(axApp, focusAXMessagingTimeout)
  var raw: CFTypeRef?
  guard !isCancelled() else { return .cancelled }
  if
    AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &raw) == .success,
    let value = raw,
    CFGetTypeID(value) == AXUIElementGetTypeID()
  {
    let element = value as! AXUIElement
    AXUIElementSetMessagingTimeout(element, focusAXMessagingTimeout)
    guard !isCancelled() else { return .cancelled }
    if !axWindowIsMinimized(element) {
      guard !isCancelled() else { return .cancelled }
      var windowID: CGWindowID = 0
      if
        _AXUIElementGetWindow(element, &windowID) == .success,
        windowID != 0
      {
        return focusResolvedWindowAX(
          pid: pid,
          windowID: windowID,
          window: element,
          forceFront: true,
          sls: sls,
          isCancelled: isCancelled,
          checkMinimized: false,
        )
      }
    }
  }
  guard !isCancelled() else { return .cancelled }
  raw = nil
  if
    AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &raw) == .success,
    let windows = raw as? [AXUIElement]
  {
    for element in windows {
      guard !isCancelled() else { return .cancelled }
      AXUIElementSetMessagingTimeout(element, focusAXMessagingTimeout)
      guard !axWindowIsMinimized(element) else { continue }
      guard !isCancelled() else { return .cancelled }
      var windowID: CGWindowID = 0
      guard
        _AXUIElementGetWindow(element, &windowID) == .success,
        windowID != 0
      else { continue }
      return focusResolvedWindowAX(
        pid: pid,
        windowID: windowID,
        window: element,
        forceFront: true,
        sls: sls,
        isCancelled: isCancelled,
        checkMinimized: false,
      )
    }
  }
  return isCancelled() ? .cancelled : .activateApp
}

private func performFocusAX(
  pid: pid_t,
  windowID: CGWindowID,
  forceFront: Bool = false,
  fallbackToAppFront: Bool = true,
  sls: SLSClient,
  isCancelled: @Sendable () -> Bool,
  willPerformAXFocus: (@Sendable () -> Void)?,
) -> FocusAXResult {
  guard !isCancelled() else { return .cancelled }
  let axApp = AXUIElementCreateApplication(pid)
  AXUIElementSetMessagingTimeout(axApp, focusAXMessagingTimeout)
  // FFM can re-enter the window it already focused after an MFF warp resets
  // event-tap deduplication. A no-op AX main/raise is not guaranteed to emit a
  // focus notification, so recording pointer origin for it would leave a
  // phantom queue entry. Cross-app `forceFront` must still transfer the front
  // process even when this app remembers the same focused window.
  if
    !forceFront,
    willPerformAXFocus != nil,
    focusedWindowID(of: axApp) == windowID
  {
    return .completed
  }
  guard !isCancelled() else { return .cancelled }
  var raw: CFTypeRef?
  guard
    AXUIElementCopyAttributeValue(
      axApp,
      kAXWindowsAttribute as CFString,
      &raw,
    ) == .success,
    let windows = raw as? [AXUIElement]
  else {
    // Window list unreadable — ask the main actor to bring the app up after
    // the worker returns, preserving the old deliberate-switch fallback.
    return focusAXFallbackResult(
      forceFront: forceFront,
      isCancelled: isCancelled,
    )
  }
  for window in windows {
    guard !isCancelled() else { return .cancelled }
    AXUIElementSetMessagingTimeout(window, focusAXMessagingTimeout)
    var wid: CGWindowID = 0
    guard _AXUIElementGetWindow(window, &wid) == .success, wid == windowID else { continue }
    return focusResolvedWindowAX(
      pid: pid,
      windowID: windowID,
      window: window,
      forceFront: forceFront,
      sls: sls,
      isCancelled: isCancelled,
      willPerformAXFocus: willPerformAXFocus,
    )
  }
  // An MRU key can go stale between the reducer's last sync and activation.
  // Deliberate focus then fronts the app's current main/first non-minimized
  // window instead of silently leaving keyboard focus in the old workspace.
  if forceFront, fallbackToAppFront {
    return focusAppFrontAX(pid: pid, sls: sls, isCancelled: isCancelled)
  }
  return isCancelled() ? .cancelled : .completed
}

/// A blocking AX lookup can become stale while it waits on the target app.
/// Revalidate the request before asking MainActor to run the AppKit fallback;
/// returning `.activateApp` for a superseded request would steal focus back.
func focusAXFallbackResult(
  forceFront: Bool,
  isCancelled: @Sendable () -> Bool,
) -> FocusAXResult {
  guard !isCancelled() else { return .cancelled }
  return forceFront ? .activateApp : .completed
}

private func focusedWindowID(of app: AXUIElement) -> CGWindowID? {
  var raw: CFTypeRef?
  guard
    AXUIElementCopyAttributeValue(
      app,
      kAXFocusedWindowAttribute as CFString,
      &raw,
    ) == .success,
    let value = raw,
    CFGetTypeID(value) == AXUIElementGetTypeID()
  else { return nil }
  var windowID: CGWindowID = 0
  guard
    _AXUIElementGetWindow(value as! AXUIElement, &windowID) == .success,
    windowID != 0
  else { return nil }
  return windowID
}

private func focusResolvedWindowAX(
  pid: pid_t,
  windowID: CGWindowID,
  window: AXUIElement,
  forceFront: Bool,
  sls: SLSClient,
  isCancelled: @Sendable () -> Bool,
  checkMinimized: Bool = true,
  willPerformAXFocus: (@Sendable () -> Void)? = nil,
) -> FocusAXResult {
  guard !isCancelled() else { return .cancelled }
  // Never de-minimize a window the user minimized: raising a minimized
  // window restores it. Auto-open is the only intended restore path.
  if checkMinimized, axWindowIsMinimized(window) { return .completed }
  // Pointer-origin bookkeeping must happen only after this request reaches
  // the serial AX lane and survives cancellation. Recording in the caller
  // leaves a phantom origin when a newer mouse move cancels queued work.
  let applied = focusAXMutationLock.withLock {
    guard
      beginAXFocusMutationIfCurrent(
        isCancelled: isCancelled,
        willPerformAXFocus: willPerformAXFocus,
      )
    else { return false }
    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    if forceFront {
      // A deliberate switch must make `pid` the frontmost *application* so
      // keyboard focus follows and the focus resolver (frontmost-app based)
      // observes the change — otherwise cross-app window cycling stalls, the
      // window raising but the front app never changing. NSRunningApplication
      // .activate() from an accessory app can't do this reliably (esp. on a
      // secondary display); SLPS can (and does the AX raise itself).
      sls.focusWindow(pid, windowID, window)
    } else {
      AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
    return true
  }
  return applied ? .completed : .cancelled
}

/// Treat origin recording and the following synchronous AX mutation as one
/// admission edge: once admitted, cancellation is observed only after the
/// mutation. This prevents a canceled queued FFM request from leaving origin
/// state without ever issuing the focus operation it describes.
func beginAXFocusMutationIfCurrent(
  isCancelled: @Sendable () -> Bool,
  willPerformAXFocus: (@Sendable () -> Void)?,
) -> Bool {
  guard !isCancelled() else { return false }
  willPerformAXFocus?()
  return true
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
