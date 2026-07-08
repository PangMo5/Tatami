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
    /// The layout-preview concern (resolve/edit/persist), owned by its own
    /// reducer.
    public var layout: WorkspaceLayoutFeature.State
    /// One-shot request to scroll the Apps section to an app row (from the
    /// layout preview's "Configure in Apps"). The token distinguishes repeat
    /// requests for the same app so the view's scroll refires.
    public var appScrollRequest: ScrollRequest?
    @Presents public var alert: AlertState<Action.Alert>?

    public struct ScrollRequest: Equatable {
      public var bundleId: String
      public var token: Int
    }

    public init(workspaceId: Workspace.ID) {
      self.workspaceId = workspaceId
      self.layout = WorkspaceLayoutFeature.State(workspaceId: workspaceId)
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
    /// Scroll the Apps section to (and briefly highlight) this app's row.
    case scrollToApp(bundleId: String)
    case layout(WorkspaceLayoutFeature.Action)
    case alert(PresentationAction<Alert>)

    public enum Alert: Equatable {
      case confirmAppRemoval(bundleIdentifier: String)
    }
  }

  @Dependency(\.runningApps) var runningApps
  @Dependency(\.displays) var displays
  @Dependency(\.hotKeys) var hotKeys
  @Dependency(\.appChooser) var appChooser

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Scope(state: \.layout, action: \.layout) { WorkspaceLayoutFeature() }
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .onAppear:
        state.availableDisplays = displays.all()
        return .none

      case .layout:
        // Handled by the layout reducer; AppFeature observes `.layout.delegate`.
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

      case .scrollToApp(let bundleId):
        let token = (state.appScrollRequest?.token ?? 0) + 1
        state.appScrollRequest = State.ScrollRequest(bundleId: bundleId, token: token)
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert)
  }
}
