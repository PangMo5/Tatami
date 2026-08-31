// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Sharing

/// Sidebar listing of the active profile's workspaces, plus the "Shared"
/// entry — presented like a special workspace whose apps live in every
/// workspace. Drives add/delete and routes selection into a
/// `WorkspaceDetailFeature` or `SharedAppsFeature` child.
@Reducer
public struct WorkspaceListFeature {

  // MARK: Lifecycle

  public init() { }

  // MARK: Public

  public enum NameTarget: Equatable, Hashable, Sendable {
    case profile(Profile.ID)
    case workspace(Workspace.ID)
  }

  public struct RenameSession: Equatable, Sendable {
    public init(target: NameTarget, draft: String) {
      self.target = target
      self.draft = draft
    }

    public var draft: String
    public var target: NameTarget
  }

  /// Immutable source data shown by the duplicate chooser. Keeping the
  /// snapshot in reducer state means the eventual clone matches the options
  /// the user reviewed even if config.toml changes while the sheet is open.
  public struct DuplicationReview: Equatable, Identifiable, Sendable {
    public enum Source: Equatable, Sendable {
      case profile(Profile)
      case workspace(Workspace)
    }

    public init(source: Source, baseline: AppConfig) {
      self.source = source
      self.baseline = baseline
    }

    public let baseline: AppConfig
    public let source: Source

    public var id: NameTarget {
      switch source {
      case .profile(let profile): .profile(profile.id)
      case .workspace(let workspace): .workspace(workspace.id)
      }
    }
  }

  /// Stable ids shared by the reducer's selective-copy logic and the
  /// `SyncPreviewSheet` rows in the app target.
  public enum DuplicationOptionID {
    public static let profileIcon = "profile:icon"

    public static func includeWorkspace(_ id: Workspace.ID) -> String {
      "\(id.uuidString):workspace"
    }

    public static func app(_ bundleIdentifier: String, in workspaceID: Workspace.ID) -> String {
      "\(workspaceID.uuidString):app:\(bundleIdentifier)"
    }

    public static func field(_ fieldID: String, in workspaceID: Workspace.ID) -> String {
      "\(workspaceID.uuidString):field:\(fieldID)"
    }

    public static func layout(_ workspaceID: Workspace.ID) -> String {
      "\(workspaceID.uuidString):layout"
    }
  }

  /// Validate a duplicate chooser's entire effective selection and map every
  /// collision back to the source row id shown by `SyncPreviewSheet`.
  public static func duplicationShortcutConflicts(
    review: DuplicationReview,
    excluding excludedItemIDs: Set<String>
  ) -> [String: [WorkspaceShortcutConflict]] {
    guard let pending = prepareDuplication(
      review: review,
      excluding: excludedItemIDs,
      selectionRevision: 0
    ) else { return [:] }
    var result = [String: [WorkspaceShortcutConflict]]()
    for conflict in pending.updated.shortcutCopyConflicts(
      for: pending.shortcutSelections,
      comparedTo: pending.baseline
    ) {
      guard let itemID = pending.shortcutItemIDs[conflict.selection] else { continue }
      result[itemID, default: []].append(conflict)
    }
    return result
  }

  public struct DuplicationPreparation: Equatable, Sendable {
    var baseline: AppConfig
    var configRevision: Data?
    var updated: AppConfig
    var target: NameTarget
    var newWorkspaceIDs: [Workspace.ID]
    var selectionRevision: UInt64
    var layoutCopied: Bool
    var shortcutSelections = Set<WorkspaceShortcutSelection>()
  }

  /// What the sidebar column (col 1) can select: a profile (whose contents fill
  /// col 2), or the global Shared Apps entry (profile-independent, so it lives
  /// in col 1 rather than under any one profile).
  public enum SidebarTop: Equatable, Hashable, Sendable {
    case profile(Profile.ID)
    case shared
  }

  /// What the *content* column (col 2) can select within the selected profile:
  /// the profile's own settings or one of its workspaces.
  public enum SidebarItem: Equatable, Hashable, Sendable {
    case profileSettings
    case workspace(Workspace.ID)
  }

  @ObservableState
  public struct State: Equatable {

    // MARK: Lifecycle

    public init() { }

    // MARK: Public

    @Shared(.tatamiConfig) public var config
    /// The sidebar (col 1) selection — a profile being viewed/edited, or the
    /// global Shared Apps. Independent of the *active* (running) profile, so a
    /// non-active profile can be inspected and edited without switching to it.
    public var topSelection: SidebarTop?
    /// The content-column (col 2) selection within the selected profile.
    public var selection: SidebarItem?
    public var isAddSheetPresented = false
    public var draftName = ""
    /// A sidebar rename is persisted only on Return or blur. Escape discards it.
    public var renameSession: RenameSession?
    /// Source snapshot currently being reviewed before a duplicate is queued.
    public var duplicationReview: DuplicationReview?
    public var detail: WorkspaceDetailFeature.State?
    public var shared: SharedAppsFeature.State?
    /// Profile settings shown in the detail pane (like `detail` for a workspace).
    public var profileDetail: ProfileDetailFeature.State?
    @Presents public var alert: AlertState<Action.Alert>?

    /// The profile selected in col 1, or nil when Shared Apps (or nothing) is.
    public var selectedProfileId: Profile.ID? {
      if case .profile(let id) = topSelection { return id }
      return nil
    }

    /// Whether col 1's global Shared Apps entry is selected.
    public var isViewingShared: Bool {
      topSelection == .shared
    }

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

    // MARK: Internal

    /// Invalidates delayed duplicate-selection completions after any newer
    /// selection intent, so background layout I/O cannot steal navigation.
    var selectionRevision: UInt64 = 0
    var pendingDuplications = [PendingDuplication]()
    var isDuplicationInFlight = false
    /// Includes every confirmed in-flight/queued clone, letting another
    /// chooser opened during layout I/O snapshot the exact baseline it will
    /// follow instead of racing the not-yet-published shared config.
    var projectedDuplicationConfig: AppConfig?

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
      after: Bool,
    )
    case sidebarSelected(SidebarItem?)
    /// First render: highlight the active profile in col 1 without opening its
    /// settings (leaves the detail column empty until the user picks something).
    case sidebarAppeared
    // The sidebar column (col 1): selecting a profile switches which profile
    // col 2 lists (without activating it); selecting shared opens Shared Apps.
    case topSelected(SidebarTop?)
    case newProfileButtonTapped
    case duplicateProfileTapped(Profile.ID)
    case duplicateWorkspaceTapped(Workspace.ID)
    case duplicationReviewConfirmed(excluding: Set<String>)
    case duplicationPrepared(DuplicationPreparation)
    case selectDuplicateIfUnchanged(NameTarget, selectionRevision: UInt64)
    case deleteProfileRequested(Profile.ID)
    case profilesReordered(IndexSet, Int)
    case renameCancelled
    case renameDraftChanged(String)
    case renameRequested(NameTarget)
    case renameSubmitted
    case detail(WorkspaceDetailFeature.Action)
    case shared(SharedAppsFeature.Action)
    case profileDetail(ProfileDetailFeature.Action)
    case alert(PresentationAction<Alert>)
    case binding(BindingAction<State>)
    case delegate(Delegate)

    // MARK: Public

    public enum Alert: Equatable {
      case confirmDeletion(Workspace.ID)
      case confirmProfileDeletion(Profile.ID)
      case dismissShortcutConflicts
    }

    /// Profile side effects the parent (AppFeature) owns: switching drives
    /// re-activation + hotkey rebind + HUD; any structural change re-registers
    /// hotkeys.
    public enum Delegate: Equatable {
      case activateProfile(Profile.ID)
      case activateProfileAfterDeletion(Profile.ID, previousProfile: Profile)
      case profilesChanged
    }
  }

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
        return .run { [layoutStore] _ in await layoutStore.clear(id) }

      case .alert(.presented(.confirmProfileDeletion(let id))):
        // Clear the deleted profile's workspace layouts, then remove it. If it
        // was the active one, switch to the new first profile.
        guard let deletedProfile = state.config.profiles.first(where: { $0.id == id })
        else { return .none }
        let wsIds = deletedProfile.workspaces.map(\.id)
        let wasActive = (state.config.activeProfileId ?? state.config.profiles.first?.id) == id
        state.$config.withLock { $0.profiles.removeAll { $0.id == id } }
        // If the viewed profile was the one deleted, move the sidebar selection
        // to the new first profile so col 2 / col 3 don't dangle.
        if state.selectedProfileId == id || (state.topSelection == nil && wasActive) {
          let fallback = state.config.profiles.first?.id
          state.topSelection = fallback.map { .profile($0) }
          state.selection = fallback == nil ? nil : .profileSettings
          state.profileDetail = fallback.map { ProfileDetailFeature.State(profileId: $0) }
          state.detail = nil
          state.shared = nil
        }
        let switchAway: Effect<Action> = wasActive
          ? (state.config.profiles.first.map {
            .send(.delegate(.activateProfileAfterDeletion(
              $0.id,
              previousProfile: deletedProfile,
            )))
          }
            ?? .send(.delegate(.profilesChanged)))
          : .send(.delegate(.profilesChanged))
        return .merge(
          .run { [layoutStore] _ in
            for wsId in wsIds { await layoutStore.clear(wsId) }
          },
          switchAway,
        )

      case .alert:
        return .none

      case .workspaceDropped(let draggedId, let kind, let target, let after):
        let profileId = state.selectedProfileResolvedId
        state.$config.withLock { config in
          config.placeWorkspace(draggedId, kind: kind, relativeTo: target, after: after, in: profileId)
        }
        return .none

      case .sidebarAppeared:
        if state.topSelection == nil, let id = state.selectedProfileResolvedId {
          state.topSelection = .profile(id)
        }
        return .none

      case .topSelected(let top):
        state.selectionRevision &+= 1
        state.topSelection = top
        switch top {
        case .profile:
          // Switching the viewed profile resets col 2 to that profile's
          // settings; it does *not* activate the profile.
          return .send(.sidebarSelected(.profileSettings))

        case .shared:
          // Shared Apps is global — open its editor in the detail column and
          // clear the profile-scoped col 2 selection.
          state.selection = nil
          state.detail = nil
          state.profileDetail = nil
          state.shared = SharedAppsFeature.State()
          return .none

        case nil:
          state.selection = nil
          state.detail = nil
          state.profileDetail = nil
          state.shared = nil
          return .none
        }

      case .sidebarSelected(let item):
        state.selectionRevision &+= 1
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

        case nil:
          state.detail = nil
          state.shared = nil
          state.profileDetail = nil
        }
        return .none

      case .duplicateProfileTapped(let id):
        let baseline = state.projectedDuplicationConfig ?? state.config
        guard let profile = baseline.profiles.first(where: { $0.id == id })
        else { return .none }
        state.duplicationReview = DuplicationReview(source: .profile(profile), baseline: baseline)
        return .none

      case .duplicateWorkspaceTapped(let id):
        let baseline = state.projectedDuplicationConfig ?? state.config
        guard let workspace = baseline.workspace(id: id) else { return .none }
        state.duplicationReview = DuplicationReview(source: .workspace(workspace), baseline: baseline)

        return .none

      case .duplicationReviewConfirmed(let excludedItemIDs):
        guard
          let review = state.duplicationReview,
          let pending = Self.prepareDuplication(
            review: review,
            excluding: excludedItemIDs,
            selectionRevision: state.selectionRevision,
          )
        else { return .none }
        let conflicts = pending.updated.shortcutCopyConflicts(
          for: pending.shortcutSelections,
          comparedTo: pending.baseline
        )
        guard conflicts.isEmpty else {
          state.alert = shortcutConflictAlert(conflicts)
          return .none
        }
        state.duplicationReview = nil
        state.projectedDuplicationConfig = pending.updated
        state.pendingDuplications.append(pending)
        return startNextDuplication(state: &state)

      case .duplicationPrepared(let preparation):
        state.isDuplicationInFlight = false
        guard preparation.layoutCopied else {
          state.pendingDuplications.removeAll()
          state.projectedDuplicationConfig = nil
          state.duplicationReview = nil
          return .none
        }
        let conflicts = preparation.updated.shortcutCopyConflicts(
          for: preparation.shortcutSelections,
          comparedTo: preparation.baseline
        )
        guard conflicts.isEmpty else {
          state.alert = shortcutConflictAlert(conflicts)
          state.pendingDuplications.removeAll()
          state.projectedDuplicationConfig = nil
          state.duplicationReview = nil
          return clearLayouts(preparation.newWorkspaceIDs)
        }
        do {
          try configPersistence.commit(
            state.$config,
            preparation.baseline,
            preparation.configRevision,
            preparation.updated,
            { true },
          )
        } catch {
          errorReporter.report(
            "Duplication",
            String(localized: "Configuration changed before duplication finished"),
            ErrorReportClient.describe(error),
          )
          state.pendingDuplications.removeAll()
          state.projectedDuplicationConfig = nil
          state.duplicationReview = nil
          if case ConfigPersistenceError.outcomeUnknown = error {
            return .none
          }
          return clearLayouts(preparation.newWorkspaceIDs)
        }
        errorReporter.resolve("Duplication")
        let nextDuplication = startNextDuplication(state: &state)
        return .concatenate(
          .send(.delegate(.profilesChanged)),
          .send(.selectDuplicateIfUnchanged(
            preparation.target,
            selectionRevision: preparation.selectionRevision,
          )),
          nextDuplication,
        )

      case .selectDuplicateIfUnchanged(let target, let selectionRevision):
        guard
          state.selectionRevision == selectionRevision,
          name(for: target, in: state.config) != nil
        else { return .none }
        let revision = state.selectionRevision
        select(target, state: &state)
        // Programmatic selection of one completed duplicate must not invalidate
        // another duplicate the user already queued at the same revision.
        state.selectionRevision = revision
        return .none

      case .newProfileButtonTapped:
        // Create an empty profile and open its detail so it's named + configured
        // there. It doesn't become active until "Activate" in the detail.
        let profile = Profile(name: "New Profile")
        state.$config.withLock { $0.profiles.append(profile) }
        return .send(.topSelected(.profile(profile.id)))

      case .profilesReordered(let source, let destination):
        // Order matters: `activeProfile` falls back to the first, and an
        // auto-activation tie breaks toward the earlier profile.
        state.$config.withLock { $0.profiles.move(fromOffsets: source, toOffset: destination) }
        return .none

      case .renameCancelled:
        state.renameSession = nil
        return .none

      case .renameDraftChanged(let draft):
        state.renameSession?.draft = draft
        return .none

      case .renameRequested(let target):
        if state.renameSession?.target == target { return .none }
        commitRename(state: &state)
        guard let name = name(for: target, in: state.config) else { return .none }
        select(target, state: &state)
        state.renameSession = RenameSession(target: target, draft: name)
        return .none

      case .renameSubmitted:
        commitRename(state: &state)
        return .none

      // Profile detail bubbles its side-effecting ops up (switch → AppFeature,
      // delete → the confirm alert here, edits → hotkey rebind).
      case .profileDetail(.delegate(.activateProfile(let id))):
        return .send(.delegate(.activateProfile(id)))

      case .profileDetail(.delegate(.profilesChanged)):
        return .send(.delegate(.profilesChanged))

      case .deleteProfileRequested(let id):
        // Keep at least one profile; the delete option is hidden past that too.
        guard
          state.config.profiles.count > 1,
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

      case .detail,
           .shared,
           .binding,
           .delegate,
           .profileDetail:
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

  // MARK: Internal

  struct PendingDuplication: Equatable, Sendable {
    var baseline: AppConfig
    var updated: AppConfig
    var target: NameTarget
    var layoutMapping: [Workspace.ID: Workspace.ID]
    var selectionRevision: UInt64
    var shortcutSelections = Set<WorkspaceShortcutSelection>()
    var shortcutItemIDs = [WorkspaceShortcutSelection: String]()
  }

  @Dependency(\.displays) var displays
  @Dependency(\.configPersistence) var configPersistence
  @Dependency(\.errorReporter) var errorReporter
  @Dependency(\.layoutStore) var layoutStore

  // MARK: Private

  private func startNextDuplication(state: inout State) -> Effect<Action> {
    guard !state.isDuplicationInFlight else { return .none }
    guard !state.pendingDuplications.isEmpty else {
      state.projectedDuplicationConfig = nil
      return .none
    }

    let request = state.pendingDuplications.removeFirst()
    let configRevision: Data?
    do {
      configRevision = try configPersistence.captureRevision(request.baseline)
    } catch {
      errorReporter.report(
        "Duplication",
        String(localized: "Configuration changed before duplication started"),
        ErrorReportClient.describe(error),
      )
      state.pendingDuplications.removeAll()
      state.projectedDuplicationConfig = nil
      state.duplicationReview = nil
      return .none
    }
    state.isDuplicationInFlight = true
    // Prepare external layout state first. The clone is published to the
    // shared config only after that atomic copy succeeds, so opening it can
    // never race a nil first load.
    return .run { [layoutStore] send in
      let copied: Bool
      if request.layoutMapping.isEmpty {
        copied = true
      } else {
        copied = await layoutStore.copyLayouts(request.layoutMapping)
      }
      await send(.duplicationPrepared(DuplicationPreparation(
        baseline: request.baseline,
        configRevision: configRevision,
        updated: request.updated,
        target: request.target,
        newWorkspaceIDs: Array(request.layoutMapping.values),
        selectionRevision: request.selectionRevision,
        layoutCopied: copied,
        shortcutSelections: request.shortcutSelections,
      )))
    }
  }

  private static func prepareDuplication(
    review: DuplicationReview,
    excluding excludedItemIDs: Set<String>,
    selectionRevision: UInt64
  ) -> PendingDuplication? {
    let baseline = review.baseline
    var updated = baseline
    let target: NameTarget
    let layoutMapping: [Workspace.ID: Workspace.ID]
    var shortcutSelections = Set<WorkspaceShortcutSelection>()
    var shortcutItemIDs = [WorkspaceShortcutSelection: String]()

    switch review.source {
    case .profile(let source):
      guard let result = updated.duplicateProfile(source.id) else { return nil }
      target = .profile(result.profileId)
      var selectedWorkspaces = [Workspace]()
      var selectedLayouts: [Workspace.ID: Workspace.ID] = [:]
      for workspace in source.workspaces {
        guard
          !excludedItemIDs.contains(DuplicationOptionID.includeWorkspace(workspace.id)),
          let clonedID = result.workspaceIdMap[workspace.id],
          let clonedName = updated.workspace(id: clonedID)?.name
        else { continue }
        let selectiveCopy = selectiveWorkspaceCopy(
          of: workspace,
          id: clonedID,
          name: clonedName,
          excluding: excludedItemIDs,
          includeShortcuts: true,
        )
        selectedWorkspaces.append(selectiveCopy.workspace)
        shortcutSelections.formUnion(selectiveCopy.shortcutSelections)
        for selection in selectiveCopy.shortcutSelections {
          shortcutItemIDs[selection] = DuplicationOptionID.field(
            selection.field.rawValue,
            in: workspace.id
          )
        }
        if !excludedItemIDs.contains(DuplicationOptionID.layout(workspace.id)) {
          selectedLayouts[workspace.id] = clonedID
        }
      }
      updated.mutateProfile(result.profileId) { clone in
        if excludedItemIDs.contains(DuplicationOptionID.profileIcon) {
          clone.symbolIconName = nil
        }
        clone.workspaces = IdentifiedArray(uniqueElements: selectedWorkspaces)
      }
      layoutMapping = selectedLayouts

    case .workspace(let source):
      guard
        let duplicateID = updated.duplicateWorkspace(source.id),
        let duplicateName = updated.workspace(id: duplicateID)?.name
      else { return nil }
      let selectiveCopy = selectiveWorkspaceCopy(
        of: source,
        id: duplicateID,
        name: duplicateName,
        excluding: excludedItemIDs,
        includeShortcuts: false,
      )
      updated.mutateWorkspace(duplicateID) { $0 = selectiveCopy.workspace }
      target = .workspace(duplicateID)
      layoutMapping = excludedItemIDs.contains(DuplicationOptionID.layout(source.id))
        ? [:]
        : [source.id: duplicateID]
    }

    return PendingDuplication(
      baseline: baseline,
      updated: updated,
      target: target,
      layoutMapping: layoutMapping,
      selectionRevision: selectionRevision,
      shortcutSelections: shortcutSelections,
      shortcutItemIDs: shortcutItemIDs,
    )
  }

  /// Builds the reviewed contents onto a clean workspace shell. Starting from
  /// defaults makes every unchecked option mean "do not copy" instead of
  /// needing to reverse fields after a full clone. Identity and Finder-style
  /// naming still come from AppConfig's duplicate helpers.
  private struct SelectiveWorkspaceCopy {
    var shortcutSelections: Set<WorkspaceShortcutSelection>
    var workspace: Workspace
  }

  private static func selectiveWorkspaceCopy(
    of source: Workspace,
    id: Workspace.ID,
    name: String,
    excluding excludedItemIDs: Set<String>,
    includeShortcuts: Bool
  ) -> SelectiveWorkspaceCopy {
    var copy = Workspace(id: id, name: name)

    let appChanges = WorkspaceSync.appChanges(from: source.apps, to: copy.apps)
    let excludedApps = Set(appChanges.compactMap { change in
      excludedItemIDs.contains(DuplicationOptionID.app(change.bundleId, in: source.id))
        ? change.bundleId
        : nil
    })
    copy.apps = WorkspaceSync.apply(appChanges, to: copy.apps, excluding: excludedApps)

    let fieldChanges = WorkspaceSync.fieldChanges(from: source, to: copy)
    let excludedFields = Set(fieldChanges.compactMap { change in
      if !includeShortcuts, isShortcutIdentity(change) { return change.id }
      return excludedItemIDs.contains(DuplicationOptionID.field(change.id, in: source.id))
        ? change.id
        : nil
    })
    WorkspaceSync.apply(fieldChanges, to: &copy, excluding: excludedFields)

    var shortcutSelections = Set<WorkspaceShortcutSelection>()
    if includeShortcuts {
      for change in fieldChanges where !excludedFields.contains(change.id) {
        if let field = change.shortcutField {
          shortcutSelections.insert(.init(workspaceId: id, field: field))
        }
      }
    }

    if !includeShortcuts {
      // Same-profile workspace duplicates must never register the source's
      // direct or derived shortcuts. Workspaces copied as part of a new
      // profile remain independently scoped and may retain selected shortcuts.
      copy.keyEquivalent = nil
      copy.activateShortcut = nil
      copy.assignAppShortcut = nil
      copy.borrowShortcut = nil
    }

    if
      let focusBundleID = copy.appToFocusBundleId,
      !copy.apps.contains(where: { $0.bundleIdentifier == focusBundleID })
    {
      copy.appToFocusBundleId = nil
    }
    return SelectiveWorkspaceCopy(
      shortcutSelections: shortcutSelections,
      workspace: copy
    )
  }

  private static func isShortcutIdentity(_ change: WorkspaceFieldChange) -> Bool {
    switch change {
    case .keyEquivalent, .activateShortcut, .assignAppShortcut, .borrowShortcut:
      true
    case .icon, .kind, .appToFocus, .displayHint, .borrowEdge, .borrowFraction:
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
        "Nothing was duplicated. Deselect the conflicting shortcut changes and try again: \(descriptions)"
      )
    }
  }

  private func clearLayouts(_ workspaceIDs: [Workspace.ID]) -> Effect<Action> {
    .run { [layoutStore, errorReporter] _ in
      guard await layoutStore.removeLayouts(workspaceIDs) else {
        errorReporter.report(
          "Duplication",
          String(localized: "Incomplete duplicate layout cleanup"),
          String(localized: "The duplicate was not added to the configuration."),
        )
        return
      }
    }
  }

  private func commitRename(state: inout State) {
    guard let session = state.renameSession else { return }
    state.renameSession = nil
    let name = session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    state.$config.withLock { config in
      switch session.target {
      case .profile(let id):
        config.mutateProfile(id) { $0.name = name }
      case .workspace(let id):
        config.mutateWorkspace(id) { $0.name = name }
      }
    }
  }

  private func name(for target: NameTarget, in config: AppConfig) -> String? {
    switch target {
    case .profile(let id):
      config.profiles.first(where: { $0.id == id })?.name
    case .workspace(let id):
      config.workspace(id: id)?.name
    }
  }

  private func select(_ target: NameTarget, state: inout State) {
    switch target {
    case .profile(let id):
      let selectionChanged = state.topSelection != .profile(id)
        || state.selection != .profileSettings
      if selectionChanged { state.selectionRevision &+= 1 }
      state.topSelection = .profile(id)
      state.selection = .profileSettings
      if state.profileDetail?.profileId != id {
        state.profileDetail = ProfileDetailFeature.State(profileId: id)
      }
      state.detail = nil
      state.shared = nil

    case .workspace(let id):
      let owner = state.config.profileId(owning: id)
      let selectionChanged = state.topSelection != owner.map { .profile($0) }
        || state.selection != .workspace(id)
      if selectionChanged { state.selectionRevision &+= 1 }
      if let profileId = state.config.profileId(owning: id) {
        state.topSelection = .profile(profileId)
      }
      state.selection = .workspace(id)
      if state.detail?.workspaceId != id {
        state.detail = WorkspaceDetailFeature.State(workspaceId: id)
      }
      state.profileDetail = nil
      state.shared = nil
    }
  }

}
