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

  // MARK: Lifecycle

  public init() { }

  // MARK: Public

  @ObservableState
  public struct State: Equatable {
    public init() { }

    @Shared(.tatamiConfig) public var config
    public var isAppPickerPresented = false
    public var availableRunningApps = [MacApp]()
    public var suppressConfirmation = false
    @Presents public var alert: AlertState<Action.Alert>?

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
    case layoutApplied
    case autoOpenToggled(bundleIdentifier: String, isOn: Bool)
    case confirmationSuppressionChanged(Bool)
    case alert(PresentationAction<Alert>)

    public enum Alert: Equatable {
      case confirmAppRemoval(bundleIdentifier: String)
      case confirmLayoutChange(bundleIdentifier: String, previous: LayoutMode, layout: LayoutMode)
    }
  }

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .confirmationSuppressionChanged(let suppressed):
        state.suppressConfirmation = suppressed
        return .none

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
          guard
            !config.sharedApps.contains(where: {
              $0.bundleIdentifier == app.bundleIdentifier
            })
          else { return }
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

      case .layoutChanged(let bundleId, let layout):
        guard let app = state.apps.first(where: { $0.bundleIdentifier == bundleId }), app.layout != layout else { return .none }
        state.alert = AlertState {
          TextState("Change layout for \(app.name)?")
        } actions: {
          ButtonState(
            role: .destructive,
            action: .confirmLayoutChange(bundleIdentifier: bundleId, previous: app.layout, layout: layout),
          ) { TextState("Change") }
          ButtonState(role: .cancel) { TextState("Cancel") }
        } message: {
          TextState("Save \(String(localized: layout.displayName)) for this app. Its membership is unchanged.")
        }
        return .none

      case .alert(.presented(.confirmLayoutChange(let bundleId, let previous, let layout))):
        guard state.apps.first(where: { $0.bundleIdentifier == bundleId })?.layout == previous else { return .none }
        state.$config.withLock { config in
          guard
            let idx = config.sharedApps.firstIndex(where: {
              $0.bundleIdentifier == bundleId
            })
          else { return }
          config.sharedApps[idx].layout = layout
        }
        return .send(.layoutApplied)

      case .layoutApplied:
        return .none

      case .alert:
        return .none

      case .autoOpenToggled(let bundleId, let isOn):
        state.$config.withLock { config in
          guard
            let idx = config.sharedApps.firstIndex(where: {
              $0.bundleIdentifier == bundleId
            })
          else { return }
          config.sharedApps[idx].autoOpen = isOn
        }
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert)
    .persistentConfirmations(
      config: \.$config,
      alert: \.alert,
      action: \.alert,
      suppress: \.suppressConfirmation,
      kind: { action in
        switch action {
        case .confirmAppRemoval: .removeSharedApp
        case .confirmLayoutChange(_, _, let layout): .layout(layout, shared: true)
        }
      },
    )
  }

  // MARK: Internal

  @Dependency(\.runningApps) var runningApps
  @Dependency(\.appChooser) var appChooser

}
