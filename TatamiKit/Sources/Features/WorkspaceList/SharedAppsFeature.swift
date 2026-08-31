// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import Sharing

/// Edit the shared apps — apps present in *every* workspace. Selected from
/// the Workspaces sidebar's "Shared" entry, which presents like a special
/// workspace: same app list UI, same per-app Float toggle (Float here means
/// "shared floating": untiled and kept above the tiles everywhere).
///
/// All mutations flow through `state.$config.withLock` and persist to the
/// TOML file; re-tiling the active workspace is routed in `AppFeature`.
@Reducer
public struct SharedAppsFeature {
  @ObservableState
  public struct State: Equatable {
    @Shared(.tatamiConfig) public var config
    public var isAppPickerPresented = false
    public var availableRunningApps: [MacApp] = []
    @Presents public var alert: AlertState<Action.Alert>?

    public init() {}

    public var apps: [SharedApp] {
      config.sharedApps
    }
  }

  public enum Action {
    case addAppButtonTapped
    case appPickerDismissed
    case appPickerAppSelected(MacApp)
    case chooseAppFileTapped
    case appRemoveRequested(bundleIdentifier: String)
    case layoutChanged(bundleIdentifier: String, layout: LayoutMode)
    case autoOpenToggled(bundleIdentifier: String, isOn: Bool)
    case alert(PresentationAction<Alert>)

    public enum Alert: Equatable {
      case confirmAppRemoval(bundleIdentifier: String)
    }
  }

  @Dependency(\.runningApps) var runningApps
  @Dependency(\.appChooser) var appChooser

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .addAppButtonTapped:
        let alreadyShared = Set(state.apps.map(\.bundleIdentifier))
        state.availableRunningApps = runningApps.current()
          .filter { !alreadyShared.contains($0.bundleIdentifier) }
        state.isAppPickerPresented = true
        return .none

      case .appPickerDismissed:
        state.isAppPickerPresented = false
        state.availableRunningApps = []
        return .none

      case .appPickerAppSelected(let app):
        state.isAppPickerPresented = false
        state.availableRunningApps = []
        state.$config.withLock { config in
          guard !config.sharedApps.contains(where: {
            $0.bundleIdentifier == app.bundleIdentifier
          }) else { return }
          config.sharedApps.append(SharedApp(app))
        }
        return .none

      case .chooseAppFileTapped:
        // Pick an app from disk; route through the same add path as the
        // running-app picker. Cancelling leaves the sheet untouched.
        return .run { [appChooser] send in
          if let app = await appChooser.choose() {
            await send(.appPickerAppSelected(app))
          }
        }

      case .appRemoveRequested(let bundleId):
        let name = state.apps.first { $0.bundleIdentifier == bundleId }?.name ?? bundleId
        state.alert = AlertState {
          TextState("Remove \"\(name)\" from every workspace?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmAppRemoval(bundleIdentifier: bundleId)) {
            TextState("Remove")
          }
          ButtonState(role: .cancel) {
            TextState("Cancel")
          }
        } message: {
          TextState("Shared apps appear in all workspaces, so this removes it everywhere. You can add it back anytime.")
        }
        return .none

      case .alert(.presented(.confirmAppRemoval(let bundleId))):
        state.$config.withLock { config in
          config.sharedApps.removeAll { $0.bundleIdentifier == bundleId }
        }
        return .none

      case .alert:
        return .none

      case .layoutChanged(let bundleId, let layout):
        state.$config.withLock { config in
          guard let idx = config.sharedApps.firstIndex(where: {
            $0.bundleIdentifier == bundleId
          }) else { return }
          config.sharedApps[idx].layout = layout
        }
        return .none

      case .autoOpenToggled(let bundleId, let isOn):
        state.$config.withLock { config in
          guard let idx = config.sharedApps.firstIndex(where: {
            $0.bundleIdentifier == bundleId
          }) else { return }
          config.sharedApps[idx].autoOpen = isOn
        }
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert)
  }
}
