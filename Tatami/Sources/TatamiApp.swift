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

  @State private var windowActivation = WindowActivationCoordinator()

  var body: some Scene {
    Window("Tatami", id: "main") {
      AppRootView(store: appStore)
        .regularWhileOpen(id: "main", coordinator: windowActivation)
    }
    .windowResizability(.contentSize)
    .commands {
      // Standard ⌘, opens the main Tatami window (the Workspaces / Settings /
      // About tab view).
      CommandGroup(replacing: .appSettings) {
        OpenSettingsButton()
      }
    }

    Window("Guided Setup", id: "onboarding") {
      OnboardingView(
        store: appStore.scope(state: \.onboarding, action: \.onboarding)
      )
      .regularWhileOpen(id: "onboarding", coordinator: windowActivation)
    }
    .defaultSize(width: 1040, height: 720)
    .windowResizability(.contentMinSize)

    MenuBarExtra {
      MenuBarContentView(store: appStore)
    } label: {
      MenuBarLabel(store: appStore)
    }
    .menuBarExtraStyle(.menu)
  }
}

@MainActor
private final class WindowActivationCoordinator {
  private var visibleWindowIDs = Set<String>()

  func appeared(_ id: String) {
    visibleWindowIDs.insert(id)
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  func disappeared(_ id: String) {
    visibleWindowIDs.remove(id)
    if visibleWindowIDs.isEmpty {
      NSApp.setActivationPolicy(.accessory)
    }
  }
}

private struct RegularWhileOpen: ViewModifier {
  let id: String
  let coordinator: WindowActivationCoordinator

  func body(content: Content) -> some View {
    content
      .onAppear { coordinator.appeared(id) }
      .onDisappear { coordinator.disappeared(id) }
  }
}

extension View {
  fileprivate func regularWhileOpen(
    id: String,
    coordinator: WindowActivationCoordinator
  ) -> some View {
    modifier(RegularWhileOpen(id: id, coordinator: coordinator))
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
