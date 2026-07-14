import ComposableArchitecture
import SwiftUI
import TatamiKit

struct WorkspaceListView: View {
  @Bindable var store: StoreOf<WorkspaceListFeature>
  let activationStore: StoreOf<WorkspaceActivationFeature>

  /// Where the in-flight drag would land: a row + which edge (below when
  /// `after`). Drives the insertion line the row overlays draw. Set/cleared by
  /// each row's two `.dropDestination` half-zones via `isTargeted`, which
  /// SwiftUI toggles reliably on enter/exit/drop/cancel (the reason this beats
  /// a hand-cleared `DropDelegate`).
  struct DropIndicator: Equatable {
    let workspaceID: Workspace.ID
    let after: Bool
  }

  @State private var dropIndicator: DropIndicator?

  var body: some View {
    NavigationSplitView {
      List(selection: $store.selection.sending(\.sidebarSelected)) {
        profilesSection
        Section("Workspaces") {
          // `id: \.sidebarItem` (not Workspace's own ID): macOS only wires
          // the selection gesture when the ForEach id type matches the
          // List's selection type.
          ForEach(store.normalWorkspaces, id: \.sidebarItem) { workspace in
            draggableRow(workspace)
          }
          .onDelete { offsets in
            for offset in offsets {
              store.send(.workspaceDeleteRequested(store.normalWorkspaces[offset].id))
            }
          }
        }
        // Scratchpads are borrow-only — never activated on their own — so they
        // get their own section (mirrors the menu bar). Always shown so a row
        // can be dragged in to convert it, even when currently empty.
        Section("Scratchpads") {
          ForEach(store.scratchpadWorkspaces, id: \.sidebarItem) { workspace in
            draggableRow(workspace)
          }
          .onDelete { offsets in
            for offset in offsets {
              store.send(.workspaceDeleteRequested(store.scratchpadWorkspaces[offset].id))
            }
          }
          // Empty ForEach exposes no drop target, so give the section one to
          // land the first scratchpad (appended → no target row).
          if store.scratchpadWorkspaces.isEmpty {
            Label("Drag a workspace here", systemImage: "tray")
              .font(.callout)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
              .dropDestination(for: String.self) { ids, _ in
                dropWorkspace(ids, kind: .scratchpad, relativeTo: nil, after: false)
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
      } else if let profileStore = store.scope(state: \.profileDetail, action: \.profileDetail) {
        ProfileDetailView(store: profileStore)
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
    .alert($store.scope(state: \.alert, action: \.alert))
  }

  /// The "Profiles" sidebar section: one row per profile (click switches;
  /// right-click duplicates / renames / deletes that specific profile) plus a
  /// "New Profile" row. Rows are plain buttons (not List-selectable) so picking
  /// a profile never collides with workspace-row selection.
  @ViewBuilder
  private var profilesSection: some View {
    let activeId = store.config.activeProfileId ?? store.config.profiles.first?.id
    Section("Profiles") {
      // Selectable rows (like workspaces): click opens the profile's detail
      // settings; the green dot marks the *active* (running) profile — distinct
      // from the selected one. Switching is the Activate button in the detail.
      // `id: \.sidebarItem` (matching the List's selection type) is what wires
      // the selection gesture — Profile's own UUID id wouldn't.
      ForEach(store.config.profiles, id: \.sidebarItem) { profile in
        HStack {
          Label(profile.name, systemImage: profile.symbolIconName ?? "rectangle.stack")
          Spacer()
          if store.config.autoActivationDiagnostic(for: profile.id).hasConflict {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
              .imageScale(.small)
              .help("Auto-activation overlaps another profile at the same priority — order decides which one activates.")
          }
          if profile.id == activeId {
            Image(systemName: "circle.fill")
              .foregroundStyle(.green)
              .imageScale(.small)
              .help("Active profile")
          }
        }
        .tag(WorkspaceListFeature.SidebarItem.profile(profile.id) as WorkspaceListFeature.SidebarItem?)
        .contextMenu {
          Button("Duplicate") { store.send(.duplicateProfileTapped(profile.id)) }
          if store.config.profiles.count > 1 {
            Divider()
            Button("Delete", role: .destructive) {
              store.send(.deleteProfileRequested(profile.id))
            }
          }
        }
      }
      .onMove { source, destination in
        store.send(.profilesReordered(source, destination))
      }
      Button {
        store.send(.newProfileButtonTapped)
      } label: {
        Label("New Profile", systemImage: "plus")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func row(for workspace: Workspace) -> some View {
    HStack(spacing: 6) {
      Label(workspace.name, systemImage: workspace.symbolIconName ?? "square.stack.3d.up")
      Spacer()
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

  /// `row(for:)` wrapped as a drag source + drop target. One mechanism serves
  /// both intra-section reorder and cross-section retyping: the row carries
  /// its id, and two stacked half-height drop zones split it into an
  /// above/below target so the insertion line follows the cursor and the drop
  /// lands there (`workspace.kind` picks the destination section).
  @ViewBuilder
  private func draggableRow(_ workspace: Workspace) -> some View {
    row(for: workspace)
      .draggable(workspace.id.uuidString) {
        dragPreview(for: workspace)
      }
      .overlay {
        VStack(spacing: 0) {
          dropZone(workspace, after: false)
          dropZone(workspace, after: true)
        }
      }
      .overlay(alignment: .top) {
        insertionLine(visible: dropIndicator == DropIndicator(workspaceID: workspace.id, after: false))
      }
      .overlay(alignment: .bottom) {
        insertionLine(visible: dropIndicator == DropIndicator(workspaceID: workspace.id, after: true))
      }
  }

  /// Half of a row's drop area. `isTargeted` toggles the insertion line for
  /// this edge; SwiftUI drives it, so the line never strands.
  private func dropZone(_ workspace: Workspace, after: Bool) -> some View {
    Color.clear
      .contentShape(Rectangle())
      .dropDestination(for: String.self) { ids, _ in
        dropWorkspace(ids, kind: workspace.kind, relativeTo: workspace.id, after: after)
      } isTargeted: { targeted in
        let marker = DropIndicator(workspaceID: workspace.id, after: after)
        if targeted {
          dropIndicator = marker
        } else if dropIndicator == marker {
          dropIndicator = nil
        }
      }
  }

  @ViewBuilder
  private func insertionLine(visible: Bool) -> some View {
    if visible {
      Capsule()
        .fill(.tint)
        .frame(height: 2)
        .padding(.horizontal, 4)
        .allowsHitTesting(false)
    }
  }

  /// What the cursor carries mid-drag: icon + name on an opaque pill so it
  /// reads against any backdrop.
  private func dragPreview(for workspace: Workspace) -> some View {
    Label(workspace.name, systemImage: workspace.symbolIconName ?? "square.stack.3d.up")
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
  }

  /// Resolve a dropped workspace id and place it relative to a target row
  /// (nil target → append to the kind's subset).
  private func dropWorkspace(
    _ ids: [String],
    kind: WorkspaceKind,
    relativeTo targetId: Workspace.ID?,
    after: Bool
  ) -> Bool {
    guard let first = ids.first, let draggedId = UUID(uuidString: first) else { return false }
    dropIndicator = nil
    store.send(.workspaceDropped(draggedId: draggedId, kind: kind, relativeTo: targetId, after: after))
    return true
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

private extension Profile {
  /// Sidebar row identity for the profile rows — same reason as `Workspace`.
  var sidebarItem: WorkspaceListFeature.SidebarItem { .profile(id) }
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

