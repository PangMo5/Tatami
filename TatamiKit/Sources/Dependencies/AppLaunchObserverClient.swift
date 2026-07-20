import AppKit
import Dependencies
import DependenciesMacros
import Foundation
import OSLog

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

enum AppLaunchEvent: Sendable, Hashable {
  case launched(bundleId: String, name: String)
  case activated(bundleId: String)
  case terminated(bundleId: String)
  /// User switched to a different native macOS Space, or the system
  /// just woke from sleep. Either way the on-screen window set may
  /// have changed without any per-app notification firing — so the
  /// reducer should re-reconcile the active workspace.
  case activeSpaceChanged
  case didWake
}

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

private final class AppLaunchObserverCenter: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<AppLaunchEvent>.Continuation] = [:]

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

  private func broadcast(_ event: AppLaunchEvent) {
    let live = lock.withLock { Array(continuations.values) }
    for continuation in live { continuation.yield(event) }
  }

  init() {
    let nc = NSWorkspace.shared.notificationCenter
    nc.addObserver(
      forName: NSWorkspace.didLaunchApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication,
        let bundleId = app.bundleIdentifier, !bundleId.isEmpty,
        app.activationPolicy == .regular
      else { return }
      self?.broadcast(.launched(bundleId: bundleId, name: app.localizedName ?? bundleId))
    }
    nc.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication,
        let bundleId = app.bundleIdentifier, !bundleId.isEmpty,
        app.activationPolicy == .regular
      else { return }
      self?.broadcast(.activated(bundleId: bundleId))
    }
    // Unhide fires when a previously-hidden app's windows come back —
    // e.g. KakaoTalk opening a chat via the Notification Center while
    // the rest of the app stays hidden. Surface this as an `.activated`
    // so the reducer reconciles the same way it does on a normal app
    // activation.
    nc.addObserver(
      forName: NSWorkspace.didUnhideApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication,
        let bundleId = app.bundleIdentifier, !bundleId.isEmpty,
        app.activationPolicy == .regular
      else { return }
      self?.broadcast(.activated(bundleId: bundleId))
    }
    nc.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication,
        let bundleId = app.bundleIdentifier, !bundleId.isEmpty
      else { return }
      self?.broadcast(.terminated(bundleId: bundleId))
    }
    // Native macOS Space changes don't fire any per-app notification.
    // Without this the on-screen window set silently drifts away from
    // what the BSP tree thinks is current.
    nc.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.broadcast(.activeSpaceChanged)
    }
    // After wake the window list may have re-laid out (macOS sometimes
    // moves windows across Spaces during sleep). Reconcile.
    nc.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.broadcast(.didWake)
    }
  }
}
