// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Dependencies
import DependenciesMacros
import Foundation
import OSLog

// MARK: - AppLaunchObserverClient

/// Streams regular-app launch events from `NSWorkspace`. Used by the
/// activation reducer so apps that the user opens manually (e.g.
/// KakaoTalk) get folded into the active workspace's BSP layout — and by the
/// layout preview to refresh window titles / shared-app presence.
///
/// `events()` is **multicast**: every call returns a fresh, independent stream,
/// and each `NSWorkspace` notification fans out to all live consumers. So the
/// activation reducer (one process-lifetime subscription) and the layout
/// preview (a fresh subscription per workspace selection) can both consume it
/// without starving each other.
@DependencyClient
struct AppLaunchObserverClient: Sendable {
  var events: @Sendable () -> AsyncStream<AppLaunchEvent> = { AsyncStream { _ in } }
}

// MARK: - AppLaunchEvent

enum AppLaunchEvent: Sendable, Hashable {
  case launched(bundleId: String, name: String, pid: pid_t)
  case activated(bundleId: String, pid: pid_t)
  /// A running app became visible again without necessarily becoming
  /// frontmost. Borrow intentionally uses `setFocus: false`, so this is a
  /// membership edge, not an activation/follow-focus edge.
  case unhidden(bundleId: String, pid: pid_t)
  case terminated(bundleId: String, pid: pid_t)
  /// User switched to a different native macOS Space, or the system
  /// just woke from sleep. Either way the on-screen window set may
  /// have changed without any per-app notification firing — so the
  /// reducer should re-reconcile the active workspace.
  case activeSpaceChanged
  /// WindowServer can retire every surface while the machine sleeps or shuts
  /// down. Mark that teardown window before its 804/816 events arrive so it
  /// cannot be mistaken for a sequence of user-initiated closes.
  case willSleep
  case willPowerOff
  case didWake
  /// A user-session transition can make every application window temporarily
  /// unavailable to AX without putting the machine to sleep.
  case sessionWillResign
  case sessionDidBecomeActive
  /// Direct screen lock raises loginwindow's shield before AX starts returning
  /// zero window ids/non-settable attributes. Freeze membership on that early
  /// edge and resume only after authentication completes.
  case screenWillLock
  case screenDidUnlock
}

// MARK: - AppLaunchObserverClient + DependencyKey

extension AppLaunchObserverClient: DependencyKey {
  static let liveValue: AppLaunchObserverClient = {
    let center = AppLaunchObserverCenter()
    return AppLaunchObserverClient(events: { center.makeStream() })
  }()

  static let testValue = AppLaunchObserverClient(events: {
    AsyncStream { _ in }
  })

  static let previewValue = testValue
}

extension DependencyValues {
  var appLaunch: AppLaunchObserverClient {
    get { self[AppLaunchObserverClient.self] }
    set { self[AppLaunchObserverClient.self] = newValue }
  }
}

// MARK: - AppLaunchObserverCenter

private final class AppLaunchObserverCenter: @unchecked Sendable {

  // MARK: Lifecycle

  init() {
    let nc = NSWorkspace.shared.notificationCenter
    nc.addObserver(
      forName: NSWorkspace.didLaunchApplicationNotification,
      object: nil,
      queue: .main,
    ) { [weak self] notification in
      guard
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
        as? NSRunningApplication,
        let bundleId = app.bundleIdentifier, !bundleId.isEmpty,
        app.activationPolicy == .regular
      else { return }
      self?.broadcast(
        .launched(
          bundleId: bundleId,
          name: app.localizedName ?? bundleId,
          pid: app.processIdentifier,
        )
      )
    }
    nc.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main,
    ) { [weak self] notification in
      guard
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
        as? NSRunningApplication,
        let bundleId = app.bundleIdentifier, !bundleId.isEmpty,
        app.activationPolicy == .regular
      else { return }
      self?.broadcast(.activated(bundleId: bundleId, pid: app.processIdentifier))
    }
    // Unhide fires when a previously-hidden app's windows come back —
    // e.g. a Borrow reveals KakaoTalk while deliberately leaving the host
    // frontmost. Keep this distinct from activation: frontmost validation is
    // correct for follow-focus, but would discard this valid visibility edge.
    nc.addObserver(
      forName: NSWorkspace.didUnhideApplicationNotification,
      object: nil,
      queue: .main,
    ) { [weak self] notification in
      guard
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
        as? NSRunningApplication,
        let bundleId = app.bundleIdentifier, !bundleId.isEmpty,
        app.activationPolicy == .regular
      else { return }
      self?.broadcast(.unhidden(bundleId: bundleId, pid: app.processIdentifier))
    }
    nc.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification,
      object: nil,
      queue: .main,
    ) { [weak self] notification in
      guard
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
        as? NSRunningApplication,
        let bundleId = app.bundleIdentifier, !bundleId.isEmpty
      else { return }
      self?.broadcast(.terminated(bundleId: bundleId, pid: app.processIdentifier))
    }
    // Native macOS Space changes don't fire any per-app notification.
    // Without this the on-screen window set silently drifts away from
    // what the BSP tree thinks is current.
    nc.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil,
      queue: .main,
    ) { [weak self] _ in
      self?.broadcast(.activeSpaceChanged)
    }
    // After wake the window list may have re-laid out (macOS sometimes
    // moves windows across Spaces during sleep). Reconcile.
    nc.addObserver(
      forName: NSWorkspace.willSleepNotification,
      object: nil,
      queue: .main,
    ) { [weak self] _ in
      self?.broadcast(.willSleep)
    }
    nc.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main,
    ) { [weak self] _ in
      self?.broadcast(.didWake)
    }
    nc.addObserver(
      forName: NSWorkspace.sessionDidResignActiveNotification,
      object: nil,
      queue: .main,
    ) { [weak self] _ in
      self?.broadcast(.sessionWillResign)
    }
    nc.addObserver(
      forName: NSWorkspace.sessionDidBecomeActiveNotification,
      object: nil,
      queue: .main,
    ) { [weak self] _ in
      self?.broadcast(.sessionDidBecomeActive)
    }
    nc.addObserver(
      forName: NSWorkspace.willPowerOffNotification,
      object: nil,
      queue: .main,
    ) { [weak self] _ in
      self?.broadcast(.willPowerOff)
    }

    let distributed = DistributedNotificationCenter.default()
    distributed.addObserver(
      forName: Self.shieldWindowRaisedNotification,
      object: nil,
      queue: .main,
    ) { [weak self] _ in
      self?.broadcast(.screenWillLock)
    }
    distributed.addObserver(
      forName: Self.screenIsUnlockedNotification,
      object: nil,
      queue: .main,
    ) { [weak self] _ in
      self?.broadcast(.screenDidUnlock)
    }
  }

  // MARK: Internal

  /// A fresh independent stream per caller; each is registered for fan-out and
  /// deregisters itself on termination (subscription cancelled).
  func makeStream() -> AsyncStream<AppLaunchEvent> {
    let id = UUID()
    return AsyncStream(bufferingPolicy: .unbounded) { continuation in
      lock.withLock { continuations[id] = continuation }
      continuation.onTermination = { [weak self] _ in
        self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
      }
    }
  }

  // MARK: Private

  private static let shieldWindowRaisedNotification = Notification.Name(
    "com.apple.shieldWindowRaised"
  )
  private static let screenIsUnlockedNotification = Notification.Name(
    "com.apple.screenIsUnlocked"
  )

  private let lock = NSLock()
  private var continuations = [UUID: AsyncStream<AppLaunchEvent>.Continuation]()

  private func broadcast(_ event: AppLaunchEvent) {
    let live = lock.withLock { Array(continuations.values) }
    for continuation in live { continuation.yield(event) }
  }

}
