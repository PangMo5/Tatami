import ComposableArchitecture
import SwiftUI
import TatamiKit

struct AppRootView: View {
  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    WorkspaceListView(
      store: store.scope(state: \.workspaceList, action: \.workspaceList),
      activationStore: store.scope(state: \.activation, action: \.activation)
    )
  }
}
