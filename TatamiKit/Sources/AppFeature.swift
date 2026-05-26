import ComposableArchitecture
import Foundation

/// Top-level reducer. Composes the feature reducers that make up the
/// Tatami app and routes global hotkey events to the right child.
@Reducer
public struct AppFeature {
  @ObservableState
  public struct State: Equatable {
    public var workspaceList = WorkspaceListFeature.State()
    public var activation = WorkspaceActivationFeature.State()
    public var hotKeys = HotKeysFeature.State()
    public var cli = CLIServerFeature.State()
    public init() {}
  }

  public enum Action {
    case task
    case workspaceList(WorkspaceListFeature.Action)
    case activation(WorkspaceActivationFeature.Action)
    case hotKeys(HotKeysFeature.Action)
    case cli(CLIServerFeature.Action)
  }

  @Dependency(\.focusManager) var focusManager

  public init() {}

  public var body: some ReducerOf<Self> {
    Scope(state: \.workspaceList, action: \.workspaceList) {
      WorkspaceListFeature()
    }
    Scope(state: \.activation, action: \.activation) {
      WorkspaceActivationFeature()
    }
    Scope(state: \.hotKeys, action: \.hotKeys) {
      HotKeysFeature()
    }
    Scope(state: \.cli, action: \.cli) {
      CLIServerFeature()
    }
    Reduce { state, action in
      switch action {
      case .task:
        return .merge(
          .send(.hotKeys(.onAppear)),
          .send(.cli(.start))
        )

      case .hotKeys(.actionTriggered(let hotKeyAction)):
        return route(hotKeyAction, state: state)

      case .workspaceList(.addWorkspaceFormSubmitted),
           .workspaceList(.workspaceDeleteRequested),
           .workspaceList(.detail(.activateShortcutChanged)):
        return .send(.hotKeys(.refreshBindings))

      default:
        return .none
      }
    }
  }

  private func route(_ action: HotKeyAction, state: State) -> Effect<Action> {
    switch action {
    case .activateWorkspace(let id):
      return .send(.activation(.activate(workspaceId: id, setFocus: true)))
    case .moveFocusedWindowToWorkspace(let id):
      return .send(.activation(.moveFocusedAppTo(workspaceId: id)))
    case .switchToNextWorkspace:
      return .send(.activation(.activateNext))
    case .switchToPreviousWorkspace:
      return .send(.activation(.activatePrevious))
    case .switchToRecentWorkspace:
      return .send(.activation(.activateRecent))

    case .focusLeft:
      return .run { [client = focusManager] _ in await client.moveFocus(.left) }
    case .focusRight:
      return .run { [client = focusManager] _ in await client.moveFocus(.right) }
    case .focusUp:
      return .run { [client = focusManager] _ in await client.moveFocus(.up) }
    case .focusDown:
      return .run { [client = focusManager] _ in await client.moveFocus(.down) }

    case .cycleNextWindow:
      let bundleIds = currentWorkspaceBundleIds(state)
      return .run { [client = focusManager] _ in
        await client.cycleApp(.next, bundleIds)
      }
    case .cyclePreviousWindow:
      let bundleIds = currentWorkspaceBundleIds(state)
      return .run { [client = focusManager] _ in
        await client.cycleApp(.previous, bundleIds)
      }

    case .toggleFloating:
      return .send(.activation(.toggleFloatingOnFocusedApp))
    case .toggleSpaceActivated:
      return .send(.activation(.togglePaused))

    case .resizeGrow:
      return .send(.activation(.bspResize(axis: .vertical, delta: 0.05)))
    case .resizeShrink:
      return .send(.activation(.bspResize(axis: .vertical, delta: -0.05)))
    case .swapLeft:
      return .send(.activation(.bspSwap(.left)))
    case .swapRight:
      return .send(.activation(.bspSwap(.right)))
    case .swapUp:
      return .send(.activation(.bspSwap(.left)))
    case .swapDown:
      return .send(.activation(.bspSwap(.right)))
    case .toggleOrientation:
      return .send(.activation(.bspToggleOrientation))

    // Fullscreen (BSP zoom overlay) is a frame-overlay concern that
    // doesn't mutate the tree — defer to a later phase.
    case .toggleFullscreen:
      return .none
    }
  }

  private func currentWorkspaceBundleIds(_ state: State) -> [String] {
    guard let id = state.activation.primaryActiveWorkspaceID,
          let ws = state.workspaceList.config.activeProfile?
            .workspaces.first(where: { $0.id == id })
    else { return [] }
    return ws.apps.map(\.bundleIdentifier)
  }
}
