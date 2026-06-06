import ComposableArchitecture
import Foundation
import Sharing

/// Sidebar listing of the active profile's workspaces, plus the "Shared"
/// entry — presented like a special workspace whose apps live in every
/// workspace. Drives add/delete and routes selection into a
/// `WorkspaceDetailFeature` or `SharedAppsFeature` child.
@Reducer
public struct WorkspaceListFeature {
  /// What the sidebar can select: a regular workspace, or the Shared
  /// pseudo-workspace.
  public enum SidebarItem: Equatable, Hashable, Sendable {
    case workspace(Workspace.ID)
    case shared
  }

  @ObservableState
  public struct State: Equatable {
    @Shared(.tatamiConfig) public var config = AppConfig()
    public var selection: SidebarItem?
    public var isAddSheetPresented = false
    public var draftName = ""
    public var detail: WorkspaceDetailFeature.State?
    public var shared: SharedAppsFeature.State?

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
    case sidebarSelected(SidebarItem?)
    case detail(WorkspaceDetailFeature.Action)
    case shared(SharedAppsFeature.Action)
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
        return .send(.sidebarSelected(.workspace(workspace.id)))

      case .addWorkspaceFormCancelled:
        state.isAddSheetPresented = false
        state.draftName = ""
        return .none

      case .workspaceDeleteRequested(let id):
        if state.selection == .workspace(id) {
          state.selection = nil
          state.detail = nil
        }
        state.$config.withLock { config in
          config.mutateActiveProfile { profile in
            profile.workspaces.removeAll { $0.id == id }
          }
        }
        return .none

      case .sidebarSelected(let item):
        state.selection = item
        switch item {
        case .workspace(let id):
          state.detail = WorkspaceDetailFeature.State(workspaceId: id)
          state.shared = nil
        case .shared:
          state.detail = nil
          state.shared = SharedAppsFeature.State()
        case nil:
          state.detail = nil
          state.shared = nil
        }
        return .none

      case .detail, .shared, .binding:
        return .none
      }
    }
    .ifLet(\.detail, action: \.detail) {
      WorkspaceDetailFeature()
    }
    .ifLet(\.shared, action: \.shared) {
      SharedAppsFeature()
    }
  }
}
