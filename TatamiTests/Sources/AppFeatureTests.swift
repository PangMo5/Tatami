import ComposableArchitecture
import Testing
@testable import TatamiKit

@MainActor
struct AppFeatureTests {
  @Test
  func onAppearDoesNothingYet() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }

    await store.send(.onAppear)
  }
}
