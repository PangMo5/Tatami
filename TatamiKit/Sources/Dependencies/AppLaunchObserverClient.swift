import AppKit
import Dependencies
import DependenciesMacros
import Foundation
import OSLog

/// Streams regular-app launch events from `NSWorkspace`. Used by the
/// activation reducer so apps that the user opens manually (e.g.
/// KakaoTalk) get folded into the active workspace's BSP layout.
@DependencyClient
public struct AppLaunchObserverClient: Sendable {
  public var events: @Sendable () -> AsyncStream<AppLaunchEvent> = { AsyncStream { _ in } }
}

public enum AppLaunchEvent: Sendable, Hashable {
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
  public static let liveValue: AppLaunchObserverClient = {
    let center = AppLaunchObserverCenter()
    return AppLaunchObserverClient(events: { center.events })
  }()

  public static let testValue = AppLaunchObserverClient(events: {
    AsyncStream { _ in }
  })

  public static let previewValue = testValue
}

extension DependencyValues {
  public var appLaunch: AppLaunchObserverClient {
    get { self[AppLaunchObserverClient.self] }
    set { self[AppLaunchObserverClient.self] = newValue }
  }
}

private final class AppLaunchObserverCenter: @unchecked Sendable {
  let events: AsyncStream<AppLaunchEvent>
  private let continuation: AsyncStream<AppLaunchEvent>.Continuation

  init() {
    var c: AsyncStream<AppLaunchEvent>.Continuation!
    self.events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
    self.continuation = c

    let nc = NSWorkspace.shared.notificationCenter
    let cont = continuation
    nc.addObserver(
      forName: NSWorkspace.didLaunchApplicationNotification,
      object: nil,
      queue: .main
    ) { notification in
      guard
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication,
        let bundleId = app.bundleIdentifier, !bundleId.isEmpty,
        app.activationPolicy == .regular
      else { return }
      cont.yield(.launched(bundleId: bundleId, name: app.localizedName ?? bundleId))
    }
    nc.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { notification in
      guard
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication,
        let bundleId = app.bundleIdentifier, !bundleId.isEmpty,
        app.activationPolicy == .regular
      else { return }
      cont.yield(.activated(bundleId: bundleId))
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
    ) { notification in
      guard
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication,
        let bundleId = app.bundleIdentifier, !bundleId.isEmpty,
        app.activationPolicy == .regular
      else { return }
      cont.yield(.activated(bundleId: bundleId))
    }
    nc.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification,
      object: nil,
      queue: .main
    ) { notification in
      guard
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication,
        let bundleId = app.bundleIdentifier, !bundleId.isEmpty
      else { return }
      cont.yield(.terminated(bundleId: bundleId))
    }
    // Native macOS Space changes don't fire any per-app notification.
    // Without this the on-screen window set silently drifts away from
    // what the BSP tree thinks is current.
    nc.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil,
      queue: .main
    ) { _ in
      cont.yield(.activeSpaceChanged)
    }
    // Mirror of `didUnhide` — record but don't broadcast a redundant
    // `.activated` (apps almost always also raise a windowFocused, and
    // an extra reconcile here would just churn the BSP). Kept as an
    // observer so we can hook into it later if needed.
    nc.addObserver(
      forName: NSWorkspace.didHideApplicationNotification,
      object: nil,
      queue: .main
    ) { _ in /* no-op for now */ }
    // After wake the window list may have re-laid out (macOS sometimes
    // moves windows across Spaces during sleep). Reconcile.
    nc.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { _ in
      cont.yield(.didWake)
    }
  }
}
