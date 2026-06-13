import ComposableArchitecture
import Foundation

/// Owns the *side-effecting* state behind the Settings screen — CLI install
/// status, Accessibility permission, and update availability. The declarative
/// config toggles stay as `@Shared` bindings in the view; this reducer holds
/// only the logic that talks to the system (install, permission, relaunch).
@Reducer
public struct SettingsFeature {
  @ObservableState
  public struct State: Equatable {
    public var cli = CLIStatus()
    /// Default `true` to avoid a "not granted" flash before the first read.
    public var hasAXPermission = true
    /// Same flash-avoidance default as `hasAXPermission`.
    public var hasScreenRecordingPermission = true

    public init() {}
  }

  public enum Action {
    /// View appeared — read current status and start the updater stream.
    case task
    case refreshCLIStatus
    case installCLITapped
    case uninstallCLITapped
    /// A trust-DB change (or app re-activation) — re-read permission status.
    case accessibilityChanged
    case grantAccessibilityTapped
    case openAccessibilitySettingsTapped
    case grantScreenRecordingTapped
    case openScreenRecordingSettingsTapped
    case relaunchTapped
    case checkForUpdatesTapped
    /// A shortcut recorder started (`true`) / stopped (`false`) capturing.
    case shortcutRecordingChanged(Bool)
  }

  @Dependency(\.cliInstaller) var cliInstaller
  @Dependency(\.accessibility) var accessibility
  @Dependency(\.screenRecording) var screenRecording
  @Dependency(\.updater) var updater
  @Dependency(\.hotKeys) var hotKeys

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        state.cli = cliInstaller.status()
        state.hasAXPermission = accessibility.isTrusted()
        state.hasScreenRecordingPermission = screenRecording.isGranted()
        return .run { [accessibility] send in
          // Trust-DB change / app re-activation → re-read permission
          // status (the re-activation tick also covers coming back from
          // the Screen Recording pane of System Settings).
          for await _ in accessibility.changes() {
            await send(.accessibilityChanged)
          }
        }

      case .refreshCLIStatus:
        state.cli = cliInstaller.status()
        return .none

      case .installCLITapped:
        return .run { [cliInstaller] send in
          await cliInstaller.install()
          await send(.refreshCLIStatus)
        }

      case .uninstallCLITapped:
        return .run { [cliInstaller] send in
          await cliInstaller.uninstall()
          await send(.refreshCLIStatus)
        }

      case .accessibilityChanged:
        state.hasAXPermission = accessibility.isTrusted()
        state.hasScreenRecordingPermission = screenRecording.isGranted()
        return .none

      case .grantAccessibilityTapped:
        return .run { [accessibility] _ in
          await accessibility.requestAccess()
          await accessibility.openSettings()
        }

      case .openAccessibilitySettingsTapped:
        return .run { [accessibility] _ in await accessibility.openSettings() }

      case .grantScreenRecordingTapped:
        return .run { [screenRecording] _ in
          await screenRecording.requestAccess()
          await screenRecording.openSettings()
        }

      case .openScreenRecordingSettingsTapped:
        return .run { [screenRecording] _ in await screenRecording.openSettings() }

      case .relaunchTapped:
        return .run { [accessibility] _ in await accessibility.relaunch() }

      case .checkForUpdatesTapped:
        updater.checkForUpdates()
        return .none

      case .shortcutRecordingChanged(let recording):
        return .run { [hotKeys] _ in await hotKeys.setRecording(recording) }
      }
    }
  }
}
