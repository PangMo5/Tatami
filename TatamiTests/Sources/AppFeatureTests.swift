import ComposableArchitecture
import Foundation
import Testing
@testable import TatamiKit

@MainActor
struct WorkspaceListFeatureTests {
  @Test
  func addingWorkspaceAppendsToActiveProfile() async throws {
    let store = TestStore(initialState: WorkspaceListFeature.State()) {
      WorkspaceListFeature()
    }
    store.exhaustivity = .off

    await store.send(.addWorkspaceButtonTapped) {
      $0.isAddSheetPresented = true
    }
    await store.send(.binding(.set(\.draftName, "Focus")))
    await store.send(.addWorkspaceFormSubmitted) {
      $0.isAddSheetPresented = false
      $0.draftName = ""
    }

    #expect(store.state.workspaces.contains(where: { $0.name == "Focus" }))
  }
}

@MainActor
struct GestureRoutingTests {
  @Test
  func configuredGestureRoutesThroughTheSharedTatamiCommandPath() async {
    let state = AppFeature.State()
    state.$config.withLock {
      $0.settings.gestures = AppSettings.Gestures(
        enabled: true,
        fourFinger: .init(up: .toggleFullscreen)
      )
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.gesturePerformed(.init(fingerCount: 4, direction: .up)))
    await store.receive {
      guard case .activation(.bspToggleZoomFullscreen) = $0 else { return false }
      return true
    }
  }

}

@MainActor
@Suite(.serialized)
struct WindowCycleShortcutRoutingTests {
  @Test
  func hotKeyPreservesItsHoldModifierForTheCycleSession() async throws {
    let state = AppFeature.State()
    state.$config.withLock {
      $0.settings.shortcuts.cycleNextWindow = HotKey(parsing: "alt - tab")
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.hotKeys(.actionTriggered(.cycleNextWindow)))
    await store.receive {
      guard case .activation(.cycleWindowShortcut(.next, let modifiers)) = $0 else {
        return false
      }
      return modifiers == .option
    }
  }

  @Test
  func workspaceGestureSwitchesToTheOwningProfile() async {
    let currentWorkspace = Workspace(name: "Current")
    let targetWorkspace = Workspace(name: "Target")
    let currentProfile = Profile(name: "Default", workspaces: [currentWorkspace])
    let targetProfile = Profile(name: "Dual", workspaces: [targetWorkspace])
    let state = AppFeature.State()
    state.$config.withLock {
      $0.profiles = [currentProfile, targetProfile]
      $0.activeProfileId = currentProfile.id
      $0.settings.gestures = AppSettings.Gestures(
        enabled: true,
        fourFinger: .init(up: .activateWorkspace(targetWorkspace.id))
      )
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.gesturePerformed(.init(fingerCount: 4, direction: .up)))
    await store.receive {
      guard case .activateProfile(let id, let focus) = $0 else { return false }
      return id == targetProfile.id && focus == targetWorkspace.id
    }
    #expect(store.state.config.activeProfileId == targetProfile.id)
  }
}
