import AppKit
import Dependencies
import Foundation
import OSLog

/// Streams regular-app launch events from `NSWorkspace`. Used by the
/// activation reducer so apps that the user opens manually (e.g.
/// KakaoTalk) get folded into the active workspace's BSP layout.
public struct AppLaunchObserverClient: Sendable {
  public var events: @Sendable () -> AsyncStream<AppLaunchEvent>

  public init(events: @escaping @Sendable () -> AsyncStream<AppLaunchEvent>) {
    self.events = events
  }
}

public enum AppLaunchEvent: Sendable, Hashable {
  case launched(bundleId: String, name: String)
  case activated(bundleId: String)
  case terminated(bundleId: String)
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
  }
}
