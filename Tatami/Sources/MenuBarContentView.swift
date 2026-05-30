import ComposableArchitecture
import SwiftUI
import TatamiKit

/// Menu bar status item label: shows the active workspace's name + icon
/// so the bar reflects where you are, not just a static app glyph.
struct MenuBarLabel: View {
  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    let config = store.workspaceList.config
    let activeId = store.activation.primaryActiveWorkspaceID
    let workspace = config.activeProfile?.workspaces.first { $0.id == activeId }
    // macOS renders a Label as icon-only in the menu bar, so compose the
    // icon and name explicitly to make the title show.
    HStack(spacing: 4) {
      Image(systemName: workspace?.symbolIconName ?? "square.stack.3d.up.fill")
      if config.settings.menuBar.showWorkspaceName, let name = workspace?.name {
        Text(name)
      }
    }
  }
}

struct MenuBarContentView: View {
  @Bindable var store: StoreOf<AppFeature>
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    let config = store.workspaceList.config
    let activeId = store.activation.primaryActiveWorkspaceID

    if let workspaces = config.activeProfile?.workspaces, !workspaces.isEmpty {
      Section("Workspaces") {
        ForEach(workspaces) { workspace in
          // Toggle inside a menu renders as a labeled item with a
          // trailing checkmark when the binding is `true` — the
          // macOS-native "active" indicator. We swallow the off-write
          // so re-clicking the active workspace just re-activates it
          // (matching the toolbar Activate button's behavior).
          Toggle(isOn: Binding(
            get: { workspace.id == activeId },
            set: { newValue in
              guard newValue else { return }
              store.send(.activation(.activate(workspaceId: workspace.id, setFocus: true)))
            }
          )) {
            Label(
              workspace.name,
              systemImage: workspace.symbolIconName ?? "square.dashed"
            )
          }
        }
      }
      Divider()
    }

    Button(store.activation.isTilingPaused ? "Resume Tiling" : "Pause Tiling") {
      store.send(.activation(.togglePaused))
    }

    Divider()

    // Opens the main window (the Workspaces / Settings / About tab view).
    // ⌘, is also wired globally via the app's commands.
    Button("Settings") {
      openWindow(id: "main")
      NSApp.activate(ignoringOtherApps: true)
    }
    .keyboardShortcut(",", modifiers: .command)

    Button("Check for Updates…") {
      store.send(.checkForUpdatesTapped)
    }
    .disabled(!store.canCheckForUpdates)

    Divider()

    Button("Quit") {
      NSApp.terminate(nil)
    }
    .keyboardShortcut("q")
  }
}
