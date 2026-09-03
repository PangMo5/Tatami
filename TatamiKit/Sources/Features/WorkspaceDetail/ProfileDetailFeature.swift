// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation

/// Settings for one profile, shown in the detail pane when a profile row is
/// selected in the sidebar (mirrors `WorkspaceDetailFeature`). Selecting a
/// profile *edits* it here; switching to it is the explicit "Activate" button.
@Reducer
public struct ProfileDetailFeature {

  // MARK: Lifecycle

  public init() { }

  // MARK: Public

  @ObservableState
  public struct State: Equatable {

    // MARK: Lifecycle

    public init(profileId: Profile.ID) {
      self.profileId = profileId
    }

    // MARK: Public

    @Shared(.tatamiConfig) public var config
    public var profileId: Profile.ID
    /// Displays offered in the auto-activation editor: currently connected plus
    /// any referenced by a workspace's `displayHint`. Loaded on appear.
    public var availableDisplays = [DisplayName]()
    @Presents public var alert: AlertState<Action.Alert>?

    public var profile: Profile? {
      config.profiles.first { $0.id == profileId }
    }

    /// The active (running) profile — distinct from the selected/edited one.
    public var isActive: Bool {
      (config.activeProfileId ?? config.profiles.first?.id) == profileId
    }

    /// How this profile's auto-activation rule overlaps the other profiles'.
    public var autoActivationDiagnostic: ProfileActivationDiagnostic {
      config.autoActivationDiagnostic(for: profileId)
    }

    /// Conflict title for the profile switch shortcut (this profile excluded).
    public func shortcutConflict(for candidate: HotKey) -> String? {
      config.shortcutConflictAcrossProfiles(
        for: candidate,
        excluding: .activateProfile(profileId),
      )
    }

  }

  public enum Action: BindableAction {
    case onAppear
    case nameChanged(String)
    case symbolIconChanged(String?)
    case shortcutChanged(HotKey?)
    case shortcutRecordingChanged(Bool)
    case autoActivationChanged(ProfileActivation?)
    case saveWorkspaceChain(
      original: WorkspaceChain?,
      updated: WorkspaceChain,
    )
    case deleteWorkspaceChainRequested(WorkspaceChain)
    case activateTapped
    /// Apply a reviewed sync from `source` into this profile — the excluded
    /// maps carry the app bundle ids / field ids the user unchecked, per
    /// target workspace.
    case applyProfileSync(
      target: Profile.ID,
      source: Profile.ID,
      baseline: AppConfig,
      excludedApps: [Workspace.ID: Set<String>],
      excludedFields: [Workspace.ID: Set<String>],
    )
    case binding(BindingAction<State>)
    case delegate(Delegate)
    case alert(PresentationAction<Alert>)

    // MARK: Public

    public enum Alert: Equatable {
      case dismissConfigurationChanged
      case dismissCopyFailure
      case dismissShortcutConflicts
      case dismissWorkspaceChainConflict
      case confirmWorkspaceChainDeletion(WorkspaceChain)
    }

    public enum Delegate: Equatable {
      case activateProfile(Profile.ID)
      /// A structural edit (name / shortcut / rule / app sync) — parent rebinds.
      case profilesChanged
    }
  }

  public var body: some ReducerOf<Self> {
    CombineReducers {
      BindingReducer()
      Reduce { state, action in
        switch action {
        case .onAppear:
          // Connected displays + any pinned-to by a workspace, de-duplicated.
          let liveDisplays = displays.all()
          var seen = Set<DisplayName>()
          var out = [DisplayName]()
          func add(_ d: DisplayName) {
            if seen.insert(d).inserted { out.append(d) }
          }
          liveDisplays.forEach(add)
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

        case .symbolIconChanged(let symbol):
          // Cosmetic: the @Shared write re-renders the sidebar / menu bar; no
          // hotkey rebind needed.
          mutate(state) { $0.symbolIconName = symbol }
          return .none

        case .shortcutChanged(let hotKey):
          mutate(state) { $0.shortcut = hotKey }
          return .send(.delegate(.profilesChanged))

        case .shortcutRecordingChanged(let recording):
          return .run { [hotKeys] _ in await hotKeys.setRecording(recording) }

        case .autoActivationChanged(let rule):
          mutate(state) { $0.autoActivation = rule }
          return .send(.delegate(.profilesChanged))

        case .saveWorkspaceChain(let original, var chain):
          guard var profile = state.profile else { return .none }
          let trimmedName = chain.name?.trimmingCharacters(in: .whitespacesAndNewlines)
          chain.name = trimmedName?.isEmpty == false ? trimmedName : nil
          chain.normalizeDynamicWorkspaceIDs()

          if let original {
            guard let index = profile.workspaceChains.firstIndex(of: original) else {
              state.alert = workspaceChainConflictAlert()
              return .none
            }
            let otherIDs = Set(profile.workspaceChains.enumerated().compactMap { offset, existing in
              offset == index ? nil : existing.id
            })
            while otherIDs.contains(chain.id) { chain.id = uuid() }
            profile.workspaceChains[index] = chain
          } else {
            let existingIDs = Set(profile.workspaceChains.map(\.id))
            while existingIDs.contains(chain.id) { chain.id = uuid() }
            profile.workspaceChains.append(chain)
          }

          let invalid = profile.validateWorkspaceChains().issues.contains {
            $0.affectedChainIDs.contains(chain.id)
          }
          guard !invalid else {
            state.alert = workspaceChainConflictAlert()
            return .none
          }
          mutate(state) { $0 = profile }
          return .send(.delegate(.profilesChanged))

        case .deleteWorkspaceChainRequested(let chain):
          guard state.profile?.workspaceChains.contains(chain) == true else { return .none }
          let name = workspaceChainName(chain)
          state.alert = AlertState {
            TextState("Delete workspace chain?")
          } actions: {
            ButtonState(role: .destructive, action: .confirmWorkspaceChainDeletion(chain)) {
              TextState("Delete")
            }
            ButtonState(role: .cancel) {
              TextState("Cancel")
            }
          } message: {
            TextState(
              "“\(name)” will stop switching its linked workspaces together. This can't be undone."
            )
          }
          return .none

        case .alert(.presented(.confirmWorkspaceChainDeletion(let chain))):
          guard state.profile?.workspaceChains.contains(chain) == true else { return .none }
          mutate(state) { profile in
            guard let index = profile.workspaceChains.firstIndex(of: chain) else { return }
            profile.workspaceChains.remove(at: index)
          }
          return .send(.delegate(.profilesChanged))

        case .activateTapped:
          return .send(.delegate(.activateProfile(state.profileId)))

        case .applyProfileSync(let target, let source, let baseline, let excludedApps, let excludedFields):
          guard
            state.profileId == target,
            let projection = baseline.profileSyncProjection(
              into: target,
              from: source,
              excludedAppsByWorkspace: excludedApps,
              excludedFieldsByWorkspace: excludedFields,
            )
          else {
            state.alert = configurationChangedAlert()
            return .none
          }
          guard projection.conflicts.isEmpty else {
            state.alert = shortcutConflictAlert(projection.conflicts)
            return .none
          }

          do {
            let revision = try configPersistence.captureRevision(baseline)
            try configPersistence.commit(
              state.$config,
              baseline,
              revision,
              projection.config,
              { true },
            )
            return .send(.delegate(.profilesChanged))
          } catch {
            state.alert = isStaleReview(error)
              ? configurationChangedAlert()
              : copyFailedAlert(error)
            return .none
          }

        case .alert,
             .binding,
             .delegate:
          return .none
        }
      }
    }
    .ifLet(\.$alert, action: \.alert)
  }

  // MARK: Internal

  @Dependency(\.hotKeys) var hotKeys
  @Dependency(\.displays) var displays
  @Dependency(\.configPersistence) var configPersistence
  @Dependency(\.uuid) var uuid

  // MARK: Private

  private func configurationChangedAlert() -> AlertState<Action.Alert> {
    AlertState {
      TextState("Configuration changed")
    } actions: {
      ButtonState(role: .cancel, action: .dismissConfigurationChanged) {
        TextState("OK")
      }
    } message: {
      TextState(
        "Nothing was copied because the configuration changed while the review was open. Reopen Copy and review the latest changes."
      )
    }
  }

  private func copyFailedAlert(_ error: any Error) -> AlertState<Action.Alert> {
    AlertState {
      TextState("Copy failed")
    } actions: {
      ButtonState(role: .cancel, action: .dismissCopyFailure) {
        TextState("OK")
      }
    } message: {
      TextState(ErrorReportClient.describe(error))
    }
  }

  private func isStaleReview(_ error: any Error) -> Bool {
    guard let error = error as? ConfigPersistenceError else { return false }
    return switch error {
    case .changedInMemory,
         .changedOnDisk,
         .transactionExpired:
      true
    case .outcomeUnknown:
      false
    }
  }

  private func shortcutConflictAlert(
    _ conflicts: [WorkspaceShortcutConflict]
  ) -> AlertState<Action.Alert> {
    let descriptions = Set(conflicts.map { "\($0.hotKey.symbols): \($0.owner)" })
      .sorted()
      .formatted()
    return AlertState {
      TextState("Shortcut conflicts")
    } actions: {
      ButtonState(role: .cancel, action: .dismissShortcutConflicts) {
        TextState("OK")
      }
    } message: {
      TextState(
        "Nothing was copied. Deselect the conflicting shortcut changes and try again: \(descriptions)"
      )
    }
  }

  private func workspaceChainConflictAlert() -> AlertState<Action.Alert> {
    AlertState {
      TextState("Workspace chain conflict")
    } actions: {
      ButtonState(role: .cancel, action: .dismissWorkspaceChainConflict) {
        TextState("OK")
      }
    } message: {
      TextState(
        "The chain was not saved because one of its workspaces conflicts with another chain or is unavailable. Review the latest profile settings and try again."
      )
    }
  }

  private func workspaceChainName(_ chain: WorkspaceChain) -> String {
    let name = chain.name?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let name, !name.isEmpty { return name }
    return String(localized: "Untitled Workspace Chain")
  }

  private func mutate(_ state: State, _ body: (inout Profile) -> Void) {
    state.$config.withLock { config in
      guard let idx = config.profiles.firstIndex(where: { $0.id == state.profileId }) else { return }
      body(&config.profiles[idx])
    }
  }

}
