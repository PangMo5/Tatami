import ComposableArchitecture
import Foundation
import Sharing

/// Edit a single `Workspace`'s apps, display, hotkeys and metadata.
///
/// The detail reducer is scoped to a `workspaceId`; all mutations flow
/// through `state.$config.withLock` and persist to the TOML file.
@Reducer
public struct WorkspaceDetailFeature {
  @ObservableState
  public struct State: Equatable {
    @Shared(.tatamiConfig) public var config = AppConfig()
    public var workspaceId: Workspace.ID
    public var isAppPickerPresented = false
    public var availableRunningApps: [MacApp] = []
    public var availableDisplays: [DisplayName] = []
    /// Persisted layout template for this workspace, loaded on appear. Drives
    /// the layout preview when the workspace isn't currently active (no live
    /// tree); edits write back through here.
    public var layoutSnapshot: LayoutSnapshot?
    /// AX titles for the workspace's apps' live windows, keyed by window —
    /// lets the preview disambiguate several windows of the same app.
    public var windowTitles: [WindowKey: String] = [:]
    /// Bundle ids that currently have discoverable (tileable) windows. A shared
    /// app absent here is hidden and wouldn't tile on switch, so the preview
    /// omits it.
    public var presentBundleIds: Set<String> = []
    @Presents public var alert: AlertState<Action.Alert>?

    public init(workspaceId: Workspace.ID) {
      self.workspaceId = workspaceId
    }

    public var workspace: Workspace? {
      config.activeProfile?.workspaces[id: workspaceId]
    }

    public var apps: [AppAssignment] {
      workspace?.apps ?? []
    }

    /// Title of another action already bound to `candidate`, or nil if free
    /// — for the activate-shortcut recorder's conflict message. Lives here
    /// (not the view) so the config read stays in the reducer's state.
    public func activateShortcutConflict(for candidate: HotKey) -> String? {
      config.shortcutConflict(for: candidate, excluding: .activateWorkspace(workspaceId))
    }

    /// Same, for the assign-app-shortcut recorder.
    public func assignShortcutConflict(for candidate: HotKey) -> String? {
      config.shortcutConflict(
        for: candidate, excluding: .assignFocusedAppToWorkspace(workspaceId)
      )
    }

    /// Same, for the borrow-shortcut recorder.
    public func borrowShortcutConflict(for candidate: HotKey) -> String? {
      config.shortcutConflict(for: candidate, excluding: .borrowWorkspace(workspaceId))
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case onAppear
    case addAppButtonTapped
    case appPickerDismissed
    case appPickerAppSelected(MacApp)
    case chooseAppFileTapped
    case appRemoveRequested(bundleIdentifier: String)
    case autoOpenToggled(bundleIdentifier: String, isOn: Bool)
    case layoutChanged(bundleIdentifier: String, layout: LayoutMode)
    case nameSubmitted(String)
    case symbolIconChanged(String?)
    case activateShortcutChanged(HotKey?)
    case assignAppShortcutChanged(HotKey?)
    case appToFocusChanged(String?)
    case displayHintChanged(DisplayName?)
    case kindChanged(WorkspaceKind)
    case keyEquivalentChanged(String?)
    case borrowShortcutChanged(HotKey?)
    case borrowEdgeChanged(BorrowEdge?)
    case borrowFractionChanged(Double?)
    case refreshDisplays
    /// A shortcut recorder started (`true`) / stopped (`false`) capturing.
    case shortcutRecordingChanged(Bool)
    /// Persisted layout snapshot arrived from disk (or nil if none saved yet).
    case layoutSnapshotLoaded(LayoutSnapshot?)
    /// A layout-preview edit for this *inactive* workspace: apply to its
    /// template, persist, and opt the workspace into `.persistent` memory so
    /// the edit is honored on next activation. (Active edits route to
    /// `WorkspaceActivationFeature.layoutEdited` instead.)
    case layoutEdited(LayoutEditOp)
    /// Fullscreen-zoom (`zoomIn: true`) or restore (`false`) one window of
    /// `bundleId` in this *inactive* workspace's saved layout. Tracked as a
    /// count in `fullscreenZoomedBundleIds` (a workspace can hold several
    /// windows of the same app), matching how activation restores them. Active
    /// toggles route to `bspToggleZoomFullscreen` per live window instead.
    case layoutFullscreenToggled(bundleId: String, zoomIn: Bool)
    /// Fetch AX titles for the workspace's apps' live windows (by bundle id, so
    /// it works even when the workspace isn't active).
    case loadWindowTitles(bundleIds: [String])
    case windowInfoLoaded(titles: [WindowKey: String], present: Set<String>)
    case alert(PresentationAction<Alert>)

    public enum Alert: Equatable {
      case confirmAppRemoval(bundleIdentifier: String)
    }
  }

  @Dependency(\.runningApps) var runningApps
  @Dependency(\.displays) var displays
  @Dependency(\.hotKeys) var hotKeys
  @Dependency(\.appChooser) var appChooser
  @Dependency(\.layoutStore) var layoutStore
  @Dependency(\.windowSnapshot) var windowSnapshot

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .onAppear:
        state.availableDisplays = displays.all()
        let id = state.workspaceId
        return .run { [layoutStore] send in
          await send(.layoutSnapshotLoaded(layoutStore.load(id)))
        }

      case .layoutSnapshotLoaded(let snapshot):
        state.layoutSnapshot = snapshot
        return .none

      case .layoutEdited(let op):
        let id = state.workspaceId
        guard let workspace = state.config.activeProfile?.workspaces[id: id] else { return .none }
        let tiled = tiledLayoutBundleIds(workspace: workspace, sharedApps: state.config.sharedApps)
        guard let template = state.layoutSnapshot?.tree
          ?? BSPNode<String>.synthesizedTemplate(tiledBundleIds: tiled)
        else { return .none }
        // Rekey to unique tokens so relocate is unambiguous even when a bundle
        // id repeats across leaves, apply, then map back to bundle ids.
        let (tokenized, back) = template.tokenized()
        let newTemplate = tokenized.applying(op).mapWindows { back[$0]! }
        guard newTemplate != template else { return .none }
        let snapshot = LayoutSnapshot(
          tree: newTemplate,
          fullscreenZoomedBundleIds: state.layoutSnapshot?.fullscreenZoomedBundleIds ?? []
        )
        state.layoutSnapshot = snapshot
        // Layouts always persist, so the edit is saved and honored on the next
        // activation without touching any per-workspace memory flag.
        return .run { [layoutStore] _ in layoutStore.save(id, snapshot) }

      case .layoutFullscreenToggled(let bundleId, let zoomIn):
        let id = state.workspaceId
        guard let workspace = state.config.activeProfile?.workspaces[id: id] else { return .none }
        let tiled = tiledLayoutBundleIds(workspace: workspace, sharedApps: state.config.sharedApps)
        guard let template = state.layoutSnapshot?.tree
          ?? BSPNode<String>.synthesizedTemplate(tiledBundleIds: tiled)
        else { return .none }
        var zoomed = state.layoutSnapshot?.fullscreenZoomedBundleIds ?? []
        if zoomIn {
          // Cap at the number of that app's windows in the layout — can't zoom
          // more windows than exist.
          let total = template.windows.filter { $0 == bundleId }.count
          let current = zoomed.filter { $0 == bundleId }.count
          guard current < total else { return .none }
          zoomed.append(bundleId)
        } else {
          guard let idx = zoomed.firstIndex(of: bundleId) else { return .none }
          zoomed.remove(at: idx)
        }
        let snapshot = LayoutSnapshot(tree: template, fullscreenZoomedBundleIds: zoomed.sorted())
        state.layoutSnapshot = snapshot
        return .run { [layoutStore] _ in layoutStore.save(id, snapshot) }

      case .loadWindowTitles(let bundleIds):
        guard !bundleIds.isEmpty else {
          state.windowTitles = [:]
          state.presentBundleIds = []
          return .none
        }
        // Discover the apps' live windows by bundle id — even when this
        // workspace isn't active, its apps are running, so their AX titles are
        // readable. The discovered set also tells the preview which shared apps
        // are currently present (hidden ones won't tile on switch).
        return .run { [windowSnapshot] send in
          let (titles, present) = await MainActor.run {
            () -> ([WindowKey: String], Set<String>) in
            let keys = windowSnapshot.cachedKeys(bundleIds, true)
            return (windowSnapshot.windowTitles(keys), Set(keys.map(\.bundleId)))
          }
          await send(.windowInfoLoaded(titles: titles, present: present))
        }

      case .windowInfoLoaded(let titles, let present):
        state.windowTitles = titles
        state.presentBundleIds = present
        return .none

      case .refreshDisplays:
        // Re-read the live display list (driven by the view's screen-change
        // observer) so the pinned-display picker reflects plug/unplug.
        state.availableDisplays = displays.all()
        return .none

      case .addAppButtonTapped:
        let alreadyAssigned = Set(state.apps.map(\.bundleIdentifier))
        state.availableRunningApps = runningApps.current()
          .filter { !alreadyAssigned.contains($0.bundleIdentifier) }
        state.isAppPickerPresented = true
        return .none

      case .appPickerDismissed:
        state.isAppPickerPresented = false
        state.availableRunningApps = []
        return .none

      case .appPickerAppSelected(let app):
        state.isAppPickerPresented = false
        state.availableRunningApps = []
        let id = state.workspaceId
        state.$config.withLock { config in
          config.mutateWorkspace(id) { workspace in
            guard !workspace.apps.contains(where: { $0.bundleIdentifier == app.bundleIdentifier })
            else { return }
            workspace.apps.append(AppAssignment(app))
          }
        }
        return .none

      case .chooseAppFileTapped:
        // Pick an app from disk; route through the same add path as the
        // running-app picker. Cancelling leaves the sheet untouched.
        return .run { [appChooser] send in
          if let app = await appChooser.choose() {
            await send(.appPickerAppSelected(app))
          }
        }

      case .appRemoveRequested(let bundleId):
        let name = state.apps.first { $0.bundleIdentifier == bundleId }?.name ?? bundleId
        state.alert = AlertState {
          TextState("Remove \"\(name)\"?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmAppRemoval(bundleIdentifier: bundleId)) {
            TextState("Remove")
          }
          ButtonState(role: .cancel) {
            TextState("Cancel")
          }
        } message: {
          TextState("It will no longer open or tile in this workspace. You can add it back anytime.")
        }
        return .none

      case .alert(.presented(.confirmAppRemoval(let bundleId))):
        let id = state.workspaceId
        state.$config.withLock { config in
          config.mutateWorkspace(id) { workspace in
            workspace.apps.removeAll { $0.bundleIdentifier == bundleId }
          }
        }
        return .none

      case .alert:
        return .none

      case .autoOpenToggled(let bundleId, let isOn):
        let id = state.workspaceId
        state.$config.withLock { config in
          config.mutateWorkspace(id) { workspace in
            guard let idx = workspace.apps.firstIndex(where: { $0.bundleIdentifier == bundleId })
            else { return }
            workspace.apps[idx].autoOpen = isOn
          }
        }
        return .none

      case .layoutChanged(let bundleId, let layout):
        let id = state.workspaceId
        state.$config.withLock { config in
          config.mutateWorkspace(id) { workspace in
            guard let idx = workspace.apps.firstIndex(where: { $0.bundleIdentifier == bundleId })
            else { return }
            workspace.apps[idx].layout = layout
          }
        }
        // Re-tile so the window drops out of (or back into) the layout
        // immediately when this workspace is active — handled in AppFeature.
        return .none

      case .nameSubmitted(let name):
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        let id = state.workspaceId
        state.$config.withLock { config in
          config.mutateWorkspace(id) { $0.name = trimmed }
        }
        return .none

      case .symbolIconChanged(let symbol):
        let id = state.workspaceId
        state.$config.withLock { config in
          config.mutateWorkspace(id) { $0.symbolIconName = symbol }
        }
        return .none

      case .activateShortcutChanged(let hotKey):
        let id = state.workspaceId
        state.$config.withLock { config in
          config.mutateWorkspace(id) { $0.activateShortcut = hotKey }
        }
        return .none

      case .assignAppShortcutChanged(let hotKey):
        let id = state.workspaceId
        state.$config.withLock { config in
          config.mutateWorkspace(id) { $0.assignAppShortcut = hotKey }
        }
        return .none

      case .appToFocusChanged(let bundleId):
        let id = state.workspaceId
        state.$config.withLock { config in
          config.mutateWorkspace(id) { $0.appToFocusBundleId = bundleId }
        }
        return .none

      case .displayHintChanged(let display):
        let id = state.workspaceId
        state.$config.withLock { config in
          config.mutateWorkspace(id) { $0.displayHint = display }
        }
        return .none

      case .kindChanged(let kind):
        let id = state.workspaceId
        state.$config.withLock { config in
          config.mutateWorkspace(id) { $0.kind = kind }
        }
        return .none

      case .keyEquivalentChanged(let raw):
        // The recorder hands a single key *name* (e.g. "d", "delete", "left",
        // ","), stored as-is lowercased — don't truncate to a character, or
        // multi-letter names like "delete" collapse to "e".
        let key = (raw?.isEmpty == false) ? raw?.lowercased() : nil
        let id = state.workspaceId
        state.$config.withLock { config in
          config.mutateWorkspace(id) { $0.keyEquivalent = key }
        }
        return .none

      case .borrowShortcutChanged(let hotKey):
        let id = state.workspaceId
        state.$config.withLock { config in
          config.mutateWorkspace(id) { $0.borrowShortcut = hotKey }
        }
        return .none

      case .borrowEdgeChanged(let edge):
        let id = state.workspaceId
        state.$config.withLock { config in
          config.mutateWorkspace(id) { $0.borrowEdge = edge }
        }
        return .none

      case .borrowFractionChanged(let fraction):
        let id = state.workspaceId
        state.$config.withLock { config in
          config.mutateWorkspace(id) { $0.borrowFraction = fraction }
        }
        return .none

      case .shortcutRecordingChanged(let recording):
        return .run { [hotKeys] _ in await hotKeys.setRecording(recording) }
      }
    }
    .ifLet(\.$alert, action: \.alert)
  }
}
