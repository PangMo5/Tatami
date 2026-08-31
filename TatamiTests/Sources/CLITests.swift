// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import Sharing
import TatamiCLIProtocol
import Testing
@testable import TatamiKit

// MARK: - CLIProtocolTests

struct CLIProtocolTests {
  @Test
  func `empty revision is valid only for the recommended fresh seed`() throws {
    let seed = AppConfig(settings: AppSettings(shortcuts: .recommended))
    try validateConfigRevision(Data(), expected: seed)
    try validateConfigRevision(nil, expected: seed)

    let configured = AppConfig(profiles: [Profile(name: "Configured")])
    #expect(throws: (any Error).self) {
      try validateConfigRevision(Data(), expected: configured)
    }
    #expect(throws: (any Error).self) {
      try validateConfigRevision(nil, expected: configured)
    }
  }

  @Test
  func `shared config uses the key's recommended fresh install seed`() {
    withDependencies {
      $0.defaultFileStorage = .inMemory
    } operation: {
      let state = CLIServerFeature.State()
      #expect(state.config.settings.shortcuts == .recommended)
    }
  }

  @Test
  func `legacy request defaults additive fields`() throws {
    let data = Data(#"{"command":"list-workspaces","arguments":[]}"#.utf8)

    let request = try JSONDecoder().decode(CLIMessage.Request.self, from: data)

    #expect(request.command == .listWorkspaces)
    #expect(request.arguments.isEmpty)
    #expect(request.options.isEmpty)
    #expect(request.outputFormat == .plain)
  }

  @Test
  func `legacy response is explicitly distinguishable from JSON capability`() throws {
    let data = Data(#"{"success":true,"output":"Browser"}"#.utf8)

    let response = try JSONDecoder().decode(CLIMessage.Response.self, from: data)

    #expect(response.outputFormat == .plain)
  }

  @Test
  func `new request round trips`() throws {
    let request = CLIMessage.Request(
      command: .duplicateWorkspace,
      arguments: ["Work"],
      options: [
        CLIMessage.Option.profile.rawValue: "Dual",
        CLIMessage.Option.name.rawValue: "Work copy",
      ],
      outputFormat: .json,
    )

    let decoded = try JSONDecoder().decode(
      CLIMessage.Request.self,
      from: JSONEncoder().encode(request),
    )

    #expect(decoded == request)
  }
}

// MARK: - CLIQueryTests

struct CLIQueryTests {
  @Test
  func `profile list JSON is structured and marks active profile`() throws {
    let first = Profile(
      id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
      name: "Default",
    )
    let second = Profile(
      id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
      name: "Dual",
    )
    let config = AppConfig(profiles: [first, second], activeProfileId: second.id)

    let response = CLIServerFeature.handle(
      request: .init(command: .listProfiles, outputFormat: .json),
      config: config,
    )

    #expect(response.success)
    let output = try #require(response.output)
    let values = try JSONDecoder().decode([CLIMessage.ProfileInfo].self, from: Data(output.utf8))
    #expect(values.map(\.name) == ["Default", "Dual"])
    #expect(values.map(\.isActive) == [false, true])
  }

  @Test
  func `workspace and app queries can target an inactive profile`() throws {
    let browser = Workspace(
      id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000010")),
      name: "Browser",
      apps: [
        AppAssignment(
          bundleIdentifier: "company.thebrowser.Browser",
          name: "Browser",
          autoOpen: true,
          layout: .tiled,
        )
      ],
    )
    let first = Profile(name: "Default")
    let second = Profile(name: "Dual", workspaces: [browser])
    let config = AppConfig(profiles: [first, second], activeProfileId: first.id)
    let options = [CLIMessage.Option.profile.rawValue: second.id.uuidString]

    let workspaces = CLIServerFeature.handle(
      request: .init(
        command: .listWorkspaces,
        options: options,
        outputFormat: .json,
      ),
      config: config,
    )
    let apps = CLIServerFeature.handle(
      request: .init(
        command: .listApps,
        arguments: [browser.id.uuidString],
        options: options,
        outputFormat: .json,
      ),
      config: config,
    )

    let workspaceOutput = try #require(workspaces.output)
    let workspaceValues = try JSONDecoder().decode(
      [CLIMessage.WorkspaceInfo].self,
      from: Data(workspaceOutput.utf8),
    )
    let appOutput = try #require(apps.output)
    let appValues = try JSONDecoder().decode(
      [CLIMessage.AppInfo].self,
      from: Data(appOutput.utf8),
    )
    #expect(workspaceValues.map(\.name) == ["Browser"])
    #expect(appValues.map(\.bundleIdentifier) == ["company.thebrowser.Browser"])
    #expect(appValues.first?.autoOpen == true)
  }

  @Test
  func `legacy plain queries keep their original line output`() {
    let workspace = Workspace(
      name: "Work",
      apps: [AppAssignment(bundleIdentifier: "com.apple.Terminal", name: "Terminal")],
    )
    let config = AppConfig(profiles: [Profile(name: "Default", workspaces: [workspace])])

    let workspaces = CLIServerFeature.handle(
      request: .init(command: .listWorkspaces),
      config: config,
    )
    let apps = CLIServerFeature.handle(
      request: .init(command: .listApps, arguments: ["Work"]),
      config: config,
    )

    #expect(workspaces.output == "Work")
    #expect(apps.output == "com.apple.Terminal")
  }

  @Test
  func `hook list reports semantic validity`() throws {
    let valid = HookDefinition(
      id: "valid",
      event: .profileChanged,
      command: ["/usr/bin/true"],
    )
    let invalid = HookDefinition(
      id: "invalid id",
      event: .workspaceActivated,
      command: ["/usr/bin/true"],
    )
    let config = AppConfig(hooks: [valid, invalid])

    let response = CLIServerFeature.handle(
      request: .init(command: .listHooks, outputFormat: .json),
      config: config,
    )

    let output = try #require(response.output)
    let hooks = try JSONDecoder().decode([CLIMessage.HookInfo].self, from: Data(output.utf8))
    #expect(hooks.map(\.valid) == [true, false])
  }
}

// MARK: - ConfigPersistenceTests

@Suite(.serialized)
struct ConfigPersistenceTests {
  @Test @MainActor
  func `filesystem self write echo preserves the active profile session`() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatami-config-echo-\(UUID().uuidString)")
    let url = directory.appendingPathComponent("config.toml")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = Profile(name: "First")
    let second = Profile(name: "Second")
    let initial = AppConfig(profiles: [first, second])
    try encodeTatamiConfig(initial).write(to: url, options: .atomic)
    let storage = FileStorageKey<AppConfig>.fileStorage(
      url,
      decode: decodeTatamiConfig,
      encode: encodeTatamiConfig,
    )
    let shared = Shared(wrappedValue: initial, TatamiConfigKey(base: storage))

    shared.withLock { $0.activeProfileId = second.id }
    shared.withLock { $0.mutateProfile(first.id) { $0.name = "Renamed" } }
    try await Task.sleep(for: .milliseconds(300))

    #expect(shared.wrappedValue.activeProfileId == second.id)
    #expect(shared.wrappedValue.profiles.first?.name == "Renamed")
  }

  @Test
  func `revision mismatch preserves the external edit and matching revision commits`() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatami-config-transaction-\(UUID().uuidString)")
    let url = directory.appendingPathComponent("config.toml")
    defer { try? FileManager.default.removeItem(at: directory) }

    let baseline = AppConfig(profiles: [Profile(name: "Baseline")])
    let external = AppConfig(profiles: [Profile(name: "External")])
    let updated = AppConfig(profiles: [Profile(name: "Updated")])
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try encodeTatamiConfig(baseline).write(to: url, options: .atomic)
    let revision = try TatamiConfigTransactionCoordinator.shared.captureRevision(
      expected: baseline,
      at: url,
    )

    let externalData = try encodeTatamiConfig(external)
    try externalData.write(to: url, options: .atomic)
    let externalInode = try fileInode(at: url)
    let exchangeCalled = LockIsolated(false)
    let rejectedBeforeExchange = LockIsolated(false)
    do {
      try TatamiConfigTransactionCoordinator.shared.replace(
        revision: revision,
        with: updated,
        at: url,
        afterInitialExchange: { exchangeCalled.setValue(true) },
      )
      Issue.record("Expected the stale revision to be rejected")
    } catch ConfigPersistenceError.changedOnDisk {
      rejectedBeforeExchange.setValue(true)
    } catch {
      Issue.record("Expected changedOnDisk, got \(error)")
    }
    let preservedData = try Data(contentsOf: url)
    let preserved = try decodeTatamiConfig(preservedData)
    #expect(rejectedBeforeExchange.value)
    #expect(!exchangeCalled.value)
    #expect(preservedData == externalData)
    #expect(try fileInode(at: url) == externalInode)
    #expect(preserved.hasSamePersistedContent(as: external))

    let externalRevision = try Data(contentsOf: url)
    try TatamiConfigTransactionCoordinator.shared.replace(
      revision: externalRevision,
      with: updated,
      at: url,
    )
    let committed = try decodeTatamiConfig(Data(contentsOf: url))
    #expect(committed.hasSamePersistedContent(as: updated))
    #expect(TatamiConfigTransactionCoordinator.shared.consumeSuppressedDidSet(updated))

    let committedRevision = try Data(contentsOf: url)
    let expiredUpdate = AppConfig(profiles: [Profile(name: "Expired")])
    #expect(throws: (any Error).self) {
      try TatamiConfigTransactionCoordinator.shared.replace(
        revision: committedRevision,
        with: expiredUpdate,
        at: url,
        reserve: { false },
      )
    }
    let afterExpiration = try decodeTatamiConfig(Data(contentsOf: url))
    #expect(afterExpiration.hasSamePersistedContent(as: updated))

    let first = Profile(name: "First")
    let second = Profile(name: "Second")
    var active = AppConfig(profiles: [first, second], activeProfileId: second.id)
    TatamiConfigTransactionCoordinator.shared.recordSelfWrite(active)
    active.activeProfileId = nil
    let restored = TatamiConfigTransactionCoordinator.shared.preservingSessionProfile(in: active)
    #expect(restored.activeProfileId == second.id)
    TatamiConfigTransactionCoordinator.shared.recordSelfWrite(AppConfig())
  }

  @Test
  func `same inode rewrite matching candidate bytes preserves the newer external generation`() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatami-config-aba-\(UUID().uuidString)")
    let url = directory.appendingPathComponent("config.toml")
    defer { try? FileManager.default.removeItem(at: directory) }

    let baseline = AppConfig(profiles: [Profile(name: "Baseline")])
    let displacedExternal = AppConfig(profiles: [Profile(name: "External")])
    let updated = AppConfig(profiles: [Profile(name: "Updated")])
    let updatedData = try encodeTatamiConfig(updated)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try encodeTatamiConfig(baseline).write(to: url, options: .atomic)
    let revision = try TatamiConfigTransactionCoordinator.shared.captureRevision(
      expected: baseline,
      at: url,
    )
    let displacedExternalData = try encodeTatamiConfig(displacedExternal)

    let hookError = LockIsolated<String?>(nil)
    let exchangeCalled = LockIsolated(false)
    let inPlaceInodes = LockIsolated<[UInt64]>([])
    #expect(throws: (any Error).self) {
      try TatamiConfigTransactionCoordinator.shared.replace(
        revision: revision,
        with: updated,
        at: url,
        afterPreflightCheck: {
          do {
            // Land a rename-based writer after the raw preflight check so the
            // transaction must still enter the exchange/restore path.
            try displacedExternalData.write(to: url, options: .atomic)
          } catch {
            hookError.setValue(String(describing: error))
          }
        },
        afterInitialExchange: {
          exchangeCalled.setValue(true)
          do {
            let before = try fileInode(at: url)
            // Ensure the same-byte write advances the high-resolution content
            // generation even on a very fast filesystem.
            Thread.sleep(forTimeInterval: 0.02)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: updatedData)
            try handle.synchronize()
            try handle.close()
            let after = try fileInode(at: url)
            inPlaceInodes.setValue([before, after])
          } catch {
            hookError.setValue(String(describing: error))
          }
        },
      )
    }

    #expect(hookError.value == nil)
    #expect(exchangeCalled.value)
    #expect(inPlaceInodes.value.count == 2)
    #expect(inPlaceInodes.value.first == inPlaceInodes.value.last)
    #expect(try Data(contentsOf: url) == updatedData)
    #expect(try fileInode(at: url) == inPlaceInodes.value.last)
  }
}

private func fileInode(at url: URL) throws -> UInt64 {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return try #require((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
}

// MARK: - CLIDomainCommandTests

@MainActor
struct CLIDomainCommandTests {
  @Test
  func `fixed domain command dispatches through the shared hotkey action`() async throws {
    let response = LockIsolated<CLIMessage.Response?>(nil)
    let store = TestStore(initialState: CLIServerFeature.State()) {
      CLIServerFeature()
    }
    store.exhaustivity = .off

    await store.send(.incomingRequest(
      .init(
        command: .dispatchDomainCommand,
        arguments: [CLIMessage.DomainCommand.windowFocusLeft.rawValue],
        outputFormat: .json,
      ),
      reply: CLIReply { response.setValue($0) },
    ))
    await store.receive {
      guard
        case .delegate(.dispatchDomainCommandRequested(.focusLeft, let complete)) = $0
      else {
        return false
      }
      complete(nil)
      return true
    }
    await store.finish()

    let output = try #require(response.value?.output)
    let info = try JSONDecoder().decode(
      CLIMessage.DomainCommandResult.self,
      from: Data(output.utf8),
    )
    #expect(response.value?.success == true)
    #expect(info.command == .windowFocusLeft)
    #expect(info.status == .accepted)
  }

  @Test
  func `workspace activate waits for terminal completion`() async throws {
    let workspace = Workspace(name: "Focus")
    let profile = Profile(name: "Default", workspaces: [workspace])
    let state = CLIServerFeature.State()
    state.$config = Shared(value: AppConfig(
      profiles: [profile],
      activeProfileId: profile.id,
    ))
    let response = LockIsolated<CLIMessage.Response?>(nil)
    let store = TestStore(initialState: state) {
      CLIServerFeature()
    }
    store.exhaustivity = .off

    await store.send(.incomingRequest(
      .init(
        command: .dispatchDomainCommand,
        arguments: [CLIMessage.DomainCommand.workspaceActivate.rawValue, workspace.name],
        outputFormat: .json,
      ),
      reply: CLIReply { response.setValue($0) },
    ))
    #expect(response.value == nil)
    await store.receive {
      guard
        case .delegate(.activateWorkspaceRequested(let id, let complete)) = $0,
        id == workspace.id
      else { return false }
      complete(nil)
      return true
    }
    await store.finish()

    let output = try #require(response.value?.output)
    let info = try JSONDecoder().decode(
      CLIMessage.DomainCommandResult.self,
      from: Data(output.utf8),
    )
    #expect(response.value?.success == true)
    #expect(info.command == .workspaceActivate)
    #expect(info.status == .completed)
  }

  @Test
  func `targeted domain command resolves a workspace name in the requested profile`() async {
    let workspace = Workspace(name: "Coding")
    let active = Profile(name: "Default")
    let target = Profile(name: "Dual", workspaces: [workspace])
    let state = CLIServerFeature.State()
    state.$config = Shared(value: AppConfig(
      profiles: [active, target],
      activeProfileId: active.id,
    ))
    let response = LockIsolated<CLIMessage.Response?>(nil)
    let store = TestStore(initialState: state) {
      CLIServerFeature()
    }
    store.exhaustivity = .off

    await store.send(.incomingRequest(
      .init(
        command: .dispatchDomainCommand,
        arguments: [CLIMessage.DomainCommand.workspaceAssignAppTo.rawValue, workspace.name],
        options: [CLIMessage.Option.profile.rawValue: target.name],
      ),
      reply: CLIReply { response.setValue($0) },
    ))
    await store.receive {
      guard
        case .delegate(.dispatchDomainCommandRequested(
          .assignFocusedAppToWorkspace(let id),
          let complete,
        )) = $0,
        id == workspace.id
      else { return false }
      complete(nil)
      return true
    }
    await store.finish()

    #expect(response.value?.success == true)
  }

  @Test
  func `UUID shaped workspace name falls back from global ID lookup`() async {
    let uuidName = "00000000-0000-0000-0000-00000000cafe"
    let workspace = Workspace(name: uuidName)
    let profile = Profile(name: "Default", workspaces: [workspace])
    let state = CLIServerFeature.State()
    state.$config = Shared(value: AppConfig(
      profiles: [profile],
      activeProfileId: profile.id,
    ))
    let response = LockIsolated<CLIMessage.Response?>(nil)
    let store = TestStore(initialState: state) {
      CLIServerFeature()
    }
    store.exhaustivity = .off

    await store.send(.incomingRequest(
      .init(
        command: .dispatchDomainCommand,
        arguments: [CLIMessage.DomainCommand.workspaceAssignAppTo.rawValue, uuidName],
      ),
      reply: CLIReply { response.setValue($0) },
    ))
    await store.receive {
      guard
        case .delegate(.dispatchDomainCommandRequested(
          .assignFocusedAppToWorkspace(let id),
          let complete,
        )) = $0,
        id == workspace.id
      else { return false }
      complete(nil)
      return true
    }
    await store.finish()

    #expect(response.value?.success == true)
  }

  @Test
  func `borrow rejects a workspace owned by an inactive profile`() async {
    let workspace = Workspace(name: "Scratch")
    let active = Profile(name: "Default")
    let inactive = Profile(name: "Dual", workspaces: [workspace])
    let state = CLIServerFeature.State()
    state.$config = Shared(value: AppConfig(
      profiles: [active, inactive],
      activeProfileId: active.id,
    ))
    let response = LockIsolated<CLIMessage.Response?>(nil)
    let store = TestStore(initialState: state) {
      CLIServerFeature()
    }
    store.exhaustivity = .off

    await store.send(.incomingRequest(
      .init(
        command: .dispatchDomainCommand,
        arguments: [CLIMessage.DomainCommand.workspaceBorrowFrom.rawValue, workspace.id.uuidString],
      ),
      reply: CLIReply { response.setValue($0) },
    ))
    await store.finish()

    #expect(response.value?.success == false)
    #expect(response.value?.error?.contains("active profile") == true)
  }

  @Test
  func `raw generic action names are not a domain command escape hatch`() async {
    let response = LockIsolated<CLIMessage.Response?>(nil)
    let store = TestStore(initialState: CLIServerFeature.State()) {
      CLIServerFeature()
    }
    store.exhaustivity = .off

    await store.send(.incomingRequest(
      .init(command: .dispatchDomainCommand, arguments: ["focus-left"]),
      reply: CLIReply { response.setValue($0) },
    ))
    await store.finish()

    #expect(response.value?.success == false)
    #expect(response.value?.error?.contains("Unknown internal domain command") == true)
  }
}

// MARK: - CLIMutationTests

@MainActor
struct CLIMutationTests {
  @Test
  func `scratchpad activation is rejected instead of leaving A pending reply`() async {
    let scratchpad = Workspace(name: "Scratch", kind: .scratchpad)
    let state = CLIServerFeature.State()
    state.$config = Shared(value: AppConfig(
      profiles: [Profile(name: "Default", workspaces: [scratchpad])]
    ))
    let response = LockIsolated<CLIMessage.Response?>(nil)
    let store = TestStore(initialState: state) {
      CLIServerFeature()
    }
    store.exhaustivity = .off

    await store.send(.incomingRequest(
      .init(command: .activate, arguments: [scratchpad.id.uuidString]),
      reply: CLIReply { response.setValue($0) },
    ))
    await store.finish()

    #expect(response.value?.success == false)
    #expect(response.value?.error?.contains("borrow-only") == true)
  }

  @Test
  func `success reply follows the durable configuration commit`() async {
    let workspace = Workspace(name: "Old")
    let state = CLIServerFeature.State()
    state.$config = Shared(value: AppConfig(
      profiles: [Profile(name: "Default", workspaces: [workspace])]
    ))
    let response = LockIsolated<CLIMessage.Response?>(nil)
    let committedBeforeReply = LockIsolated(false)
    let store = TestStore(initialState: state) {
      CLIServerFeature()
    } withDependencies: {
      $0.configPersistence.commit = { config, baseline, _, updated, reserve in
        committedBeforeReply.setValue(response.value == nil)
        guard reserve() else { throw CancellationError() }
        config.withLock { current in
          guard current.hasSamePersistedContent(as: baseline) else { return }
          current = updated
        }
      }
    }

    await store.send(.incomingRequest(
      .init(command: .renameWorkspace, arguments: [workspace.id.uuidString, "New"]),
      reply: CLIReply { response.setValue($0) },
    )) {
      $0.$config.withLock { $0.mutateWorkspace(workspace.id) { $0.name = "New" } }
    }
    await store.receive {
      guard case .delegate(.configurationChanged) = $0 else { return false }
      return true
    }
    await store.finish()

    #expect(committedBeforeReply.value)
    #expect(response.value?.success == true)
  }

  @Test
  func `renaming workspace persists through shared config and delegates refresh`() async {
    let workspace = Workspace(name: "Old")
    let state = CLIServerFeature.State()
    state.$config = Shared(value: AppConfig(
      profiles: [Profile(name: "Default", workspaces: [workspace])]
    ))
    let response = LockIsolated<CLIMessage.Response?>(nil)
    let store = TestStore(initialState: state) {
      CLIServerFeature()
    }

    await store.send(.incomingRequest(
      .init(command: .renameWorkspace, arguments: [workspace.id.uuidString, "New"]),
      reply: CLIReply { response.setValue($0) },
    )) {
      $0.$config.withLock { $0.mutateWorkspace(workspace.id) { $0.name = "New" } }
    }
    await store.receive {
      guard case .delegate(.configurationChanged) = $0 else { return false }
      return true
    }
    await store.finish()

    #expect(store.state.config.workspace(id: workspace.id)?.name == "New")
    #expect(response.value?.success == true)
  }

  @Test
  func `duplicating workspace copies its layout and delegates refresh`() async throws {
    let workspace = Workspace(name: "Work")
    let shared = Shared(value: AppConfig(
      profiles: [Profile(name: "Default", workspaces: [workspace])]
    ))
    let state = CLIServerFeature.State()
    state.$config = shared
    let snapshot = LayoutSnapshot(tree: .leaf(SlotID(bundleId: "com.apple.Terminal", occurrence: 0)))
    let saved = LockIsolated<[Workspace.ID: LayoutSnapshot]>([:])
    let response = LockIsolated<CLIMessage.Response?>(nil)
    let copyStartedBeforeCommit = LockIsolated(false)
    let store = TestStore(initialState: state) {
      CLIServerFeature()
    } withDependencies: {
      $0.layoutStore.copyLayouts = { mapping in
        copyStartedBeforeCommit.setValue(
          response.value == nil
            && shared.wrappedValue.activeProfile?.workspaces.count == 1
        )
        for (source, destination) in mapping where source == workspace.id {
          saved.withValue { $0[destination] = snapshot }
        }
        return true
      }
    }
    store.exhaustivity = .off

    await store.send(.incomingRequest(
      .init(command: .duplicateWorkspace, arguments: [workspace.id.uuidString]),
      reply: CLIReply { response.setValue($0) },
    ))
    await store.receive {
      guard case .duplicationPrepared = $0 else { return false }
      return true
    }
    await store.finish()

    let duplicate = try #require(
      store.state.config.activeProfile?.workspaces.first(where: { $0.id != workspace.id })
    )
    #expect(duplicate.name == "Work copy")
    #expect(copyStartedBeforeCommit.value)
    #expect(saved.value[duplicate.id] == snapshot)
    #expect(response.value?.success == true)
  }

  @Test
  func `layout copy failure does not publish a partial duplicate`() async {
    let workspace = Workspace(name: "Work")
    let state = CLIServerFeature.State()
    state.$config = Shared(value: AppConfig(
      profiles: [Profile(name: "Default", workspaces: [workspace])]
    ))
    let response = LockIsolated<CLIMessage.Response?>(nil)
    let store = TestStore(initialState: state) {
      CLIServerFeature()
    } withDependencies: {
      $0.layoutStore.copyLayouts = { _ in false }
    }
    store.exhaustivity = .off

    await store.send(.incomingRequest(
      .init(command: .duplicateWorkspace, arguments: [workspace.id.uuidString]),
      reply: CLIReply { response.setValue($0) },
    ))
    await store.finish()

    #expect(store.state.config.activeProfile?.workspaces.map(\.id) == [workspace.id])
    #expect(response.value?.success == false)
    #expect(response.value?.error?.contains("configuration was not changed") == true)
  }

  @Test
  func `expired reply lease prevents a prepared duplicate from committing`() async {
    let workspace = Workspace(name: "Work")
    let state = CLIServerFeature.State()
    state.$config = Shared(value: AppConfig(
      profiles: [Profile(name: "Default", workspaces: [workspace])]
    ))
    let cleared = LockIsolated<[Workspace.ID]>([])
    let response = LockIsolated<CLIMessage.Response?>(nil)
    let reply = CLIReply(
      claim: { false },
      finish: { response.setValue($0) },
    )
    let store = TestStore(initialState: state) {
      CLIServerFeature()
    } withDependencies: {
      $0.layoutStore.copyLayouts = { _ in true }
      $0.layoutStore.removeLayouts = { ids in
        cleared.withValue { $0.append(contentsOf: ids) }
        return true
      }
    }
    store.exhaustivity = .off

    await store.send(.incomingRequest(
      .init(command: .duplicateWorkspace, arguments: [workspace.id.uuidString]),
      reply: reply,
    ))
    await store.finish()

    #expect(store.state.config.activeProfile?.workspaces.map(\.id) == [workspace.id])
    #expect(response.value == nil)
    #expect(cleared.value.count == 1)
  }

  @Test
  func `config write failure rejects duplicate and cleans copied layout`() async {
    struct WriteFailure: Error { }

    let workspace = Workspace(name: "Work")
    let state = CLIServerFeature.State()
    state.$config = Shared(value: AppConfig(
      profiles: [Profile(name: "Default", workspaces: [workspace])]
    ))
    let cleaned = LockIsolated<[Workspace.ID]>([])
    let response = LockIsolated<CLIMessage.Response?>(nil)
    let store = TestStore(initialState: state) {
      CLIServerFeature()
    } withDependencies: {
      $0.layoutStore.copyLayouts = { _ in true }
      $0.layoutStore.removeLayouts = { ids in
        cleaned.withValue { $0.append(contentsOf: ids) }
        return true
      }
      $0.configPersistence.commit = { _, _, _, _, _ in throw WriteFailure() }
    }
    store.exhaustivity = .off

    await store.send(.incomingRequest(
      .init(command: .duplicateWorkspace, arguments: [workspace.id.uuidString]),
      reply: CLIReply { response.setValue($0) },
    ))
    await store.finish()

    #expect(store.state.config.activeProfile?.workspaces.map(\.id) == [workspace.id])
    #expect(cleaned.value.count == 1)
    #expect(response.value?.success == false)
    #expect(response.value?.error?.contains("config.toml could not be saved") == true)
  }

  @Test
  func `unknown duplicate outcome preserves copied layout for recovery`() async {
    let workspace = Workspace(name: "Work")
    let state = CLIServerFeature.State()
    state.$config = Shared(value: AppConfig(
      profiles: [Profile(name: "Default", workspaces: [workspace])]
    ))
    let cleaned = LockIsolated<[Workspace.ID]>([])
    let response = LockIsolated<CLIMessage.Response?>(nil)
    let store = TestStore(initialState: state) {
      CLIServerFeature()
    } withDependencies: {
      $0.layoutStore.copyLayouts = { _ in true }
      $0.layoutStore.removeLayouts = { ids in
        cleaned.withValue { $0.append(contentsOf: ids) }
        return true
      }
      $0.configPersistence.commit = { _, _, _, _, reserve in
        _ = reserve()
        throw ConfigPersistenceError.outcomeUnknown(recoveryPath: nil)
      }
    }
    store.exhaustivity = .off

    await store.send(.incomingRequest(
      .init(command: .duplicateWorkspace, arguments: [workspace.id.uuidString]),
      reply: CLIReply { response.setValue($0) },
    ))
    await store.finish()

    #expect(cleaned.value.isEmpty)
    #expect(response.value?.success == false)
    #expect(response.value?.error?.hasPrefix("Command outcome is unknown") == true)
  }
}
