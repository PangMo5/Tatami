// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation

/// Owns the *side-effecting* state behind the Settings screen — CLI install
/// status, Accessibility permission, and update availability. The declarative
/// config toggles stay as `@Shared` bindings in the view; this reducer holds
/// only the logic that talks to the system (install, permission, relaunch).
@Reducer
public struct SettingsFeature {

  // MARK: Lifecycle

  public init() { }

  // MARK: Public

  @ObservableState
  public struct State: Equatable {
    public init() { }

    public var cli = CLIStatus()
    public var hooks = HookSettingsFeature.State()
    public var overlayAwareApps = OverlayAwareAppsFeature.State()
    /// Default `true` to avoid a "not granted" flash before the first read.
    public var hasAXPermission = true
    /// Same flash-avoidance default as `hasAXPermission`.
    public var hasScreenRecordingPermission = true
    @Presents public var alert: AlertState<Action.Alert>?
  }

  public enum Action {
    /// View appeared — read current status and start the updater stream.
    case task
    case refreshCLIStatus
    case installCLITapped
    case hooks(HookSettingsFeature.Action)
    case overlayAwareApps(OverlayAwareAppsFeature.Action)
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
    case alert(PresentationAction<Alert>)

    // MARK: Public

    public enum Alert: Equatable {
      case confirmUninstall
    }
  }

  public var body: some ReducerOf<Self> {
    CombineReducers {
      Scope(state: \.hooks, action: \.hooks) {
        HookSettingsFeature()
      }
      Scope(state: \.overlayAwareApps, action: \.overlayAwareApps) {
        OverlayAwareAppsFeature()
      }
      Reduce { state, action in
        switch action {
        case .task:
          state.cli = cliInstaller.status()
          state.hasAXPermission = accessibility.isTrusted()
          state.hasScreenRecordingPermission = screenRecording.isGranted()
          return .merge(
            .send(.overlayAwareApps(.onAppear)),
            .run { [accessibility] send in
              // Trust-DB change / app re-activation → re-read permission
              // status (the re-activation tick also covers coming back from
              // the Screen Recording pane of System Settings).
              for await _ in accessibility.changes() {
                await send(.accessibilityChanged)
              }
            },
          )

        case .refreshCLIStatus:
          state.cli = cliInstaller.status()
          return .none

        case .installCLITapped:
          return .run { [cliInstaller] send in
            await cliInstaller.install()
            await send(.refreshCLIStatus)
          }

        case .uninstallCLITapped:
          state.alert = AlertState {
            TextState("Uninstall tatami CLI?")
          } actions: {
            ButtonState(role: .destructive, action: .confirmUninstall) {
              TextState("Uninstall")
            }
            ButtonState(role: .cancel) {
              TextState("Cancel")
            }
          } message: {
            TextState("Removes the tatami symlink from /usr/local/bin. You can reinstall it anytime from here.")
          }
          return .none

        case .alert(.presented(.confirmUninstall)):
          return .run { [cliInstaller] send in
            await cliInstaller.uninstall()
            await send(.refreshCLIStatus)
          }

        case .alert:
          return .none

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
          return .run { [updater] _ in await updater.checkForUpdates() }

        case .shortcutRecordingChanged(let recording):
          return .run { [hotKeys] _ in await hotKeys.setRecording(recording) }

        case .hooks:
          return .none

        case .overlayAwareApps:
          return .none
        }
      }
    }
    .ifLet(\.$alert, action: \.alert)
  }

  // MARK: Internal

  @Dependency(\.cliInstaller) var cliInstaller
  @Dependency(\.accessibility) var accessibility
  @Dependency(\.screenRecording) var screenRecording
  @Dependency(\.updater) var updater
  @Dependency(\.hotKeys) var hotKeys

}
