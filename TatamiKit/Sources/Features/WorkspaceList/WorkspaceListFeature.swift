import ComposableArchitecture
import Foundation
import Sharing

/// Sidebar listing of the active profile's workspaces. Drives add/delete
/// and routes selection into a `WorkspaceDetailFeature` child.
@Reducer
public struct WorkspaceListFeature {
  @ObservableState
  public struct State: Equatable {
    @Shared(.tatamiConfig) public var config = AppConfig()
    public var selectedWorkspaceID: Workspace.ID?
    public var isAddSheetPresented = false
    public var draftName = ""
    public var detail: WorkspaceDetailFeature.State?

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
    case detail(WorkspaceDetailFeature.Action)
    case binding(BindingAction<State>)
  }

  @Dependency(\.displays) var displays

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
        // Default to static: pin new workspaces to the current display so
        // multi-monitor placement is predictable (workspace ↔ monitor). The
        // user can switch a workspace back to Dynamic in its Display picker.
        let workspace = Workspace(name: trimmed, displayHint: displays.current())
        state.$config.withLock { config in
          config.mutateActiveProfile { $0.workspaces.append(workspace) }
        }
        return .send(.workspaceSelected(workspace.id))

      case .addWorkspaceFormCancelled:
        state.isAddSheetPresented = false
        state.draftName = ""
        return .none

      case .workspaceDeleteRequested(let id):
        if state.selectedWorkspaceID == id {
          state.selectedWorkspaceID = nil
          state.detail = nil
        }
        state.$config.withLock { config in
          config.mutateActiveProfile { profile in
            profile.workspaces.removeAll { $0.id == id }
          }
        }
        return .none

      case .workspaceSelected(let id):
        state.selectedWorkspaceID = id
        state.detail = id.map(WorkspaceDetailFeature.State.init(workspaceId:))
        return .none

      case .detail, .binding:
        return .none
      }
    }
    .ifLet(\.detail, action: \.detail) {
      WorkspaceDetailFeature()
    }
  }
}
