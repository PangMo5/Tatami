import ComposableArchitecture
import SwiftUI
import TatamiKit

struct WorkspaceListView: View {
  @Bindable var store: StoreOf<WorkspaceListFeature>
  let activationStore: StoreOf<WorkspaceActivationFeature>

  var body: some View {
    NavigationSplitView {
      List(selection: $store.selectedWorkspaceID.sending(\.workspaceSelected)) {
        Section("Workspaces") {
          ForEach(store.workspaces) { workspace in
            row(for: workspace)
              .tag(workspace.id as Workspace.ID?)
              .contextMenu {
                Button("Activate") {
                  activationStore.send(.activate(workspaceId: workspace.id, setFocus: true))
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
    HStack {
      Label(workspace.name, systemImage: workspace.symbolIconName ?? "square.stack.3d.up")
      Spacer()
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
