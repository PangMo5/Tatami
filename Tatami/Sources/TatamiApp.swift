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
    .commands {
      // Standard ⌘, opens the main Tatami window (the Workspaces / Settings /
      // About tab view).
      CommandGroup(replacing: .appSettings) {
        OpenSettingsButton()
      }
    }

    MenuBarExtra {
      MenuBarContentView(store: appStore)
    } label: {
      MenuBarLabel(store: appStore)
    }
    .menuBarExtraStyle(.menu)
  }
}

/// Opens the main window. A dedicated view so it can read the `openWindow`
/// environment action from inside `.commands`.
private struct OpenSettingsButton: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("Settings…") {
      openWindow(id: "main")
      NSApp.activate(ignoringOtherApps: true)
    }
    .keyboardShortcut(",", modifiers: .command)
  }
}
