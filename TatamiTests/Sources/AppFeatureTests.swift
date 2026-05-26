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
