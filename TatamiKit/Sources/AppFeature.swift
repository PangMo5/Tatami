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
    case tileCompleted
  }

  @Dependency(\.windowTiler) var windowTiler

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
        return route(hotKeyAction)

      case .workspaceList(.addWorkspaceFormSubmitted),
           .workspaceList(.workspaceDeleteRequested),
           .workspaceList(.detail(.activateShortcutChanged)):
        return .send(.hotKeys(.refreshBindings))

      case .activation(.activationCompleted(let workspaceId, let display)):
        guard
          let workspace = state.workspaceList.config.activeProfile?
            .workspaces.first(where: { $0.id == workspaceId })
        else { return .none }
        let request = TilingRequest(
          workspaceId: workspace.id,
          mode: workspace.tilingMode,
          bundleIdentifiers: workspace.apps.map(\.bundleIdentifier),
          targetDisplay: display
        )
        return .run { [client = windowTiler] send in
          await client.tile(request)
          await send(.tileCompleted)
        }

      case .tileCompleted:
        return .none

      default:
        return .none
      }
    }
  }

  private func route(_ action: HotKeyAction) -> Effect<Action> {
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
    // Remaining BSP / focus / mouse actions land in upcoming phases.
    case .focusLeft, .focusRight, .focusUp, .focusDown,
         .cycleNextWindow, .cyclePreviousWindow,
         .resizeGrow, .resizeShrink,
         .swapLeft, .swapRight, .swapUp, .swapDown,
         .toggleOrientation, .toggleFullscreen,
         .toggleFloating, .toggleSpaceActivated:
      return .none
    }
  }
}
