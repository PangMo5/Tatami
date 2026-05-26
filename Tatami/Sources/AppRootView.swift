import ComposableArchitecture
import SwiftUI
import TatamiKit

struct AppRootView: View {
  let store: StoreOf<AppFeature>

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "square.stack.3d.up.fill")
        .font(.system(size: 64))
        .foregroundStyle(.tint)

      Text("Tatami")
        .font(.largeTitle)
        .fontWeight(.semibold)

      Text("Workspace manager with yabai-style tiling")
        .foregroundStyle(.secondary)

      Text("Status: skeleton — features coming")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .padding(40)
    .frame(minWidth: 520, minHeight: 360)
  }
}

#Preview {
  AppRootView(
    store: Store(initialState: AppFeature.State()) {
      AppFeature()
    }
  )
}
