// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ApplicationServices
import CoreGraphics
import Dependencies
import Foundation
import os

// MARK: - ManagedDesktopNavigator

/// Only one native preparation mutates system shortcut state at a time. A
/// cancelled predecessor finishes restoration before its replacement starts.
actor ManagedDesktopNavigator {

  // MARK: Internal

  static let shared = ManagedDesktopNavigator()

  func prepare(_ request: ManagedDesktopPreparation) async -> ManagedDesktopPreparationResult {
    let previous = tail
    let task = Task {
      _ = await previous?.value
      guard !Task.isCancelled else { return ManagedDesktopPreparationResult.cancelled }
      return await Self.run(request)
    }
    tail = task
    tailID = request.id
    let result = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    if tailID == request.id {
      tail = nil
      tailID = nil
    }
    return result
  }

  // MARK: Private

  private struct FullscreenCandidate: Sendable {
    var window: DesktopSpaces.FullscreenWindow
    var identity: WindowIdentity
  }

  private struct WindowIdentity: Sendable {
    var windowID: UInt32
    var pid: Int32
    var bundleID: String
    var started: Date
  }

  private struct Failure: Error, LocalizedError {
    init(_ message: String) {
      self.message = message
    }

    var errorDescription: String? {
      message
    }

    private let message: String
  }

  private static let worker = BlockingWorkQueue(label: "dev.PangMo5.Tatami.native-desktop")
  private static let shortcuts = SymbolicDesktopShortcut()
  private static let windowSpaces = NativeWindowSpaces()

  private var tail: Task<ManagedDesktopPreparationResult, Never>?
  private var tailID: UUID?

  private static func run(_ request: ManagedDesktopPreparation) async -> ManagedDesktopPreparationResult {
    let cancellation = NativePreparationCancellation()
    let resources = NativePreparationResources()
    let monitor = await MainActor
      .run { NativePreparationInputMonitor(since: request.requestedAtUptime, cancellation: cancellation) }
    let result = await withTaskCancellationHandler {
      do {
        let outcome = try await perform(
          request,
          cancellation: cancellation,
          resources: resources,
        )
        return ManagedDesktopPreparationResult.prepared(outcome.spaces, requiresReconciliation: outcome.changed)
      } catch is CancellationError {
        return .cancelled
      } catch {
        return .failed(error.localizedDescription)
      }
    } onCancel: {
      cancellation.cancel()
    }
    // Cancellation does not skip system-setting restoration.
    let restorationError: String? = await worker.run {
      resources.move = nil
      guard let lease = resources.lease else { return nil }
      do { try shortcuts.restore(lease)
        return nil
      } catch { return error.localizedDescription }
    }
    await monitor.stop()
    if let restorationError {
      return .failed(restorationError)
    }
    return result
  }

  private static func perform(
    _ request: ManagedDesktopPreparation,
    cancellation: NativePreparationCancellation,
    resources: NativePreparationResources,
  ) async throws -> (spaces: DesktopSpaces, changed: Bool) {
    @Dependency(\.sls) var sls
    // This is a deadline, not a presentation delay. Native readiness is tested
    // immediately and at display-frame intervals; no UI work runs on this wait.
    let deadline = ContinuousClock.now + .seconds(10)
    try check(cancellation, deadline: deadline)
    var changed = false
    let initial = try await snapshot(sls)
    guard let initialDisplay = initial.space(on: request.display), initialDisplay.userDesktops.contains(request.home) else {
      throw Failure("The target monitor or its managed Desktop is unavailable")
    }
    let candidates = try await worker.runThrowing {
      try initialDisplay.fullscreenWindows.compactMap { window -> FullscreenCandidate? in
        guard
          let application = NSRunningApplication(processIdentifier: window.pid),
          let bundleID = application.bundleIdentifier
        else {
          throw Failure("The owner of a native fullscreen window is unavailable")
        }
        guard request.bundleIDs.contains(bundleID) else { return nil }
        guard let started = application.launchDate else { throw Failure("The fullscreen process identity is unavailable") }
        return FullscreenCandidate(window: window, identity: WindowIdentity(
          windowID: window.windowID,
          pid: window.pid,
          bundleID: bundleID,
          started: started,
        ))
      }
    }
    for candidate in candidates {
      try check(cancellation, deadline: deadline)
      let current = try await readySnapshot(sls, cancellation: cancellation, deadline: deadline)
      guard current.space(on: request.display)?.fullscreenWindows.contains(candidate.window) == true else { continue }
      try await waitForWindowIdentity(candidate.identity, cancellation: cancellation, deadline: deadline)
      let resolved = try await worker.runThrowing {
        try resolveWindows([candidate.identity], cancellation: cancellation, deadline: deadline)
      }
      guard let window = resolved[candidate.window.windowID]
      else { throw Failure("The requested fullscreen window is unavailable") }
      try check(cancellation, deadline: deadline)
      try await worker.runThrowing {
        guard
          !cancellation.isCancelled,
          identityMatches(candidate.identity),
          windowID(window.element) == candidate.window.windowID
        else {
          throw CancellationError()
        }
        var settable = DarwinBoolean(false)
        guard
          AXUIElementIsAttributeSettable(window.element, "AXFullScreen" as CFString, &settable) == .success,
          settable.boolValue
        else { throw Failure("The requested window does not allow native fullscreen changes") }
        guard AXUIElementSetAttributeValue(window.element, "AXFullScreen" as CFString, kCFBooleanFalse) == .success else {
          throw Failure("The requested window could not leave native fullscreen")
        }
      }
      changed = true
      try await waitForFullscreenExit(
        candidate,
        window: window,
        display: request.display,
        sls: sls,
        cancellation: cancellation,
        deadline: deadline,
      )
    }
    var current = try await readySnapshot(sls, cancellation: cancellation, deadline: deadline)
    let remainingSnapshot = current
    let remaining = try await worker.runThrowing {
      try (remainingSnapshot.space(on: request.display)?.fullscreenWindows ?? []).contains { window in
        guard
          let application = NSRunningApplication(processIdentifier: window.pid),
          let bundleID = application.bundleIdentifier
        else {
          throw Failure("The remaining fullscreen owner could not be verified")
        }
        return request.bundleIDs.contains(bundleID)
      }
    }
    guard !remaining else { throw Failure("The requested fullscreen windows changed during activation") }
    let movedWindows = try await returnWorkspaceWindows(
      request,
      snapshot: current,
      sls: sls,
      cancellation: cancellation,
      resources: resources,
      deadline: deadline,
    )
    changed = changed || movedWindows
    current = try await readySnapshot(sls, cancellation: cancellation, deadline: deadline)
    guard let display = current.space(on: request.display), display.userDesktops.contains(request.home) else {
      throw Failure("The managed Desktop changed during activation")
    }
    if display.currentSpace != request.home {
      changed = true
      // Preserve a user's held shortcut modifiers; post the native shortcut
      // only once their triggering chord has been released.
      while await worker.run({
        !CGEventSource.flagsState(.hidSystemState).intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand]).isEmpty
      }) {
        try await nextFrame(cancellation, deadline: deadline)
      }
      try check(cancellation, deadline: deadline)
      let selectionSnapshot = current
      let lease = try await worker.runThrowing { try shortcuts.acquire(home: request.home, snapshot: selectionSnapshot) }
      resources.lease = lease
      current = try await readySnapshot(sls, cancellation: cancellation, deadline: deadline)
      guard SymbolicDesktopShortcut.ordinaryOrder(in: current) == lease.ordinaryOrder else {
        throw Failure("Native Desktop order changed before the system shortcut was sent")
      }
      try check(cancellation, deadline: deadline)
      try await worker.runThrowing {
        guard !cancellation.isCancelled else { throw CancellationError() }
        try shortcuts.post(lease)
      }
      current = try await waitForSnapshot(sls, cancellation: cancellation, deadline: deadline) {
        guard let row = $0.space(on: request.display) else { return false }
        return row.isUserDesktop && row.currentSpace == request.home
      }
    }
    try check(cancellation, deadline: deadline)
    guard
      current.space(on: request.display)?.isUserDesktop == true,
      current.space(on: request.display)?.currentSpace == request.home
    else {
      throw Failure("The managed Desktop was not reached")
    }
    return (current, changed)
  }

  private static func returnWorkspaceWindows(
    _ request: ManagedDesktopPreparation,
    snapshot: DesktopSpaces,
    sls: SLSClient,
    cancellation: NativePreparationCancellation,
    resources: NativePreparationResources,
    deadline: ContinuousClock.Instant,
  ) async throws -> Bool {
    guard let display = snapshot.space(on: request.display), display.userDesktops.contains(request.home) else {
      throw Failure("The target monitor or its managed Desktop changed")
    }
    let candidates = try await worker.runThrowing {
      guard let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
        throw Failure("Workspace window placement is unavailable")
      }
      return try rows.compactMap { row -> WindowIdentity? in
        try check(cancellation, deadline: deadline)
        guard
          (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
          (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
          let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
          let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
          let app = NSRunningApplication(processIdentifier: pid),
          let bundle = app.bundleIdentifier,
          request.bundleIDs.contains(bundle),
          let started = app.launchDate
        else { return nil }
        let spaces = try windowSpaces.spaces(for: id)
        guard NativeWindowSpaces.needsMove(spaces, on: display, home: request.home) else { return nil }
        return WindowIdentity(windowID: id, pid: pid, bundleID: bundle, started: started)
      }
    }
    guard !candidates.isEmpty else { return false }
    try check(cancellation, deadline: deadline)
    try await worker.runThrowing {
      guard !cancellation.isCancelled, candidates.allSatisfy(identityMatches) else { throw CancellationError() }
      for candidate in candidates {
        guard NativeWindowSpaces.needsMove(try windowSpaces.spaces(for: candidate.windowID), on: display, home: request.home)
        else {
          throw Failure("Workspace window placement changed before assignment")
        }
      }
      resources.move = try windowSpaces.beginMove(candidates.map(\.windowID), to: request.home)
    }
    while true {
      try check(cancellation, deadline: deadline)
      let current = try await readySnapshot(sls, cancellation: cancellation, deadline: deadline)
      guard current.space(on: request.display)?.userDesktops.contains(request.home) == true else {
        throw Failure("The managed Desktop disappeared during window assignment")
      }
      let arrived = try await worker.runThrowing {
        guard candidates.allSatisfy(identityMatches) else { throw Failure("The assigned window identity changed") }
        return try candidates.allSatisfy { try windowSpaces.spaces(for: $0.windowID) == [request.home] }
      }
      if arrived {
        return true
      }
      try await nextFrame(cancellation, deadline: deadline)
    }
  }

  private static func snapshot(_ sls: SLSClient) async throws -> DesktopSpaces {
    guard let spaces = await sls.desktopSpaces() else { throw Failure("Native Desktop state is unavailable") }
    return spaces
  }

  /// A native fullscreen exit can briefly retain its Space row while removing
  /// its window metadata. Wait for a coherent observation under the request's
  /// deadline; never reinterpret that transition as an empty layout.
  private static func readySnapshot(
    _ sls: SLSClient,
    cancellation: NativePreparationCancellation,
    deadline: ContinuousClock.Instant,
  ) async throws -> DesktopSpaces {
    try await waitForSnapshot(sls, cancellation: cancellation, deadline: deadline) { _ in true }
  }

  private static func waitForSnapshot(
    _ sls: SLSClient,
    cancellation: NativePreparationCancellation,
    deadline: ContinuousClock.Instant,
    until predicate: (DesktopSpaces) -> Bool,
  ) async throws -> DesktopSpaces {
    while true {
      try check(cancellation, deadline: deadline)
      if let spaces = await sls.desktopSpaces(), predicate(spaces) {
        return spaces
      }
      try await nextFrame(cancellation, deadline: deadline)
    }
  }

  private static func waitForFullscreenExit(
    _ candidate: FullscreenCandidate,
    window: NativeAXWindow,
    display: DisplayName,
    sls: SLSClient,
    cancellation: NativePreparationCancellation,
    deadline: ContinuousClock.Instant,
  ) async throws {
    while true {
      try check(cancellation, deadline: deadline)
      let current = try await readySnapshot(sls, cancellation: cancellation, deadline: deadline)
      guard let row = current.space(on: display) else { throw Failure("The target monitor disconnected") }
      let exited = try await worker.runThrowing {
        switch identityStatus(candidate.identity) {
        case .changed: throw Failure("The fullscreen window identity changed")
        case .unavailable: return false
        case .current: break
        }
        // AX and SLS can temporarily describe different stages of the native
        // transition. Unknown AX state is not proof of a completed exit.
        let element = findWindow(candidate.identity)?.element ?? window.element
        return (attribute(element, "AXFullScreen") as? Bool) == false
      }
      if exited, !row.fullscreenWindows.contains(candidate.window) {
        return
      }
      try await nextFrame(cancellation, deadline: deadline)
    }
  }

  private static func check(_ cancellation: NativePreparationCancellation, deadline: ContinuousClock.Instant) throws {
    guard !Task.isCancelled, !cancellation.isCancelled else { throw CancellationError() }
    guard ContinuousClock.now < deadline else { throw Failure("Native Desktop preparation timed out") }
  }

  private static func nextFrame(_ cancellation: NativePreparationCancellation, deadline: ContinuousClock.Instant) async throws {
    try check(cancellation, deadline: deadline)
    try await Task.sleep(for: .milliseconds(16))
  }

  private static func identityMatches(_ candidate: WindowIdentity) -> Bool {
    identityStatus(candidate) == .current
  }

  private static func identityStatus(_ candidate: WindowIdentity) -> NativeWindowIdentityStatus {
    let application = NSRunningApplication(processIdentifier: candidate.pid)
    let bundleID = application?.bundleIdentifier
    let launched = application?.launchDate
    let terminated = application?.isTerminated
    let processMatches: Bool? =
      if terminated == true {
        false
      } else if let bundleID, let launched {
        bundleID == candidate.bundleID && launched == candidate.started
      } else {
        nil
      }
    let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, candidate.windowID) as? [[String: Any]]
    let row = rows?.first { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == candidate.windowID }
    let ownerPID = (row?[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
    let status = NativeWindowIdentityStatus.observed(
      processMatches: processMatches,
      ownerPID: ownerPID,
      expectedPID: candidate.pid,
    )
    if status == .changed {
      @Dependency(\.debugLog) var debugLog
      debugLog.log(
        "Space",
        "native identity changed window=\(candidate.windowID) expectedPID=\(candidate.pid) ownerPID=\(ownerPID.map(String.init) ?? "unavailable") "
          +
          "bundle=\(bundleID ?? "unavailable") terminated=\(terminated?.description ?? "unavailable") expectedStart=\(candidate.started.timeIntervalSince1970) actualStart=\(launched?.timeIntervalSince1970.description ?? "unavailable")",
      )
    }
    return status
  }

  private static func waitForWindowIdentity(
    _ candidate: WindowIdentity,
    cancellation: NativePreparationCancellation,
    deadline: ContinuousClock.Instant,
  ) async throws {
    while true {
      try check(cancellation, deadline: deadline)
      switch await worker.run({ identityStatus(candidate) }) {
      case .current: return
      case .changed: throw Failure("The requested window identity changed")
      case .unavailable: try await nextFrame(cancellation, deadline: deadline)
      }
    }
  }

  private static func findWindow(_ candidate: WindowIdentity) -> NativeAXWindow? {
    guard identityMatches(candidate) else { return nil }
    let app = AXUIElementCreateApplication(candidate.pid)
    AXUIElementSetMessagingTimeout(app, 1)
    var elements = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    if let main = attribute(app, kAXMainWindowAttribute), CFGetTypeID(main) == AXUIElementGetTypeID() {
      elements.append(main as! AXUIElement)
    }
    guard let element = elements.first(where: { windowID($0) == candidate.windowID }) else { return nil }
    AXUIElementSetMessagingTimeout(element, 1)
    return NativeAXWindow(element)
  }

  /// AXWindows only lists the current Space. Resolve the explicitly requested
  /// WindowServer identities before mutating any window, without visiting its
  /// Space. The remote-token layout is also used by yabai and AltTab:
  /// https://github.com/asmvik/yabai/blob/b2dc8b4c892d74738a6e865d73048ed2dc3c9ed1/src/window_manager.c
  private static func resolveWindows(
    _ candidates: [WindowIdentity],
    cancellation: NativePreparationCancellation,
    deadline: ContinuousClock.Instant,
  ) throws -> [UInt32: NativeAXWindow] {
    var resolved = [UInt32: NativeAXWindow]()
    for candidate in candidates {
      try check(cancellation, deadline: deadline)
      if let window = findWindow(candidate) {
        resolved[candidate.windowID] = window
      }
    }
    for group in Dictionary(grouping: candidates, by: { $0.pid }).values {
      var missing = group.filter { resolved[$0.windowID] == nil }
      guard !missing.isEmpty else { continue }
      guard missing.allSatisfy(identityMatches) else { throw Failure("The fullscreen process identity changed") }
      var token = Data(count: 20)
      var pid = group[0].pid
      var cocoa: UInt32 = 0x636f636f
      withUnsafeBytes(of: &pid) { token.replaceSubrange(0..<4, with: $0) }
      withUnsafeBytes(of: &cocoa) { token.replaceSubrange(8..<12, with: $0) }
      for index in UInt64(0)..<0x7fff {
        try check(cancellation, deadline: deadline)
        var elementID = index
        withUnsafeBytes(of: &elementID) { token.replaceSubrange(12..<20, with: $0) }
        guard let element = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
        AXUIElementSetMessagingTimeout(element, 1)
        guard
          attribute(element, kAXRoleAttribute) as? String == kAXWindowRole,
          let id = windowID(element),
          let match = missing.firstIndex(where: { $0.windowID == id }),
          identityMatches(missing[match])
        else { continue }
        resolved[id] = NativeAXWindow(element)
        missing.remove(at: match)
        if missing.isEmpty {
          break
        }
      }
      guard missing.isEmpty else { throw Failure("The requested fullscreen windows could not be resolved") }
    }
    return resolved
  }

  private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
    return value
  }

  private static func windowID(_ element: AXUIElement) -> UInt32? {
    var id: UInt32 = 0
    return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
  }

}

// MARK: - NativeAXWindow

private final class NativeAXWindow: @unchecked Sendable {

  // MARK: Lifecycle

  init(_ element: AXUIElement) {
    self.element = element
  }

  // MARK: Internal

  let element: AXUIElement

}

// MARK: - NativePreparationCancellation

private final class NativePreparationCancellation: Sendable {

  // MARK: Internal

  var isCancelled: Bool {
    value.withLock { $0 }
  }

  func cancel() {
    value.withLock { $0 = true }
  }

  // MARK: Private

  private let value = OSAllocatedUnfairLock(initialState: false)

}

// MARK: - NativePreparationResources

private final class NativePreparationResources: Sendable {

  // MARK: Internal

  var move: NativeWindowMove? {
    get { moveValue.withLock { $0 } }
    set { moveValue.withLock { $0 = newValue } }
  }

  var lease: SymbolicDesktopShortcut.Lease? {
    get { value.withLock { $0 } }
    set { value.withLock { $0 = newValue } }
  }

  // MARK: Private

  private let moveValue = OSAllocatedUnfairLock<NativeWindowMove?>(initialState: nil)

  private let value = OSAllocatedUnfairLock<SymbolicDesktopShortcut.Lease?>(initialState: nil)

}

// MARK: - NativePreparationInputMonitor

@MainActor
private final class NativePreparationInputMonitor {

  // MARK: Lifecycle

  init(since: TimeInterval, cancellation: NativePreparationCancellation) {
    let mask: NSEvent.EventTypeMask = [
      .keyDown,
      .leftMouseDown,
      .rightMouseDown,
      .otherMouseDown,
      .leftMouseDragged,
      .rightMouseDragged,
      .scrollWheel,
    ]
    let observe: (NSEvent) -> Void = { event in
      guard
        event.timestamp > since,
        event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid())
      else { return }
      cancellation.cancel()
    }
    global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: observe)
    local = NSEvent.addLocalMonitorForEvents(matching: mask) { event in observe(event)
      return event
    }
  }

  // MARK: Internal

  func stop() {
    if let global {
      NSEvent.removeMonitor(global)
    }
    if let local {
      NSEvent.removeMonitor(local)
    }
    global = nil
    local = nil
  }

  // MARK: Private

  private var global: Any?
  private var local: Any?

}

@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

// MARK: - NativeWindowIdentityStatus

/// Native fullscreen transitions can temporarily remove a live CGWindow row.
/// Absence cannot prove replacement; a different process/owner can.
enum NativeWindowIdentityStatus: Equatable, Sendable {
  case current
  case unavailable
  case changed

  static func observed(processMatches: Bool?, ownerPID: Int32?, expectedPID: Int32) -> Self {
    if processMatches == false || ownerPID.map({ $0 != expectedPID }) == true {
      return .changed
    }
    guard processMatches == true, ownerPID != nil else { return .unavailable }
    return .current
  }
}
