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
        // LSUIElement launches the app as an accessory (no Dock icon), whose
        // windows can't take normal front-most focus — the GUI window would
        // sink behind everything. Promote to a regular app while the window is
        // open so it activates + orders to the front like a normal app, and
        // drop back to accessory (menu-bar-only, no Dock icon) when it closes.
        .onAppear {
          NSApp.setActivationPolicy(.regular)
          NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear {
          NSApp.setActivationPolicy(.accessory)
        }
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
