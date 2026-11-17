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

  private var tail: Task<ManagedDesktopPreparationResult, Never>?
  private var tailID: UUID?

  private static func run(_ request: ManagedDesktopPreparation) async -> ManagedDesktopPreparationResult {
    let cancellation = NativePreparationCancellation()
    let resources = NativePreparationResources()
    let monitor = await MainActor
      .run { NativePreparationInputMonitor(since: request.requestedAtUptime, cancellation: cancellation) }
    let result = await withTaskCancellationHandler {
      do {
        return ManagedDesktopPreparationResult.prepared(try await perform(
          request,
          cancellation: cancellation,
          resources: resources,
        ))
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
  ) async throws -> DesktopSpaces {
    @Dependency(\.sls) var sls
    // This is a deadline, not a presentation delay. Native readiness is tested
    // immediately and at display-frame intervals; no UI work runs on this wait.
    let deadline = ContinuousClock.now + .seconds(10)
    try check(cancellation, deadline: deadline)
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
        return FullscreenCandidate(window: window, bundleID: bundleID, started: started)
      }
    }
    let resolved = try await worker.runThrowing {
      try resolveWindows(candidates, cancellation: cancellation, deadline: deadline)
    }
    for candidate in candidates {
      try check(cancellation, deadline: deadline)
      let current = try await snapshot(sls)
      guard current.space(on: request.display)?.fullscreenWindows.contains(candidate.window) == true else { continue }
      guard let window = resolved[candidate.window.windowID]
      else { throw Failure("The requested fullscreen window is unavailable") }
      try check(cancellation, deadline: deadline)
      try await worker.runThrowing {
        guard !cancellation.isCancelled, identityMatches(candidate), windowID(window.element) == candidate.window.windowID else {
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
      try await waitForFullscreenExit(
        candidate,
        window: window,
        display: request.display,
        sls: sls,
        cancellation: cancellation,
        deadline: deadline,
      )
    }
    var current = try await snapshot(sls)
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
    guard let display = current.space(on: request.display), display.userDesktops.contains(request.home) else {
      throw Failure("The managed Desktop changed during activation")
    }
    if display.currentSpace != request.home {
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
      current = try await snapshot(sls)
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
    return current
  }

  private static func snapshot(_ sls: SLSClient) async throws -> DesktopSpaces {
    guard let spaces = await sls.desktopSpaces() else { throw Failure("Native Desktop state is unavailable") }
    return spaces
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
      let current = try await snapshot(sls)
      guard let row = current.space(on: display) else { throw Failure("The target monitor disconnected") }
      let exited = try await worker.runThrowing {
        guard identityMatches(candidate) else { throw Failure("The fullscreen window identity changed") }
        guard let fullscreen = attribute(window.element, "AXFullScreen") as? Bool else {
          throw Failure("The fullscreen transition could not be verified")
        }
        return !fullscreen
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

  private static func identityMatches(_ candidate: FullscreenCandidate) -> Bool {
    guard
      let application = NSRunningApplication(processIdentifier: candidate.window.pid),
      !application.isTerminated,
      application.bundleIdentifier == candidate.bundleID,
      application.launchDate == candidate.started,
      let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, candidate.window.windowID) as? [[String: Any]]
    else { return false }
    return rows.contains {
      ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == candidate.window.windowID
        && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == candidate.window.pid
    }
  }

  private static func findWindow(_ candidate: FullscreenCandidate) -> NativeAXWindow? {
    guard identityMatches(candidate) else { return nil }
    let app = AXUIElementCreateApplication(candidate.window.pid)
    AXUIElementSetMessagingTimeout(app, 1)
    var elements = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    if let main = attribute(app, kAXMainWindowAttribute), CFGetTypeID(main) == AXUIElementGetTypeID() {
      elements.append(main as! AXUIElement)
    }
    guard let element = elements.first(where: { windowID($0) == candidate.window.windowID }) else { return nil }
    AXUIElementSetMessagingTimeout(element, 1)
    return NativeAXWindow(element)
  }

  /// AXWindows only lists the current Space. Resolve the explicitly requested
  /// WindowServer identities before mutating any window, without visiting its
  /// Space. The remote-token layout is also used by yabai and AltTab:
  /// https://github.com/asmvik/yabai/blob/b2dc8b4c892d74738a6e865d73048ed2dc3c9ed1/src/window_manager.c
  private static func resolveWindows(
    _ candidates: [FullscreenCandidate],
    cancellation: NativePreparationCancellation,
    deadline: ContinuousClock.Instant,
  ) throws -> [UInt32: NativeAXWindow] {
    var resolved = [UInt32: NativeAXWindow]()
    for candidate in candidates {
      try check(cancellation, deadline: deadline)
      if let window = findWindow(candidate) {
        resolved[candidate.window.windowID] = window
      }
    }
    for group in Dictionary(grouping: candidates, by: { $0.window.pid }).values {
      var missing = group.filter { resolved[$0.window.windowID] == nil }
      guard !missing.isEmpty else { continue }
      guard missing.allSatisfy(identityMatches) else { throw Failure("The fullscreen process identity changed") }
      var token = Data(count: 20)
      var pid = group[0].window.pid
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
          let match = missing.firstIndex(where: { $0.window.windowID == id }),
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

  var lease: SymbolicDesktopShortcut.Lease? {
    get { value.withLock { $0 } }
    set { value.withLock { $0 = newValue } }
  }

  // MARK: Private

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
