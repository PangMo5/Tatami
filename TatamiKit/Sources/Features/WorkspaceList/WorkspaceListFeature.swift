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
    /// Drives the profile name sheet (create / rename); nil = hidden.
    public var profileSheet: ProfileSheet?
    public var profileDraftName = ""
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

  /// Which profile the name sheet is editing.
  public enum ProfileSheet: Equatable {
    case new
    case rename(Profile.ID)
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
    // Profiles — a list in the sidebar with a per-profile context menu.
    case profileSelected(Profile.ID)
    case newProfileButtonTapped
    case duplicateProfileTapped(Profile.ID)
    case renameProfileTapped(Profile.ID)
    case profileSheetSubmitted
    case profileSheetCancelled
    case deleteProfileRequested(Profile.ID)
    case detail(WorkspaceDetailFeature.Action)
    case shared(SharedAppsFeature.Action)
    case alert(PresentationAction<Alert>)
    case binding(BindingAction<State>)
    case delegate(Delegate)

    public enum Alert: Equatable {
      case confirmDeletion(Workspace.ID)
      case confirmProfileDeletion(Profile.ID)
    }

    /// Profile side effects the parent (AppFeature) owns: switching drives
    /// re-activation + hotkey rebind + HUD; any structural change re-registers
    /// hotkeys.
    public enum Delegate: Equatable {
      case activateProfile(Profile.ID)
      case profilesChanged
    }
  }

  @Dependency(\.displays) var displays
  @Dependency(\.layoutStore) var layoutStore

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
        // Drop the saved layout too, so layouts.json doesn't accumulate orphaned
        // entries (the delete confirmation promises the layout is removed).
        return .run { [layoutStore] _ in layoutStore.clear(id) }

      case .alert(.presented(.confirmProfileDeletion(let id))):
        // Clear the deleted profile's workspace layouts, then remove it. If it
        // was the active one, switch to the new first profile.
        let wsIds = state.config.profiles.first(where: { $0.id == id })?.workspaces.map(\.id) ?? []
        let wasActive = (state.config.activeProfileId ?? state.config.profiles.first?.id) == id
        state.$config.withLock { $0.profiles.removeAll { $0.id == id } }
        let switchAway: Effect<Action> = wasActive
          ? (state.config.profiles.first.map { .send(.delegate(.activateProfile($0.id))) }
            ?? .send(.delegate(.profilesChanged)))
          : .send(.delegate(.profilesChanged))
        return .merge(
          .run { [layoutStore] _ in for wsId in wsIds { layoutStore.clear(wsId) } },
          switchAway
        )

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

      case .profileSelected(let id):
        return .send(.delegate(.activateProfile(id)))

      case .duplicateProfileTapped(let id):
        let remap = state.$config.withLock { $0.duplicateProfile(id) }
        guard !remap.isEmpty else { return .none }
        return .merge(
          .send(.delegate(.profilesChanged)),
          // Copy each source workspace's saved layout onto its fresh id so the
          // clone opens identical (layouts are keyed by workspace id).
          .run { [layoutStore] _ in
            for (old, new) in remap {
              if let snapshot = await layoutStore.load(old) { layoutStore.save(new, snapshot) }
            }
          }
        )

      case .newProfileButtonTapped:
        state.profileSheet = .new
        state.profileDraftName = ""
        return .none

      case .renameProfileTapped(let id):
        state.profileSheet = .rename(id)
        state.profileDraftName = state.config.profiles.first(where: { $0.id == id })?.name ?? ""
        return .none

      case .profileSheetSubmitted:
        let trimmed = state.profileDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sheet = state.profileSheet
        state.profileSheet = nil
        state.profileDraftName = ""
        guard !trimmed.isEmpty else { return .none }
        switch sheet {
        case .new:
          // Create with the entered name and switch to it so ⌘N fills it out.
          let profile = Profile(name: trimmed)
          state.$config.withLock { $0.profiles.append(profile) }
          return .send(.delegate(.activateProfile(profile.id)))
        case .rename(let id):
          state.$config.withLock { config in
            if let idx = config.profiles.firstIndex(where: { $0.id == id }) {
              config.profiles[idx].name = trimmed
            }
          }
          return .send(.delegate(.profilesChanged))
        case nil:
          return .none
        }

      case .profileSheetCancelled:
        state.profileSheet = nil
        state.profileDraftName = ""
        return .none

      case .deleteProfileRequested(let id):
        // Keep at least one profile; the delete option is hidden past that too.
        guard state.config.profiles.count > 1,
              let name = state.config.profiles.first(where: { $0.id == id })?.name
        else { return .none }
        state.alert = AlertState {
          TextState("Delete profile \"\(name)\"?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmProfileDeletion(id)) {
            TextState("Delete")
          }
          ButtonState(role: .cancel) { TextState("Cancel") }
        } message: {
          TextState("This removes the profile and all its workspaces, assignments, and layouts. This can't be undone.")
        }
        return .none

      case .detail, .shared, .binding, .delegate:
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
