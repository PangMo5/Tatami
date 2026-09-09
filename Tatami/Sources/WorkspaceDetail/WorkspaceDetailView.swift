// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ComposableArchitecture
import SFSafeSymbols
import SwiftUI
import TatamiKit

// MARK: - ActivationSlice

/// The sibling activation store's per-workspace slice, mirrored into the layout
/// reducer. Equatable so `.onChange` only fires on real changes.
private struct ActivationSlice: Equatable {
  var liveTree: BSPNode<WindowKey>?
  var liveZoomed: Set<WindowKey>
  var isActive: Bool
}

// MARK: - WorkspaceDetailView

struct WorkspaceDetailView: View {

  // MARK: Internal

  @Bindable var store: StoreOf<WorkspaceDetailFeature>

  let activationStore: StoreOf<WorkspaceActivationFeature>
  let editorFocus: FocusState<WorkspaceEditorFocus?>.Binding

  var body: some View {
    if let workspace = store.workspace {
      ScrollViewReader { proxy in
        Form {
          Section {
            WorkspaceLayoutPreview(store: store.scope(state: \.layout, action: \.layout))
          } header: {
            Text("Layout")
          }

          Section("Workspace") {
            // Icon picker — opens the SF Symbol grid on tap. Plain HStack with
            // center alignment so the label sits vertically centered against
            // the icon (LabeledContent aligns to the text baseline, which
            // floats the label above taller controls).
            HStack {
              Text("Icon")
              Spacer()
              Button {
                symbolPickerPresented = true
              } label: {
                Image(systemName: workspace.symbolIconName ?? "square.stack.3d.up")
                  .font(.title2)
                  .foregroundStyle(.tint)
                  .frame(width: 28, height: 28)
              }
              .buttonStyle(.plain)
              .help("Choose an icon for this workspace.")
              .sheet(isPresented: $symbolPickerPresented) {
                SymbolPicker(
                  selected: workspace.symbolIconName,
                  onSelect: { store.send(.symbolIconChanged($0)) },
                )
              }
            }

            // Name — separate row, commits on blur or Return.
            HStack {
              Text("Name")
              Spacer(minLength: 16)
              TextField("", text: $nameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
                .focused(editorFocus, equals: .workspaceName(workspace.id))
                .onSubmit { commitNameDraft() }
                .onChange(of: editorFocus.wrappedValue) { previous, current in
                  if previous == .workspaceName(workspace.id), previous != current { commitNameDraft() }
                }
            }

            // Key equivalent — the workspace's single key. Combined with the
            // switch / assign / borrow modifiers below for those actions.
            VStack(alignment: .leading, spacing: 4) {
              HStack(spacing: 10) {
                Text("Key equivalent")
                Spacer(minLength: 12)
                KeyEquivalentRecorder(
                  key: workspace.keyEquivalent,
                  modifierSymbols: "",
                  accessibilityLabel: "Key equivalent",
                  conflict: { keyEquivalentConflict($0) },
                  onRecordingChanged: { store.send(.shortcutRecordingChanged($0)) },
                ) { store.send(.keyEquivalentChanged($0)) }
              }
              Text(
                "One key for this workspace — hold it with the switch / assign / borrow modifier (Settings → Workspace Keys) to run each action."
              )
              .font(.caption)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Kind — normal vs scratchpad.
            Picker(
              selection: Binding(
                get: { workspace.kind },
                set: { store.send(.kindChanged($0)) },
              )
            ) {
              ForEach(WorkspaceKind.allCases, id: \.self) { kind in
                Text(kind.displayName).tag(kind)
              }
            } label: {
              Text("Kind")
              Text(workspace.kind == .scratchpad
                ? "Borrow-only: excluded from cycling and never activated on its own — pull it in beside another workspace with a borrow."
                :
                "A normal workspace you switch to and cycle through. Borrow mode summons it by this key (h/j/k/l steer direction, so a workspace keyed to one isn't borrow-summonable).")
            }
            .pickerStyle(.menu)
          }

          Section {
            ForEach(store.apps) { assignment in
              AppAssignmentRow(
                name: assignment.name,
                bundleIdentifier: assignment.bundleIdentifier,
                iconPath: assignment.iconPath,
                autoOpenBinding: Binding(
                  get: { assignment.autoOpen },
                  set: { value in
                    store.send(
                      .autoOpenToggled(bundleIdentifier: assignment.bundleIdentifier, isOn: value)
                    )
                  },
                ),
                layoutBinding: Binding(
                  get: { assignment.layout },
                  set: { value in
                    store.send(
                      .layoutChanged(bundleIdentifier: assignment.bundleIdentifier, layout: value)
                    )
                  },
                ),
                showLayoutOptions: workspace.kind != .scratchpad,
                autoOpenHelp: "Launch this app automatically when the workspace activates, if it isn't already running.",
                onRemove: {
                  store.send(.appRemoveRequested(bundleIdentifier: assignment.bundleIdentifier))
                },
              )
              .id("app-\(assignment.bundleIdentifier)")
              .listRowBackground(
                highlightedApp == assignment.bundleIdentifier
                  ? Color.accentColor.opacity(0.18)
                  : nil
              )
            }
          } header: {
            HStack {
              Text("Apps")
              Spacer()
              Button {
                store.send(.addAppButtonTapped)
              } label: {
                Label("Add", systemImage: "plus.circle")
                  .labelStyle(.iconOnly)
              }
              .buttonStyle(.borderless)
            }
          } footer: {
            if store.apps.isEmpty {
              Text("No apps yet. Tap + to assign one.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }

          Section {
            // Each action derives from the workspace key (its modifier in
            // Settings → Workspace Keys); the recorder beside it overrides that.
            // Activate / Assign are meaningless for a borrow-only scratchpad.
            if workspace.kind != .scratchpad {
              derivedShortcutRow(
                "Activate",
                modifiers: store.config.settings.shortcuts.keyEquivalentModifiers,
                key: workspace.keyEquivalent,
                override: workspace.activateShortcut,
                conflict: { store.state.activateShortcutConflict(for: $0) },
                onOverride: { store.send(.activateShortcutChanged($0)) },
              )
              derivedShortcutRow(
                "Assign focused app here",
                modifiers: store.config.settings.shortcuts.assignModifiers,
                key: workspace.keyEquivalent,
                override: workspace.assignAppShortcut,
                conflict: { store.state.assignShortcutConflict(for: $0) },
                onOverride: { store.send(.assignAppShortcutChanged($0)) },
              )
            }
            derivedShortcutRow(
              "Borrow",
              modifiers: store.config.settings.shortcuts.borrowModifiers,
              key: workspace.keyEquivalent,
              override: workspace.borrowShortcut,
              conflict: { store.state.borrowShortcutConflict(for: $0) },
              onOverride: { store.send(.borrowShortcutChanged($0)) },
            )
          } header: {
            HStack {
              Text("Shortcuts")
              Spacer()
              Button {
                store.send(.openWorkspaceKeysTapped)
              } label: {
                Label("Workspace Keys", systemImage: "keyboard")
                  .font(.caption)
              }
              .buttonStyle(.borderless)
              .help("Edit the switch / assign / borrow modifiers these combine with, in Settings → Workspace Keys.")
            }
          } footer: {
            Text(
              "Each uses its modifier (Settings → Workspace Keys) + this workspace's key equivalent; record a shortcut to override. Borrow pulls this workspace in beside the current one — then a direction key places it unless a default is set below."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }

          Section("Borrow Placement") {
            let globalEdge = store.config.settings.switching.borrowDefaultEdge
            let globalEdgeLabel = globalEdge.map { String(localized: $0.displayName) }
              ?? String(localized: "Ask")
            let globalFraction = store.config.settings.switching.borrowFraction
            Picker(
              selection: Binding(
                get: { workspace.borrowEdge },
                set: { store.send(.borrowEdgeChanged($0)) },
              )
            ) {
              Text("Use Global (\(globalEdgeLabel))").tag(BorrowEdge?.none)
              Divider()
              ForEach(BorrowEdge.allCases, id: \.self) { edge in
                Text(edge.displayName).tag(BorrowEdge?.some(edge))
              }
            } label: {
              Text("Direction")
              Text("Where this workspace docks when borrowed. Change the global default in Settings.")
            }
            .pickerStyle(.menu)
            Picker(
              selection: Binding(
                get: { workspace.borrowFraction },
                set: { store.send(.borrowFractionChanged($0)) },
              )
            ) {
              Text("Use Global (\(Int((globalFraction * 100).rounded()))%)").tag(Double?.none)
              Divider()
              ForEach([0.3, 0.4, 0.5, 0.6, 0.7], id: \.self) { f in
                Text("\(Int((f * 100).rounded()))%").tag(Double?.some(f))
              }
            } label: {
              Text("Size")
              Text("This workspace's share of the screen when borrowed.")
            }
            .pickerStyle(.menu)
          }

          if workspace.kind != .scratchpad {
            DisplayPickerSection(
              availableDisplays: store.availableDisplays,
              selectedHint: workspace.displayHint,
              onSelect: { store.send(.displayHintChanged($0)) },
            )
          }

          if workspace.kind != .scratchpad {
            Section("On Activation") {
              Picker(
                selection: Binding(
                  get: { workspace.appToFocusBundleId },
                  set: { store.send(.appToFocusChanged($0)) },
                )
              ) {
                Text("Most recently used").tag(String?.none)
                ForEach(workspace.apps, id: \.bundleIdentifier) { app in
                  Text(app.name).tag(String?.some(app.bundleIdentifier))
                }
              } label: {
                Text("Focus app")
                Text("Which assigned app gets focus when this workspace activates.")
              }
              .pickerStyle(.menu)
            }
          }

          copyFromSection(workspace)
        }
        .formStyle(.grouped)
        .navigationTitle(workspace.name)
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            let active = isActive(workspace)
            Button {
              store.send(.activateTapped)
            } label: {
              Label(
                active ? "Active" : "Activate",
                systemImage: active ? "checkmark.circle.fill" : "play.fill",
              )
            }
            .disabled(active || activationStore.isActivating)
            .help(active ? "This workspace is already active." : "Activate this workspace.")
          }
        }
        .sheet(isPresented: $store.isAppPickerPresented) {
          AppPickerSheet(
            apps: store.availableRunningApps,
            onSelect: { app in store.send(.appPickerAppSelected(app)) },
            onChooseFile: { store.send(.chooseAppFileTapped) },
            onCancel: { store.send(.appPickerDismissed) },
          )
        }
        .sheet(item: $importReview) { review in
          SyncPreviewSheet(
            title: "Copy from “\(review.workspaceName)”",
            message: "Copy each change from “\(review.workspaceName)” (\(review.profileName)) into this workspace. Uncheck anything you'd rather keep.",
            applyTitle: "Copy",
            groups: importGroups(review),
            confirmationKind: .copyWorkspace,
            validateSelection: { excluded in
              importConflicts(review, excluding: excluded)
            },
            onApply: { excluded, suppressed in applyImport(review, excluding: excluded, suppressFuture: suppressed) },
          )
        }
        .onChange(of: workspace.id, initial: true) { _, _ in
          // A reused detail view must not carry its text-field focus or draft
          // into the newly selected workspace.
          commitNameDraft()
          if case .workspaceName(let owner) = editorFocus.wrappedValue, owner != workspace.id {
            editorFocus.wrappedValue = .workspaces
          }
          nameDraftWorkspaceID = workspace.id
          originalNameDraft = workspace.name
          nameDraft = workspace.name
        }
        // A sidebar inline rename keeps the workspace identity. Refresh only
        // this draft instead of rebuilding the whole detail view (which would
        // discard its scroll position, sheets, and transient highlighting).
        .onChange(of: workspace.name) { _, name in
          guard editorFocus.wrappedValue != .workspaceName(workspace.id), nameDraftWorkspaceID == workspace.id else { return }
          originalNameDraft = name
          nameDraft = name
        }
        // Keyed on the workspace so re-running per selection re-fetches the
        // display list (a plain `.task` only fires on first appearance, which
        // left later workspaces' pickers showing just their own pinned display).
        .task(id: workspace.id) { store.send(.onAppear) }
        // Mirror the sibling activation store's slice for this workspace into the
        // layout reducer (it can't read the activation subtree directly). The
        // Equatable gate fires only on real changes to this workspace's tree /
        // zoom / active state.
        .onChange(of: activationSlice(workspace.id), initial: true) { _, slice in
          store.send(.layout(.activationObserved(
            liveTree: slice.liveTree,
            liveZoomed: slice.liveZoomed,
            isActive: slice.isActive,
          )))
        }
        // Refresh the pinned-display picker when monitors are plugged/unplugged.
        .onReceive(
          NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
        ) { _ in store.send(.refreshDisplays) }
        .persistentChangeAlert(
          $store.scope(state: \.alert, action: \.alert),
          suppressible: store.alert?.buttons.contains(where: { $0.role == .destructive }) == true,
          suppress: Binding(
            get: { store.suppressConfirmation },
            set: { store.send(.confirmationSuppressionChanged($0)) },
          ),
        )
        // A "Configure in Apps" jump: scroll the Apps section to the row and
        // flash it. Keyed on the request token so repeat jumps refire.
        .task(id: store.appScrollRequest?.token) {
          guard let request = store.appScrollRequest else { return }
          withAnimation { proxy.scrollTo("app-\(request.bundleId)", anchor: .center) }
          withAnimation { highlightedApp = request.bundleId }
          try? await Task.sleep(for: highlightFlash)
          guard !Task.isCancelled else { return }
          withAnimation { highlightedApp = nil }
        }
      } // ScrollViewReader
    } else {
      ContentUnavailableView(
        "Workspace Unavailable",
        systemImage: "exclamationmark.triangle",
        description: Text("This workspace no longer exists."),
      )
    }
  }

  // MARK: Private

  /// A chosen source workspace for the "copy from" review sheet.
  private struct WorkspaceImportReview: Identifiable {
    let baseline: AppConfig
    let profileId: Profile.ID
    let profileName: String
    let targetWorkspaceId: Workspace.ID
    let workspaceId: Workspace.ID
    let workspaceName: String

    var id: String {
      "\(profileId.uuidString):\(workspaceId.uuidString)"
    }
  }

  @State private var nameDraft = ""
  @State private var symbolPickerPresented = false
  /// App row briefly tinted after a "Configure in Apps" jump, so the user's eye
  /// lands on the right row.
  @State private var highlightedApp: String?
  /// The workspace picked to copy from — drives the review sheet.
  @State private var importReview: WorkspaceImportReview?
  @State private var nameDraftWorkspaceID: Workspace.ID?
  @State private var originalNameDraft = ""

  private let highlightFlash = Duration.seconds(1.6)

  /// True when *this* workspace is the currently-active one on any
  /// display. Drives the toolbar Activate button's disabled state.
  private func isActive(_ workspace: Workspace) -> Bool {
    activationStore.activeWorkspacesByDisplay.values.contains(workspace.id)
  }

  private func activationSlice(_ id: Workspace.ID) -> ActivationSlice {
    ActivationSlice(
      liveTree: activationStore.tilingTrees[id],
      liveZoomed: activationStore.fullscreenZoomed[id] ?? [],
      isActive: activationStore.activeWorkspacesByDisplay.values.contains(id),
    )
  }

  /// Conflict title for a candidate key equivalent on this workspace. The one
  /// key generates three combos — switch+key (activate), assign+key, borrow+key
  /// — so each is checked against every other binding (excluding this
  /// workspace's matching action). Nil when all three are free / unbound.
  private func keyEquivalentConflict(_ char: String) -> String? {
    store.config.workspaceKeyEquivalentConflict(
      for: char,
      workspaceId: store.state.workspaceId,
    )
  }

  /// A shortcut row whose default is "modifier + the workspace key equivalent"
  /// (shown read-only in a capsule) with an explicit-shortcut override beside.
  private func derivedShortcutRow(
    _ title: LocalizedStringResource,
    modifiers: [String],
    key: String?,
    override: HotKey?,
    conflict: @escaping (HotKey) -> String?,
    onOverride: @escaping (HotKey?) -> Void,
  ) -> some View {
    HStack(spacing: 10) {
      Text(title)
      Spacer(minLength: 12)
      let mods = HotKey.modifierSymbols(from: modifiers)
      let combo = (key?.isEmpty == false) && !mods.isEmpty ? mods + HotKey.keySymbol(forName: key ?? "") : ""
      ComboCapsule(text: combo, dimmed: override != nil)
      Text("or")
        .font(.caption)
        .foregroundStyle(.tertiary)
      ShortcutRecorder(
        hotKey: override,
        accessibilityLabel: title,
        conflict: conflict,
        onRecordingChanged: { store.send(.shortcutRecordingChanged($0)) },
      ) { onOverride($0) }
    }
  }

  @ViewBuilder
  private func copyFromSection(_ workspace: Workspace) -> some View {
    let profiles = store.config.profiles
    let hasSources = profiles.contains { p in p.workspaces.contains { $0.id != workspace.id } }
    if hasSources {
      Section {
        Menu {
          ForEach(profiles, id: \.id) { profile in
            let sources = profile.workspaces.filter { $0.id != workspace.id }
            if !sources.isEmpty {
              Menu(profile.name) {
                ForEach(sources, id: \.id) { ws in
                  let hasChanges = WorkspaceSync.hasChanges(from: ws, to: workspace)
                  Button {
                    let baseline = store.config
                    guard
                      let profileSnapshot = baseline.profiles.first(where: { $0.id == profile.id }),
                      let workspaceSnapshot = profileSnapshot.workspaces[id: ws.id],
                      let targetSnapshot = baseline.workspace(id: store.workspaceId),
                      WorkspaceSync.hasChanges(from: workspaceSnapshot, to: targetSnapshot)
                    else { return }
                    importReview = WorkspaceImportReview(
                      baseline: baseline,
                      profileId: profileSnapshot.id,
                      profileName: profileSnapshot.name,
                      targetWorkspaceId: store.workspaceId,
                      workspaceId: workspaceSnapshot.id,
                      workspaceName: workspaceSnapshot.name,
                    )
                  } label: {
                    if hasChanges {
                      Text(verbatim: ws.name)
                    } else {
                      Text("\(ws.name) · No differences")
                    }
                  }
                  .disabled(!hasChanges)
                }
              }
            }
          }
        } label: {
          Label("Copy from another workspace…", systemImage: "square.on.square")
        }
      } header: {
        Text("Copy")
      } footer: {
        Text(
          "Pull another workspace's apps and settings into this one — you'll review and pick each change. The display pin is included, so uncheck it to keep this workspace's own."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func importGroups(_ review: WorkspaceImportReview) -> [SyncChangeGroup] {
    guard
      let sourceWorkspace = review.baseline.profiles.first(where: { $0.id == review.profileId })?
        .workspaces[id: review.workspaceId],
      let target = review.baseline.workspace(id: review.targetWorkspaceId)
    else { return [] }
    var groups = [SyncChangeGroup]()
    let appChanges = WorkspaceSync.appChanges(from: sourceWorkspace.apps, to: target.apps)
    if !appChanges.isEmpty {
      groups.append(SyncChangeGroup(
        id: "apps",
        title: String(localized: "Apps"),
        items: appChanges.map { SyncChangeItem($0, prefix: "") },
      ))
    }
    let fieldChanges = WorkspaceSync.fieldChanges(from: sourceWorkspace, to: target)
    if !fieldChanges.isEmpty {
      groups.append(SyncChangeGroup(
        id: "settings",
        title: String(localized: "Settings"),
        items: fieldChanges.map { SyncChangeItem($0, prefix: "") },
      ))
    }
    return groups
  }

  private func commitNameDraft() {
    guard let id = nameDraftWorkspaceID, nameDraft != originalNameDraft else { return }
    store.send(.nameSubmitted(nameDraft, workspaceID: id))
    originalNameDraft = nameDraft
  }

  private func applyImport(
    _ review: WorkspaceImportReview,
    excluding excluded: Set<String>,
    suppressFuture: Bool,
  ) {
    let exclusions = importExclusions(excluded)
    store.send(.importWorkspace(
      targetWorkspace: review.targetWorkspaceId,
      sourceProfile: review.profileId,
      sourceWorkspace: review.workspaceId,
      baseline: review.baseline,
      excludingApps: exclusions.apps,
      excludingFields: exclusions.fields,
      suppressFuture: suppressFuture,
    ))
  }

  private func importConflicts(
    _ review: WorkspaceImportReview,
    excluding excluded: Set<String>,
  ) -> [String: [WorkspaceShortcutConflict]] {
    let exclusions = importExclusions(excluded)
    guard
      let projection = review.baseline.workspaceImportProjection(
        into: review.targetWorkspaceId,
        from: review.profileId,
        sourceWorkspace: review.workspaceId,
        excludingApps: exclusions.apps,
        excludingFields: exclusions.fields,
      )
    else { return [:] }
    return Dictionary(grouping: projection.conflicts) { conflict in
      SyncChangeItem.fieldId("", conflict.selection.field.rawValue)
    }
  }

  private func importExclusions(
    _ excluded: Set<String>
  ) -> (apps: Set<String>, fields: Set<String>) {
    var excApps = Set<String>()
    var excFields = Set<String>()
    for id in excluded {
      if id.hasPrefix("app:") { excApps.insert(String(id.dropFirst(4))) }
      else if id.hasPrefix("field:") { excFields.insert(String(id.dropFirst(6))) }
    }
    return (excApps, excFields)
  }

}

// MARK: - SymbolPicker

/// Searchable SF Symbol picker backed by SFSafeSymbols' full catalog.
/// Shared with ProfileDetailView (same target), hence not file-private.
struct SymbolPicker: View {

  // MARK: Internal

  let selected: String?
  let onSelect: (String?) -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Choose Icon").font(.headline)
        Spacer()
        Button("Reset") { onSelect(nil)
          dismiss()
        }
        .buttonStyle(.borderless)
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(.horizontal, 12)
      .padding(.top, 12)

      TextField("Search symbols", text: $query)
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)

      Divider()

      ScrollView {
        LazyVGrid(columns: columns, spacing: 8) {
          ForEach(filtered, id: \.self) { name in
            Button {
              onSelect(name)
              dismiss()
            } label: {
              Image(systemName: name)
                .font(.system(size: 18))
                .frame(width: 40, height: 40)
                .background(
                  RoundedRectangle(cornerRadius: 8)
                    .fill(name == selected ? Color.accentColor.opacity(0.3) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .help(name)
          }
        }
        .padding(12)
      }
    }
    .frame(width: 420, height: 460)
  }

  // MARK: Private

  /// Full catalog, sorted once. Some entries require a newer OS than the
  /// deployment target and just render blank — harmless for a picker.
  private static let allNames: [String] =
    SFSymbol.allSymbols.map(\.rawValue).sorted()

  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  private let columns = [GridItem(.adaptive(minimum: 40), spacing: 8)]

  private var filtered: [String] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return Self.allNames }
    return Self.allNames.filter { $0.localizedCaseInsensitiveContains(trimmed) }
  }

}

// MARK: - DisplayPickerSection

private struct DisplayPickerSection: View {

  // MARK: Internal

  // Plain values passed by the parent (which is `@Bindable` and observes the
  // store), so this section reliably re-renders when the display list loads.
  let availableDisplays: [DisplayName]
  let selectedHint: DisplayName?
  let onSelect: (DisplayName?) -> Void

  var body: some View {
    Section {
      Picker("Pinned display", selection: binding) {
        Text("Dynamic (follows mouse)").tag(DisplayName?.none)
        ForEach(pickerItems, id: \.self) { display in
          Text(display.name).tag(DisplayName?.some(display))
        }
      }
      .pickerStyle(.menu)
    } header: {
      Text("Display")
    } footer: {
      Text(
        "Pin this workspace to always open on one display. Dynamic follows the mouse, opening on the display under the pointer."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  // MARK: Private

  /// Connected displays, plus the pinned display itself when it's currently
  /// disconnected — so the picker can still show the existing selection.
  private var pickerItems: [DisplayName] {
    var items = availableDisplays
    if let hint = selectedHint, !items.contains(where: { $0.matches(hint) }) {
      items.append(hint)
    }
    return items
  }

  private var binding: Binding<DisplayName?> {
    Binding(
      get: {
        guard let hint = selectedHint else { return nil }
        // Resolve the hint to the actual picker item (UUID-or-name match) so a
        // legacy / name-only hint still highlights the right display.
        return pickerItems.first { $0.matches(hint) } ?? hint
      },
      set: { onSelect($0) },
    )
  }

}

// MARK: - AppIcon

/// Shared with SharedAppsView (same target), hence not file-private.
struct AppIcon: View {

  // MARK: Internal

  let bundleIdentifier: String
  let iconPath: String?

  var body: some View {
    Group {
      if loaded?.identity == identity, let image = loaded?.image {
        Image(decorative: image, scale: 1)
          .resizable()
          .scaledToFit()
      } else {
        Image(systemName: "app.dashed")
          .foregroundStyle(.secondary)
      }
    }
    .task(id: identity) {
      let requested = identity
      let image = await AppIconLoader.shared.load(bundleIdentifier: bundleIdentifier, iconPath: iconPath)
      guard !Task.isCancelled else { return }
      loaded = (requested, image)
    }
  }

  // MARK: Private

  @State private var loaded: (identity: String, image: CGImage?)?

  private var identity: String {
    bundleIdentifier + "\n" + (iconPath ?? "")
  }

}

// MARK: - AppIconLoader

/// Mutable AppKit images remain on this serial worker. Only an immutable,
/// rasterized CGImage crosses to SwiftUI; scrolling never performs disk I/O.
private actor AppIconLoader {

  // MARK: Internal

  static let shared = AppIconLoader()

  nonisolated var unownedExecutor: UnownedSerialExecutor {
    executor.asUnownedSerialExecutor()
  }

  func load(bundleIdentifier: String, iconPath: String?) -> CGImage? {
    let key = (bundleIdentifier + "\n" + (iconPath ?? "")) as NSString
    if let hit = cache.object(forKey: key) { return hit }
    let image: NSImage? =
      if let iconPath, let fromFile = NSImage(contentsOfFile: iconPath) {
        fromFile
      } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
        NSWorkspace.shared.icon(forFile: url.path)
      } else {
        nil
      }
    guard let bitmap = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    cache.setObject(bitmap, forKey: key)
    return bitmap
  }

  // MARK: Private

  private let executor = DispatchSerialQueue(label: "dev.PangMo5.Tatami.app-icons", qos: .userInitiated)
  private let cache: NSCache<NSString, CGImage> = {
    let cache = NSCache<NSString, CGImage>()
    cache.countLimit = 256
    return cache
  }()

}

// MARK: - AppPickerSheet

/// Shared with SharedAppsView (same target), hence not file-private.
struct AppPickerSheet: View {

  // MARK: Internal

  let apps: [MacApp]
  let onSelect: (MacApp) -> Void
  /// Pick an app from disk instead of the running list.
  let onChooseFile: () -> Void
  let onCancel: () -> Void

  var body: some View {
    NavigationStack {
      // Always a List so the title + search bar stay anchored at the top; the
      // empty state overlays it centered (a bare ContentUnavailableView shrank
      // the content and let the navigation title float to the middle).
      List(filtered, id: \.bundleIdentifier) { app in
        Button {
          onSelect(app)
        } label: {
          HStack {
            AppIcon(bundleIdentifier: app.bundleIdentifier, iconPath: app.iconPath)
              .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
              Text(app.name)
              Text(app.bundleIdentifier)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
          }
        }
        .buttonStyle(.plain)
      }
      .overlay {
        if filtered.isEmpty {
          ContentUnavailableView {
            Label(apps.isEmpty ? "No Running Apps" : "No Matches", systemImage: "magnifyingglass")
          } description: {
            Text(apps.isEmpty
              ? "Use “Choose from Files…” to add an app that isn't running."
              : "No running app matches “\(query)”.")
          }
        }
      }
      .navigationTitle("Add App")
      .searchable(text: $query, prompt: "Search running apps")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: onCancel)
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            onChooseFile()
          } label: {
            Label("Choose from Files…", systemImage: "folder")
          }
          .help("Pick an app from disk that isn't currently running.")
        }
      }
    }
    .frame(width: 420, height: 480)
  }

  // MARK: Private

  @State private var query = ""

  private var filtered: [MacApp] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return apps }
    return apps.filter {
      $0.name.localizedCaseInsensitiveContains(trimmed)
        || $0.bundleIdentifier.localizedCaseInsensitiveContains(trimmed)
    }
  }

}
