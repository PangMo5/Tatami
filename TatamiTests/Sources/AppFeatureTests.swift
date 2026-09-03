// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import Testing
@testable import TatamiKit

// MARK: - WorkspaceListFeatureTests

@MainActor
struct WorkspaceListFeatureTests {
  @Test
  func `adding workspace appends to active profile`() async {
    let store = TestStore(initialState: WorkspaceListFeature.State()) {
      WorkspaceListFeature()
    }
    store.exhaustivity = .off

    await store.send(.addWorkspaceButtonTapped) {
      $0.isAddSheetPresented = true
    }
    await store.send(.binding(.set(\.draftName, "Focus")))
    await store.send(.addWorkspaceFormSubmitted) {
      $0.isAddSheetPresented = false
      $0.draftName = ""
    }

    #expect(store.state.workspaces.contains(where: { $0.name == "Focus" }))
  }

  @Test
  func `duplicating workspace copies layout selects clone and clears shortcuts`() async throws {
    let shortcut = try #require(HotKey(parsing: "ctrl + alt - f"))
    let workspace = Workspace(
      name: "Focus",
      activateShortcut: shortcut,
      assignAppShortcut: shortcut,
      keyEquivalent: "f",
      borrowShortcut: shortcut,
    )
    let profile = Profile(name: "Default", workspaces: [workspace])
    let snapshot = LayoutSnapshot(
      tree: .leaf(BSPLeaf(windowList: [SlotID(bundleId: "com.example.App", occurrence: 0)]))
    )
    let saved = LockIsolated<[Workspace.ID: LayoutSnapshot]>([:])
    var state = WorkspaceListFeature.State()
    state.$config = Shared(value: AppConfig(profiles: [profile], activeProfileId: profile.id))
    state.topSelection = .profile(profile.id)
    state.selection = .workspace(workspace.id)
    let store = TestStore(initialState: state) {
      WorkspaceListFeature()
    } withDependencies: {
      $0.layoutStore.copyLayouts = { mapping in
        for (source, destination) in mapping where source == workspace.id {
          saved.withValue { $0[destination] = snapshot }
        }
        return true
      }
    }
    store.exhaustivity = .off

    await store.send(.duplicateWorkspaceTapped(workspace.id))
    #expect(store.state.duplicationReview?.id == .workspace(workspace.id))
    #expect(store.state.config.profiles[0].workspaces.count == 1)
    await store.send(.duplicationReviewConfirmed(excluding: []))
    let duplicateID = LockIsolated<Workspace.ID?>(nil)
    await store.receive {
      guard
        case .duplicationPrepared(let preparation) = $0,
        case .workspace(let receivedID) = preparation.target
      else { return false }
      duplicateID.setValue(receivedID)
      return preparation.selectionRevision == 0 && preparation.layoutCopied
    }
    await store.receive {
      guard case .delegate(.profilesChanged) = $0 else { return false }
      return true
    }
    await store.receive {
      guard
        case .selectDuplicateIfUnchanged(
          .workspace(let receivedID),
          selectionRevision: 0,
        ) = $0
      else { return false }
      return receivedID == duplicateID.value
    }
    await store.finish()

    let duplicateId = try #require(duplicateID.value)
    #expect(store.state.selection == .workspace(duplicateId))
    let duplicate = try #require(store.state.config.workspace(id: duplicateId))
    #expect(duplicate.name == "Focus copy")
    #expect(duplicate.keyEquivalent == nil)
    #expect(duplicate.activateShortcut == nil)
    #expect(duplicate.assignAppShortcut == nil)
    #expect(duplicate.borrowShortcut == nil)
    #expect(saved.value[duplicateId] == snapshot)
  }

  @Test
  func `workspace duplicate applies chooser exclusions and never offers shortcut identity`() async throws {
    let shortcut = try #require(HotKey(parsing: "ctrl + alt - f"))
    let keptApp = AppAssignment(bundleIdentifier: "com.example.Kept", name: "Kept")
    let skippedApp = AppAssignment(bundleIdentifier: "com.example.Skipped", name: "Skipped")
    let workspace = Workspace(
      name: "Focus",
      displayHint: DisplayName("Studio Display"),
      activateShortcut: shortcut,
      assignAppShortcut: shortcut,
      symbolIconName: "hammer",
      keyEquivalent: "f",
      borrowShortcut: shortcut,
      borrowEdge: .left,
      apps: [keptApp, skippedApp],
    )
    let profile = Profile(name: "Default", workspaces: [workspace])
    let layoutCopyCount = LockIsolated(0)
    let state = WorkspaceListFeature.State()
    state.$config = Shared(value: AppConfig(profiles: [profile]))
    let store = TestStore(initialState: state) {
      WorkspaceListFeature()
    } withDependencies: {
      $0.layoutStore.copyLayouts = { _ in
        layoutCopyCount.withValue { $0 += 1 }
        return true
      }
    }
    store.exhaustivity = .off

    await store.send(.duplicateWorkspaceTapped(workspace.id))
    await store.send(.duplicationReviewConfirmed(excluding: [
      WorkspaceListFeature.DuplicationOptionID.app(skippedApp.bundleIdentifier, in: workspace.id),
      WorkspaceListFeature.DuplicationOptionID.field("displayHint", in: workspace.id),
      WorkspaceListFeature.DuplicationOptionID.layout(workspace.id),
    ]))
    let duplicateID = LockIsolated<Workspace.ID?>(nil)
    await store.receive {
      guard
        case .duplicationPrepared(let preparation) = $0,
        case .workspace(let id) = preparation.target
      else { return false }
      duplicateID.setValue(id)
      return preparation.layoutCopied && preparation.newWorkspaceIDs.isEmpty
    }
    await store.receive {
      guard case .delegate(.profilesChanged) = $0 else { return false }
      return true
    }
    await store.receive {
      guard case .selectDuplicateIfUnchanged = $0 else { return false }
      return true
    }
    await store.finish()

    let id = try #require(duplicateID.value)
    let duplicate = try #require(store.state.config.workspace(id: id))
    #expect(duplicate.apps.map(\.bundleIdentifier) == [keptApp.bundleIdentifier])
    #expect(duplicate.displayHint == nil)
    #expect(duplicate.symbolIconName == workspace.symbolIconName)
    #expect(duplicate.borrowEdge == workspace.borrowEdge)
    #expect(duplicate.keyEquivalent == nil)
    #expect(duplicate.activateShortcut == nil)
    #expect(duplicate.assignAppShortcut == nil)
    #expect(duplicate.borrowShortcut == nil)
    #expect(layoutCopyCount.value == 0)
  }

  @Test
  func `profile duplicate selects workspaces content and layout while retaining workspace shortcuts`() async throws {
    let activateShortcut = try #require(HotKey(parsing: "cmd - 1"))
    let assignShortcut = try #require(HotKey(parsing: "cmd - 2"))
    let borrowShortcut = try #require(HotKey(parsing: "cmd - 3"))
    let profileShortcut = try #require(HotKey(parsing: "cmd - p"))
    let app = AppAssignment(bundleIdentifier: "com.example.App", name: "Example")
    let included = Workspace(
      name: "Focus",
      activateShortcut: activateShortcut,
      assignAppShortcut: assignShortcut,
      keyEquivalent: "f",
      borrowShortcut: borrowShortcut,
      apps: [app],
    )
    let excluded = Workspace(name: "Browse")
    let workspaceChain = WorkspaceChain(workspaceIDs: [included.id, excluded.id])
    let profile = Profile(
      name: "Default",
      symbolIconName: "rectangle.stack.fill",
      shortcut: profileShortcut,
      autoActivation: ProfileActivation(),
      workspaceChains: [workspaceChain],
      workspaces: [included, excluded],
    )
    let layoutCopyCount = LockIsolated(0)
    let state = WorkspaceListFeature.State()
    state.$config = Shared(value: AppConfig(profiles: [profile]))
    let store = TestStore(initialState: state) {
      WorkspaceListFeature()
    } withDependencies: {
      $0.layoutStore.copyLayouts = { _ in
        layoutCopyCount.withValue { $0 += 1 }
        return true
      }
    }
    store.exhaustivity = .off

    await store.send(.duplicateProfileTapped(profile.id))
    await store.send(.duplicationReviewConfirmed(excluding: [
      WorkspaceListFeature.DuplicationOptionID.app(app.bundleIdentifier, in: included.id),
      WorkspaceListFeature.DuplicationOptionID.layout(included.id),
      WorkspaceListFeature.DuplicationOptionID.includeWorkspace(excluded.id),
    ]))
    let duplicateID = LockIsolated<Profile.ID?>(nil)
    await store.receive {
      guard
        case .duplicationPrepared(let preparation) = $0,
        case .profile(let id) = preparation.target
      else { return false }
      duplicateID.setValue(id)
      return preparation.layoutCopied && preparation.newWorkspaceIDs.isEmpty
    }
    await store.receive {
      guard case .delegate(.profilesChanged) = $0 else { return false }
      return true
    }
    await store.receive {
      guard case .selectDuplicateIfUnchanged = $0 else { return false }
      return true
    }
    await store.finish()

    let clone = try #require(store.state.config.profiles.first { $0.id == duplicateID.value })
    let clonedWorkspace = try #require(clone.workspaces.first)
    #expect(clone.workspaces.count == 1)
    #expect(clonedWorkspace.name == included.name)
    #expect(clonedWorkspace.apps.isEmpty)
    #expect(clonedWorkspace.keyEquivalent == included.keyEquivalent)
    #expect(clonedWorkspace.activateShortcut == included.activateShortcut)
    #expect(clonedWorkspace.assignAppShortcut == included.assignAppShortcut)
    #expect(clonedWorkspace.borrowShortcut == included.borrowShortcut)
    #expect(clone.symbolIconName == profile.symbolIconName)
    #expect(clone.shortcut == nil)
    #expect(clone.autoActivation == nil)
    #expect(clone.workspaceChains.isEmpty)
    #expect(layoutCopyCount.value == 0)
  }

  @Test
  func `profile duplicate chooser exposes selective shortcut conflict and refuses confirmation`() async throws {
    let explicit = try #require(HotKey(parsing: "cmd - x"))
    let derived = try #require(HotKey(parsing: "ctrl + alt - a"))
    let workspace = Workspace(
      name: "Focus",
      activateShortcut: explicit,
      keyEquivalent: "a",
    )
    let profile = Profile(name: "Default", workspaces: [workspace])
    var settings = AppSettings()
    settings.shortcuts.assignModifiers = []
    settings.shortcuts.borrowModifiers = []
    settings.shortcuts.focusLeft = derived
    let state = WorkspaceListFeature.State()
    state.$config = Shared(value: AppConfig(profiles: [profile], settings: settings))
    let store = TestStore(initialState: state) {
      WorkspaceListFeature()
    }
    store.exhaustivity = .off
    let excluded: Set<String> = [
      WorkspaceListFeature.DuplicationOptionID.field(
        WorkspaceShortcutField.activateShortcut.rawValue,
        in: workspace.id,
      )
    ]

    await store.send(.duplicateProfileTapped(profile.id))
    let review = try #require(store.state.duplicationReview)
    let conflictMap = WorkspaceListFeature.duplicationShortcutConflicts(
      review: review,
      excluding: excluded,
    )
    let keyItemID = WorkspaceListFeature.DuplicationOptionID.field(
      WorkspaceShortcutField.keyEquivalent.rawValue,
      in: workspace.id,
    )
    #expect(conflictMap[keyItemID]?.map(\.hotKey) == [derived])

    await store.send(.duplicationReviewConfirmed(excluding: excluded))

    #expect(store.state.config.profiles.count == 1)
    #expect(store.state.pendingDuplications.isEmpty)
    #expect(store.state.alert != nil)
  }

  @Test
  func `duplicate revalidates shortcuts immediately before config commit`() async throws {
    let explicit = try #require(HotKey(parsing: "cmd - x"))
    let derived = try #require(HotKey(parsing: "ctrl + alt - a"))
    let workspace = Workspace(
      name: "Focus",
      activateShortcut: explicit,
      keyEquivalent: "a",
    )
    let profile = Profile(name: "Default", workspaces: [workspace])
    var settings = AppSettings()
    settings.shortcuts.assignModifiers = []
    settings.shortcuts.borrowModifiers = []
    settings.shortcuts.focusLeft = derived
    let baseline = AppConfig(profiles: [profile], settings: settings)
    var updated = baseline
    let duplicationResult = updated.duplicateProfile(profile.id)
    let result = try #require(duplicationResult)
    let clonedWorkspaceID = try #require(result.workspaceIdMap[workspace.id])
    updated.mutateWorkspace(clonedWorkspaceID) { $0.activateShortcut = nil }
    var state = WorkspaceListFeature.State()
    state.$config = Shared(value: baseline)
    state.isDuplicationInFlight = true
    state.projectedDuplicationConfig = updated
    let store = TestStore(initialState: state) {
      WorkspaceListFeature()
    }
    store.exhaustivity = .off

    await store.send(.duplicationPrepared(.init(
      baseline: baseline,
      configRevision: nil,
      updated: updated,
      target: .profile(result.profileId),
      newWorkspaceIDs: [],
      selectionRevision: 0,
      layoutCopied: true,
      shortcutSelections: [
        .init(workspaceId: clonedWorkspaceID, field: .keyEquivalent)
      ],
    )))

    #expect(store.state.config == baseline)
    #expect(store.state.alert != nil)
    #expect(store.state.projectedDuplicationConfig == nil)
  }

  @Test
  func `duplicating an empty profile still publishes and selects the clone`() async throws {
    let profile = Profile(name: "Empty")
    var state = WorkspaceListFeature.State()
    state.$config = Shared(value: AppConfig(profiles: [profile], activeProfileId: profile.id))
    state.topSelection = .profile(profile.id)
    state.selection = .profileSettings
    state.profileDetail = ProfileDetailFeature.State(profileId: profile.id)
    let copiedMappings = LockIsolated<[[Workspace.ID: Workspace.ID]]>([])
    let store = TestStore(initialState: state) {
      WorkspaceListFeature()
    } withDependencies: {
      $0.layoutStore.copyLayouts = { mapping in
        copiedMappings.withValue { $0.append(mapping) }
        return true
      }
    }
    store.exhaustivity = .off
    let cloneID = LockIsolated<Profile.ID?>(nil)

    await store.send(.duplicateProfileTapped(profile.id))
    #expect(store.state.duplicationReview?.id == .profile(profile.id))
    #expect(store.state.config.profiles.count == 1)
    await store.send(.duplicationReviewConfirmed(excluding: []))
    await store.receive {
      guard
        case .duplicationPrepared(let preparation) = $0,
        case .profile(let id) = preparation.target
      else { return false }
      cloneID.setValue(id)
      return preparation.layoutCopied
    }
    await store.receive {
      guard case .delegate(.profilesChanged) = $0 else { return false }
      return true
    }
    await store.receive {
      guard case .selectDuplicateIfUnchanged(.profile(let id), selectionRevision: 0) = $0
      else { return false }
      return id == cloneID.value
    }
    await store.finish()

    let id = try #require(cloneID.value)
    #expect(copiedMappings.value.isEmpty)
    #expect(store.state.config.profiles.first(where: { $0.id == id })?.name == "Empty copy")
    #expect(store.state.topSelection == .profile(id))
    #expect(store.state.profileDetail?.profileId == id)
  }

  @Test
  func `rename draft commits trimmed and escape keeps original`() async {
    let workspace = Workspace(name: "Focus")
    let profile = Profile(name: "Default", workspaces: [workspace])
    let state = WorkspaceListFeature.State()
    state.$config = Shared(value: AppConfig(profiles: [profile], activeProfileId: profile.id))
    let store = TestStore(initialState: state) {
      WorkspaceListFeature()
    }
    store.exhaustivity = .off

    await store.send(.renameRequested(.workspace(workspace.id)))
    await store.send(.renameDraftChanged("  Build  "))
    #expect(store.state.config.workspace(id: workspace.id)?.name == "Focus")
    await store.send(.renameSubmitted)
    #expect(store.state.config.workspace(id: workspace.id)?.name == "Build")

    await store.send(.renameRequested(.profile(profile.id)))
    await store.send(.renameDraftChanged("Discarded"))
    await store.send(.renameCancelled)
    #expect(store.state.config.profiles.first?.name == "Default")
    #expect(store.state.renameSession == nil)
  }

  @Test
  func `renaming the selected item preserves loaded detail state`() async {
    let workspace = Workspace(name: "Focus")
    let profile = Profile(name: "Default", workspaces: [workspace])
    var state = WorkspaceListFeature.State()
    state.$config = Shared(value: AppConfig(profiles: [profile], activeProfileId: profile.id))
    state.topSelection = .profile(profile.id)
    state.selection = .workspace(workspace.id)
    state.detail = WorkspaceDetailFeature.State(workspaceId: workspace.id)
    state.detail?.layout.snapshotLoadedFor = workspace.id
    state.detail?.layout.windowInfoLoadedFor = workspace.id
    let store = TestStore(initialState: state) {
      WorkspaceListFeature()
    }
    store.exhaustivity = .off

    await store.send(.renameRequested(.workspace(workspace.id)))

    #expect(store.state.detail?.layout.snapshotLoadedFor == workspace.id)
    #expect(store.state.detail?.layout.windowInfoLoadedFor == workspace.id)
  }

  @Test
  func `delayed duplicate selection does not override newer navigation`() async {
    let workspace = Workspace(name: "Focus")
    let first = Profile(name: "Default", workspaces: [workspace])
    let second = Profile(name: "Dual")
    var state = WorkspaceListFeature.State()
    state.$config = Shared(value: AppConfig(
      profiles: [first, second],
      activeProfileId: first.id,
    ))
    state.topSelection = .profile(first.id)
    state.selection = .workspace(workspace.id)
    state.detail = WorkspaceDetailFeature.State(workspaceId: workspace.id)
    let store = TestStore(initialState: state) {
      WorkspaceListFeature()
    } withDependencies: {
      $0.layoutStore.copyLayouts = { _ in
        try? await Task.sleep(for: .milliseconds(50))
        return true
      }
    }
    store.exhaustivity = .off

    await store.send(.duplicateWorkspaceTapped(workspace.id))
    await store.send(.duplicationReviewConfirmed(excluding: []))
    await store.send(.topSelected(.profile(second.id)))
    await store.receive {
      guard case .sidebarSelected(.profileSettings) = $0 else { return false }
      return true
    }
    await store.receive {
      guard case .duplicationPrepared(let preparation) = $0 else { return false }
      return preparation.selectionRevision == 0 && preparation.layoutCopied
    }
    await store.receive {
      guard case .delegate(.profilesChanged) = $0 else { return false }
      return true
    }
    await store.receive {
      guard case .selectDuplicateIfUnchanged(_, selectionRevision: 0) = $0
      else { return false }
      return true
    }
    await store.finish()

    #expect(store.state.topSelection == .profile(second.id))
    #expect(store.state.selection == .profileSettings)
    #expect(store.state.profileDetail?.profileId == second.id)
    #expect(store.state.detail == nil)
  }

  @Test
  func `duplicate review rejects configuration changes after the chooser opened`() async {
    let workspace = Workspace(name: "Focus")
    let profile = Profile(name: "Default", workspaces: [workspace])
    let shared = Shared(value: AppConfig(profiles: [profile]))
    let state = WorkspaceListFeature.State()
    state.$config = shared
    let store = TestStore(initialState: state) {
      WorkspaceListFeature()
    }
    store.exhaustivity = .off

    await store.send(.duplicateWorkspaceTapped(workspace.id))
    shared.withLock { $0.mutateWorkspace(workspace.id) { $0.name = "Changed elsewhere" } }
    await store.send(.duplicationReviewConfirmed(excluding: [
      WorkspaceListFeature.DuplicationOptionID.layout(workspace.id)
    ]))
    await store.receive {
      guard case .duplicationPrepared(let preparation) = $0 else { return false }
      return preparation.layoutCopied
    }
    await store.finish()

    #expect(store.state.config.profiles[0].workspaces.count == 1)
    #expect(store.state.config.workspace(id: workspace.id)?.name == "Changed elsewhere")
    #expect(store.state.projectedDuplicationConfig == nil)
  }

  @Test
  func `failed duplicate chain closes a later chooser and drops dependent work`() async throws {
    let workspace = Workspace(name: "Focus")
    let profile = Profile(name: "Default", workspaces: [workspace])
    let baseline = AppConfig(profiles: [profile])
    var updated = baseline
    let duplicateCandidate = updated.duplicateWorkspace(workspace.id)
    let duplicateID = try #require(duplicateCandidate)
    var state = WorkspaceListFeature.State()
    state.$config = Shared(value: baseline)
    state.isDuplicationInFlight = true
    state.pendingDuplications = [WorkspaceListFeature.PendingDuplication(
      baseline: updated,
      updated: updated,
      target: .workspace(duplicateID),
      layoutMapping: [:],
      selectionRevision: 0,
    )]
    state.projectedDuplicationConfig = updated
    state.duplicationReview = WorkspaceListFeature.DuplicationReview(
      source: .workspace(workspace),
      baseline: baseline,
    )
    let store = TestStore(initialState: state) {
      WorkspaceListFeature()
    }
    store.exhaustivity = .off

    await store.send(.duplicationPrepared(WorkspaceListFeature.DuplicationPreparation(
      baseline: baseline,
      configRevision: nil,
      updated: updated,
      target: .workspace(duplicateID),
      newWorkspaceIDs: [duplicateID],
      selectionRevision: 0,
      layoutCopied: false,
    )))

    #expect(store.state.isDuplicationInFlight == false)
    #expect(store.state.pendingDuplications.isEmpty)
    #expect(store.state.projectedDuplicationConfig == nil)
    #expect(store.state.duplicationReview == nil)
  }

  @Test
  func `rapid duplicate requests are serialized and both commit`() async {
    let workspace = Workspace(name: "Focus")
    let profile = Profile(name: "Default", workspaces: [workspace])
    var state = WorkspaceListFeature.State()
    state.$config = Shared(value: AppConfig(profiles: [profile], activeProfileId: profile.id))
    state.topSelection = .profile(profile.id)
    state.selection = .workspace(workspace.id)
    state.detail = WorkspaceDetailFeature.State(workspaceId: workspace.id)
    let copyCount = LockIsolated(0)
    let store = TestStore(initialState: state) {
      WorkspaceListFeature()
    } withDependencies: {
      $0.layoutStore.copyLayouts = { _ in
        let call = copyCount.withValue { count -> Int in
          count += 1
          return count
        }
        if call == 1 { try? await Task.sleep(for: .milliseconds(50)) }
        return true
      }
    }
    store.exhaustivity = .off

    await store.send(.duplicateWorkspaceTapped(workspace.id))
    await store.send(.duplicationReviewConfirmed(excluding: []))
    await store.send(.duplicateWorkspaceTapped(workspace.id))
    await store.send(.duplicationReviewConfirmed(excluding: []))
    for _ in 0 ..< 2 {
      await store.receive {
        guard case .duplicationPrepared = $0 else { return false }
        return true
      }
      await store.receive {
        guard case .delegate(.profilesChanged) = $0 else { return false }
        return true
      }
      await store.receive {
        guard case .selectDuplicateIfUnchanged = $0 else { return false }
        return true
      }
    }
    await store.finish()

    #expect(copyCount.value == 2)
    #expect(store.state.config.activeProfile?.workspaces.map(\.name) == [
      "Focus",
      "Focus copy 2",
      "Focus copy",
    ])
    guard case .workspace(let selectedID) = store.state.selection else {
      Issue.record("Expected the last duplicate to remain selected")
      return
    }
    #expect(store.state.config.workspace(id: selectedID)?.name == "Focus copy 2")
  }
}

// MARK: - AppConfigDuplicationTests

struct AppConfigDuplicationTests {
  @Test
  func `workspace copies use unique finder names and fresh I ds`() throws {
    let shortcut = try #require(HotKey(parsing: "ctrl + alt - f"))
    let app = AppAssignment(
      bundleIdentifier: "com.example.App",
      name: "Example",
      autoOpen: true,
      layout: .floating,
    )
    let source = Workspace(
      name: "Focus",
      displayHint: DisplayName("Studio Display"),
      activateShortcut: shortcut,
      assignAppShortcut: shortcut,
      symbolIconName: "hammer",
      appToFocusBundleId: app.bundleIdentifier,
      kind: .scratchpad,
      keyEquivalent: "f",
      borrowShortcut: shortcut,
      borrowEdge: .left,
      borrowFraction: 0.3,
      apps: [app],
    )
    var config = AppConfig(profiles: [Profile(name: "Default", workspaces: [source])])

    let firstCandidate = config.duplicateWorkspace(source.id)
    let firstId = try #require(firstCandidate)
    let secondCandidate = config.duplicateWorkspace(source.id)
    let secondId = try #require(secondCandidate)
    let first = try #require(config.workspace(id: firstId))
    let second = try #require(config.workspace(id: secondId))

    #expect(first.id != source.id)
    #expect(second.id != source.id)
    #expect(first.id != second.id)
    #expect(first.name == "Focus copy")
    #expect(second.name == "Focus copy 2")
    #expect(first.displayHint == source.displayHint)
    #expect(first.symbolIconName == source.symbolIconName)
    #expect(first.appToFocusBundleId == source.appToFocusBundleId)
    #expect(first.kind == source.kind)
    #expect(first.borrowEdge == source.borrowEdge)
    #expect(first.borrowFraction == source.borrowFraction)
    #expect(first.apps == source.apps)
    #expect(first.keyEquivalent == nil)
    #expect(first.activateShortcut == nil)
    #expect(first.assignAppShortcut == nil)
    #expect(first.borrowShortcut == nil)
  }

  @Test
  func `profile duplicate deep copies I ds and select metadata for empty profiles`() throws {
    let workspace = Workspace(name: "Focus")
    let populated = Profile(name: "Default", workspaces: [workspace])
    let empty = Profile(name: "Empty")
    var config = AppConfig(profiles: [populated, empty])

    let populatedCandidate = config.duplicateProfile(populated.id)
    let populatedResult = try #require(populatedCandidate)
    let populatedClone = try #require(
      config.profiles.first(where: { $0.id == populatedResult.profileId })
    )
    let clonedWorkspace = try #require(populatedClone.workspaces.first)
    #expect(populatedClone.name == "Default copy")
    #expect(populatedClone.id != populated.id)
    #expect(clonedWorkspace.id != workspace.id)
    #expect(populatedResult.workspaceIdMap[workspace.id] == clonedWorkspace.id)

    let emptyCandidate = config.duplicateProfile(empty.id)
    let emptyResult = try #require(emptyCandidate)
    #expect(emptyResult.workspaceIdMap.isEmpty)
    #expect(config.profiles.contains(where: { $0.id == emptyResult.profileId }))
  }
}

// MARK: - ProfileCopyTransactionTests

@MainActor
struct ProfileCopyTransactionTests {
  @Test
  func `external writer after revision capture rejects profile copy`() async {
    let sourceWorkspace = Workspace(name: "Browser", symbolIconName: "star")
    let targetWorkspace = Workspace(name: "Browser", symbolIconName: "bolt")
    let source = Profile(name: "Source", workspaces: [sourceWorkspace])
    let target = Profile(name: "Target", workspaces: [targetWorkspace])
    let baseline = AppConfig(profiles: [target, source])
    let commitAttempts = LockIsolated(0)
    let state = ProfileDetailFeature.State(profileId: target.id)
    state.$config = Shared(value: baseline)
    let store = TestStore(initialState: state) {
      ProfileDetailFeature()
    } withDependencies: {
      $0.configPersistence.captureRevision = { expected in
        #expect(expected == baseline)
        return Data("reviewed-revision".utf8)
      }
      $0.configPersistence.commit = { _, _, _, _, _ in
        commitAttempts.withValue { $0 += 1 }
        throw ConfigPersistenceError.changedOnDisk
      }
    }
    store.exhaustivity = .off

    await store.send(.applyProfileSync(
      target: target.id,
      source: source.id,
      baseline: baseline,
      excludedApps: [:],
      excludedFields: [:],
    ))
    await store.finish()

    #expect(commitAttempts.value == 1)
    #expect(store.state.config == baseline)
    #expect(store.state.config.workspace(id: targetWorkspace.id)?.symbolIconName == "bolt")
    #expect(store.state.alert != nil)
  }

  @Test
  func `profile copy rejects source changes after review opens`() async {
    let sourceWorkspace = Workspace(name: "Browser", symbolIconName: "star")
    let targetWorkspace = Workspace(name: "Browser", symbolIconName: "bolt")
    let source = Profile(name: "Source", workspaces: [sourceWorkspace])
    let target = Profile(name: "Target", workspaces: [targetWorkspace])
    let baseline = AppConfig(profiles: [target, source])
    var changed = baseline
    changed.mutateWorkspace(sourceWorkspace.id) { $0.symbolIconName = "heart" }
    let state = ProfileDetailFeature.State(profileId: target.id)
    state.$config = Shared(value: changed)
    let store = TestStore(initialState: state) {
      ProfileDetailFeature()
    }
    store.exhaustivity = .off

    await store.send(.applyProfileSync(
      target: target.id,
      source: source.id,
      baseline: baseline,
      excludedApps: [:],
      excludedFields: [:],
    ))
    await store.finish()

    #expect(store.state.config == changed)
    #expect(store.state.config.workspace(id: targetWorkspace.id)?.symbolIconName == "bolt")
    #expect(store.state.alert != nil)
  }
}

// MARK: - ProfileWorkspaceChainFeatureTests

@MainActor
struct ProfileWorkspaceChainFeatureTests {
  @Test
  func `valid workspace chain saves into selected profile`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let code = Workspace(name: "Code", displayHint: displayA)
    let slack = Workspace(name: "Slack", displayHint: displayB)
    let profile = Profile(name: "Default", workspaces: [code, slack])
    let state = ProfileDetailFeature.State(profileId: profile.id)
    state.$config = Shared(value: AppConfig(profiles: [profile]))
    let chain = WorkspaceChain(
      name: "  Coding  ",
      workspaceIDs: [code.id, slack.id],
    )
    let store = TestStore(initialState: state) {
      ProfileDetailFeature()
    }
    store.exhaustivity = .off

    await store.send(.saveWorkspaceChain(original: nil, updated: chain))
    await store.finish()

    #expect(store.state.profile?.workspaceChains.first?.name == "Coding")
    #expect(store.state.profile?.workspaceChains.first?.workspaceIDs == chain.workspaceIDs)
    #expect(store.state.alert == nil)
  }

  @Test
  func `workspace chain save repairs dynamic references in membership order`() async {
    let first = Workspace(name: "First")
    let second = Workspace(name: "Second")
    let outside = Workspace(name: "Outside")
    let profile = Profile(name: "Default", workspaces: [first, second, outside])
    let state = ProfileDetailFeature.State(profileId: profile.id)
    state.$config = Shared(value: AppConfig(profiles: [profile]))
    let chain = WorkspaceChain(
      workspaceIDs: [first.id, second.id],
      dynamicWorkspaceIDs: [second.id, outside.id, first.id, second.id],
    )
    let store = TestStore(initialState: state) {
      ProfileDetailFeature()
    }
    store.exhaustivity = .off

    await store.send(.saveWorkspaceChain(original: nil, updated: chain))
    await store.finish()

    #expect(
      store.state.profile?.workspaceChains.first?.dynamicWorkspaceIDs
        == [first.id, second.id]
    )
    #expect(store.state.alert == nil)
  }

  @Test
  func `workspace chain save allows overlapping pins and preserves any priority length`() async {
    let sharedDisplay = DisplayName(uuid: "display-a", name: "Studio Display")
    let first = Workspace(name: "First", displayHint: sharedDisplay)
    let second = Workspace(name: "Second", displayHint: sharedDisplay)
    let third = Workspace(name: "Third", displayHint: sharedDisplay)
    let profile = Profile(name: "Default", workspaces: [first, second, third])
    let state = ProfileDetailFeature.State(profileId: profile.id)
    state.$config = Shared(value: AppConfig(profiles: [profile]))
    let chain = WorkspaceChain(workspaceIDs: [first.id, second.id, third.id])
    let store = TestStore(initialState: state) {
      ProfileDetailFeature()
    }
    store.exhaustivity = .off

    await store.send(.saveWorkspaceChain(original: nil, updated: chain))
    await store.finish()

    #expect(store.state.profile?.workspaceChains == [chain])
    #expect(store.state.alert == nil)
  }

  @Test
  func `editing workspace chain preserves identity and position while updating order`() async throws {
    let first = Workspace(name: "A")
    let second = Workspace(name: "B")
    let third = Workspace(name: "C")
    let otherFirst = Workspace(name: "D")
    let otherSecond = Workspace(name: "E")
    let untouched = WorkspaceChain(
      name: "Untouched",
      workspaceIDs: [otherFirst.id, otherSecond.id],
    )
    let original = WorkspaceChain(
      name: "Primary",
      workspaceIDs: [first.id, second.id, third.id],
    )
    let profile = Profile(
      name: "Default",
      workspaceChains: [untouched, original],
      workspaces: [first, second, third, otherFirst, otherSecond],
    )
    let state = ProfileDetailFeature.State(profileId: profile.id)
    state.$config = Shared(value: AppConfig(profiles: [profile]))
    let store = TestStore(initialState: state) {
      ProfileDetailFeature()
    }
    store.exhaustivity = .off
    var updated = original
    updated.workspaceIDs = [third.id, first.id, second.id]

    await store.send(.saveWorkspaceChain(original: original, updated: updated))
    await store.finish()

    let chains = try #require(store.state.profile?.workspaceChains)
    #expect(chains == [untouched, updated])
    #expect(chains[1].id == original.id)
    #expect(chains[1].workspaceIDs == [third.id, first.id, second.id])
    #expect(store.state.alert == nil)
  }

  @Test
  func `workspace shared by two workspace chains rejects the new chain`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let displayC = DisplayName("C")
    let code = Workspace(name: "Code", displayHint: displayA)
    let slack = Workspace(name: "Slack", displayHint: displayB)
    let notes = Workspace(name: "Notes", displayHint: displayC)
    let existing = WorkspaceChain(workspaceIDs: [code.id, slack.id])
    let conflicting = WorkspaceChain(workspaceIDs: [code.id, notes.id])
    let profile = Profile(
      name: "Default",
      workspaceChains: [existing],
      workspaces: [code, slack, notes],
    )
    let state = ProfileDetailFeature.State(profileId: profile.id)
    state.$config = Shared(value: AppConfig(profiles: [profile]))
    let store = TestStore(initialState: state) {
      ProfileDetailFeature()
    }
    store.exhaustivity = .off

    await store.send(.saveWorkspaceChain(original: nil, updated: conflicting))
    await store.finish()

    #expect(store.state.profile?.workspaceChains == [existing])
    #expect(store.state.alert != nil)
  }

  @Test
  func `workspace chain deletion removes the confirmed exact chain`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let code = Workspace(name: "Code", displayHint: displayA)
    let slack = Workspace(name: "Slack", displayHint: displayB)
    let chain = WorkspaceChain(
      name: "Coding",
      workspaceIDs: [code.id, slack.id],
    )
    let profile = Profile(
      name: "Default",
      workspaceChains: [chain],
      workspaces: [code, slack],
    )
    let state = ProfileDetailFeature.State(profileId: profile.id)
    state.$config = Shared(value: AppConfig(profiles: [profile]))
    let store = TestStore(initialState: state) {
      ProfileDetailFeature()
    }
    store.exhaustivity = .off

    await store.send(.deleteWorkspaceChainRequested(chain))
    #expect(store.state.alert != nil)
    await store.send(.alert(.presented(.confirmWorkspaceChainDeletion(chain))))
    await store.finish()

    #expect(store.state.profile?.workspaceChains.isEmpty == true)
  }
}

// MARK: - GestureRoutingTests

@MainActor
struct GestureRoutingTests {
  @Test
  func `configured gesture routes through the shared tatami command path`() async {
    let state = AppFeature.State()
    state.$config.withLock {
      $0.settings.gestures = AppSettings.Gestures(
        enabled: true,
        fourFinger: .init(up: .toggleFullscreen),
      )
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.gesturePerformed(.init(fingerCount: 4, direction: .up)))
    await store.receive {
      guard case .activation(.bspToggleZoomFullscreen) = $0 else { return false }
      return true
    }
  }

  @Test
  func `onboarding routes the real recognizer into the safe preview`() async {
    let first = Workspace(name: "Focus")
    let second = Workspace(name: "Browse")
    let profile = Profile(name: "Default", workspaces: [first, second])
    var state = AppFeature.State()
    state.onboarding.isPresented = true
    state.onboarding.draft = AppConfig(
      profiles: [profile],
      settings: AppSettings(gestures: .init(enabled: true)),
      activeProfileId: profile.id,
    )
    state.onboarding.demoActiveWorkspaceID = first.id
    let gesture = TrackpadGesture(fingerCount: 3, direction: .right)
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.onboardingProgress.save = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.gesturePerformed(gesture))
    await store.receive(\.onboarding.demoGesturePerformed)

    #expect(store.state.onboarding.demoLastGesture == gesture)
    #expect(store.state.onboarding.demoActiveWorkspaceID == second.id)
  }
}

// MARK: - WorkspaceDetailActivationRoutingTests

@MainActor
struct WorkspaceDetailActivationRoutingTests {
  @Test
  func `detail activate freezes the pointer display before child routing`() async {
    let displayA = DisplayName(uuid: "display-a", name: "A")
    let displayB = DisplayName(uuid: "display-b", name: "B")
    let workspace = Workspace(name: "Work")
    let profile = Profile(name: "Default", workspaces: [workspace])
    let sharedConfig = Shared(value: AppConfig(
      profiles: [profile],
      activeProfileId: profile.id,
    ))
    var state = AppFeature.State()
    state.$config = sharedConfig
    state.activation.$config = sharedConfig
    state.workspaceList.$config = sharedConfig
    state.workspaceList.detail = WorkspaceDetailFeature.State(workspaceId: workspace.id)
    let pointerDisplay = LockIsolated(displayA)
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.displays.current = { pointerDisplay.value }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { _ in }
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.workspaceList(.detail(.activateTapped)))
    pointerDisplay.setValue(displayB)
    await store.receive {
      guard
        case .activation(.activate(
          let workspaceID,
          let setFocus,
          let interactionDisplay,
        )) = $0
      else { return false }
      return workspaceID == workspace.id
        && setFocus
        && interactionDisplay == displayA
    }
    await store.finish()
  }
}

// MARK: - WindowCycleShortcutRoutingTests

@MainActor
@Suite(.serialized)
struct WindowCycleShortcutRoutingTests {
  @Test
  func `hot key preserves its hold modifier for the cycle session`() async {
    let state = AppFeature.State()
    state.$config.withLock {
      $0.settings.shortcuts.cycleNextWindow = HotKey(parsing: "alt - tab")
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.hotKeys(.actionTriggered(.cycleNextWindow)))
    await store.receive {
      guard case .activation(.cycleWindowShortcut(.next, let modifiers)) = $0 else {
        return false
      }
      return modifiers == .option
    }
  }

  @Test
  func `workspace hot key freezes the pointer display before child routing`() async {
    let displayA = DisplayName(uuid: "display-a", name: "A")
    let displayB = DisplayName(uuid: "display-b", name: "B")
    var state = AppFeature.State()
    state.activation.focusedDisplay = displayB
    let pointerDisplay = LockIsolated(displayA)
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.displays.current = { pointerDisplay.value }
    }
    store.exhaustivity = .off

    await store.send(.hotKeys(.actionTriggered(.switchToNextWorkspace)))
    pointerDisplay.setValue(displayB)
    await store.receive {
      guard case .activation(.activateNext(let interactionDisplay)) = $0 else {
        return false
      }
      return interactionDisplay == displayA
    }
  }

  @Test
  func `workspace gesture switches to the owning profile`() async {
    let displayA = DisplayName(uuid: "display-a", name: "A")
    let displayB = DisplayName(uuid: "display-b", name: "B")
    let currentWorkspace = Workspace(name: "Current")
    let targetWorkspace = Workspace(name: "Target")
    let currentProfile = Profile(name: "Default", workspaces: [currentWorkspace])
    let targetProfile = Profile(name: "Dual", workspaces: [targetWorkspace])
    let state = AppFeature.State()
    state.$config.withLock {
      $0.profiles = [currentProfile, targetProfile]
      $0.activeProfileId = currentProfile.id
      $0.settings.gestures = AppSettings.Gestures(
        enabled: true,
        fourFinger: .init(up: .activateWorkspace(targetWorkspace.id)),
      )
    }
    let pointerDisplay = LockIsolated(displayA)
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.displays.current = { pointerDisplay.value }
      $0.continuousClock = TestClock()
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.gesturePerformed(.init(fingerCount: 4, direction: .up)))
    // The parent route owns the command's input beat. Pointer movement before
    // its child action is reduced must not retarget the workspace/profile.
    pointerDisplay.setValue(displayB)
    await store.receive {
      guard case .activateProfile(let id, let focus, let interactionDisplay) = $0 else {
        return false
      }
      return id == targetProfile.id
        && focus == targetWorkspace.id
        && interactionDisplay == displayA
    }
    #expect(store.state.config.activeProfileId == targetProfile.id)
  }

  @Test
  func `membership profile switch forwards its captured display into reactivation`() async {
    let displayA = DisplayName(uuid: "display-a", name: "A")
    let displayB = DisplayName(uuid: "display-b", name: "B")
    let currentWorkspace = Workspace(name: "Current")
    let targetWorkspace = Workspace(name: "Target", kind: .scratchpad)
    let currentProfile = Profile(name: "Default", workspaces: [currentWorkspace])
    let targetProfile = Profile(name: "Dual", workspaces: [targetWorkspace])
    let state = AppFeature.State()
    state.$config.withLock {
      $0.profiles = [currentProfile, targetProfile]
      $0.activeProfileId = currentProfile.id
    }
    let pointerDisplay = LockIsolated(displayA)
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.displays.all = { [] }
      $0.displays.current = { pointerDisplay.value }
    }
    store.exhaustivity = .off

    await store.send(.activation(.delegate(.profileSwitchRequested(
      targetProfile.id,
      focus: targetWorkspace.id,
      interactionDisplay: displayA,
    ))))
    await store.receive {
      guard case .activateProfile(let id, let focus, let interactionDisplay) = $0 else {
        return false
      }
      return id == targetProfile.id
        && focus == targetWorkspace.id
        && interactionDisplay == displayA
    }
    pointerDisplay.setValue(displayB)
    await store.receive {
      guard
        case .activation(.reactivateActiveProfile(
          let focus,
          let interactionDisplay,
        )) = $0
      else { return false }
      return focus == targetWorkspace.id && interactionDisplay == displayA
    }
    await store.receive(\.activation.activateInitial)
    await store.finish()

    #expect(store.state.config.activeProfileId == targetProfile.id)
  }
}

// MARK: - CLIDomainCommandRoutingTests

@MainActor
struct CLIDomainCommandRoutingTests {
  @Test
  func `CLI domain command reuses the gesture and hotkey dispatcher before acknowledging`() async {
    let completions = LockIsolated<[String?]>([])
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.cli(.delegate(.dispatchDomainCommandRequested(
      .focusLeft,
      complete: { error in completions.withValue { $0.append(error) } },
    ))))
    await store.receive {
      guard case .activation(.bspFocus(.west)) = $0 else { return false }
      return true
    }
    await store.finish()

    #expect(completions.value == [nil])
  }

  @Test
  func `CLI targeted domain command is revalidated immediately before dispatch`() async {
    let completions = LockIsolated<[String?]>([])
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.cli(.delegate(.dispatchDomainCommandRequested(
      .activateWorkspace(UUID()),
      complete: { error in completions.withValue { $0.append(error) } },
    ))))
    await store.finish()

    #expect(completions.value == ["The requested workspace no longer exists"])
  }

  @Test
  func `CLI domain command freezes the pointer display before child routing`() async {
    let displayA = DisplayName(uuid: "display-a", name: "A")
    let displayB = DisplayName(uuid: "display-b", name: "B")
    let pointerDisplay = LockIsolated(displayA)
    let completions = LockIsolated<[String?]>([])
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.displays.current = { pointerDisplay.value }
    }
    store.exhaustivity = .off

    await store.send(.cli(.delegate(.dispatchDomainCommandRequested(
      .borrowRecentWorkspace,
      complete: { error in completions.withValue { $0.append(error) } },
    ))))
    pointerDisplay.setValue(displayB)
    await store.receive {
      guard case .activation(.borrowRecentWorkspace(let interactionDisplay)) = $0 else {
        return false
      }
      return interactionDisplay == displayA
    }
    await store.finish()

    #expect(completions.value == [nil])
  }
}

// MARK: - CLIActivationRoutingTests

@MainActor
@Suite("CLI activation routing", .serialized)
struct CLIActivationRoutingTests {
  @Test
  func `workspace request freezes the pointer display before activation tracking`() async {
    let displayA = DisplayName(uuid: "display-a", name: "A")
    let displayB = DisplayName(uuid: "display-b", name: "B")
    let workspace = Workspace(name: "CLI")
    let profile = Profile(name: "Default", workspaces: [workspace])
    let sharedConfig = Shared(value: AppConfig(
      profiles: [profile],
      activeProfileId: profile.id,
    ))
    let state = AppFeature.State()
    state.$config = sharedConfig
    state.activation.$config = sharedConfig
    let pointerDisplay = LockIsolated(displayA)
    let completions = LockIsolated<[String?]>([])
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.displays.current = { pointerDisplay.value }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { _ in }
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.cli(.delegate(.activateWorkspaceRequested(
      workspace.id,
      complete: { error in completions.withValue { $0.append(error) } },
    ))))
    pointerDisplay.setValue(displayB)
    await store.receive {
      guard case .activation(.trackCLIActivation(let request, _)) = $0 else {
        return false
      }
      return request.target == .workspace(workspace.id)
    }
    await store.receive {
      guard
        case .activation(.activateFromCLI(
          let workspaceID,
          _,
          let interactionDisplay,
        )) = $0
      else { return false }
      return workspaceID == workspace.id && interactionDisplay == displayA
    }
    await store.finish()

    #expect(completions.value == [nil])
  }

  @Test
  func `deleted profile request fails without entering activation tracking`() async {
    let missingProfileID = UUID()
    let completions = LockIsolated<[String?]>([])
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.cli(.delegate(.activateProfileRequested(
      missingProfileID,
      complete: { error in completions.withValue { $0.append(error) } },
    ))))
    await store.finish()

    #expect(completions.value == ["The requested profile no longer exists"])
    #expect(store.state.activation.pendingCLIActivation == nil)
  }

  @Test
  func `profile removed after tracking completes the pending request exactly once`() async {
    let removedProfileID = UUID()
    let completions = LockIsolated<[String?]>([])
    let request = WorkspaceActivationFeature.CLIActivationRequest(
      target: .profile(removedProfileID),
      complete: { error in completions.withValue { $0.append(error) } },
    )
    var state = AppFeature.State()
    state.activation.pendingCLIActivation = request
    let store = TestStore(initialState: state) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.activateProfile(removedProfileID, focus: nil))
    await store.finish()
    await store.send(.activateProfile(removedProfileID, focus: nil))
    await store.finish()

    #expect(completions.value == ["The requested profile no longer exists"])
    #expect(store.state.activation.pendingCLIActivation == nil)
  }

  @Test
  func `same profile request joins the in flight activation tail`() async {
    let display = DisplayName("Main")
    let workspace = Workspace(name: "Work")
    let profile = Profile(name: "Default", workspaces: [workspace])
    let sharedConfig = Shared(value: AppConfig(
      profiles: [profile],
      activeProfileId: profile.id,
    ))
    var state = AppFeature.State()
    state.$config = sharedConfig
    state.activation.$config = sharedConfig
    state.activation.isActivating = true
    state.activation.activationGeneration = 1
    state.activation.activeActivationGeneration = 1
    let completions = LockIsolated<[String?]>([])
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    await store.send(.cli(.delegate(.activateProfileRequested(
      profile.id,
      complete: { error in completions.withValue { $0.append(error) } },
    ))))
    #expect(completions.value.isEmpty)

    await store.send(.activation(.activationCompleted(
      workspaceId: workspace.id,
      display: display,
      generation: 1,
    )))
    #expect(completions.value.isEmpty)
    await store.send(.activation(.activationTailFinished(generation: 1)))
    await store.finish()

    #expect(completions.value == [nil])
  }

  @Test
  func `same profile request joins the core completion to tail gap`() async {
    let workspace = Workspace(name: "Work")
    let profile = Profile(name: "Default", workspaces: [workspace])
    let sharedConfig = Shared(value: AppConfig(
      profiles: [profile],
      activeProfileId: profile.id,
    ))
    var state = AppFeature.State()
    state.$config = sharedConfig
    state.activation.$config = sharedConfig
    state.activation.activationGeneration = 1
    state.activation.activeActivationGeneration = 1
    let completions = LockIsolated<[String?]>([])
    let store = TestStore(initialState: state) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.cli(.delegate(.activateProfileRequested(
      profile.id,
      complete: { error in completions.withValue { $0.append(error) } },
    ))))
    #expect(completions.value.isEmpty)

    await store.send(.activation(.activationTailFinished(generation: 1)))
    await store.finish()

    #expect(completions.value == [nil])
  }

  @Test
  func `stale core completion neither mutates activation nor emits workspace hook`() async {
    let display = DisplayName("Main")
    let current = Workspace(name: "Current")
    let stale = Workspace(name: "Stale")
    let profile = Profile(name: "Default", workspaces: [current, stale])
    let hook = HookDefinition(
      id: "workspace",
      event: .workspaceActivated,
      command: ["/usr/bin/true"],
    )
    let sharedConfig = Shared(value: AppConfig(
      profiles: [profile],
      hooks: [hook],
      activeProfileId: profile.id,
    ))
    var state = AppFeature.State()
    state.$config = sharedConfig
    state.activation.$config = sharedConfig
    state.hooks.$config = sharedConfig
    state.activation.isActivating = true
    state.activation.activationGeneration = 2
    state.activation.activeActivationGeneration = 2
    state.activation.activeWorkspacesByDisplay[display] = current.id
    let hookRuns = LockIsolated(0)
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.hookRunner.run = { _, _ in
        hookRuns.withValue { $0 += 1 }
        return .success(stdout: "", stderr: "")
      }
    }
    store.exhaustivity = .off

    await store.send(.activation(.activationCompleted(
      workspaceId: stale.id,
      display: display,
      generation: 1,
    )))
    await store.finish()

    #expect(store.state.activation.isActivating)
    #expect(store.state.activation.activeActivationGeneration == 2)
    #expect(store.state.activation.activeWorkspacesByDisplay[display] == current.id)
    #expect(hookRuns.value == 0)
  }

  @Test
  func `workspace reply waits for the focus effect to finish`() async {
    let display = DisplayName("Main")
    let workspace = Workspace(name: "CLI")
    let profile = Profile(name: "Default", workspaces: [workspace])
    let window = WindowKey(pid: 1, windowID: 101, bundleId: "app.cli")
    var state = AppFeature.State()
    let sharedConfig = Shared(value: AppConfig(
      profiles: [profile],
      activeProfileId: profile.id,
    ))
    state.$config = sharedConfig
    state.activation.$config = sharedConfig
    state.activation.activeWorkspacesByDisplay[display] = workspace.id
    state.activation.focusedDisplay = display
    state.activation.tilingTrees[workspace.id] = .leaf(window)
    let completions = LockIsolated<[String?]>([])
    let (focusGate, focusGateContinuation) = AsyncStream<Void>.makeStream()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.displays.current = { display }
      $0.focusManager.focusWindow = { _ in
        for await _ in focusGate { break }
      }
    }
    store.exhaustivity = .off

    await store.send(.cli(.delegate(.activateWorkspaceRequested(
      workspace.id,
      complete: { error in completions.withValue { $0.append(error) } },
    ))))
    #expect(completions.value.isEmpty)

    focusGateContinuation.yield(())
    focusGateContinuation.finish()
    await store.finish()

    #expect(completions.value == [nil])
  }
}

// MARK: - HotKeyRegistrationRefreshTests

@MainActor
@Suite("Hot key registration refresh", .serialized)
struct HotKeyRegistrationRefreshTests {
  @Test
  func `external writer after revision capture rejects workspace copy`() async {
    let sourceWorkspace = Workspace(name: "Source", symbolIconName: "star")
    let targetWorkspace = Workspace(name: "Target", symbolIconName: "bolt")
    let sourceProfile = Profile(name: "Source", workspaces: [sourceWorkspace])
    let targetProfile = Profile(name: "Target", workspaces: [targetWorkspace])
    let baseline = AppConfig(profiles: [targetProfile, sourceProfile])
    let registrations = LockIsolated<[[HotKeyBinding]]>([])
    let commitAttempts = LockIsolated(0)
    var state = AppFeature.State()
    state.$config.withLock { $0 = baseline }
    state.workspaceList.detail = WorkspaceDetailFeature.State(
      workspaceId: targetWorkspace.id
    )
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.configPersistence.captureRevision = { expected in
        #expect(expected == baseline)
        return Data("reviewed-revision".utf8)
      }
      $0.configPersistence.commit = { _, _, _, _, _ in
        commitAttempts.withValue { $0 += 1 }
        throw ConfigPersistenceError.changedOnDisk
      }
      $0.hotKeys.register = { bindings in
        registrations.withValue { $0.append(bindings) }
      }
    }
    store.exhaustivity = .off

    await store.send(.workspaceList(.detail(.importWorkspace(
      targetWorkspace: targetWorkspace.id,
      sourceProfile: sourceProfile.id,
      sourceWorkspace: sourceWorkspace.id,
      baseline: baseline,
      excludingApps: [],
      excludingFields: [],
    ))))
    await store.finish()

    #expect(commitAttempts.value == 1)
    #expect(registrations.value.isEmpty)
    #expect(store.state.config == baseline)
    #expect(store.state.workspaceList.detail?.alert != nil)
  }

  @Test
  func `rejected workspace copy does not refresh or reactivate`() async {
    let copiedApp = AppAssignment(bundleIdentifier: "copied", name: "Copied")
    let sourceWorkspace = Workspace(name: "Source", apps: [copiedApp])
    let targetWorkspace = Workspace(name: "Target")
    let profile = Profile(name: "Default", workspaces: [targetWorkspace, sourceWorkspace])
    let baseline = AppConfig(profiles: [profile], activeProfileId: profile.id)
    var changed = baseline
    changed.mutateWorkspace(sourceWorkspace.id) { $0.symbolIconName = "star" }
    let registrations = LockIsolated<[[HotKeyBinding]]>([])
    var state = AppFeature.State()
    state.$config.withLock { $0 = changed }
    state.workspaceList.detail = WorkspaceDetailFeature.State(
      workspaceId: targetWorkspace.id
    )
    state.activation.activeWorkspacesByDisplay["Built-in"] = targetWorkspace.id
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.hotKeys.register = { bindings in
        registrations.withValue { $0.append(bindings) }
      }
    }
    store.exhaustivity = .off

    await store.send(.workspaceList(.detail(.importWorkspace(
      targetWorkspace: targetWorkspace.id,
      sourceProfile: profile.id,
      sourceWorkspace: sourceWorkspace.id,
      baseline: baseline,
      excludingApps: [],
      excludingFields: [],
    ))))
    await store.finish()

    #expect(registrations.value.isEmpty)
    #expect(store.state.activation.activeActivationGeneration == nil)
    #expect(store.state.config == changed)
    #expect(store.state.workspaceList.detail?.alert != nil)
  }

  @Test
  func `successful workspace copy delegates one hot key refresh`() async {
    let sourceWorkspace = Workspace(name: "Source", keyEquivalent: "a")
    let targetWorkspace = Workspace(name: "Target", keyEquivalent: "b")
    let targetProfile = Profile(name: "Default", workspaces: [targetWorkspace])
    let sourceProfile = Profile(name: "Source", workspaces: [sourceWorkspace])
    let baseline = AppConfig(
      profiles: [targetProfile, sourceProfile],
      activeProfileId: targetProfile.id,
    )
    var current = baseline
    current.activeProfileId = sourceProfile.id
    let registrations = LockIsolated<[[HotKeyBinding]]>([])
    var state = AppFeature.State()
    state.$config.withLock { $0 = current }
    state.workspaceList.detail = WorkspaceDetailFeature.State(
      workspaceId: targetWorkspace.id
    )
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.hotKeys.register = { bindings in
        registrations.withValue { $0.append(bindings) }
      }
    }
    store.exhaustivity = .off

    await store.send(.workspaceList(.detail(.importWorkspace(
      targetWorkspace: targetWorkspace.id,
      sourceProfile: sourceProfile.id,
      sourceWorkspace: sourceWorkspace.id,
      baseline: baseline,
      excludingApps: [],
      excludingFields: [],
    ))))
    await store.finish()

    #expect(registrations.value.count == 1)
    #expect(store.state.config.workspace(id: targetWorkspace.id)?.keyEquivalent == "a")
    #expect(store.state.config.activeProfileId == sourceProfile.id)
  }

  @Test
  func `key equivalent and borrow shortcut changes refresh the registered bindings`() async throws {
    let workspace = Workspace(name: "Focus")
    let profile = Profile(name: "Default", workspaces: [workspace])
    let switchKey = try #require(HotKey(parsing: "ctrl + alt - a"))
    let borrowKey = try #require(HotKey(parsing: "ctrl + alt + cmd - b"))
    let registrations = LockIsolated<[[HotKeyBinding]]>([])
    var state = AppFeature.State()
    state.$config.withLock {
      $0 = AppConfig(profiles: [profile], activeProfileId: profile.id)
    }
    state.workspaceList.detail = WorkspaceDetailFeature.State(workspaceId: workspace.id)
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.hotKeys.register = { bindings in
        registrations.withValue { $0.append(bindings) }
      }
    }
    store.exhaustivity = .off

    await store.send(.workspaceList(.detail(.keyEquivalentChanged("a"))))
    await store.finish()
    #expect(registrations.value.count == 1)
    #expect(
      registrations.value.last?.contains {
        $0.action == .activateWorkspace(workspace.id)
          && $0.hotKey == switchKey
      } == true
    )

    await store.send(.workspaceList(.detail(.borrowShortcutChanged(borrowKey))))
    await store.finish()
    #expect(registrations.value.count == 2)
    #expect(
      registrations.value.last?.contains {
        $0.action == .borrowWorkspace(workspace.id) && $0.hotKey == borrowKey
      } == true
    )
  }

  @Test
  func `confirmed workspace deletion refreshes without the deleted binding`() async throws {
    let key = try #require(HotKey(parsing: "ctrl + alt - a"))
    let workspace = Workspace(name: "Focus", activateShortcut: key)
    let companion = Workspace(name: "Companion")
    let chain = WorkspaceChain(workspaceIDs: [workspace.id, companion.id])
    let profile = Profile(
      name: "Default",
      workspaceChains: [chain],
      workspaces: [workspace, companion],
    )
    let registrations = LockIsolated<[[HotKeyBinding]]>([])
    var state = AppFeature.State()
    state.$config.withLock {
      $0 = AppConfig(profiles: [profile], activeProfileId: profile.id)
    }
    state.workspaceList.detail = WorkspaceDetailFeature.State(workspaceId: workspace.id)
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.hotKeys.register = { bindings in
        registrations.withValue { $0.append(bindings) }
      }
      $0.layoutStore.clear = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.workspaceList(.workspaceDeleteRequested(workspace.id)))
    #expect(registrations.value.isEmpty)

    await store.send(
      .workspaceList(.alert(.presented(.confirmDeletion(workspace.id))))
    )
    await store.finish()

    #expect(registrations.value.count == 1)
    let bindings = try #require(registrations.value.first)
    #expect(
      bindings.contains { $0.action == .activateWorkspace(workspace.id) } == false
    )
    #expect(store.state.config.profiles[0].workspaceChains.isEmpty)
  }
}
