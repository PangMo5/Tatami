import ComposableArchitecture
import SwiftUI
import TatamiKit

struct AppRootView: View {
  let store: StoreOf<AppFeature>

  var body: some View {
    WorkspaceListView(
      store: store.scope(state: \.workspaceList, action: \.workspaceList)
    )
  }
}
