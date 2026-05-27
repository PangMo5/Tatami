import ComposableArchitecture
import SwiftUI
import TatamiKit

struct MenuBarContentView: View {
  @Bindable var store: StoreOf<AppFeature>
  @Environment(\.openWindow) private var openWindow

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

    Button(config.settings.isPaused ? "Resume Tiling" : "Pause Tiling") {
      store.send(.activation(.togglePaused))
    }

    Divider()

    Button("Open Tatami") {
      openWindow(id: "main")
      NSApp.activate(ignoringOtherApps: true)
    }

    Divider()

    Button("Quit") {
      NSApp.terminate(nil)
    }
    .keyboardShortcut("q")
  }
}
