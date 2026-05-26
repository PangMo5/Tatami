import ComposableArchitecture
import Foundation
import Sharing

/// Lists the workspaces of the currently active profile and drives
/// create/delete/select side effects against the shared config.
///
/// The `@Shared(.tatamiConfig)` binding is the single source of truth —
/// reads observe the on-disk TOML, writes flush back to disk via the
/// Sharing file-storage strategy.
@Reducer
public struct WorkspaceListFeature {
  @ObservableState
  public struct State: Equatable {
    @Shared(.tatamiConfig) public var config = AppConfig()
    public var selectedWorkspaceID: Workspace.ID?
    public var isAddSheetPresented = false
    public var draftName = ""

    public init() {}

    public var workspaces: [Workspace] {
      config.activeProfile?.workspaces ?? []
    }
  }

  public enum Action: BindableAction {
    case addWorkspaceButtonTapped
    case addWorkspaceFormSubmitted
    case addWorkspaceFormCancelled
    case workspaceDeleteRequested(Workspace.ID)
    case workspaceSelected(Workspace.ID?)
    case binding(BindingAction<State>)
  }

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .addWorkspaceButtonTapped:
        state.draftName = ""
        state.isAddSheetPresented = true
        return .none

      case .addWorkspaceFormSubmitted:
        let trimmed = state.draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        state.isAddSheetPresented = false
        state.draftName = ""
        guard !trimmed.isEmpty else { return .none }
        let workspace = Workspace(name: trimmed)
        state.$config.withLock { config in
          config.mutateActiveProfile { $0.workspaces.append(workspace) }
        }
        return .none

      case .addWorkspaceFormCancelled:
        state.isAddSheetPresented = false
        state.draftName = ""
        return .none

      case .workspaceDeleteRequested(let id):
        if state.selectedWorkspaceID == id {
          state.selectedWorkspaceID = nil
        }
        state.$config.withLock { config in
          config.mutateActiveProfile { profile in
            profile.workspaces.removeAll { $0.id == id }
          }
        }
        return .none

      case .workspaceSelected(let id):
        state.selectedWorkspaceID = id
        return .none

      case .binding:
        return .none
      }
    }
  }
}
