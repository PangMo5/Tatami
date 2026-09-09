// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import CustomDump
import Testing
@testable import TatamiKit

@MainActor
struct PersistentConfirmationTests {
  @Test
  func `a name draft finishing during navigation saves to its original workspace`() async {
    let old = Workspace(name: "Old")
    let current = Workspace(name: "Current")
    let state = WorkspaceDetailFeature.State(workspaceId: current.id)
    state.$config.withLock { $0.profiles = [Profile(name: "Default", workspaces: [old, current])] }
    let store = TestStore(initialState: state) { WorkspaceDetailFeature() }
    store.exhaustivity = .off
    await store.send(.nameSubmitted("Edited old workspace", workspaceID: old.id))
    #expect(store.state.config.workspace(id: old.id)?.name == "Edited old workspace")
    #expect(store.state.workspace?.name == "Current")
    await store.finish()
  }

  @Test(arguments: [false, true])
  func `native removal saves suppression only after confirming`(_ confirmed: Bool) async {
    let state = SharedAppsFeature.State()
    state.$config.withLock { $0.sharedApps = [SharedApp(bundleIdentifier: "app.test", name: "Test")] }
    let store = TestStore(initialState: state) { SharedAppsFeature() }
    store.exhaustivity = .off
    await store.send(.appRemoveRequested(bundleIdentifier: "app.test"))
    #expect(store.state.apps.count == 1)
    await store.send(.confirmationSuppressionChanged(true))
    if confirmed {
      await store.send(.alert(.presented(.confirmAppRemoval(bundleIdentifier: "app.test"))))
    } else {
      await store.send(.alert(.dismiss))
    }
    #expect(store.state.config.settings.confirmations[.removeSharedApp] == !confirmed)
    #expect(store.state.config.settings.confirmations[.removeWorkspaceApp])
    #expect(store.state.config.settings.confirmations[.floatSharedApp])
    #expect(store.state.apps.count == (confirmed ? 0 : 1))
    #expect(!store.state.suppressConfirmation)
    await store.finish()
  }

  @Test
  func `disabled confirmation policy executes native removal`() async {
    let state = SharedAppsFeature.State()
    state.$config.withLock {
      $0.sharedApps = [SharedApp(bundleIdentifier: "app.test", name: "Test")]
      $0.settings.confirmations[.removeSharedApp] = false
    }
    let store = TestStore(initialState: state) { SharedAppsFeature() }
    store.exhaustivity = .off
    await store.send(.appRemoveRequested(bundleIdentifier: "app.test"))
    await store.receive(\.alert)
    #expect(store.state.apps.isEmpty)
    #expect(store.state.alert == nil)
    await store.finish()
  }

  @Test(arguments: [false, true])
  func `native layout confirmation freezes the prior layout`(_ changed: Bool) async {
    let state = SharedAppsFeature.State()
    state.$config.withLock { $0.sharedApps = [SharedApp(bundleIdentifier: "app.test", name: "Test")] }
    let store = TestStore(initialState: state) { SharedAppsFeature() }
    store.exhaustivity = .off
    await store.send(.layoutChanged(bundleIdentifier: "app.test", layout: .floating))
    #expect(store.state.apps.first?.layout == .tiled)
    if changed { state.$config.withLock { $0.sharedApps[0].layout = .unmanaged } }
    await store.send(.alert(.presented(.confirmLayoutChange(bundleIdentifier: "app.test", previous: .tiled, layout: .floating))))
    await store.finish()
    #expect(store.state.apps.first?.layout == (changed ? .unmanaged : .floating))
  }

  @Test(arguments: [false, true])
  func `workspace layout changes wait for explicit confirmation`(_ confirmed: Bool) async {
    let workspace = Workspace(name: "Work", apps: [AppAssignment(bundleIdentifier: "app.test", name: "Test")])
    let state = WorkspaceDetailFeature.State(workspaceId: workspace.id)
    state.$config.withLock { $0.profiles = [Profile(name: "Default", workspaces: [workspace])] }
    let store = TestStore(initialState: state) { WorkspaceDetailFeature() }
    store.exhaustivity = .off
    await store.send(.layoutChanged(bundleIdentifier: "app.test", layout: .floating))
    #expect(store.state.apps.first?.layout == .tiled)
    if confirmed {
      await store.send(.alert(.presented(.confirmLayoutChange(
        bundleIdentifier: "app.test",
        previous: .tiled,
        layout: .floating,
      ))))
    } else {
      await store.send(.alert(.dismiss))
    }
    await store.finish()
    #expect(store.state.apps.first?.layout == (confirmed ? .floating : .tiled))
  }

  @Test(arguments: [false, true])
  func `guided setup reset preserves the draft until confirmed`(_ confirmed: Bool) async {
    var state = OnboardingFeature.State()
    state.draft = AppConfig(profiles: [Profile(name: "Custom", workspaces: [Workspace(name: "Custom Work")])])
    state.roleDescription = "My draft"
    let before = state.draft
    let store = TestStore(initialState: state) { OnboardingFeature() } withDependencies: {
      $0.onboardingProgress.save = { _ in }
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.resetButtonTapped)
    expectNoDifference(store.state.draft, before)
    await store.send(.confirmationSuppressionChanged(true))
    if confirmed {
      await store.send(.alert(.presented(.confirmReset)))
    } else {
      await store.send(.alert(.dismiss))
    }
    await store.finish()
    #expect(store.state.roleDescription == (confirmed ? "" : "My draft"))
    #expect(store.state.config.settings.confirmations[.resetSetup] == !confirmed)
    #expect(store.state.config.settings.confirmations[.applySetup])
  }
}
