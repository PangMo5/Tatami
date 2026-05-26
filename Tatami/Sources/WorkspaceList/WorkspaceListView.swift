import ComposableArchitecture
import SwiftUI
import TatamiKit

struct WorkspaceListView: View {
  @Bindable var store: StoreOf<WorkspaceListFeature>

  var body: some View {
    NavigationSplitView {
      List(selection: $store.selectedWorkspaceID.sending(\.workspaceSelected)) {
        Section("Workspaces") {
          ForEach(store.workspaces) { workspace in
            Label(workspace.name, systemImage: workspace.symbolIconName ?? "square.stack.3d.up")
              .tag(workspace.id as Workspace.ID?)
              .contextMenu {
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
        }
      }
    } detail: {
      if let id = store.selectedWorkspaceID,
         let workspace = store.workspaces.first(where: { $0.id == id })
      {
        WorkspaceDetailPlaceholder(workspace: workspace)
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
}

private struct AddWorkspaceForm: View {
  @Bindable var store: StoreOf<WorkspaceListFeature>
  @FocusState private var nameFieldFocused: Bool

  var body: some View {
    Form {
      TextField("Name", text: $store.draftName)
        .focused($nameFieldFocused)
        .onSubmit { store.send(.addWorkspaceFormSubmitted) }
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

private struct WorkspaceDetailPlaceholder: View {
  let workspace: Workspace

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: workspace.symbolIconName ?? "square.stack.3d.up")
        .font(.system(size: 48))
        .foregroundStyle(.tint)
      Text(workspace.name).font(.title2)
      Text(workspace.id.uuidString)
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
    .padding()
  }
}
