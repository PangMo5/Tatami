import ComposableArchitecture
import Foundation
import Sharing

/// Sidebar listing of the active profile's workspaces, plus the "Shared"
/// entry — presented like a special workspace whose apps live in every
/// workspace. Drives add/delete and routes selection into a
/// `WorkspaceDetailFeature` or `SharedAppsFeature` child.
@Reducer
public struct WorkspaceListFeature {
  /// What the *content* column (col 2) can select within the selected profile:
  /// the profile's own settings, one of its workspaces, or the Shared apps
  /// pseudo-workspace. The profile itself is picked in the sidebar (col 1) via
  /// `selectedProfileId`.
  public enum SidebarItem: Equatable, Hashable, Sendable {
    case profileSettings
    case workspace(Workspace.ID)
    case shared
  }

  @ObservableState
  public struct State: Equatable {
    @Shared(.tatamiConfig) public var config = AppConfig()
    /// The profile being viewed/edited (col 1) — independent of the *active*
    /// (running) profile, so a non-active profile can be inspected and edited
    /// without switching to it. nil falls back to the active/first profile.
    public var selectedProfileId: Profile.ID?
    /// The content-column (col 2) selection within the selected profile.
    public var selection: SidebarItem?
    public var isAddSheetPresented = false
    public var draftName = ""
    public var detail: WorkspaceDetailFeature.State?
    public var shared: SharedAppsFeature.State?
    /// Profile settings shown in the detail pane (like `detail` for a workspace).
    public var profileDetail: ProfileDetailFeature.State?
    @Presents public var alert: AlertState<Action.Alert>?

    public init() {}

    /// The profile whose contents col 2 lists — the selected one, falling back
    /// to the active/first when nothing is selected yet.
    public var selectedProfileResolvedId: Profile.ID? {
      selectedProfileId ?? config.activeProfileId ?? config.profiles.first?.id
    }

    public var selectedProfile: Profile? {
      guard let id = selectedProfileResolvedId else { return nil }
      return config.profiles.first { $0.id == id }
    }

    public var workspaces: IdentifiedArrayOf<Workspace> {
      selectedProfile?.workspaces ?? []
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
    /// First render: highlight the active profile in col 1 without opening its
    /// settings (leaves the detail column empty until the user picks something).
    case sidebarAppeared
    // Profiles — the sidebar column (col 1); selecting one switches which
    // profile col 2 lists, without activating it.
    case profileSelected(Profile.ID?)
    case newProfileButtonTapped
    case duplicateProfileTapped(Profile.ID)
    case deleteProfileRequested(Profile.ID)
    case profilesReordered(IndexSet, Int)
    case detail(WorkspaceDetailFeature.Action)
    case shared(SharedAppsFeature.Action)
    case profileDetail(ProfileDetailFeature.Action)
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
        guard !trimmed.isEmpty, let profileId = state.selectedProfileResolvedId
        else { return .none }
        // Default to static: pin new workspaces to the current display so
        // multi-monitor placement is predictable (workspace ↔ monitor). The
        // user can switch a workspace back to Dynamic in its Display picker.
        let workspace = Workspace(name: trimmed, displayHint: displays.current())
        state.$config.withLock { config in
          config.mutateProfile(profileId) { $0.workspaces.append(workspace) }
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
          guard let profileId = config.profileId(owning: id) else { return }
          config.mutateProfile(profileId) { profile in
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
        // If the viewed profile was the one deleted, move the sidebar selection
        // to the new first profile so col 2 / col 3 don't dangle.
        if state.selectedProfileResolvedId == id || state.selectedProfileId == id {
          let fallback = state.config.profiles.first?.id
          state.selectedProfileId = fallback
          state.selection = fallback == nil ? nil : .profileSettings
          state.profileDetail = fallback.map { ProfileDetailFeature.State(profileId: $0) }
          state.detail = nil
          state.shared = nil
        }
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
        let profileId = state.selectedProfileResolvedId
        state.$config.withLock { config in
          config.placeWorkspace(draggedId, kind: kind, relativeTo: target, after: after, in: profileId)
        }
        return .none

      case .sidebarAppeared:
        if state.selectedProfileId == nil {
          state.selectedProfileId = state.selectedProfileResolvedId
        }
        return .none

      case .profileSelected(let id):
        // Switching the viewed profile resets the content column to that
        // profile's settings; it does *not* activate the profile.
        state.selectedProfileId = id
        return .send(.sidebarSelected(.profileSettings))

      case .sidebarSelected(let item):
        state.selection = item
        switch item {
        case .profileSettings:
          state.profileDetail = state.selectedProfileResolvedId
            .map { ProfileDetailFeature.State(profileId: $0) }
          state.detail = nil
          state.shared = nil
        case .workspace(let id):
          state.detail = WorkspaceDetailFeature.State(workspaceId: id)
          state.shared = nil
          state.profileDetail = nil
        case .shared:
          state.detail = nil
          state.shared = SharedAppsFeature.State()
          state.profileDetail = nil
        case nil:
          state.detail = nil
          state.shared = nil
          state.profileDetail = nil
        }
        return .none

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
        // Create an empty profile and open its detail so it's named + configured
        // there. It doesn't become active until "Activate" in the detail.
        let profile = Profile(name: "New Profile")
        state.$config.withLock { $0.profiles.append(profile) }
        return .send(.profileSelected(profile.id))

      case let .profilesReordered(source, destination):
        // Order matters: `activeProfile` falls back to the first, and an
        // auto-activation tie breaks toward the earlier profile.
        state.$config.withLock { $0.profiles.move(fromOffsets: source, toOffset: destination) }
        return .none

      // Profile detail bubbles its side-effecting ops up (switch → AppFeature,
      // delete → the confirm alert here, edits → hotkey rebind).
      case .profileDetail(.delegate(.activateProfile(let id))):
        return .send(.delegate(.activateProfile(id)))
      case .profileDetail(.delegate(.profilesChanged)):
        return .send(.delegate(.profilesChanged))

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

      case .detail, .shared, .binding, .delegate, .profileDetail:
        return .none
      }
    }
    .ifLet(\.detail, action: \.detail) {
      WorkspaceDetailFeature()
    }
    .ifLet(\.shared, action: \.shared) {
      SharedAppsFeature()
    }
    .ifLet(\.profileDetail, action: \.profileDetail) {
      ProfileDetailFeature()
    }
    .ifLet(\.$alert, action: \.alert)
  }
}
