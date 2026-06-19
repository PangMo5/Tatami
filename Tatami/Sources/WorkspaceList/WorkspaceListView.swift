import ComposableArchitecture
import SwiftUI
import TatamiKit

struct WorkspaceListView: View {
  @Bindable var store: StoreOf<WorkspaceListFeature>
  let activationStore: StoreOf<WorkspaceActivationFeature>

  var body: some View {
    NavigationSplitView {
      List(selection: $store.selection.sending(\.sidebarSelected)) {
        Section("Workspaces") {
          // `id: \.sidebarItem` (not Workspace's own ID): macOS only wires
          // the selection gesture when the ForEach id type matches the
          // List's selection type.
          ForEach(store.workspaces, id: \.sidebarItem) { workspace in
            row(for: workspace)
              .tag(workspace.sidebarItem as WorkspaceListFeature.SidebarItem?)
              .contextMenu {
                if workspace.kind == .scratchpad {
                  Button("Borrow Here") {
                    activationStore.send(.borrow(workspaceId: workspace.id, edge: .right))
                  }
                } else {
                  Button("Activate") {
                    activationStore.send(.activate(workspaceId: workspace.id, setFocus: true))
                  }
                  Button("Borrow Here") {
                    activationStore.send(.borrow(workspaceId: workspace.id, edge: .right))
                  }
                }
                Divider()
                Button("Delete", role: .destructive) {
                  store.send(.workspaceDeleteRequested(workspace.id))
                }
              }
          }
          .onDelete { offsets in
            for offset in offsets {
              store.send(.workspaceDeleteRequested(store.workspaces[offset].id))
            }
          }
        }
        // The Shared pseudo-workspace: its apps live in every workspace.
        // Wrapped in a ForEach because macOS `List(selection:)` only makes
        // ForEach-generated rows selectable — a static row never gets the
        // selection gesture.
        Section("Everywhere") {
          ForEach([WorkspaceListFeature.SidebarItem.shared], id: \.self) { item in
            Label("Shared Apps", systemImage: "square.on.square")
              .tag(item as WorkspaceListFeature.SidebarItem?)
          }
        }
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 220, ideal: 240)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            store.send(.addWorkspaceButtonTapped)
          } label: {
            Label("Add Workspace", systemImage: "plus")
          }
          .keyboardShortcut("n", modifiers: .command)
          .help("Add a workspace (⌘N)")
        }
      }
    } detail: {
      if let detailStore = store.scope(state: \.detail, action: \.detail) {
        WorkspaceDetailView(store: detailStore, activationStore: activationStore)
      } else if let sharedStore = store.scope(state: \.shared, action: \.shared) {
        SharedAppsView(store: sharedStore)
      } else {
        ContentUnavailableView(
          "No Workspace Selected",
          systemImage: "square.stack.3d.up",
          description: Text("Pick a workspace from the sidebar, or add one with ⌘N.")
        )
      }
    }
    .sheet(isPresented: $store.isAddSheetPresented) {
      AddWorkspaceForm(store: store)
    }
  }

  @ViewBuilder
  private func row(for workspace: Workspace) -> some View {
    HStack(spacing: 6) {
      Label(workspace.name, systemImage: workspace.symbolIconName ?? "square.stack.3d.up")
      Spacer()
      if workspace.kind == .scratchpad {
        Image(systemName: "tray.full")
          .foregroundStyle(.secondary)
          .imageScale(.small)
          .help("Scratchpad — borrow-only, never activated on its own")
      }
      if let host = borrowedHostName(for: workspace) {
        Image(systemName: "rectangle.righthalf.inset.filled")
          .foregroundStyle(.tint)
          .imageScale(.small)
          .help("Borrowed into \(host)")
      }
      if let display = activeDisplay(for: workspace) {
        Image(systemName: "circle.fill")
          .foregroundStyle(dotColor(for: display))
          .imageScale(.small)
          .help("Active on \(display.name)")
      }
    }
  }

  /// The display this workspace is currently active on, if any.
  private func activeDisplay(for workspace: Workspace) -> DisplayName? {
    activationStore.activeWorkspacesByDisplay.first { $0.value == workspace.id }?.key
  }

  /// The host workspace's name when `workspace` is currently borrowed into a
  /// live composition, else nil.
  private func borrowedHostName(for workspace: Workspace) -> String? {
    for (_, comp) in activationStore.compositionsByDisplay
    where comp.borrowed.contains(where: { $0.workspace == workspace.id }) {
      return activationStore.config.activeProfile?.workspaces[id: comp.host]?.name
        ?? "another workspace"
    }
    return nil
  }

  /// A distinct dot color per active display (so each monitor's active
  /// workspace is visually distinguishable); plain green with one display.
  private func dotColor(for display: DisplayName) -> Color {
    let displays = activationStore.activeWorkspacesByDisplay.keys
      .sorted { $0.name < $1.name }
    guard displays.count > 1, let index = displays.firstIndex(of: display) else { return .green }
    let palette: [Color] = [.green, .blue, .orange, .purple, .pink, .teal]
    return palette[index % palette.count]
  }
}

private extension Workspace {
  /// Sidebar row identity — must be the List's selection type for macOS to
  /// make the row selectable (see the ForEach above).
  var sidebarItem: WorkspaceListFeature.SidebarItem { .workspace(id) }
}

private struct AddWorkspaceForm: View {
  @Bindable var store: StoreOf<WorkspaceListFeature>
  @FocusState private var nameFieldFocused: Bool

  var body: some View {
    Form {
      Section {
        TextField("Name", text: $store.draftName)
          .focused($nameFieldFocused)
          .onSubmit { store.send(.addWorkspaceFormSubmitted) }
      } footer: {
        Text("Starts pinned to the display you're on. Change this anytime in the workspace's Display section.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 360)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { store.send(.addWorkspaceFormCancelled) }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Add") { store.send(.addWorkspaceFormSubmitted) }
          .disabled(store.draftName.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding()
    .onAppear { nameFieldFocused = true }
  }
}
