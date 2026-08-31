// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import SwiftUI
import TatamiKit

// MARK: - WorkspaceListView

struct WorkspaceListView: View {

  // MARK: Internal

  /// Where the in-flight drag would land: a row + which edge (below when
  /// `after`). Drives the insertion line the row overlays draw. Set/cleared by
  /// each row's two `.dropDestination` half-zones via `isTargeted`, which
  /// SwiftUI toggles reliably on enter/exit/drop/cancel (the reason this beats
  /// a hand-cleared `DropDelegate`).
  struct DropIndicator: Equatable {
    let workspaceID: Workspace.ID
    let after: Bool
  }

  @Bindable var store: StoreOf<WorkspaceListFeature>

  let activationStore: StoreOf<WorkspaceActivationFeature>

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
    .sheet(item: $store.duplicationReview) { review in
      DuplicationReviewSheet(review: review) { excluded in
        store.send(.duplicationReviewConfirmed(excluding: excluded))
      }
    }
    .alert($store.scope(state: \.alert, action: \.alert))
    .task { store.send(.sidebarAppeared) }
    .onChange(of: focusedRenameTarget) { oldTarget, newTarget in
      guard
        let oldTarget,
        newTarget != oldTarget,
        store.renameSession?.target == oldTarget
      else { return }
      store.send(.renameSubmitted)
    }
  }

  // MARK: Private

  @State private var dropIndicator: DropIndicator?
  @FocusState private var focusedRenameTarget: WorkspaceListFeature.NameTarget?

  /// The profile whose contents col 2 lists. Its green dot in col 1 marks the
  /// *active* (running) profile, which need not be the selected one.
  private var activeProfileId: Profile.ID? {
    store.config.activeProfileId ?? store.config.profiles.first?.id
  }

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
              RenameButton()
              Button("Duplicate") { store.send(.duplicateProfileTapped(profile.id)) }
              if store.config.profiles.count > 1 {
                Divider()
                Button("Delete", role: .destructive) {
                  store.send(.deleteProfileRequested(profile.id))
                }
              }
            }
            .renameAction {
              store.send(.renameRequested(.profile(profile.id)))
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

  @ViewBuilder
  private var contentColumn: some View {
    if store.isViewingShared {
      // Shared Apps is a global editor shown in the detail column; col 2 has
      // nothing profile-scoped to list.
      ContentUnavailableView(
        "Shared Apps",
        systemImage: "square.on.square",
        description: Text("These apps join every workspace in every profile. Edit them in the detail pane."),
      )
      .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
      .navigationTitle("Everywhere")
    } else {
      profileContentList
    }
  }

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
    .navigationTitle(store.selectedProfile?.name ?? String(localized: "Workspaces"))
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
        description: Text("Pick a profile's settings or a workspace from the sidebar, or add one with ⌘N."),
      )
    }
  }

  /// Whether col 2 is showing the *active* profile — gates the Activate / Borrow
  /// row actions, which only make sense for workspaces of the running profile.
  private var isViewingActiveProfile: Bool {
    store.selectedProfileResolvedId == activeProfileId
  }

  /// A profile row: icon + name, an overlap-conflict badge, and a green dot on
  /// the *active* profile (distinct from the selected/highlighted one).
  private func profileRow(_ profile: Profile) -> some View {
    HStack {
      Label {
        editableName(profile.name, target: .profile(profile.id))
      } icon: {
        Image(systemName: profile.symbolIconName ?? "rectangle.stack")
      }
      Spacer()
      if store.config.autoActivationDiagnostic(for: profile.id).hasConflict {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .imageScale(.small)
          .help("Auto-activation overlaps another profile at the same priority. Order decides which one activates.")
      }
      if profile.id == activeProfileId {
        Image(systemName: "circle.fill")
          .foregroundStyle(.green)
          .imageScale(.small)
          .help("Active profile")
      }
    }
  }

  private func row(for workspace: Workspace) -> some View {
    HStack(spacing: 6) {
      Label {
        editableName(workspace.name, target: .workspace(workspace.id))
      } icon: {
        Image(systemName: workspace.symbolIconName ?? "square.stack.3d.up")
      }
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
      RenameButton()
      Button("Duplicate") {
        store.send(.duplicateWorkspaceTapped(workspace.id))
      }
      Divider()
      Button("Delete", role: .destructive) {
        store.send(.workspaceDeleteRequested(workspace.id))
      }
    }
    .renameAction {
      store.send(.renameRequested(.workspace(workspace.id)))
    }
  }

  @ViewBuilder
  private func editableName(
    _ name: String,
    target: WorkspaceListFeature.NameTarget,
  ) -> some View {
    if store.renameSession?.target == target {
      TextField(
        "Name",
        text: Binding(
          get: { store.renameSession?.draft ?? name },
          set: { store.send(.renameDraftChanged($0)) },
        ),
      )
      .textFieldStyle(.plain)
      .focused($focusedRenameTarget, equals: target)
      .onAppear { focusedRenameTarget = target }
      .onSubmit {
        store.send(.renameSubmitted)
        focusedRenameTarget = nil
      }
      .onExitCommand {
        store.send(.renameCancelled)
        focusedRenameTarget = nil
      }
    } else {
      Text(name)
    }
  }

  /// `row(for:)` wrapped as a drag source + drop target. One mechanism serves
  /// both intra-section reorder and cross-section retyping: the row carries its
  /// id, and two stacked half-height drop zones split it into an above/below
  /// target so the insertion line follows the cursor and the drop lands there
  /// (`workspace.kind` picks the destination section).
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
    after: Bool,
  ) -> Bool {
    guard let first = ids.first, let draggedId = UUID(uuidString: first) else { return false }
    dropIndicator = nil
    store.send(.workspaceDropped(draggedId: draggedId, kind: kind, relativeTo: targetId, after: after))
    return true
  }

}

// MARK: - DuplicationReviewSheet

/// Adapts a reducer-owned duplicate snapshot into the same grouped, toggleable
/// review surface used by Profile/Workspace "Copy from…". Keeping this out of
/// `WorkspaceListView` prevents option construction from widening the sidebar's
/// normal invalidation boundary.
private struct DuplicationReviewSheet: View {
  let review: WorkspaceListFeature.DuplicationReview
  let onConfirm: (Set<String>) -> Void

  var body: some View {
    switch review.source {
    case .profile(let profile):
      SyncPreviewSheet(
        title: "Duplicate “\(profile.name)”",
        message: "Choose which workspaces and content to include. The profile switch shortcut and auto-activation are left off; workspace shortcuts can be copied because the new profile is independently scoped.",
        applyTitle: "Duplicate",
        groups: profileGroups(profile),
        allowsEmptySelection: true,
        validateSelection: { excluded in
          WorkspaceListFeature.duplicationShortcutConflicts(
            review: review,
            excluding: excluded
          )
        },
        onApply: onConfirm,
      )

    case .workspace(let workspace):
      SyncPreviewSheet(
        title: "Duplicate “\(workspace.name)”",
        message: "Choose the apps, settings, and saved layout to include. Workspace keys and explicit shortcuts are always left blank to avoid conflicts.",
        applyTitle: "Duplicate",
        groups: workspaceGroups(workspace),
        allowsEmptySelection: true,
        validateSelection: { excluded in
          WorkspaceListFeature.duplicationShortcutConflicts(
            review: review,
            excluding: excluded
          )
        },
        onApply: onConfirm,
      )
    }
  }

  /// A profile chooser keeps each workspace in one group. Its first toggle is
  /// the parent of that workspace's content and layout rows, so excluding a
  /// workspace also excludes every subordinate option without losing the
  /// user's individual choices if it is turned back on.
  private func profileGroups(_ profile: Profile) -> [SyncChangeGroup] {
    var groups = [SyncChangeGroup]()
    if let symbol = profile.symbolIconName {
      groups.append(SyncChangeGroup(
        id: "profile",
        title: String(localized: "Profile"),
        symbol: symbol,
        items: [SyncChangeItem(
          id: WorkspaceListFeature.DuplicationOptionID.profileIcon,
          title: String(localized: "Profile icon"),
          detail: String(localized: "Copy the profile's appearance."),
          detailTint: .secondary,
          symbol: symbol,
          symbolTint: .accentColor,
          appBundleId: nil,
          appIconPath: nil,
        )],
      ))
    }

    for workspace in profile.workspaces {
      let parentId = WorkspaceListFeature.DuplicationOptionID.includeWorkspace(workspace.id)
      var items = [SyncChangeItem(
        id: parentId,
        title: String(localized: "Include workspace"),
        detail: workspace.apps.isEmpty
          ? String(localized: "Copy its settings and saved layout.")
          : String(localized: "Copy its apps, settings, and saved layout."),
        detailTint: .secondary,
        symbol: "checkmark.circle",
        symbolTint: .accentColor,
        appBundleId: nil,
        appIconPath: nil,
      )]
      items.append(contentsOf: appItems(workspace, parentId: parentId))
      items.append(contentsOf: settingItems(
        workspace,
        parentId: parentId,
        includeShortcuts: true,
      ))
      items.append(layoutItem(workspace, parentId: parentId))
      groups.append(SyncChangeGroup(
        id: workspace.id.uuidString,
        title: workspace.name,
        symbol: workspace.symbolIconName ?? "square.stack.3d.up",
        items: items,
      ))
    }
    return groups
  }

  private func workspaceGroups(_ workspace: Workspace) -> [SyncChangeGroup] {
    var groups = [SyncChangeGroup]()
    let apps = appItems(workspace)
    if !apps.isEmpty {
      groups.append(SyncChangeGroup(id: "apps", title: String(localized: "Apps"), items: apps))
    }
    let settings = settingItems(workspace)
    if !settings.isEmpty {
      groups.append(SyncChangeGroup(
        id: "settings",
        title: String(localized: "Settings"),
        items: settings,
      ))
    }
    groups.append(SyncChangeGroup(
      id: "layout",
      title: String(localized: "Layout"),
      items: [layoutItem(workspace)],
    ))
    return groups
  }

  private func appItems(
    _ workspace: Workspace,
    parentId: String? = nil
  ) -> [SyncChangeItem] {
    let prefix = "\(workspace.id.uuidString):"
    return WorkspaceSync.appChanges(from: workspace.apps, to: []).map {
      SyncChangeItem($0, prefix: prefix, parentId: parentId)
    }
  }

  private func settingItems(
    _ workspace: Workspace,
    parentId: String? = nil,
    includeShortcuts: Bool = false
  ) -> [SyncChangeItem] {
    let empty = Workspace(name: workspace.name)
    let prefix = "\(workspace.id.uuidString):"
    return WorkspaceSync.fieldChanges(from: workspace, to: empty)
      .filter { includeShortcuts || !isShortcutIdentity($0) }
      .map { SyncChangeItem($0, prefix: prefix, parentId: parentId) }
  }

  private func layoutItem(
    _ workspace: Workspace,
    parentId: String? = nil
  ) -> SyncChangeItem {
    SyncChangeItem(
      id: WorkspaceListFeature.DuplicationOptionID.layout(workspace.id),
      parentId: parentId,
      title: String(localized: "Saved layout"),
      detail: String(localized: "Copy the saved tiling tree, if one exists."),
      detailTint: .secondary,
      symbol: "rectangle.split.2x1",
      symbolTint: .accentColor,
      appBundleId: nil,
      appIconPath: nil,
    )
  }

  private func isShortcutIdentity(_ change: WorkspaceFieldChange) -> Bool {
    switch change {
    case .keyEquivalent, .activateShortcut, .assignAppShortcut, .borrowShortcut:
      true
    case .icon, .kind, .appToFocus, .displayHint, .borrowEdge, .borrowFraction:
      false
    }
  }
}

// MARK: - WorkspaceRuntimeStatusView

/// Keeps fast-changing runtime badges in their own observation boundary so a
/// Borrow toggle does not invalidate the entire three-column settings view.
private struct WorkspaceRuntimeStatusView: View {

  // MARK: Internal

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

  // MARK: Private

  /// The display this workspace is currently active on, if any.
  private var activeDisplay: DisplayName? {
    activationStore.activeWorkspacesByDisplay.first { $0.value == workspaceID }?.key
  }

  /// The host workspace's name when this workspace is currently borrowed into
  /// a live composition, else nil.
  private var borrowedHostName: String? {
    for (_, composition) in activationStore.compositionsByDisplay
      where composition.borrowed.contains(where: { $0.workspace == workspaceID })
    {
      return activationStore.config.activeProfile?.workspaces[id: composition.host]?.name
        ?? String(localized: "another workspace")
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

extension Workspace {
  /// Sidebar row identity — must be the List's selection type for macOS to make
  /// the row selectable (see the ForEach above).
  fileprivate var sidebarItem: WorkspaceListFeature.SidebarItem {
    .workspace(id)
  }
}

extension Profile {
  /// Col 1 row identity — must match the sidebar List's selection type
  /// (SidebarTop) for macOS to wire the row's selection gesture.
  fileprivate var sidebarTop: WorkspaceListFeature.SidebarTop {
    .profile(id)
  }
}

// MARK: - AddWorkspaceForm

private struct AddWorkspaceForm: View {

  // MARK: Internal

  @Bindable var store: StoreOf<WorkspaceListFeature>

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

  // MARK: Private

  @FocusState private var nameFieldFocused: Bool

}
