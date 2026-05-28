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
  @Dependency(\.updater) private var updater
  @State private var canCheckForUpdates = false

  var body: some View {
    let config = store.workspaceList.config
    let activeId = store.activation.primaryActiveWorkspaceID

    if let workspaces = config.activeProfile?.workspaces, !workspaces.isEmpty {
      Section("Workspaces") {
        ForEach(workspaces) { workspace in
          Button {
            store.send(.activation(.activate(workspaceId: workspace.id, setFocus: true)))
          } label: {
            Label(
              workspace.name,
              systemImage: workspace.id == activeId
                ? "checkmark.circle.fill"
                : (workspace.symbolIconName ?? "square.dashed")
            )
          }
        }
      }
      Divider()
    }

    Button(config.settings.general.isPaused ? "Resume Tiling" : "Pause Tiling") {
      store.send(.activation(.togglePaused))
    }

    Divider()

    Button("Open Tatami") {
      openWindow(id: "main")
      NSApp.activate(ignoringOtherApps: true)
    }

    Button("Check for Updates…") {
      updater.checkForUpdates()
    }
    .disabled(!canCheckForUpdates)
    .task {
      for await value in updater.canCheckForUpdates() {
        canCheckForUpdates = value
      }
    }

    Divider()

    Button("Quit") {
      NSApp.terminate(nil)
    }
    .keyboardShortcut("q")
  }
}
