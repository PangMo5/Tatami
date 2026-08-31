// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import Sharing

/// Adds and removes bundle identifiers that may keep a persistent elevated
/// control visible. The picker state intentionally mirrors workspace app
/// assignment so Settings can reuse the exact same `AppPickerSheet` flow.
@Reducer
public struct OverlayAwareAppsFeature {

  // MARK: Lifecycle

  public init() { }

  // MARK: Public

  @ObservableState
  public struct State: Equatable {
    public init() { }

    @Shared(.tatamiConfig) public var config
    public var isAppPickerPresented = false
    public var availableRunningApps = [MacApp]()
    public var knownApps = [String: MacApp]()

    public var apps: [MacApp] {
      config.settings.visibility.overlayAwareApps.map { bundleId in
        knownApps[bundleId]
          ?? MacApp(bundleIdentifier: bundleId, name: bundleId)
      }
    }
  }

  public enum Action {
    case onAppear
    case addAppButtonTapped
    case appPickerDismissed
    case appPickerAppSelected(MacApp)
    case chooseAppFileTapped
    case appRemoveRequested(bundleIdentifier: String)
  }

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        let registeredIds = state.config.settings.visibility.overlayAwareApps
        let registered = Set(registeredIds)
        for app in runningApps.resolveInstalled(registeredIds) {
          state.knownApps[app.bundleIdentifier] = app
        }
        for app in runningApps.current() where registered.contains(app.bundleIdentifier) {
          state.knownApps[app.bundleIdentifier] = app
        }
        return .none

      case .addAppButtonTapped:
        let registered = Set(state.config.settings.visibility.overlayAwareApps)
        let running = runningApps.current().filter {
          !registered.contains($0.bundleIdentifier)
            && !MacApp.isTatami($0.bundleIdentifier)
        }
        for app in running { state.knownApps[app.bundleIdentifier] = app }
        state.availableRunningApps = running
        state.isAppPickerPresented = true
        return .none

      case .appPickerDismissed:
        state.isAppPickerPresented = false
        state.availableRunningApps = []
        return .none

      case .appPickerAppSelected(let app):
        guard !MacApp.isTatami(app.bundleIdentifier) else { return .none }
        state.isAppPickerPresented = false
        state.availableRunningApps = []
        state.knownApps[app.bundleIdentifier] = app
        _ = state.$config.withLock {
          $0.settings.visibility.addOverlayAwareApp(
            bundleId: app.bundleIdentifier
          )
        }
        return .none

      case .chooseAppFileTapped:
        return .run { [appChooser] send in
          if let app = await appChooser.choose() {
            await send(.appPickerAppSelected(app))
          }
        }

      case .appRemoveRequested(let bundleId):
        state.$config.withLock {
          $0.settings.visibility.removeOverlayAwareApp(bundleId: bundleId)
        }
        state.knownApps[bundleId] = nil
        return .none
      }
    }
  }

  // MARK: Internal

  @Dependency(\.runningApps) var runningApps
  @Dependency(\.appChooser) var appChooser

}
