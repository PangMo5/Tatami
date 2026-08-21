// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ComposableArchitecture
import DependenciesMacros
import Sparkle

/// Wraps Sparkle's updater so reducers/views can drive software updates
/// without touching Sparkle directly. Reading the live dependency starts
/// Sparkle's background check schedule.
@DependencyClient
struct UpdaterClient: Sendable {
  /// Triggers a user-initiated update check.
  var checkForUpdates: @MainActor @Sendable () -> Void
  /// Applies the scheduled-check preferences to the underlying updater.
  var configure: @MainActor @Sendable (
    _ automaticallyChecks: Bool,
    _ interval: TimeInterval
  ) -> Void
}

extension UpdaterClient: DependencyKey {
  static let liveValue: UpdaterClient = MainActor.assumeIsolated {
    let controller = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
    let updater = controller.updater
    return UpdaterClient(
      checkForUpdates: {
        // Sparkle's window can end up behind another app without any error, so
        // record the activation state the check starts from. That is what
        // distinguishes "Sparkle refused" from "the alert opened out of sight".
        @Dependency(\.debugLog) var debugLog
        debugLog.log(
          "Updater",
          "checkForUpdates active=\(NSApp.isActive) "
            + "policy=\(NSApp.activationPolicy().rawValue) "
            + "canCheck=\(updater.canCheckForUpdates)",
        )
        updater.checkForUpdates()
      },
      configure: { automaticallyChecks, interval in
        updater.automaticallyChecksForUpdates = automaticallyChecks
        updater.updateCheckInterval = interval
      }
    )
  }

  /// Tests must not start Sparkle's background update schedule.
  static let testValue = UpdaterClient(
    checkForUpdates: {},
    configure: { _, _ in }
  )
  static let previewValue = testValue
}

extension DependencyValues {
  var updater: UpdaterClient {
    get { self[UpdaterClient.self] }
    set { self[UpdaterClient.self] = newValue }
  }
}
