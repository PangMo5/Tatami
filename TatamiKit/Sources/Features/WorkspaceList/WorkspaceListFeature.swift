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
    @Presents public var alert: AlertState<Action.Alert>?

    public init() {}

    public var workspaces: IdentifiedArrayOf<Workspace> {
      config.activeProfile?.workspaces ?? []
    }

    /// Regular workspaces — the "Workspaces" sidebar section.
    public var normalWorkspaces: [Workspace] {
      workspaces.filter { $0.kind != .scratchpad }
    }

    /// Borrow-only workspaces — the separate "Scratchpads" sidebar section.
    public var scratchpadWorkspaces: [Workspace] {
      workspaces.filter { $0.kind == .scratchpad }
    }
  }

  public enum Action: BindableAction {
    case addWorkspaceButtonTapped
    case addWorkspaceFormSubmitted
    case addWorkspaceFormCancelled
    case workspaceDeleteRequested(Workspace.ID)
    case workspaceDropped(
      draggedId: Workspace.ID,
      kind: WorkspaceKind,
      relativeTo: Workspace.ID?,
      after: Bool
    )
    case sidebarSelected(SidebarItem?)
    case detail(WorkspaceDetailFeature.Action)
    case shared(SharedAppsFeature.Action)
    case alert(PresentationAction<Alert>)
    case binding(BindingAction<State>)

    public enum Alert: Equatable {
      case confirmDeletion(Workspace.ID)
    }
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
        guard let name = state.workspaces[id: id]?.name else { return .none }
        state.alert = AlertState {
          TextState("Delete \"\(name)\"?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmDeletion(id)) {
            TextState("Delete")
          }
          ButtonState(role: .cancel) {
            TextState("Cancel")
          }
        } message: {
          TextState("This removes the workspace and its app assignments, shortcuts, and layout. This can't be undone.")
        }
        return .none

      case .alert(.presented(.confirmDeletion(let id))):
        if state.selection == .workspace(id) {
          state.selection = nil
          state.detail = nil
        }
        state.$config.withLock { config in
          config.mutateActiveProfile { profile in
            profile.workspaces.remove(id: id)
          }
        }
        return .none

      case .alert:
        return .none

      case let .workspaceDropped(draggedId, kind, target, after):
        state.$config.withLock { config in
          config.placeWorkspace(draggedId, kind: kind, relativeTo: target, after: after)
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
    .ifLet(\.$alert, action: \.alert)
  }
}
