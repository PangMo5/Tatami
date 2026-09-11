// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Dependencies
import DependenciesMacros
import Foundation
import OSLog

// MARK: - AccessibilityClient

/// Accessibility (AX) permission: status, prompting, and applying a new grant.
///
/// Permission queries can remain cached for the process. A fresh grant needs
/// relaunch, and deleting a permission record can leave an existing trusted
/// process reporting true. Reads and change notifications share EventTapAccess's
/// session state so a known revocation cannot appear granted in the UI.
@DependencyClient
struct AccessibilityClient: Sendable {
  /// Effective AX availability for this session, closed until relaunch after loss.
  var isTrusted: @Sendable () -> Bool = { false }
  /// Prompt for Accessibility access (shows the system dialog if untrusted).
  var requestAccess: @Sendable () async -> Void
  /// Open System Settings → Privacy & Security → Accessibility.
  var openSettings: @Sendable () async -> Void
  /// Relaunch the app so a freshly-granted permission takes effect.
  var relaunch: @Sendable () async -> Void
  /// Ticks on subscription, session closure, Accessibility broadcasts, and app
  /// reactivation. Re-read `isTrusted()`; system broadcasts alone miss deletion.
  var changes: @Sendable () -> AsyncStream<Void> = { .finished }
}

// MARK: - PermissionObserverTokens

/// Holds notification observers so they can be torn down from the stream's
/// `@Sendable` termination handler. The tokens/centers aren't `Sendable`, but
/// they're only ever touched on the notification machinery, so the box is a
/// documented `@unchecked Sendable`.
final class PermissionObserverTokens: @unchecked Sendable {

  // MARK: Lifecycle

  init(local: NotificationCenter) {
    self.local = local
  }

  deinit { removeAll() }

  // MARK: Internal

  let distributed = DistributedNotificationCenter.default()
  let local: NotificationCenter
  var tokens = [any NSObjectProtocol]()

  func removeAll() {
    for token in tokens { distributed.removeObserver(token)
      local.removeObserver(token)
    }
    tokens = []
  }

}

// MARK: - AccessibilityClient + DependencyKey

extension AccessibilityClient: DependencyKey {
  static let liveValue = live(access: .shared, notificationCenter: .default)

  static let testValue = AccessibilityClient(
    isTrusted: { true },
    requestAccess: { },
    openSettings: { },
    relaunch: { },
    changes: { .finished },
  )
  static let previewValue = testValue

  static func live(access: EventTapAccess, notificationCenter: NotificationCenter) -> Self {
    AccessibilityClient(
      isTrusted: { access.permitsInput() },
      requestAccess: {
        await MainActor.run { _ = ensureAccessibilityTrust() }
      },
      openSettings: {
        await MainActor.run {
          guard
            let url = URL(
              string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
          else { return }
          NSWorkspace.shared.open(url)
        }
      },
      relaunch: {
        await MainActor.run {
          // `open -n` runs independently, so it survives this process exiting.
          let task = Process()
          task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
          task.arguments = ["-n", Bundle.main.bundleURL.path]
          do {
            try task.run()
          } catch {
            // Don't terminate if the relauncher never started — that would
            // turn "relaunch" into a plain quit with no explanation.
            logger.error("relaunch failed to spawn open: \(error.localizedDescription, privacy: .public)")
            return
          }
          NSApp.terminate(nil)
        }
      },
      changes: {
        AsyncStream { continuation in
          let observers = PermissionObserverTokens(local: notificationCenter)
          observers.tokens = [
            observers.local.addObserver(
              forName: EventTapAccess.didCloseNotification,
              object: nil,
              queue: nil,
            ) { _ in continuation.yield() },
            observers.distributed.addObserver(
              forName: Notification.Name("com.apple.accessibility.api"),
              object: nil,
              queue: nil,
            ) { _ in continuation.yield() },
            observers.local.addObserver(
              forName: NSApplication.didBecomeActiveNotification,
              object: nil,
              queue: nil,
            ) { _ in continuation.yield() },
          ]
          continuation.onTermination = { _ in observers.removeAll() }
          // Close the gap between the feature's initial read and subscription.
          continuation.yield()
        }
      },
    )
  }
}

extension DependencyValues {
  var accessibility: AccessibilityClient {
    get { self[AccessibilityClient.self] }
    set { self[AccessibilityClient.self] = newValue }
  }
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "Accessibility")
