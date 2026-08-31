// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import Testing
@testable import TatamiKit

@MainActor
struct HookSettingsFeatureTests {

  // MARK: Internal

  @Test
  func `invalid add stays in the editor without committing`() async {
    let commits = LockIsolated(0)
    let store = TestStore(initialState: settingsState(AppConfig())) {
      HookSettingsFeature()
    } withDependencies: {
      $0.configPersistence.commit = { _, _, _, _, _ in
        commits.withValue { $0 += 1 }
      }
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.addButtonTapped)
    await store.send(.editor(.presented(.saveButtonTapped)))
    await store.finish()

    #expect(store.state.config.hooks.isEmpty)
    #expect(store.state.editor?.showsValidation == true)
    #expect(store.state.editor?.showsTestValidation == false)
    #expect(store.state.editor?.validationIssues.contains {
      $0.code == .definition(.emptyCommand)
    } == true)
    #expect(commits.value == 0)
  }

  @Test
  func `valid add preserves an unrelated invalid hook`() async {
    let invalid = HookDefinition(
      id: "invalid id",
      event: .profileChanged,
      command: [],
    )
    let store = TestStore(initialState: settingsState(AppConfig(hooks: [invalid]))) {
      HookSettingsFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.addButtonTapped)
    await store.send(.editor(.presented(.executableChanged("/usr/bin/true"))))
    await store.send(.editor(.presented(.saveButtonTapped)))
    await store.receive {
      guard case .editor(.presented(.delegate(.saveRequested))) = $0 else { return false }
      return true
    }
    await store.receive {
      guard case .mutationResponse(.add, .success) = $0 else { return false }
      return true
    }
    await store.finish()

    #expect(store.state.config.hooks.count == 2)
    #expect(store.state.config.hooks.first == invalid)
    #expect(store.state.config.hooks.last?.id == "hook")
    #expect(store.state.editor == nil)
  }

  @Test
  func `edit replaces the located hook and preserves argv and environment rows`() async throws {
    let hook = HookDefinition(
      id: "notify",
      event: .workspaceActivated,
      command: ["/bin/zsh", "-c", "print ok"],
      environment: ["MODE": "desktop"],
    )
    let store = TestStore(initialState: settingsState(AppConfig(hooks: [hook]))) {
      HookSettingsFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.configurationChanged)
    let locator = try #require(store.state.rows.first?.locator)
    let rowID = try #require(store.state.rows.first?.id)
    await store.send(.editButtonTapped(locator))

    #expect(store.state.editor?.draft.executable == "/bin/zsh")
    #expect(store.state.editor?.draft.arguments.map(\.value) == ["-c", "print ok"])
    #expect(store.state.editor?.draft.environment.first?.key == "MODE")

    await store.send(.editor(.presented(.idChanged("notify-new"))))
    await store.send(.editor(.presented(.saveButtonTapped)))
    await store.receive {
      guard case .editor(.presented(.delegate(.saveRequested))) = $0 else { return false }
      return true
    }
    await store.receive {
      guard case .mutationResponse(.edit(_), .success) = $0 else { return false }
      return true
    }
    await store.finish()

    #expect(store.state.config.hooks.first?.id == "notify-new")
    #expect(store.state.config.hooks.first?.command == hook.command)
    #expect(store.state.config.hooks.first?.environment == hook.environment)
    #expect(store.state.rows.first?.id == rowID)
  }

  @Test
  func `toggle commits immediately and retains the stable row id`() async throws {
    let hook = HookDefinition(
      id: "notify",
      event: .profileChanged,
      command: ["/usr/bin/true"],
    )
    let store = TestStore(initialState: settingsState(AppConfig(hooks: [hook]))) {
      HookSettingsFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.configurationChanged)
    let row = try #require(store.state.rows.first)
    await store.send(.enabledChanged(row.locator, false))
    await store.receive {
      guard case .mutationResponse(.setEnabled(_, _), .success) = $0 else { return false }
      return true
    }
    await store.finish()

    #expect(store.state.config.hooks.first?.enabled == false)
    #expect(store.state.rows.first?.id == row.id)
    #expect(store.state.rows.first?.locator.expected.enabled == false)
  }

  @Test
  func `delete requires confirmation and removes only the located hook`() async throws {
    let first = HookDefinition(
      id: "first",
      event: .profileChanged,
      command: ["/usr/bin/true"],
    )
    let second = HookDefinition(
      id: "second",
      event: .workspaceActivated,
      command: ["/usr/bin/true"],
    )
    let store = TestStore(initialState: settingsState(AppConfig(hooks: [first, second]))) {
      HookSettingsFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.configurationChanged)
    let locator = try #require(store.state.rows.first?.locator)
    await store.send(.deleteButtonTapped(locator))
    #expect(store.state.config.hooks == [first, second])
    #expect(store.state.alert != nil)

    await store.send(.alert(.presented(.confirmDelete(locator))))
    await store.receive {
      guard case .mutationResponse(.delete(_), .success) = $0 else { return false }
      return true
    }
    await store.finish()

    #expect(store.state.config.hooks == [second])
  }

  @Test
  func `stale locator cannot change another hook`() async {
    let original = HookDefinition(
      id: "original",
      event: .profileChanged,
      command: ["/usr/bin/true"],
    )
    let replacement = HookDefinition(
      id: "replacement",
      event: .profileChanged,
      command: ["/usr/bin/true"],
    )
    let locator = HookLocator(offset: 0, expected: original)
    let store = TestStore(initialState: settingsState(AppConfig(hooks: [replacement]))) {
      HookSettingsFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.enabledChanged(locator, false))

    #expect(store.state.config.hooks == [replacement])
    #expect(store.state.alert != nil)
  }

  @Test
  func `CAS failure keeps the config and editor draft`() async throws {
    let hook = HookDefinition(
      id: "notify",
      event: .profileChanged,
      command: ["/usr/bin/true"],
    )
    let store = TestStore(initialState: settingsState(AppConfig(hooks: [hook]))) {
      HookSettingsFeature()
    } withDependencies: {
      $0.configPersistence.captureRevision = { _ in
        throw ConfigPersistenceError.changedOnDisk
      }
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.configurationChanged)
    let locator = try #require(store.state.rows.first?.locator)
    await store.send(.editButtonTapped(locator))
    await store.send(.editor(.presented(.idChanged("changed"))))
    await store.send(.editor(.presented(.saveButtonTapped)))
    await store.receive {
      guard case .editor(.presented(.delegate(.saveRequested))) = $0 else { return false }
      return true
    }
    await store.receive {
      guard case .mutationResponse(.edit(_), .failure) = $0 else { return false }
      return true
    }
    await store.finish()

    #expect(store.state.config.hooks == [hook])
    #expect(store.state.editor?.draft.id == "changed")
    #expect(store.state.editor?.saveError != nil)
    #expect(store.state.alert == nil)
  }

  @Test
  func `local validation identifies duplicate ids timeout and environment keys`() throws {
    let existing = HookDefinition(
      id: "notify",
      event: .profileChanged,
      command: ["/usr/bin/true"],
    )
    var state = HookEditorFeature.State(
      mode: .add,
      baseline: AppConfig(hooks: [existing]),
      hook: HookDefinition(
        id: "notify",
        event: .profileChanged,
        command: ["/usr/bin/true"],
        timeoutMs: 99,
      ),
      makeUUID: { UUID() },
    )
    let firstID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    let secondID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
    state.draft.environment = [
      .init(id: firstID, key: "MODE", value: "one"),
      .init(id: secondID, key: "MODE", value: "two"),
    ]

    let codes = state.validationIssues.map(\.code)
    #expect(codes.contains(.definition(.duplicateID)))
    #expect(codes.contains(.definition(.timeoutOutOfRange)))
    #expect(codes.count(where: { $0 == .duplicateEnvironmentKey }) == 2)
  }

  @Test
  func `Run Test reuses the runner with deterministic workspace context`() async throws {
    let workspace = Workspace(name: "Work")
    let profile = Profile(name: "Default", workspaces: [workspace])
    let baseline = AppConfig(
      profiles: [profile],
      hooks: [],
      activeProfileId: profile.id,
    )
    let hook = HookDefinition(
      id: "notify",
      event: .workspaceActivated,
      command: ["/usr/bin/printf", "ok"],
    )
    let state = HookEditorFeature.State(
      mode: .add,
      baseline: baseline,
      hook: hook,
      makeUUID: { UUID() },
    )
    let received = LockIsolated<(HookDefinition, HookInvocation)?>(nil)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let store = TestStore(initialState: state) {
      HookEditorFeature()
    } withDependencies: {
      $0.date.now = date
      $0.hookRunner.run = { definition, invocation in
        received.setValue((definition, invocation))
        return .success(stdout: "ok", stderr: "")
      }
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.testButtonTapped)
    await store.receive {
      guard case .testResponse(_, .success) = $0 else { return false }
      return true
    }
    await store.finish()

    let invocation = try #require(received.value?.1)
    #expect(received.value?.0 == hook)
    #expect(invocation.occurredAt == date)
    #expect(invocation.profile.id == profile.id)
    #expect(invocation.workspace?.id == workspace.id)
    #expect(store.state.showsValidation == false)
    #expect(store.state.showsTestValidation)
    #expect(store.state.testStatus == .succeeded(stdout: "ok", stderr: ""))
  }

  @Test
  func `Run Test rejects a scratchpad even when its id is selected`() async {
    let scratchpad = Workspace(name: "Scratch", kind: .scratchpad)
    let workspace = Workspace(name: "Work")
    let profile = Profile(name: "Default", workspaces: [scratchpad, workspace])
    let baseline = AppConfig(
      profiles: [profile],
      activeProfileId: profile.id,
    )
    let hook = HookDefinition(
      id: "notify",
      event: .workspaceActivated,
      command: ["/usr/bin/true"],
    )
    var state = HookEditorFeature.State(
      mode: .add,
      baseline: baseline,
      hook: hook,
      makeUUID: { UUID() },
    )
    state.testWorkspaceID = scratchpad.id
    let runs = LockIsolated(0)
    let store = TestStore(initialState: state) {
      HookEditorFeature()
    } withDependencies: {
      $0.hookRunner.run = { _, _ in
        runs.withValue { $0 += 1 }
        return .success(stdout: "", stderr: "")
      }
    }

    await store.send(.testButtonTapped) {
      $0.showsTestValidation = true
    }

    #expect(store.state.testWorkspaces.map(\.id) == [workspace.id])
    #expect(store.state.testValidationIssues.contains { $0.code == .noWorkspace })
    #expect(!store.state.showsValidation)
    #expect(runs.value == 0)
  }

  @Test
  func `Run Test surfaces process failure output`() async {
    let hook = HookDefinition(
      id: "notify",
      event: .profileChanged,
      command: ["/usr/bin/false"],
    )
    let state = HookEditorFeature.State(
      mode: .add,
      baseline: AppConfig(),
      hook: hook,
      makeUUID: { UUID() },
    )
    let store = TestStore(initialState: state) {
      HookEditorFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 1_700_000_000)
      $0.hookRunner.run = { _, _ in
        .failure(message: "Exited with status 1", stdout: "out", stderr: "err")
      }
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.testButtonTapped)
    await store.receive {
      guard case .testResponse(_, .failure) = $0 else { return false }
      return true
    }
    await store.finish()

    #expect(store.state.testStatus == .failed(
      message: "Exited with status 1",
      stdout: "out",
      stderr: "err",
    ))
  }

  @Test
  func `stale test response cannot replace the latest run`() async throws {
    let oldID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    let currentID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
    var state = HookEditorFeature.State(
      mode: .add,
      baseline: AppConfig(),
      hook: HookDefinition(
        id: "notify",
        event: .profileChanged,
        command: ["/usr/bin/true"],
      ),
      makeUUID: { UUID() },
    )
    state.testStatus = .running(currentID)
    let store = TestStore(initialState: state) {
      HookEditorFeature()
    }

    await store.send(.testResponse(
      oldID,
      .failure(message: "old", stdout: "", stderr: "old"),
    ))

    #expect(store.state.testStatus == .running(currentID))
  }

  @Test
  func `stale editor definition has its own validation code`() {
    let original = HookDefinition(
      id: "original",
      event: .profileChanged,
      command: ["/usr/bin/true"],
    )
    let replacement = HookDefinition(
      id: "replacement",
      event: .profileChanged,
      command: ["/usr/bin/true"],
    )
    let state = HookEditorFeature.State(
      mode: .edit(HookLocator(offset: 0, expected: original)),
      baseline: AppConfig(hooks: [replacement]),
      hook: original,
      makeUUID: { UUID() },
    )

    #expect(state.validationIssues.map(\.code) == [.staleDefinition])
  }

  // MARK: Private

  private func settingsState(_ config: AppConfig) -> HookSettingsFeature.State {
    let state = HookSettingsFeature.State()
    state.$config = Shared(value: config)
    return state
  }

}
