import AppKit
import ApplicationServices
import CoreGraphics
import Dependencies
import DependenciesMacros
import Foundation
import os
import OSLog

// MARK: - SLSWindowEvent

public enum SLSWindowEvent: Equatable, Sendable {
  case terminated(CGWindowID)
  case becameVisible(CGWindowID)
  case becameInvisible(CGWindowID)

  var windowID: CGWindowID {
    switch self {
    case .terminated(let windowID),
         .becameVisible(let windowID),
         .becameInvisible(let windowID):
      windowID
    }
  }
}

// MARK: - SLSClient

/// Bridge to the private SkyLight (SLS) framework. Surfaces the
/// minimum subset Tatami needs:
///
///   * `spacesForWindow(_:)` — sticky detection. A window that lives in
///     more than one Space is pinned to "all desktops" and must not be
///     tiled.
///   * `windowList(on:)` — enumerate the standard windows on a given
///     Space. Lets us reconcile against AX's view of the world.
///   * `focusWindow(psn:windowID:axRef:)` — reliable focus-with-raise.
///     Posts a synthesized "annotated session" event so the OS treats
///     the focus change as user-driven and apps that inspect the
///     payload (Electron, Slack) move focus to the right window; pairs
///     it with an AX-raise for the visual side.
///
/// All entry points are exposed via `@DependencyClient` so the reducer
/// can swap them in tests.
@DependencyClient
struct SLSClient: Sendable {
  /// Spaces that contain `windowID`. A sticky window appears in more
  /// than one Space; we use that to keep them out of the BSP tree.
  var spacesForWindow: @Sendable (CGWindowID) -> [UInt64] = { _ in [] }

  /// Whether the active Space is a native macOS fullscreen Space. Tatami goes
  /// dormant in one: re-tiling there would write frames to (or raise) Desktop
  /// windows and bounce the user back out of fullscreen to the Desktop.
  /// Defaults to `false` so a missing framework never disables tiling.
  var isActiveSpaceFullscreen: @Sendable () -> Bool = { false }

  /// Standard-window CGWindowIDs the OS reports as ordered-in on `space`.
  /// Used as the source of truth instead of bruteforcing AX remote
  /// tokens.
  var windowList: @Sendable (_ space: UInt64) -> [CGWindowID] = { _ in [] }

  /// Force `windowID` (owned by `pid`) to the front: makes `pid` the frontmost
  /// application via `_SLPSSetFrontProcessWithOptions` + a synthesized annotated
  /// session event + an AX raise. Reliable where plain `NSRunningApplication
  /// .activate` leaves the window behind (an accessory app can't transfer the
  /// global frontmost app that way — especially for windows on a secondary
  /// display), which is what stalled cross-app window cycling.
  /// No hand-written default: Void endpoints get the macro's unimplemented
  /// stub, so unstubbed test calls surface as failures.
  var focusWindow: @Sendable (pid_t, CGWindowID, AXUIElement) -> Void

  /// Window-server lifecycle/visibility events for watched windows:
  /// terminated (804), visible (815), and invisible (816). The visibility
  /// edges catch hide-on-close apps immediately without treating their live
  /// WindowServer surface as permanently destroyed.
  var windowEvents: @Sendable () -> AsyncStream<SLSWindowEvent> = { AsyncStream { _ in } }
  /// Subscribe `windows` to per-window notifications. Called whenever the
  /// managed-window set changes.
  var watchWindows: @Sendable (_ windows: [CGWindowID]) -> Void
}

// MARK: DependencyKey

extension SLSClient: DependencyKey {
  static let liveValue: SLSClient = {
    let center = SLSCenter()
    return SLSClient(
      spacesForWindow: { center.spaces(for: $0) },
      isActiveSpaceFullscreen: { center.isActiveSpaceFullscreen() },
      windowList: { center.windowList(on: $0) },
      focusWindow: { pid, wid, ref in
        center.focusWindow(pid: pid, windowID: wid, axRef: ref)
      },
      windowEvents: { center.windowEvents() },
      watchWindows: { center.watchWindows($0) },
    )
  }()

  static let testValue = SLSClient()
  static let previewValue = testValue
}

extension DependencyValues {
  var sls: SLSClient {
    get { self[SLSClient.self] }
    set { self[SLSClient.self] = newValue }
  }
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "SLS")

// MARK: - Private SkyLight bridge

private typealias SLSMainConnectionIDFn = @convention(c) () -> Int32
private typealias SLSCopySpacesForWindowsFn =
  @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
private typealias SLSCopyWindowsWithOptionsAndTagsFn =
  @convention(c) (
    Int32,
    UInt32,
    CFArray,
    UInt32,
    UnsafeMutablePointer<UInt64>,
    UnsafeMutablePointer<UInt64>,
  ) -> Unmanaged<CFArray>?
private typealias _SLPSSetFrontProcessWithOptionsFn =
  @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> OSStatus
private typealias SLPSPostEventRecordToFn =
  @convention(c) (
    UnsafeMutablePointer<ProcessSerialNumber>,
    UnsafeMutablePointer<UInt8>,
  ) -> OSStatus
private typealias SLSConnectionNotifyCallback =
  @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?, Int32) -> Void
private typealias SLSRegisterConnectionNotifyProcFn =
  @convention(c) (Int32, SLSConnectionNotifyCallback, UInt32, UnsafeMutableRawPointer?) -> CGError
private typealias SLSRequestNotificationsForWindowsFn =
  @convention(c) (Int32, UnsafePointer<UInt32>?, Int32) -> CGError
private typealias SLSGetActiveSpaceFn = @convention(c) (Int32) -> UInt64
private typealias SLSSpaceGetTypeFn = @convention(c) (Int32, UInt64) -> Int32
/// Process Manager pid→PSN. Deprecated and *unavailable* in Swift, so we bind
/// it by symbol like the SLS entry points; the dylib still exports it (yabai
/// relies on the same call). `_SLPSSetFrontProcessWithOptions` needs a PSN and
/// has no pid-based entry point.
private typealias GetProcessForPIDFn =
  @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

/// `SLSSpaceGetType` value for a native macOS fullscreen Space. yabai uses
/// the same number (`0` is a normal user Space, `2` is system).
private let kSLSSpaceTypeFullscreen: Int32 = 4

/// WindowServer lifecycle/visibility notifications. 804 is the eventual
/// surface termination edge used by yabai on Sequoia/Tahoe. 815/816 are the
/// older `kCGSWindowIsVisible` / `kCGSWindowIsInvisible` edges and arrive when
/// hide-on-close apps order their still-live surface in or out.
private let kSLSWindowTerminatedEvent: UInt32 = 804
private let kSLSWindowVisibleEvent: UInt32 = 815
private let kSLSWindowInvisibleEvent: UInt32 = 816

// MARK: - SLSCenter

/// Single-instance holder for the SkyLight handles. `@unchecked Sendable`
/// is sound because every stored property is set once in `init` and only
/// read afterwards: the `dlopen` handle and the `dlsym` function pointers
/// are immutable after initialization. The SLS entry points themselves are
/// WindowServer IPC (mach messages over the process-wide connection id) and
/// are issued directly on the caller's thread — there is no per-instance
/// mutable state to serialize.
private final class SLSCenter: @unchecked Sendable {

  // MARK: Lifecycle

  init() {
    var continuation: AsyncStream<SLSWindowEvent>.Continuation!
    windowEventStream = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation = $0 }
    windowEventContinuation = continuation
    let h = dlopen(
      "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
      RTLD_NOW,
    )
    handle = h
    symSpacesForWindows = h.flatMap { dlsym($0, "SLSCopySpacesForWindows") }
      .map { unsafeBitCast($0, to: SLSCopySpacesForWindowsFn.self) }
    symWindowsWithOptions = h.flatMap { dlsym($0, "SLSCopyWindowsWithOptionsAndTags") }
      .map { unsafeBitCast($0, to: SLSCopyWindowsWithOptionsAndTagsFn.self) }
    symSetFrontProcess = h.flatMap { dlsym($0, "_SLPSSetFrontProcessWithOptions") }
      .map { unsafeBitCast($0, to: _SLPSSetFrontProcessWithOptionsFn.self) }
    symPostEventRecord = h.flatMap { dlsym($0, "SLPSPostEventRecordTo") }
      .map { unsafeBitCast($0, to: SLPSPostEventRecordToFn.self) }
    symRegisterNotify = h.flatMap { dlsym($0, "SLSRegisterConnectionNotifyProc") }
      .map { unsafeBitCast($0, to: SLSRegisterConnectionNotifyProcFn.self) }
    symRequestNotifications = h.flatMap { dlsym($0, "SLSRequestNotificationsForWindows") }
      .map { unsafeBitCast($0, to: SLSRequestNotificationsForWindowsFn.self) }
    symGetActiveSpace = h.flatMap { dlsym($0, "SLSGetActiveSpace") }
      .map { unsafeBitCast($0, to: SLSGetActiveSpaceFn.self) }
    symSpaceGetType = h.flatMap { dlsym($0, "SLSSpaceGetType") }
      .map { unsafeBitCast($0, to: SLSSpaceGetTypeFn.self) }
    // GetProcessForPID lives in ApplicationServices/CoreServices, not SkyLight;
    // resolve it from the global symbol table (already loaded via AppKit).
    symGetProcessForPID = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID")
      .map { unsafeBitCast($0, to: GetProcessForPIDFn.self) }
    if let h, let connSym = dlsym(h, "SLSMainConnectionID") {
      let fn = unsafeBitCast(connSym, to: SLSMainConnectionIDFn.self)
      connectionID = fn()
    } else {
      connectionID = 0
      logger.warning("SkyLight framework not available — SLS calls disabled")
    }
  }

  // MARK: Internal

  let connectionID: Int32

  /// Returns every Space id `wid` lives in. Mask `0x7` selects user +
  /// system + fullscreen-tile spaces — the standard sticky-window
  /// check.
  func spaces(for wid: CGWindowID) -> [UInt64] {
    guard connectionID != 0, let sym = symSpacesForWindows else { return [] }
    let widCF: [CGWindowID] = [wid]
    let arrayRef = widCF as CFArray
    guard let result = sym(connectionID, 0x7, arrayRef)?.takeRetainedValue() else { return [] }
    return (result as? [UInt64]) ?? []
  }

  /// CGWindowIDs ordered-in on `space`. Tags 0x2 (regular) + level filter
  /// would be set in a full port; we keep the call simple and let the AX
  /// pass do the eligibility filtering on top.
  func windowList(on space: UInt64) -> [CGWindowID] {
    guard connectionID != 0, let sym = symWindowsWithOptions else { return [] }
    let spaceList: [UInt64] = [space]
    let spaceArray = spaceList as CFArray
    var setTags: UInt64 = 0
    var clearTags: UInt64 = 0
    // option 0x2 = "include minimized" off, layer 0 only.
    guard
      let raw = sym(connectionID, 0x2, spaceArray, 0, &setTags, &clearTags)?
        .takeRetainedValue()
    else { return [] }
    return (raw as? [CGWindowID]) ?? []
  }

  /// Whether the active Space is a native macOS fullscreen Space, via the
  /// same `SLSGetActiveSpace` + `SLSSpaceGetType` pair yabai uses. Returns
  /// `false` whenever the framework or symbols are unavailable, so a missing
  /// SkyLight never reads as "always fullscreen" and silences tiling.
  func isActiveSpaceFullscreen() -> Bool {
    guard
      connectionID != 0,
      let getActive = symGetActiveSpace,
      let getType = symSpaceGetType
    else { return false }
    let sid = getActive(connectionID)
    guard sid != 0 else { return false }
    return getType(connectionID, sid) == kSLSSpaceTypeFullscreen
  }

  /// Focus-with-raise via a synthesized annotated session event.
  /// Annotates the event with the expected window id so apps that
  /// inspect the payload (Slack, Mail, anything Electron) move focus
  /// to the right window instead of the app's last-used one.
  func focusWindow(
    pid: pid_t,
    windowID: CGWindowID,
    axRef: AXUIElement,
  ) {
    // Derive the ProcessSerialNumber the SLPS calls require. GetProcessForPID
    // is a deprecated Process Manager call, but it's still the only way to map
    // a pid → PSN and every macOS tiling WM (yabai/AeroSpace) relies on it.
    // DO NOT "modernize" it away — SLPS has no pid-based entry point, so
    // dropping this silently breaks force-to-front focus.
    var psn = ProcessSerialNumber()
    guard let getPSN = symGetProcessForPID, getPSN(pid, &psn) == noErr else {
      // No PSN (symbol gone or lookup failed) — fall back to a bare AX raise so
      // focus at least moves visually.
      AXUIElementPerformAction(axRef, kAXRaiseAction as CFString)
      return
    }
    if let setFront = symSetFrontProcess {
      // 0x200 = kCPSUserGenerated. The OS treats the activation as if
      // the user clicked, side-stepping the "respect existing layering"
      // heuristic that hides newly-activated apps behind Finder.
      _ = setFront(&psn, windowID, 0x200)
    }
    if let postEvent = symPostEventRecord {
      // Annotated session event 0x10 — magic byte offsets are an
      // undocumented WindowServer ABI. Two posts (0x01 then 0x02 in
      // the modifier slot at 0x08) tell the server this is a
      // synthesized activation tied to a specific window id.
      var bytes = [UInt8](repeating: 0, count: 0xf8)
      bytes[0x04] = 0xf8
      bytes[0x3a] = 0x10
      withUnsafeBytes(of: UInt32(windowID)) { wid in
        for i in 0..<wid.count { bytes[0x3c + i] = wid[i] }
      }
      for i in 0..<0x10 { bytes[0x20 + i] = 0xff }
      bytes[0x08] = 0x01
      _ = bytes.withUnsafeMutableBufferPointer { buf in
        postEvent(&psn, buf.baseAddress!)
      }
      bytes[0x08] = 0x02
      _ = bytes.withUnsafeMutableBufferPointer { buf in
        postEvent(&psn, buf.baseAddress!)
      }
    }
    // AX raise on top. This is what makes the window come to the
    // front visually; the SLPS calls above ensure the OS treats the
    // focus as authoritative.
    AXUIElementPerformAction(axRef, kAXRaiseAction as CFString)
  }

  /// Stream of lifecycle/visibility edges for watched windows.
  /// Registers the 804/815/816 handlers on first call.
  func windowEvents() -> AsyncStream<SLSWindowEvent> {
    registerIfNeeded()
    return windowEventStream
  }

  /// Subscribe `ids` to per-window notifications so lifecycle and visibility
  /// edges fire for them.
  func watchWindows(_ ids: [CGWindowID]) {
    guard connectionID != 0, let request = symRequestNotifications, !ids.isEmpty else { return }
    let cid = connectionID
    ids.withUnsafeBufferPointer { buf in
      _ = request(cid, buf.baseAddress, Int32(buf.count))
    }
  }

  // MARK: Fileprivate

  /// Yielded from the WindowServer notify callback. The
  /// callback reaches it via the retained-unmanaged `self` pointer.
  fileprivate let windowEventContinuation: AsyncStream<SLSWindowEvent>.Continuation

  // MARK: Private

  private let handle: UnsafeMutableRawPointer?
  private let symSpacesForWindows: SLSCopySpacesForWindowsFn?
  private let symWindowsWithOptions: SLSCopyWindowsWithOptionsAndTagsFn?
  private let symSetFrontProcess: _SLPSSetFrontProcessWithOptionsFn?
  private let symPostEventRecord: SLPSPostEventRecordToFn?
  private let symRegisterNotify: SLSRegisterConnectionNotifyProcFn?
  private let symRequestNotifications: SLSRequestNotificationsForWindowsFn?
  private let symGetActiveSpace: SLSGetActiveSpaceFn?
  private let symSpaceGetType: SLSSpaceGetTypeFn?
  private let symGetProcessForPID: GetProcessForPIDFn?

  private let windowEventStream: AsyncStream<SLSWindowEvent>
  /// The handlers are registered once, on first `windowEvents`.
  private let didRegister = OSAllocatedUnfairLock(initialState: false)

  private func registerIfNeeded() {
    let already = didRegister.withLock { registered -> Bool in
      defer { registered = true }
      return registered
    }
    guard !already, connectionID != 0, let register = symRegisterNotify else { return }
    let cid = connectionID
    // Register on the always-running event-tap run loop, not the main one:
    // the WindowServer delivers the notification on whichever run loop the
    // proc was registered on, and the SwiftUI main loop sleeps when idle —
    // so destroy events only drained when another event happened to wake it
    // (the "only works after I move the mouse" symptom). The event-tap
    // thread's CFRunLoop is always spinning, so they arrive immediately.
    EventTapThread.shared.perform { [self] in
      let context = Unmanaged.passUnretained(self).toOpaque()
      _ = register(cid, slsWindowNotifyCallback, kSLSWindowTerminatedEvent, context)
      _ = register(cid, slsWindowNotifyCallback, kSLSWindowVisibleEvent, context)
      _ = register(cid, slsWindowNotifyCallback, kSLSWindowInvisibleEvent, context)
    }
  }

}

/// SLS connection notify callback (C ABI). Reads the window id out of the
/// event payload and forwards the typed edge through the owning center's stream.
private func slsWindowNotifyCallback(
  type: UInt32,
  data: UnsafeMutableRawPointer?,
  dataLength: Int,
  context: UnsafeMutableRawPointer?,
  cid _: Int32,
) {
  guard
    let data, dataLength >= MemoryLayout<UInt32>.size,
    let context
  else { return }
  let wid = data.loadUnaligned(as: UInt32.self)
  guard wid != 0 else { return }
  let event: SLSWindowEvent
  switch type {
  case kSLSWindowTerminatedEvent:
    event = .terminated(CGWindowID(wid))
  case kSLSWindowVisibleEvent:
    event = .becameVisible(CGWindowID(wid))
  case kSLSWindowInvisibleEvent:
    event = .becameInvisible(CGWindowID(wid))
  default:
    return
  }
  let center = Unmanaged<SLSCenter>.fromOpaque(context).takeUnretainedValue()
  center.windowEventContinuation.yield(event)
}
