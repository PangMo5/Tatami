// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ApplicationServices
import Foundation
import OSLog

// MARK: - EventTapAccess

/// Owns the lifetime of input capture and replay. A denied Accessibility check
/// closes input immediately, but deleting the permission record can leave all
/// in-process permission APIs cached as allowed. While taps exist, independently
/// verify that WindowServer still admits a new active keyboard tap.
///
/// A closed session stays closed until relaunch. Owners cancel their work on
/// their own run loops, and callbacks already in progress pass physical input
/// through as soon as this gate closes.
final class EventTapAccess: @unchecked Sendable {

  // MARK: Lifecycle

  init(
    isTrusted: @escaping @Sendable () -> Bool,
    canCaptureInput: @escaping @Sendable () -> Bool,
    startMonitoring: @escaping @Sendable (@escaping @Sendable () -> Void) -> Cancellation,
    notificationCenter: NotificationCenter = .default,
  ) {
    self.isTrusted = isTrusted
    self.canCaptureInput = canCaptureInput
    self.startMonitoring = startMonitoring
    self.notificationCenter = notificationCenter
  }

  deinit {
    stopMonitoring?()
  }

  // MARK: Internal

  typealias Cancellation = @Sendable () -> Void

  static let didCloseNotification = Notification.Name("dev.PangMo5.Tatami.inputAccessDidClose")

  static let shared = EventTapAccess(
    isTrusted: { AXIsProcessTrusted() },
    canCaptureInput: {
      // No run-loop source is installed. Invalidate immediately so the probe
      // cannot retain input. Unlike cached permission APIs, creation checks the
      // current server-side permission, including a deleted TCC record.
      guard
        let tap = CGEvent.tapCreate(
          tap: .cgSessionEventTap,
          place: .tailAppendEventTap,
          options: .defaultTap,
          eventsOfInterest: 1 << CGEventType.keyDown.rawValue,
          callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
          userInfo: nil,
        )
      else { return false }
      CFMachPortInvalidate(tap)
      return true
    },
    startMonitoring: { check in
      let monitor = EventTapAccessMonitor(check: check)
      return { monitor.cancel() }
    },
  )

  /// A cheap session snapshot for UI admission; never queries TCC or WindowServer.
  var isClosed: Bool {
    lock.withLock { revoked }
  }

  /// Warm the initial TCC query off-main before installing AppKit gesture taps.
  func prepare() async -> Bool {
    await withCheckedContinuation { continuation in
      EventTapThread.shared.perform { [self] in
        continuation.resume(returning: permitsInput())
      }
    }
  }

  func permitsInput() -> Bool {
    guard lock.withLock({ !revoked }) else { return false }
    // Never hold a lock needed by an input callback across a system query.
    if !isTrusted() {
      revoke(reason: "Accessibility access lost")
    }
    return lock.withLock { !revoked }
  }

  /// Only installed tap owners keep the monitor alive. A registration racing
  /// with revocation is rejected and must be torn down by the caller.
  func register(_ onRevoked: @escaping @Sendable () -> Void) -> UUID? {
    let registration = lock.withLock { () -> (UUID, UInt64?)? in
      guard !revoked else { return nil }
      let id = UUID()
      observers[id] = onRevoked
      guard !monitoring else { return (id, nil) }
      monitoring = true
      monitorGeneration &+= 1
      return (id, monitorGeneration)
    }
    guard let (id, generation) = registration else { return nil }
    if let generation {
      let stop = startMonitoring { [weak self] in
        self?.checkCaptureAccess(generation: generation)
      }
      let keep = lock.withLock {
        guard !revoked, monitoring, monitorGeneration == generation else { return false }
        stopMonitoring = stop
        return true
      }
      if !keep { stop() }
    }
    return lock.withLock { observers[id] == nil ? nil : id }
  }

  func unregister(_ id: UUID?) {
    guard let id else { return }
    let stop = lock.withLock { () -> Cancellation? in
      observers.removeValue(forKey: id)
      guard observers.isEmpty, monitoring else { return nil }
      monitoring = false
      monitorGeneration &+= 1
      defer { stopMonitoring = nil }
      return stopMonitoring
    }
    stop?()
  }

  // MARK: Private

  private let isTrusted: @Sendable () -> Bool
  private let canCaptureInput: @Sendable () -> Bool
  private let startMonitoring: @Sendable (@escaping @Sendable () -> Void) -> Cancellation
  private let notificationCenter: NotificationCenter
  private let lock = NSLock()
  private var revoked = false
  private var observers = [UUID: @Sendable () -> Void]()
  private var monitoring = false
  private var monitorGeneration: UInt64 = 0
  private var stopMonitoring: Cancellation?

  private func checkCaptureAccess(generation: UInt64) {
    guard lock.withLock({ !revoked && monitoring && monitorGeneration == generation }) else { return }
    guard isTrusted(), canCaptureInput() else {
      revoke(reason: "WindowServer input capture unavailable", generation: generation)
      return
    }
  }

  private func revoke(reason: String, generation: UInt64? = nil) {
    let cleanup = lock.withLock { () -> ([Cancellation], Cancellation?)? in
      guard !revoked else { return nil }
      if let generation {
        guard monitoring, monitorGeneration == generation else { return nil }
      }
      revoked = true
      monitoring = false
      monitorGeneration &+= 1
      defer {
        observers.removeAll()
        stopMonitoring = nil
      }
      return (Array(observers.values), stopMonitoring)
    }
    guard let (callbacks, stop) = cleanup else { return }
    stop?()
    Logger(subsystem: "dev.PangMo5.Tatami", category: "Accessibility")
      .notice("\(reason, privacy: .public); stopping all event taps")
    for callback in callbacks { callback() }
    notificationCenter.post(name: Self.didCloseNotification, object: nil)
  }

}

// MARK: - EventTapAccessMonitor

/// TCC record deletion sends no reliable notification and may stop event
/// delivery before a tap callback runs. Bound detection independently of input
/// and the main run loop; stop this work when the last tap owner unregisters.
/// Dispatch sources support cancellation from any thread.
private final class EventTapAccessMonitor: @unchecked Sendable {

  // MARK: Lifecycle

  init(check: @escaping @Sendable () -> Void) {
    timer = DispatchSource.makeTimerSource(queue: Self.queue)
    timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
    timer.setEventHandler(handler: check)
    timer.resume()
  }

  // MARK: Internal

  func cancel() {
    timer.cancel()
  }

  // MARK: Private

  private static let queue = DispatchQueue(label: "dev.PangMo5.Tatami.input-access", qos: .utility)

  private let timer: any DispatchSourceTimer

}
