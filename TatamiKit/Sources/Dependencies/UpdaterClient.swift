import ComposableArchitecture
import DependenciesMacros
import Sparkle

/// Wraps Sparkle's updater so reducers/views can drive software updates
/// without touching Sparkle directly. Reading the live dependency starts
/// Sparkle's background check schedule.
@DependencyClient
public struct UpdaterClient: Sendable {
  /// Triggers a user-initiated update check.
  public var checkForUpdates: @Sendable () -> Void
  /// Applies the scheduled-check preferences to the underlying updater.
  public var configure: @Sendable (_ automaticallyChecks: Bool, _ interval: TimeInterval) -> Void
}

extension UpdaterClient: DependencyKey {
  public static let liveValue: UpdaterClient = MainActor.assumeIsolated {
    let controller = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
    let updater = controller.updater
    return UpdaterClient(
      checkForUpdates: {
        Task { @MainActor in updater.checkForUpdates() }
      },
      configure: { automaticallyChecks, interval in
        Task { @MainActor in
          updater.automaticallyChecksForUpdates = automaticallyChecks
          updater.updateCheckInterval = interval
        }
      }
    )
  }
}

extension DependencyValues {
  public var updater: UpdaterClient {
    get { self[UpdaterClient.self] }
    set { self[UpdaterClient.self] = newValue }
  }
}
