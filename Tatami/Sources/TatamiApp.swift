import ComposableArchitecture
import SwiftUI
import TatamiKit

@main
struct TatamiApp: App {
  init() {
    try? ConfigLocation.ensureDirectoryExists()
  }

  @State private var appStore = Store(initialState: AppFeature.State()) {
    AppFeature()
  }

  var body: some Scene {
    Window("Tatami", id: "main") {
      AppRootView(store: appStore)
    }
    .windowResizability(.contentSize)

    MenuBarExtra {
      MenuBarContentView(store: appStore)
    } label: {
      MenuBarLabel(store: appStore)
    }
    .menuBarExtraStyle(.menu)
  }
}
