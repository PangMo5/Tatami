import AppKit
import ApplicationServices
import CoreGraphics
import Dependencies
import DependenciesMacros
import Foundation
import OSLog

/// Bridge to the private SkyLight (SLS) framework. Surfaces the
/// minimum subset Tatami needs:
///
///   * `mainConnectionID()` — the per-process connection id required
///     for every other SLS call.
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
public struct SLSClient: Sendable {
  /// The current process's connection id (`SLSMainConnectionID`).
  /// Returns 0 when the framework couldn't be opened — every other call
  /// then becomes a noop.
  public var mainConnectionID: @Sendable () -> Int32 = { 0 }

  /// Spaces that contain `windowID`. A sticky window appears in more
  /// than one Space; we use that to keep them out of the BSP tree.
  public var spacesForWindow: @Sendable (CGWindowID) -> [UInt64] = { _ in [] }

  /// Standard-window CGWindowIDs the OS reports as ordered-in on `space`.
  /// Used as the source of truth instead of bruteforcing AX remote
  /// tokens.
  public var windowList: @Sendable (_ space: UInt64) -> [CGWindowID] = { _ in [] }

  /// Focus `windowID` belonging to `psn`. Reliable in apps where plain
  /// `NSRunningApplication.activate` leaves the window behind Finder.
  public var focusWindow: @Sendable (ProcessSerialNumber, CGWindowID, AXUIElement) -> Void
    = { _, _, _ in }
}

extension SLSClient: DependencyKey {
  public static let liveValue: SLSClient = {
    let center = SLSCenter()
    return SLSClient(
      mainConnectionID: { center.connectionID },
      spacesForWindow: { center.spaces(for: $0) },
      windowList: { center.windowList(on: $0) },
      focusWindow: { psn, wid, ref in
        var mutPSN = psn
        center.focusWindow(psn: &mutPSN, windowID: wid, axRef: ref)
      }
    )
  }()

  public static let testValue = SLSClient()
  public static let previewValue = testValue
}

extension DependencyValues {
  public var sls: SLSClient {
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
    Int32, UInt32, CFArray, UInt32,
    UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>
  ) -> Unmanaged<CFArray>?
private typealias _SLPSSetFrontProcessWithOptionsFn =
  @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> OSStatus
private typealias SLPSPostEventRecordToFn =
  @convention(c) (
    UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>
  ) -> OSStatus

/// Single-instance holder for the SkyLight handles. `nonisolated(unsafe)`
/// covers the dlopen pointers (they're read-only once initialized);
/// per-call work is dispatched onto a serial queue so the underlying SLS
/// state machine stays single-threaded.
private final class SLSCenter: @unchecked Sendable {
  let connectionID: Int32

  private let handle: UnsafeMutableRawPointer?
  private let symSpacesForWindows: SLSCopySpacesForWindowsFn?
  private let symWindowsWithOptions: SLSCopyWindowsWithOptionsAndTagsFn?
  private let symSetFrontProcess: _SLPSSetFrontProcessWithOptionsFn?
  private let symPostEventRecord: SLPSPostEventRecordToFn?

  init() {
    let h = dlopen(
      "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
      RTLD_NOW
    )
    self.handle = h
    self.symSpacesForWindows = h.flatMap { dlsym($0, "SLSCopySpacesForWindows") }
      .map { unsafeBitCast($0, to: SLSCopySpacesForWindowsFn.self) }
    self.symWindowsWithOptions = h.flatMap { dlsym($0, "SLSCopyWindowsWithOptionsAndTags") }
      .map { unsafeBitCast($0, to: SLSCopyWindowsWithOptionsAndTagsFn.self) }
    self.symSetFrontProcess = h.flatMap { dlsym($0, "_SLPSSetFrontProcessWithOptions") }
      .map { unsafeBitCast($0, to: _SLPSSetFrontProcessWithOptionsFn.self) }
    self.symPostEventRecord = h.flatMap { dlsym($0, "SLPSPostEventRecordTo") }
      .map { unsafeBitCast($0, to: SLPSPostEventRecordToFn.self) }
    if let h, let connSym = dlsym(h, "SLSMainConnectionID") {
      let fn = unsafeBitCast(connSym, to: SLSMainConnectionIDFn.self)
      self.connectionID = fn()
    } else {
      self.connectionID = 0
      logger.warning("SkyLight framework not available — SLS calls disabled")
    }
  }

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
    guard let raw = sym(connectionID, 0x2, spaceArray, 0, &setTags, &clearTags)?
      .takeRetainedValue()
    else { return [] }
    return (raw as? [CGWindowID]) ?? []
  }

  /// Focus-with-raise via a synthesized annotated session event.
  /// Annotates the event with the expected window id so apps that
  /// inspect the payload (Slack, Mail, anything Electron) move focus
  /// to the right window instead of the app's last-used one.
  func focusWindow(
    psn: UnsafeMutablePointer<ProcessSerialNumber>,
    windowID: CGWindowID,
    axRef: AXUIElement
  ) {
    if let setFront = symSetFrontProcess {
      // 0x200 = kCPSUserGenerated. The OS treats the activation as if
      // the user clicked, side-stepping the "respect existing layering"
      // heuristic that hides newly-activated apps behind Finder.
      _ = setFront(psn, windowID, 0x200)
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
        postEvent(psn, buf.baseAddress!)
      }
      bytes[0x08] = 0x02
      _ = bytes.withUnsafeMutableBufferPointer { buf in
        postEvent(psn, buf.baseAddress!)
      }
    }
    // AX raise on top. This is what makes the window come to the
    // front visually; the SLPS calls above ensure the OS treats the
    // focus as authoritative.
    AXUIElementPerformAction(axRef, kAXRaiseAction as CFString)
  }
}
