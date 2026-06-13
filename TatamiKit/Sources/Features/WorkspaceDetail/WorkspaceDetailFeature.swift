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
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case onAppear
    case addAppButtonTapped
    case appPickerDismissed
    case appPickerAppSelected(MacApp)
    case appRemoveRequested(bundleIdentifier: String)
    case autoOpenToggled(bundleIdentifier: String, isOn: Bool)
    case floatingToggled(bundleIdentifier: String, isOn: Bool)
    case nameSubmitted(String)
    case symbolIconChanged(String?)
    case activateShortcutChanged(HotKey?)
    case assignAppShortcutChanged(HotKey?)
    case appToFocusChanged(String?)
    case displayHintChanged(DisplayName?)
    case tilingMemoryChanged(TilingMemory?)
    case refreshDisplays
    /// A shortcut recorder started (`true`) / stopped (`false`) capturing.
    case shortcutRecordingChanged(Bool)
  }

  @Dependency(\.runningApps) var runningApps
  @Dependency(\.displays) var displays
  @Dependency(\.hotKeys) var hotKeys

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .onAppear:
        state.availableDisplays = displays.all()
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

      case .appRemoveRequested(let bundleId):
        let id = state.workspaceId
        state.$config.withLock { config in
          config.mutateWorkspace(id) { workspace in
            workspace.apps.removeAll { $0.bundleIdentifier == bundleId }
          }
        }
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

      case .floatingToggled(let bundleId, let isOn):
        let id = state.workspaceId
        state.$config.withLock { config in
          config.mutateWorkspace(id) { workspace in
            guard let idx = workspace.apps.firstIndex(where: { $0.bundleIdentifier == bundleId })
            else { return }
            workspace.apps[idx].floating = isOn
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

      case .tilingMemoryChanged(let memory):
        let id = state.workspaceId
        state.$config.withLock { config in
          config.mutateWorkspace(id) { $0.tilingMemory = memory }
        }
        return .none

      case .shortcutRecordingChanged(let recording):
        return .run { [hotKeys] _ in await hotKeys.setRecording(recording) }
      }
    }
  }
}
