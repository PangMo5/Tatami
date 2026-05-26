import ComposableArchitecture
import Foundation
import Sharing

/// Tracks which workspace is active per display and dispatches activation
/// requests to `WorkspaceManagerClient`. Future passes will add per-display
/// state, focus history, and transition overlays.
@Reducer
public struct WorkspaceActivationFeature {
  @ObservableState
  public struct State: Equatable {
    @Shared(.tatamiConfig) public var config = AppConfig()
    /// Most recently activated workspace (single-display first pass).
    public var activeWorkspaceID: Workspace.ID?
    public var isActivating = false

    public init() {}
  }

  public enum Action {
    case activate(workspaceId: Workspace.ID, setFocus: Bool)
    case activationCompleted(workspaceId: Workspace.ID)
  }

  @Dependency(\.workspaceManager) var workspaceManager

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .activate(let workspaceId, let setFocus):
        guard let workspace = state.config.activeProfile?.workspaces.first(where: {
          $0.id == workspaceId
        }) else {
          return .none
        }
        guard !state.isActivating else { return .none }
        state.isActivating = true
        let request = ActivationRequest(
          workspace: workspace,
          floatingApps: state.config.floatingApps,
          setFocus: setFocus
        )
        return .run { [client = workspaceManager] send in
          await client.activate(request)
          await send(.activationCompleted(workspaceId: workspaceId))
        }

      case .activationCompleted(let id):
        state.activeWorkspaceID = id
        state.isActivating = false
        return .none
      }
    }
  }
}
