// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ApplicationServices
import Dependencies
import DependenciesMacros
import Foundation
import OSLog

// MARK: - WindowTilerClient

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

// MARK: - FrameApplication

struct FrameApplication: Sendable, Hashable {
  var windowFrames: [WindowKey: CGRect]
  /// User-driven BSP mutations need the newest complete frame set to win even
  /// when an older same-app AX batch was already executing when cancelled.
  /// Ordinary activation/layout passes keep the fresh-geometry skip fast path.
  var forceAllFrames = false
}

// MARK: - WindowFrameApplyCoordinator

/// Keeps unrelated apps out of each other's AX critical path.
///
/// Each submission reserves its place on every PID lane before taking the fast
/// WindowServer snapshot. A lane that was busy at reservation time always gets
/// one queued revalidation, even when the outer snapshot looked current, so an
/// older partial write cannot land after the fast path and leave stale geometry
/// behind. Reservations are submitted in-order even when concurrent preflights
/// finish out-of-order.
final class WindowFrameApplyCoordinator: Sendable {

  // MARK: Lifecycle

  init(
    currentFrames: @escaping CurrentFrames,
    applyForPID: @escaping ApplyForPID,
    didSkip: @escaping DidSkip = { _ in },
  ) {
    self.currentFrames = currentFrames
    self.applyForPID = applyForPID
    self.didSkip = didSkip
  }

  // MARK: Internal

  enum Skip: Sendable, Equatable {
    case request(frameCount: Int)
    case pid(pid_t, frameCount: Int)
  }

  typealias CancellationCheck = @Sendable () -> Bool
  typealias CurrentFrames = @Sendable () -> [CGWindowID: CGRect]
  typealias ApplyForPID = @Sendable (
    _ pid: pid_t,
    _ frames: [WindowKey: CGRect],
    _ visibleFrames: [CGWindowID: CGRect],
    _ forceAllFrames: Bool,
    _ isCancelled: @escaping CancellationCheck,
  ) -> Void
  typealias DidSkip = @Sendable (Skip) -> Void

  func apply(_ request: FrameApplication) async {
    guard !request.windowFrames.isEmpty, !Task.isCancelled else { return }

    let framesByPID = Dictionary(grouping: request.windowFrames, by: { $0.key.pid })
      .mapValues { Dictionary(uniqueKeysWithValues: $0) }
    let reservation = await laneRegistry.reserve(pids: Array(framesByPID.keys))
    guard !Task.isCancelled else {
      for ticket in reservation.tickets.values {
        ticket.lane.completeWithoutWork(ticket: ticket.ticket)
      }
      return
    }

    // Keep the cheap WindowServer probe out of every AX lane. Already-current
    // PIDs with an idle lane return without queueing any worker operation.
    let initialVisibleFrames = currentFrames()
    let initiallyPending = WindowTilerClient.framesNeedingApply(
      targets: request.windowFrames,
      visibleFrames: initialVisibleFrames,
      forceAllFrames: request.forceAllFrames,
    )
    let pidsNeedingWrite = Set(initiallyPending.keys.map(\.pid))
    let work = framesByPID.compactMap { pid, frames -> PIDWork? in
      guard let ticket = reservation.tickets[pid] else { return nil }
      return PIDWork(
        pid: pid,
        frames: frames,
        lane: ticket.lane,
        ticket: ticket.ticket,
        needsWrite: pidsNeedingWrite.contains(pid),
        wasBusy: ticket.wasBusy,
      )
    }
    let queuedWork = work.filter { $0.needsWrite || $0.wasBusy }
    for item in work where !item.needsWrite && !item.wasBusy {
      item.lane.completeWithoutWork(ticket: item.ticket)
    }
    guard !queuedWork.isEmpty else {
      didSkip(.request(frameCount: request.windowFrames.count))
      return
    }

    let cancellation = SynchronousCancellationFlag()
    let currentFramesSnapshot = currentFrames
    let applyPID = applyForPID
    let reportSkip = didSkip
    await withTaskCancellationHandler {
      await withTaskGroup(of: Void.self) { group in
        for item in queuedWork {
          group.addTask {
            await item.lane.perform(
              ticket: item.ticket
            ) {
              let isCancelled: CancellationCheck = { cancellation.isCancelled }
              guard !isCancelled() else { return }

              // An older same-PID operation may have completed or partially
              // written since the fast preflight. Re-snapshot only after a
              // busy lane reaches us. An idle lane has no older Tatami writer,
              // so the shared fast snapshot is already its exact baseline and
              // avoids one full WindowServer enumeration per app.
              let visibleFrames = item.wasBusy
                ? currentFramesSnapshot()
                : initialVisibleFrames
              let pendingFrames = WindowTilerClient.framesNeedingApply(
                targets: item.frames,
                visibleFrames: visibleFrames,
                forceAllFrames: request.forceAllFrames,
              )
              guard !pendingFrames.isEmpty else {
                reportSkip(.pid(item.pid, frameCount: item.frames.count))
                return
              }
              applyPID(
                item.pid,
                pendingFrames,
                visibleFrames,
                request.forceAllFrames,
                isCancelled,
              )
            }
          }
        }
      }
    } onCancel: {
      cancellation.cancel()
    }
  }

  // MARK: Private

  private struct PIDWork: Sendable {
    var pid: pid_t
    var frames: [WindowKey: CGRect]
    var lane: WindowFrameApplyLane
    var ticket: UInt64
    var needsWrite: Bool
    var wasBusy: Bool
  }

  private let currentFrames: CurrentFrames
  private let applyForPID: ApplyForPID
  private let didSkip: DidSkip
  private let laneRegistry = WindowFrameApplyLaneRegistry()

}

// MARK: - WindowFrameApplyReservation

private struct WindowFrameApplyReservation: Sendable {
  var tickets: [pid_t: WindowFrameApplyLaneTicket]
}

// MARK: - WindowFrameApplyLaneTicket

private struct WindowFrameApplyLaneTicket: Sendable {
  var lane: WindowFrameApplyLane
  var ticket: UInt64
  var wasBusy: Bool
}

// MARK: - WindowFrameApplyLaneRegistry

private actor WindowFrameApplyLaneRegistry {

  // MARK: Internal

  func reserve(pids: [pid_t]) -> WindowFrameApplyReservation {
    var tickets = [pid_t: WindowFrameApplyLaneTicket]()
    tickets.reserveCapacity(pids.count)
    for pid in pids {
      let lane: WindowFrameApplyLane
      if let existing = lanes[pid] {
        lane = existing
      } else {
        lane = WindowFrameApplyLane(pid: pid)
        lanes[pid] = lane
      }
      let reservation = lane.reserve()
      tickets[pid] = WindowFrameApplyLaneTicket(
        lane: lane,
        ticket: reservation.ticket,
        wasBusy: reservation.wasBusy,
      )
    }
    return WindowFrameApplyReservation(tickets: tickets)
  }

  // MARK: Private

  private var lanes = [pid_t: WindowFrameApplyLane]()

}

// MARK: - WindowFrameApplyLane

/// The lock only protects synchronous admission metadata. Blocking AX calls run
/// on `queue`; they never execute while the lock is held.
private final class WindowFrameApplyLane: @unchecked Sendable {

  // MARK: Lifecycle

  init(pid: pid_t) {
    queue = DispatchQueue(
      label: "dev.PangMo5.Tatami.ax-frame-apply.\(pid)",
      qos: .userInitiated,
    )
  }

  // MARK: Internal

  /// Reserve ordering before WindowServer preflight. `wasBusy` includes older
  /// reservations whose preflight has not submitted yet, not only work already
  /// running on the Dispatch queue.
  func reserve() -> (ticket: UInt64, wasBusy: Bool) {
    lock.withLock {
      nextTicket &+= 1
      let wasBusy = unresolvedReservationCount > 0
      unresolvedReservationCount += 1
      return (ticket: nextTicket, wasBusy: wasBusy)
    }
  }

  func completeWithoutWork(ticket: UInt64) {
    let ready = lock.withLock {
      submissions[ticket] = .noWork
      return dequeueReadySubmissions()
    }
    enqueue(ready)
  }

  func perform(
    ticket: UInt64,
    _ operation: @escaping @Sendable () -> Void,
  ) async {
    await withCheckedContinuation { continuation in
      let ready = lock.withLock {
        submissions[ticket] = .work(operation, continuation)
        return dequeueReadySubmissions()
      }
      enqueue(ready)
    }
  }

  // MARK: Private

  private enum Submission {
    case noWork
    case work(@Sendable () -> Void, CheckedContinuation<Void, Never>)
  }

  private let queue: DispatchQueue
  private let lock = NSLock()
  private var nextTicket: UInt64 = 0
  private var nextTicketToEnqueue: UInt64 = 1
  private var unresolvedReservationCount = 0
  private var submissions = [UInt64: Submission]()

  private func dequeueReadySubmissions() -> [Submission] {
    var ready = [Submission]()
    while let submission = submissions.removeValue(forKey: nextTicketToEnqueue) {
      nextTicketToEnqueue &+= 1
      if case .noWork = submission {
        unresolvedReservationCount -= 1
      }
      ready.append(submission)
    }
    return ready
  }

  private func enqueue(_ submissions: [Submission]) {
    for submission in submissions {
      switch submission {
      case .noWork:
        continue
      case .work(let operation, let continuation):
        queue.async { [self] in
          operation()
          lock.withLock {
            self.unresolvedReservationCount -= 1
          }
          continuation.resume()
        }
      }
    }
  }

}

// MARK: - WindowTilerClient + DependencyKey

extension WindowTilerClient: DependencyKey {

  // MARK: Internal

  enum FrameWritePlan: Equatable {
    case none
    case resizeOnly
    case moveOnly
    case moveAndResizeOnce
    case moveAndResizeTwice
  }

  static let liveValue = WindowTilerClient { request in
    guard !request.windowFrames.isEmpty else { return }
    guard !Task.isCancelled else { return }
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
      @Dependency(\.debugLog) var debugLog
      debugLog.log("Tiler", "apply skipped: accessibility not granted")
      return
    }
    guard !Task.isCancelled else { return }
    await frameApplyCoordinator.apply(request)
  }

  static let testValue = WindowTilerClient(apply: { _ in })
  static let previewValue = testValue

  /// Select the smallest AX mutation that can converge the current frame.
  ///
  /// A resize at the same origin never crosses displays, and a pure move
  /// cannot be clamped to a different size. Only a simultaneous move and
  /// resize (or an off-screen window without fresh geometry) needs the
  /// repeated position/size pass used for cross-display convergence.
  static func frameWritePlan(
    current: CGRect?,
    target: CGRect,
    crossesDisplays: Bool? = nil,
    tolerance: CGFloat = 1,
  ) -> FrameWritePlan {
    guard let current else { return .moveAndResizeTwice }

    let originIsCurrent =
      abs(current.minX - target.minX) <= tolerance
        && abs(current.minY - target.minY) <= tolerance
    let sizeIsCurrent =
      abs(current.width - target.width) <= tolerance
        && abs(current.height - target.height) <= tolerance

    switch (originIsCurrent, sizeIsCurrent) {
    case (true, true):
      return .none
    case (true, false):
      return .resizeOnly
    case (false, true):
      return .moveOnly
    case (false, false):
      return crossesDisplays == false ? .moveAndResizeOnce : .moveAndResizeTwice
    }
  }

  /// Keep only targets whose fresh WindowServer geometry is absent or drifted.
  /// Internal for deterministic unit tests; the live path supplies one snapshot
  /// per tile pass, never an event-lagged cache.
  static func framesNeedingApply(
    targets: [WindowKey: CGRect],
    visibleFrames: [CGWindowID: CGRect],
    tolerance: CGFloat = 1,
    forceAllFrames: Bool = false,
  ) -> [WindowKey: CGRect] {
    if forceAllFrames { return targets }
    var pending = [WindowKey: CGRect]()
    pending.reserveCapacity(targets.count)
    for (key, target) in targets {
      if
        frameWritePlan(
          current: visibleFrames[key.windowID],
          target: target,
          tolerance: tolerance,
        ) != .none
      {
        pending[key] = target
      }
    }
    return pending
  }

  // MARK: Private

  private static let frameApplyCoordinator = WindowFrameApplyCoordinator(
    currentFrames: currentOnScreenWindowFrames,
    applyForPID: { pid, frames, visibleFrames, forceAllFrames, isCancelled in
      applyForApp(
        pid: pid,
        entries: Array(frames),
        visibleFrames: visibleFrames,
        forceAllFrames: forceAllFrames,
        isCancelled: isCancelled,
      )
    },
    didSkip: { skip in
      @Dependency(\.debugLog) var debugLog
      switch skip {
      case .request(let frameCount):
        debugLog.log("Tiler", "apply skipped: all \(frameCount) frames current")
      case .pid(let pid, let frameCount):
        debugLog.log(
          "Tiler",
          "apply pid=\(pid) skipped after revalidation: all \(frameCount) frames current",
        )
      }
    },
  )

  private static func applyForApp(
    pid: pid_t,
    entries: [(key: WindowKey, value: CGRect)],
    visibleFrames: [CGWindowID: CGRect],
    forceAllFrames: Bool,
    isCancelled: @escaping @Sendable () -> Bool,
  ) {
    @Dependency(\.debugLog) var debugLog
    let logging = debugLog.isEnabled()
    let axApp = AXUIElementCreateApplication(pid)
    // Cap how long any single AX write can occupy the worker. The default has
    // no practical ceiling, so one unresponsive app could otherwise wedge all
    // later frame writes indefinitely.
    AXUIElementSetMessagingTimeout(axApp, 1.0)

    // Discover every window once + map CGWindowID → AXUIElement.
    var raw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        axApp,
        kAXWindowsAttribute as CFString,
        &raw,
      ) == .success,
      let windows = raw as? [AXUIElement]
    else {
      // The whole app's frames silently don't land when this fails (busy
      // or hung app) — the "tiling didn't update" trace needs the line.
      debugLog.log("Tiler", "apply pid=\(pid): AX window list unavailable — skipped")
      return
    }
    guard !isCancelled() else { return }

    var lookup = [CGWindowID: AXUIElement]()
    for window in windows {
      guard !isCancelled() else { return }
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
    guard !isCancelled() else { return }
    if
      AXUIElementCopyAttributeValue(axApp, enhanced, &enhancedRaw) == .success,
      let value = enhancedRaw as? Bool
    {
      enhancedWasOn = value
    }
    guard !isCancelled() else { return }
    if enhancedWasOn {
      _ = AXUIElementSetAttributeValue(axApp, enhanced, kCFBooleanFalse)
    }
    defer {
      if enhancedWasOn {
        _ = AXUIElementSetAttributeValue(axApp, enhanced, kCFBooleanTrue)
      }
    }

    for (key, frame) in entries {
      guard !isCancelled() else { return }
      guard let window = lookup[key.windowID] else {
        debugLog.log("Tiler", "apply \(key.bundleId)#\(key.windowID) → missing-window")
        continue
      }
      let writeGeneration = WindowFrameWriteTracker.shared.begin(key, target: frame)
      let outcome = applyFrame(
        frame,
        currentFrame: forceAllFrames ? nil : visibleFrames[key.windowID],
        to: window,
        isCancelled: isCancelled,
      )
      WindowFrameWriteTracker.shared.finish(key, generation: writeGeneration)
      if logging {
        debugLog.log(
          "Tiler",
          "apply \(key.bundleId)#\(key.windowID) → \(frame) = \(outcome)",
        )
      }
    }
  }

  private static func applyFrame(
    _ frame: CGRect,
    currentFrame: CGRect?,
    to window: AXUIElement,
    isCancelled: @escaping @Sendable () -> Bool,
  ) -> String {
    // A native-fullscreen window is not ours to lay out. The old behavior
    // forced it out of fullscreen (`AXFullScreen = false`) before writing the
    // tiled frame — so the space-change reconcile that fires the instant the
    // user enters fullscreen bounced them straight back to the Desktop. Leave
    // it alone; the `isInFullscreenSpace` gate keeps the reconcile dormant too.
    guard !isCancelled() else { return "cancelled" }
    if isFullScreen(window) { return "skipped-fullscreen" }
    guard !isCancelled() else { return "cancelled" }

    func setPosition() -> AXError {
      var position = CGPoint(x: frame.minX, y: frame.minY)
      guard let value = AXValueCreate(.cgPoint, &position) else { return .success }
      return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }
    func setSize() -> AXError {
      var size = CGSize(width: frame.width, height: frame.height)
      guard let value = AXValueCreate(.cgSize, &size) else { return .success }
      return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }

    let crossesDisplays = currentFrame.flatMap {
      displayID(containing: CGPoint(x: $0.midX, y: $0.midY))
    }.flatMap { currentDisplay in
      displayID(containing: CGPoint(x: frame.midX, y: frame.midY))
        .map { $0 != currentDisplay }
    }

    switch frameWritePlan(
      current: currentFrame,
      target: frame,
      crossesDisplays: crossesDisplays,
    ) {
    case .none:
      return "skipped-current"

    case .resizeOnly:
      guard !isCancelled() else { return "cancelled" }
      let sizeError = setSize()
      return sizeError == .success ? "ok" : "size=\(sizeError.rawValue)"

    case .moveOnly:
      guard !isCancelled() else { return "cancelled" }
      let posError = setPosition()
      return posError == .success ? "ok" : "pos=\(posError.rawValue)"

    case .moveAndResizeOnce:
      // Same-display geometry has no old-display clamp. Resize first so the
      // final position write restores the exact origin if the target app
      // adjusts its frame while honoring min/max-size constraints.
      guard !isCancelled() else { return "cancelled" }
      let sizeError = setSize()
      guard !isCancelled() else { return "cancelled" }
      let posError = setPosition()
      if posError == .success, sizeError == .success { return "ok" }
      return "pos=\(posError.rawValue) size=\(sizeError.rawValue)"

    case .moveAndResizeTwice:
      // Moving a window to a larger display can clamp its size to the current
      // display before the position write lands. Repeat the pair only for this
      // path; the second pass now runs against the target display.
      // (yabai uses the same repeated set for cross-display convergence.)
      guard !isCancelled() else { return "cancelled" }
      _ = setPosition()
      guard !isCancelled() else { return "cancelled" }
      _ = setSize()
      guard !isCancelled() else { return "cancelled" }
      let posError = setPosition()
      guard !isCancelled() else { return "cancelled" }
      let sizeError = setSize()
      if posError == .success, sizeError == .success { return "ok" }
      return "pos=\(posError.rawValue) size=\(sizeError.rawValue)"
    }
  }

  private static func displayID(containing point: CGPoint) -> CGDirectDisplayID? {
    var displayID: CGDirectDisplayID = 0
    var count: UInt32 = 0
    guard
      CGGetDisplaysWithPoint(point, 1, &displayID, &count) == .success,
      count > 0
    else { return nil }
    return displayID
  }

  private static func isFullScreen(_ window: AXUIElement) -> Bool {
    var raw: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(
      window,
      "AXFullScreen" as CFString,
      &raw,
    )
    guard result == .success, let value = raw as? Bool else { return false }
    return value
  }

}

// MARK: - SynchronousCancellationFlag

/// GCD callbacks don't inherit Swift task cancellation. This lock-backed flag
/// bridges `withTaskCancellationHandler` into the synchronous AX worker and is
/// intentionally synchronous; an actor cannot be queried between blocking C
/// calls without making the worker itself asynchronous.
private final class SynchronousCancellationFlag: @unchecked Sendable {

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

extension DependencyValues {
  var windowTiler: WindowTilerClient {
    get { self[WindowTilerClient.self] }
    set { self[WindowTilerClient.self] = newValue }
  }
}

// MARK: - ScreenGeometry

/// Resolve the AX work area of the named screen (or the main screen
/// if `name` is nil). Top-origin, anchored to the primary screen —
/// same convention as `kAXPositionAttribute`.
enum ScreenGeometry {
  @MainActor
  static func workArea(for name: DisplayName?) -> CGRect {
    // Resolve UUID → name → primary; the primary display also anchors the
    // AX (top-left) coordinate flip.
    guard
      let screen = DisplayResolver.screenOrPrimary(for: name),
      let primary = DisplayResolver.primaryScreen()
    else { return .zero }
    let primaryHeight = primary.frame.height
    let v = screen.visibleFrame
    let axY = primaryHeight - v.origin.y - v.height
    return CGRect(x: v.origin.x, y: axY, width: v.width, height: v.height)
  }
}

// MARK: - WindowServerSurface

/// Fresh WindowServer geometry in AX/CG top-origin coordinates. Unlike AX,
/// this is one local snapshot with no target-app run-loop wait, so reducers can
/// safely use it to partition already-discovered keys without blocking input.
struct WindowServerSurface: Equatable, Sendable {
  var ownerPID: pid_t
  var layer: Int
  var frame: CGRect
}

/// One local WindowServer snapshot with enough ownership metadata to
/// distinguish a native-tab surface replacement from an ordinary hide/close.
/// Native tabs swap CGWindowIDs inside the same process; popup/menu layers are
/// excluded by consumers without paying an AX round trip.
func currentOnScreenWindowSurfaces() -> [CGWindowID: WindowServerSurface] {
  let raw = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements],
    kCGNullWindowID,
  ) as? [[String: Any]] ?? []
  var surfaces = [CGWindowID: WindowServerSurface]()
  surfaces.reserveCapacity(raw.count)
  for entry in raw {
    guard
      let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
      let ownerPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
      let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
      let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
      let x = bounds["X"], let y = bounds["Y"],
      let width = bounds["Width"], let height = bounds["Height"]
    else { continue }
    surfaces[windowID] = WindowServerSurface(
      ownerPID: ownerPID,
      layer: layer,
      frame: CGRect(x: x, y: y, width: width, height: height),
    )
  }
  return surfaces
}

func currentOnScreenWindowFrames() -> [CGWindowID: CGRect] {
  currentOnScreenWindowSurfaces().mapValues(\.frame)
}

/// Bound every AX message this process sends (call once at startup).
///
/// The per-app-element `AXUIElementSetMessagingTimeout(axApp, …)` calls
/// only cover messages to that app element itself — the *window* elements
/// pulled out of `kAXWindowsAttribute` keep the system default (~6 s), so
/// one beachballing app (Electron mid-GC, a paused-in-debugger app) could
/// occupy an AX worker for 6 s × per-window calls per tile pass. Setting the
/// timeout on the system-wide element makes it the process-global default for
/// all elements; per-element values still override it.
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

// MARK: - WindowDiscovery

/// Result of an AX window-discovery pass.
struct WindowDiscovery: Sendable {
  var keys = [WindowKey]()
  /// Bundles where an AX read failed outright (messaging timeout — a
  /// busy, hung, or dying app): "couldn't ask", as opposed to "asked and
  /// there were no windows". Their keys are *omitted* from `keys`;
  /// consumers must preserve last-known state for them instead of
  /// treating the app as windowless — otherwise one slow app under
  /// system load reads as "all windows closed" and gets dropped from
  /// trees, mirrors, and markers.
  var unreachable = Set<String>()
  /// Windows AX enumerated this pass but rejected *only* because their
  /// subrole momentarily read as non-standard (e.g. `AXDialog`). macOS
  /// flaps a window's subrole transiently — Activity Monitor's own main
  /// window reports `AXDialog` for a beat at launch — so a window a
  /// consumer already tracks must not be treated as closed on the strength
  /// of one flap. Its `WindowKey` is absent from `keys` (it failed the
  /// standard-subrole gate), so consumers preserve the last-known key for
  /// these ids, exactly as they do for `unreachable` bundles.
  var retained = Set<CGWindowID>()
}

// MARK: - WindowCapabilityDiscovery

/// Capability-complete result of one AX enumeration. Building both views from
/// one pass prevents a mixed tiled/unmanaged app from paying the per-window AX
/// cost twice for the same process snapshot.
struct WindowCapabilityDiscovery: Sendable {
  var movableKeys = [WindowKey]()
  var resizableKeys = [WindowKey]()
  var unreachable = Set<String>()
  var retained = Set<CGWindowID>()

  func discovery(requireResizable: Bool) -> WindowDiscovery {
    WindowDiscovery(
      keys: requireResizable ? resizableKeys : movableKeys,
      unreachable: unreachable,
      retained: retained,
    )
  }
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
  requireResizable: Bool = true,
) -> WindowDiscovery {
  discoverWindowCapabilities(
    forBundleIds: bundleIds,
    pidsByBundle: runningPIDsByBundle(bundleIds),
    sls: sls,
  ).discovery(requireResizable: requireResizable)
}

/// Main-actor entry point that captures the running-process snapshot and
/// returns both eligibility views from one AX pass.
@MainActor
func discoverWindowCapabilities(
  forBundleIds bundleIds: [String],
  sls: SLSClient,
) -> WindowCapabilityDiscovery {
  discoverWindowCapabilities(
    forBundleIds: bundleIds,
    pidsByBundle: runningPIDsByBundle(bundleIds),
    sls: sls,
  )
}

/// Capture the AppKit-owned running-application snapshot briefly, before AX
/// discovery moves to Tatami's serialized worker. Apple exposes AX observer
/// run-loop selection but does not explicitly document general AX thread
/// safety, so AX references stay confined to the worker that creates them.
@MainActor
func runningPIDsByBundle(_ bundleIds: [String]) -> [String: [pid_t]] {
  let requested = Set(bundleIds)
  var pidsByBundle = [String: [pid_t]]()
  for app in NSWorkspace.shared.runningApplications
    where !app.isTerminated && app.activationPolicy == .regular
  {
    if let bundleId = app.bundleIdentifier, requested.contains(bundleId) {
      pidsByBundle[bundleId, default: []].append(app.processIdentifier)
    }
  }
  for bundleId in pidsByBundle.keys {
    pidsByBundle[bundleId]?.sort()
  }
  return pidsByBundle
}

/// AX-only discovery core. Callers provide a main-actor-captured process
/// snapshot, allowing the synchronous IPC to run on an ordinary worker.
func discoverWindowKeys(
  forBundleIds bundleIds: [String],
  pidsByBundle: [String: [pid_t]],
  sls: SLSClient,
  requireResizable: Bool = true,
  isCancelled: @escaping @Sendable () -> Bool = { false },
) -> WindowDiscovery {
  discoverWindowCapabilities(
    forBundleIds: bundleIds,
    pidsByBundle: pidsByBundle,
    sls: sls,
    isCancelled: isCancelled,
  ).discovery(requireResizable: requireResizable)
}

/// Enumerate each process once and classify every eligible window into both
/// movable and resizable views from the same AX capability reads.
func discoverWindowCapabilities(
  forBundleIds bundleIds: [String],
  pidsByBundle: [String: [pid_t]],
  sls: SLSClient,
  isCancelled: @escaping @Sendable () -> Bool = { false },
) -> WindowCapabilityDiscovery {
  guard !bundleIds.isEmpty, !isCancelled() else {
    return WindowCapabilityDiscovery()
  }
  @Dependency(\.debugLog) var debugLog
  // Per-window reject/keep bookkeeping exists only for the log line —
  // don't pay for the strings and arrays while logging is off.
  let logging = debugLog.isEnabled()

  var movableKeys = [WindowKey]()
  var resizableKeys = [WindowKey]()
  var unreachable = Set<String>()
  var retainedIDs = Set<CGWindowID>()
  let attrs = [
    kAXMinimizedAttribute,
    kAXSubroleAttribute,
  ] as CFArray
  for bundleId in bundleIds {
    if isCancelled() { break }
    let pids = pidsByBundle[bundleId] ?? []
    guard !pids.isEmpty else {
      debugLog.log("Tiler", "discover \(bundleId): no running pid")
      continue
    }
    for pid in pids {
      if isCancelled() { break }
      let axApp = AXUIElementCreateApplication(pid)
      // Same rationale as the tile pass: bound the per-message wait so a
      // hung app can't occupy the discovery worker indefinitely.
      AXUIElementSetMessagingTimeout(axApp, 1.0)
      var raw: CFTypeRef?
      let windowsError = AXUIElementCopyAttributeValue(
        axApp,
        kAXWindowsAttribute as CFString,
        &raw,
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
          "discover \(bundleId) pid=\(pid): AX kAXWindowsAttribute err=\(windowsError.rawValue)",
        )
        continue
      }
      let movableBefore = movableKeys.count
      let resizableBefore = resizableKeys.count
      var rejected = [String]()
      func reject(_ widProbe: CGWindowID, _ reason: @autoclosure () -> String) {
        if logging { rejected.append("\(widProbe):\(reason())") }
      }
      for window in windows {
        if isCancelled() { break }
        var widProbe: CGWindowID = 0
        _ = _AXUIElementGetWindow(window, &widProbe)
        var valuesRef: CFArray?
        var minimized = false
        var subrole: String?
        let attrsError = AXUIElementCopyMultipleAttributeValues(
          window,
          attrs,
          AXCopyMultipleAttributeOptions(),
          &valuesRef,
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
          // A subrole flap is transient (see `WindowDiscovery.retained`):
          // record the id so consumers keep tracking a window that's still
          // enumerated, rather than dropping it as closed.
          if widProbe != 0 { retainedIDs.insert(widProbe) }
          reject(widProbe, "subrole=\(subrole)")
          continue
        }
        // Position must be settable for either consumer. Size determines only
        // membership in the tiled subset; a fixed-size window remains valid
        // for the unmanaged/movable cache.
        var movable: DarwinBoolean = false
        var resizable: DarwinBoolean = false
        let movError = AXUIElementIsAttributeSettable(
          window,
          kAXPositionAttribute as CFString,
          &movable,
        )
        let resError = AXUIElementIsAttributeSettable(
          window,
          kAXSizeAttribute as CFString,
          &resizable,
        )
        if movError == .cannotComplete || resError == .cannotComplete {
          unreachable.insert(bundleId)
          reject(widProbe, "timeout")
          break
        }
        if !movable.boolValue {
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
          movableKeys.append(key)
          if resizable.boolValue {
            resizableKeys.append(key)
          }
        } else {
          reject(widProbe, "noWid")
        }
      }
      if logging {
        let movableKept = movableKeys[movableBefore...].map(\.windowID)
        let resizableKept = resizableKeys[resizableBefore...].map(\.windowID)
        debugLog.log(
          "Tiler",
          "discover \(bundleId) pid=\(pid) axCount=\(windows.count) "
            + "movable=\(movableKept) resizable=\(resizableKept) rejected=\(rejected)",
        )
      }
    }
  }
  // An unreachable bundle contributes no keys at all — a partial list
  // (the windows validated before the timeout hit) would read as "the
  // other windows closed". Consumers substitute last-known state.
  if !unreachable.isEmpty {
    movableKeys.removeAll { unreachable.contains($0.bundleId) }
    resizableKeys.removeAll { unreachable.contains($0.bundleId) }
  }
  // A retained id that *did* validate on a later pid/bundle in this same scan
  // is genuinely standard — don't also flag it as flapped.
  retainedIDs.subtract(movableKeys.map(\.windowID))
  return WindowCapabilityDiscovery(
    movableKeys: movableKeys,
    resizableKeys: resizableKeys,
    unreachable: unreachable,
    retained: retainedIDs,
  )
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "WindowTiler")
