import ComposableArchitecture
import SwiftUI
import TatamiKit

struct AppRootView: View {
  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    TabView {
      WorkspaceListView(
        store: store.scope(state: \.workspaceList, action: \.workspaceList),
        activationStore: store.scope(state: \.activation, action: \.activation)
      )
      .tabItem { Label("Workspaces", systemImage: "rectangle.3.group") }

      SettingsView()
        .tabItem { Label("Settings", systemImage: "gearshape") }
    }
    .task { store.send(.task) }
  }
}
