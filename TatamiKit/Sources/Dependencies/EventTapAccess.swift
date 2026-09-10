// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ApplicationServices
import Foundation
import OSLog

/// Input capture and replay require the same live Accessibility grant. Check
/// at event admission and after asynchronous preparation, not only when macOS
/// disables a tap: revocation does not reliably send a tap-disabled callback.
///
/// A revoked session stays closed until relaunch, matching AccessibilityClient's
/// grant lifecycle. Owners cancel their work on their own run loops; callbacks
/// already in progress pass input through as soon as this gate closes.
final class EventTapAccess: @unchecked Sendable {

  // MARK: Lifecycle

  init(isTrusted: @escaping @Sendable () -> Bool) {
    self.isTrusted = isTrusted
  }

  // MARK: Internal

  static let shared = EventTapAccess(isTrusted: { AXIsProcessTrusted() })

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
    // The first TCC lookup is warmed during installation; steady-state lookups
    // are cached by macOS, including live revocation, without our own timer.
    let trusted = isTrusted()
    let callbacks = lock.withLock { () -> [@Sendable () -> Void] in
      guard !revoked, !trusted else { return [] }
      revoked = true
      defer { observers.removeAll() }
      return Array(observers.values)
    }
    if !callbacks.isEmpty {
      Logger(subsystem: "dev.PangMo5.Tatami", category: "Accessibility")
        .notice("Accessibility access lost; stopping all event taps")
      for callback in callbacks { callback() }
    }
    return lock.withLock { !revoked }
  }

  /// Register only after installation succeeds. A revocation racing with
  /// installation rejects the new owner; the caller tears it down immediately.
  func register(_ onRevoked: @escaping @Sendable () -> Void) -> UUID? {
    lock.withLock {
      guard !revoked else { return nil }
      let id = UUID()
      observers[id] = onRevoked
      return id
    }
  }

  func unregister(_ id: UUID?) {
    guard let id else { return }
    _ = lock.withLock { observers.removeValue(forKey: id) }
  }

  // MARK: Private

  private let isTrusted: @Sendable () -> Bool
  private let lock = NSLock()
  private var revoked = false
  private var observers = [UUID: @Sendable () -> Void]()

}
