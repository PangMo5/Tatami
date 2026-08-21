// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

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
      profilesColumn
    } content: {
      contentColumn
    } detail: {
      detailColumn
    }
    .sheet(isPresented: $store.isAddSheetPresented) {
      AddWorkspaceForm(store: store)
    }
    .alert($store.scope(state: \.alert, action: \.alert))
    .task { store.send(.sidebarAppeared) }
  }

  // MARK: - Column 1: Profiles

  /// The profile whose contents col 2 lists. Its green dot in col 1 marks the
  /// *active* (running) profile, which need not be the selected one.
  private var activeProfileId: Profile.ID? {
    store.config.activeProfileId ?? store.config.profiles.first?.id
  }

  @ViewBuilder
  private var profilesColumn: some View {
    List(selection: $store.topSelection.sending(\.topSelected)) {
      Section("Profiles") {
        // `id: \.sidebarTop` (not Profile's own id): macOS only wires the
        // selection gesture when the ForEach id type matches the List's
        // selection type (SidebarTop) — as the shared row below does.
        ForEach(store.config.profiles, id: \.sidebarTop) { profile in
          profileRow(profile)
            .tag(profile.sidebarTop as WorkspaceListFeature.SidebarTop?)
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
      // Shared apps join every workspace of every profile — profile-independent,
      // so they live here in the sidebar rather than under any one profile.
      Section("Everywhere") {
        ForEach([WorkspaceListFeature.SidebarTop.shared], id: \.self) { item in
          Label("Shared Apps", systemImage: "square.on.square")
            .tag(item as WorkspaceListFeature.SidebarTop?)
        }
      }
    }
    .listStyle(.sidebar)
    .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
    .navigationTitle("Tatami")
  }

  /// A profile row: icon + name, an overlap-conflict badge, and a green dot on
  /// the *active* profile (distinct from the selected/highlighted one).
  @ViewBuilder
  private func profileRow(_ profile: Profile) -> some View {
    HStack {
      Label(profile.name, systemImage: profile.symbolIconName ?? "rectangle.stack")
      Spacer()
      if store.config.autoActivationDiagnostic(for: profile.id).hasConflict {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .imageScale(.small)
          .help("Auto-activation overlaps another profile at the same priority — order decides which one activates.")
      }
      if profile.id == activeProfileId {
        Image(systemName: "circle.fill")
          .foregroundStyle(.green)
          .imageScale(.small)
          .help("Active profile")
      }
    }
  }

  // MARK: - Column 2: the selected profile's contents

  @ViewBuilder
  private var contentColumn: some View {
    if store.isViewingShared {
      // Shared Apps is a global editor shown in the detail column; col 2 has
      // nothing profile-scoped to list.
      ContentUnavailableView(
        "Shared Apps",
        systemImage: "square.on.square",
        description: Text("These apps join every workspace in every profile. Edit them in the detail pane.")
      )
      .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
      .navigationTitle("Everywhere")
    } else {
      profileContentList
    }
  }

  @ViewBuilder
  private var profileContentList: some View {
    List(selection: $store.selection.sending(\.sidebarSelected)) {
      // The profile's own settings (name, icon, auto-activation, copy) — the
      // reason a non-active profile can be inspected without switching to it.
      // Wrapped in a ForEach because macOS `List(selection:)` only makes
      // ForEach-generated rows selectable.
      Section {
        ForEach([WorkspaceListFeature.SidebarItem.profileSettings], id: \.self) { item in
          Label("Profile Settings", systemImage: "slider.horizontal.3")
            .tag(item as WorkspaceListFeature.SidebarItem?)
        }
      }
      Section("Workspaces") {
        // `id: \.sidebarItem` (not Workspace's own ID): macOS only wires the
        // selection gesture when the ForEach id type matches the List's
        // selection type.
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
      // get their own section (mirrors the menu bar). Always shown so a row can
      // be dragged in to convert it, even when currently empty.
      Section("Scratchpads") {
        ForEach(store.scratchpadWorkspaces, id: \.sidebarItem) { workspace in
          draggableRow(workspace)
        }
        .onDelete { offsets in
          for offset in offsets {
            store.send(.workspaceDeleteRequested(store.scratchpadWorkspaces[offset].id))
          }
        }
        // Empty ForEach exposes no drop target, so give the section one to land
        // the first scratchpad (appended → no target row).
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
    }
    .listStyle(.sidebar)
    .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
    .navigationTitle(store.selectedProfile?.name ?? "Workspaces")
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
  }

  // MARK: - Column 3: detail

  @ViewBuilder
  private var detailColumn: some View {
    if let detailStore = store.scope(state: \.detail, action: \.detail) {
      WorkspaceDetailView(store: detailStore, activationStore: activationStore)
    } else if let sharedStore = store.scope(state: \.shared, action: \.shared) {
      SharedAppsView(store: sharedStore)
    } else if let profileStore = store.scope(state: \.profileDetail, action: \.profileDetail) {
      ProfileDetailView(store: profileStore)
    } else {
      ContentUnavailableView(
        "Nothing Selected",
        systemImage: "square.stack.3d.up",
        description: Text("Pick a profile's settings or a workspace from the sidebar, or add one with ⌘N.")
      )
    }
  }

  // MARK: - Workspace rows

  /// Whether col 2 is showing the *active* profile — gates the Activate / Borrow
  /// row actions, which only make sense for workspaces of the running profile.
  private var isViewingActiveProfile: Bool {
    store.selectedProfileResolvedId == activeProfileId
  }

  @ViewBuilder
  private func row(for workspace: Workspace) -> some View {
    HStack(spacing: 6) {
      Label(workspace.name, systemImage: workspace.symbolIconName ?? "square.stack.3d.up")
      Spacer()
      WorkspaceRuntimeStatusView(
        workspaceID: workspace.id,
        activationStore: activationStore,
      )
    }
    .tag(workspace.sidebarItem as WorkspaceListFeature.SidebarItem?)
    .contextMenu {
      // Activation runs on the active profile only; hide it while viewing a
      // different profile so the row can't silently no-op.
      if isViewingActiveProfile {
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
      }
      Button("Delete", role: .destructive) {
        store.send(.workspaceDeleteRequested(workspace.id))
      }
    }
  }

  /// `row(for:)` wrapped as a drag source + drop target. One mechanism serves
  /// both intra-section reorder and cross-section retyping: the row carries its
  /// id, and two stacked half-height drop zones split it into an above/below
  /// target so the insertion line follows the cursor and the drop lands there
  /// (`workspace.kind` picks the destination section).
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

  /// Half of a row's drop area. `isTargeted` toggles the insertion line for this
  /// edge; SwiftUI drives it, so the line never strands.
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

  /// What the cursor carries mid-drag: icon + name on an opaque pill so it reads
  /// against any backdrop.
  private func dragPreview(for workspace: Workspace) -> some View {
    Label(workspace.name, systemImage: workspace.symbolIconName ?? "square.stack.3d.up")
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
  }

  /// Resolve a dropped workspace id and place it relative to a target row (nil
  /// target → append to the kind's subset).
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

}

/// Keeps fast-changing runtime badges in their own observation boundary so a
/// Borrow toggle does not invalidate the entire three-column settings view.
private struct WorkspaceRuntimeStatusView: View {
  let workspaceID: Workspace.ID
  let activationStore: StoreOf<WorkspaceActivationFeature>

  var body: some View {
    let hostName = borrowedHostName
    HStack(spacing: 6) {
      // Keep this slot alive while Borrow appears/disappears. Stable row
      // geometry prevents every following List row from being laid out again.
      Image(systemName: "rectangle.righthalf.inset.filled")
        .foregroundStyle(.tint)
        .imageScale(.small)
        .frame(width: 12)
        .opacity(hostName == nil ? 0 : 1)
        .accessibilityHidden(hostName == nil)
        .help(hostName.map { "Borrowed into \($0)" } ?? "")

      if let display = activeDisplay {
        Image(systemName: "circle.fill")
          .foregroundStyle(dotColor(for: display))
          .imageScale(.small)
          .help("Active on \(display.name)")
      }
    }
  }

  /// The display this workspace is currently active on, if any.
  private var activeDisplay: DisplayName? {
    activationStore.activeWorkspacesByDisplay.first { $0.value == workspaceID }?.key
  }

  /// The host workspace's name when this workspace is currently borrowed into
  /// a live composition, else nil.
  private var borrowedHostName: String? {
    for (_, composition) in activationStore.compositionsByDisplay
    where composition.borrowed.contains(where: { $0.workspace == workspaceID }) {
      return activationStore.config.activeProfile?.workspaces[id: composition.host]?.name
        ?? "another workspace"
    }
    return nil
  }

  /// A distinct dot color per active display (so each monitor's active workspace
  /// is visually distinguishable); plain green with one display.
  private func dotColor(for display: DisplayName) -> Color {
    let displays = activationStore.activeWorkspacesByDisplay.keys
      .sorted { $0.name < $1.name }
    guard displays.count > 1, let index = displays.firstIndex(of: display) else { return .green }
    let palette: [Color] = [.green, .blue, .orange, .purple, .pink, .teal]
    return palette[index % palette.count]
  }
}

private extension Workspace {
  /// Sidebar row identity — must be the List's selection type for macOS to make
  /// the row selectable (see the ForEach above).
  var sidebarItem: WorkspaceListFeature.SidebarItem { .workspace(id) }
}

private extension Profile {
  /// Col 1 row identity — must match the sidebar List's selection type
  /// (SidebarTop) for macOS to wire the row's selection gesture.
  var sidebarTop: WorkspaceListFeature.SidebarTop { .profile(id) }
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
