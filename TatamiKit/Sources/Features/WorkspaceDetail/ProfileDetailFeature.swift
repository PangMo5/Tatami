import ComposableArchitecture
import Foundation

/// Settings for one profile, shown in the detail pane when a profile row is
/// selected in the sidebar (mirrors `WorkspaceDetailFeature`). Selecting a
/// profile *edits* it here; switching to it is the explicit "Activate" button.
@Reducer
public struct ProfileDetailFeature {
  @ObservableState
  public struct State: Equatable {
    @Shared(.tatamiConfig) public var config = AppConfig()
    public var profileId: Profile.ID
    /// Displays offered in the auto-activation editor: currently connected plus
    /// any referenced by a workspace's `displayHint`. Loaded on appear.
    public var availableDisplays: [DisplayName] = []

    public init(profileId: Profile.ID) {
      self.profileId = profileId
    }

    public var profile: Profile? { config.profiles.first { $0.id == profileId } }

    /// The active (running) profile — distinct from the selected/edited one.
    public var isActive: Bool {
      (config.activeProfileId ?? config.profiles.first?.id) == profileId
    }

    /// Conflict title for the profile switch shortcut (this profile excluded).
    public func shortcutConflict(for candidate: HotKey) -> String? {
      config.shortcutConflict(for: candidate, excluding: .activateProfile(profileId))
    }
  }

  public enum Action: BindableAction {
    case onAppear
    case nameChanged(String)
    case shortcutChanged(HotKey?)
    case shortcutRecordingChanged(Bool)
    case autoActivationChanged(ProfileActivation?)
    case activateTapped
    case binding(BindingAction<State>)
    case delegate(Delegate)

    public enum Delegate: Equatable {
      case activateProfile(Profile.ID)
      /// A structural edit (name / shortcut / rule) — parent rebinds hotkeys.
      case profilesChanged
    }
  }

  @Dependency(\.hotKeys) var hotKeys
  @Dependency(\.displays) var displays

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .onAppear:
        // Connected displays + any pinned-to by a workspace, de-duplicated.
        var seen = Set<DisplayName>()
        var out: [DisplayName] = []
        func add(_ d: DisplayName) { if seen.insert(d).inserted { out.append(d) } }
        displays.all().forEach(add)
        for profile in state.config.profiles {
          for ws in profile.workspaces { if let hint = ws.displayHint { add(hint) } }
        }
        state.availableDisplays = out
        return .none

      case .nameChanged(let name):
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        mutate(state) { $0.name = trimmed }
        return .send(.delegate(.profilesChanged))

      case .shortcutChanged(let hotKey):
        mutate(state) { $0.shortcut = hotKey }
        return .send(.delegate(.profilesChanged))

      case .shortcutRecordingChanged(let recording):
        return .run { [hotKeys] _ in await hotKeys.setRecording(recording) }

      case .autoActivationChanged(let rule):
        mutate(state) { $0.autoActivation = rule }
        return .send(.delegate(.profilesChanged))

      case .activateTapped:
        return .send(.delegate(.activateProfile(state.profileId)))

      case .binding, .delegate:
        return .none
      }
    }
  }

  private func mutate(_ state: State, _ body: (inout Profile) -> Void) {
    state.$config.withLock { config in
      guard let idx = config.profiles.firstIndex(where: { $0.id == state.profileId }) else { return }
      body(&config.profiles[idx])
    }
  }
}
