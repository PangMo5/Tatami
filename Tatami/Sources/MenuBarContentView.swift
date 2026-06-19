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
    let workspace = activeId.flatMap { config.activeProfile?.workspaces[id: $0] }
    // macOS renders a Label as icon-only in the menu bar, so compose the
    // icon and name explicitly to make the title show.
    HStack(spacing: 4) {
      // Persistent problem indicator — clears when the failure resolves
      // (e.g. the config edit that fixes the parse) or is dismissed.
      if !store.errorReports.isEmpty {
        Image(systemName: "exclamationmark.triangle.fill")
      }
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

    if !store.errorReports.isEmpty {
      Section("Problems") {
        ForEach(store.errorReports) { report in
          // Clicking a problem opens config.toml's folder — every report
          // domain so far is fixed by editing files that live there.
          Button {
            NSWorkspace.shared.activateFileViewerSelecting([ConfigLocation.fileURL])
          } label: {
            Label(report.message, systemImage: "exclamationmark.triangle.fill")
          }
        }
        Button("Dismiss") {
          store.send(.errorReportsDismissed)
        }
      }
      Divider()
    }

    if let workspaces = config.activeProfile?.workspaces, !workspaces.isEmpty {
      let regular = workspaces.filter { $0.kind != .scratchpad }
      let scratchpads = workspaces.filter { $0.kind == .scratchpad }
      // Switchable workspaces: a Toggle renders the native trailing checkmark
      // on the active one. We swallow the off-write so re-clicking the active
      // workspace just re-activates it (matching the toolbar Activate button).
      if !regular.isEmpty {
        Section("Workspaces") {
          ForEach(regular) { workspace in
            Toggle(isOn: Binding(
              get: { workspace.id == activeId },
              set: { newValue in
                guard newValue else { return }
                store.send(.activation(.activate(workspaceId: workspace.id, setFocus: true)))
              }
            )) {
              Label(workspace.name, systemImage: workspace.symbolIconName ?? "square.dashed")
            }
          }
        }
      }
      // Scratchpads are borrow-only — they never become "active", so a plain
      // button (clicking borrows onto the focused display) reads truer than a
      // Toggle, and the dedicated section header is what marks them.
      if !scratchpads.isEmpty {
        Section("Scratchpads") {
          ForEach(scratchpads) { workspace in
            Button {
              store.send(.activation(.activate(workspaceId: workspace.id, setFocus: true)))
            } label: {
              Label(workspace.name, systemImage: workspace.symbolIconName ?? "tray.full")
            }
          }
        }
      }
      Divider()
    }

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

    Divider()

    Button("Quit") {
      NSApp.terminate(nil)
    }
    .keyboardShortcut("q")
  }
}
