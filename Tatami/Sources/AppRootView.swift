import ComposableArchitecture
import SwiftUI
import TatamiKit

struct AppRootView: View {
  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    TabView(selection: Binding(
      get: { store.selectedTab },
      set: { store.send(.tabSelected($0)) }
    )) {
      WorkspaceListView(
        store: store.scope(state: \.workspaceList, action: \.workspaceList),
        activationStore: store.scope(state: \.activation, action: \.activation)
      )
      .tabItem { Label("Workspaces", systemImage: "rectangle.3.group") }
      .tag(AppTab.workspaces)

      SettingsView(
        pendingSection: store.pendingSettingsSection,
        onSectionConsumed: { store.send(.settingsSectionConsumed) }
      )
      .tabItem { Label("Settings", systemImage: "gearshape") }
      .tag(AppTab.settings)

      AboutView()
        .tabItem { Label("About", systemImage: "info.circle") }
        .tag(AppTab.about)
    }
    .task { store.send(.task) }
  }
}
