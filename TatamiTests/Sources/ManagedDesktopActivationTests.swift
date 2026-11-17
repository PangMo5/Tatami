// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import Testing
@testable import TatamiKit

@MainActor
struct ManagedDesktopActivationTests {

  // MARK: Internal

  @Test(arguments: [false, true], [false, true])
  func `explicit selection waits for verified home before reconciling the selected workspace`(
    succeeds: Bool,
    alreadyActive: Bool,
  ) async throws {
    let current = Workspace(name: "Current")
    var target = Workspace(name: "Target", apps: [
      AppAssignment(bundleIdentifier: "app.editor", name: "Editor"),
      AppAssignment(bundleIdentifier: "app.review", name: "Review"),
    ])
    target.displayHint = DesktopSpacesTests.left
    var initial = Self.state([current, target])
    if alreadyActive {
      initial.activeWorkspacesByDisplay[DesktopSpacesTests.left] = target.id
      initial.tilingTrees[target.id] = .leaf(WindowKey(pid: 1, windowID: 101, bundleId: "app.editor"))
    }
    let originalWorkspace = alreadyActive ? target.id : current.id
    let started = AsyncStream<ManagedDesktopPreparation>.makeStream()
    let results = AsyncStream<ManagedDesktopPreparationResult>.makeStream()
    let activations = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: initial) { WorkspaceActivationFeature() } withDependencies: {
      $0.continuousClock = TestClock()
      $0.sls.desktopSpaces = { DesktopSpacesTests.spaces(left: 3) }
      $0.managedDesktop.prepare = { request in
        started.continuation.yield(request)
        var iterator = results.stream.makeAsyncIterator()
        return await iterator.next() ?? .cancelled
      }
      $0.workspaceManager.activate = { request in activations.withValue { $0.append(request) } }
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off
    await store.send(.activate(workspaceId: target.id, setFocus: true, interactionDisplay: DesktopSpacesTests.left))
    await store.receive {
      if case .desktopSpacesResolved = $0 {
        true
      } else {
        false
      }
    }
    var iterator = started.stream.makeAsyncIterator()
    let preparation = try #require(await iterator.next())
    #expect(preparation.display == DesktopSpacesTests.left)
    #expect(preparation.home == 1)
    #expect(preparation.bundleIDs == ["app.editor", "app.review", "app.shared"])
    #expect(activations.value.isEmpty)
    #expect(store.state.activeWorkspace(on: DesktopSpacesTests.left) == originalWorkspace)
    #expect(!store.state.canManageWorkspace(target.id))
    results.continuation.yield(succeeds ? .prepared(DesktopSpacesTests.spaces()) : .failed("Native return failed"))
    results.continuation.finish()
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.pendingManagedDesktopActivation == nil)
    #expect(store.state.desktops.home(on: DesktopSpacesTests.left) == 1)
    #expect(activations.value.map(\.workspace.id) == (succeeds ? [target.id] : []))
    #expect(store.state.activeWorkspace(on: DesktopSpacesTests.left) == (succeeds ? target.id : originalWorkspace))
  }

  @Test
  func `a superseded native completion cannot activate or complete a newer CLI request`() async throws {
    let current = Workspace(name: "Current")
    let target = Workspace(name: "Target")
    var initial = Self.state([current, target])
    let staleID = UUID()
    initial.pendingManagedDesktopActivation = .init(
      id: staleID,
      workspace: target,
      profileID: try #require(initial.config.activeProfile?.id),
      display: DesktopSpacesTests.left,
      setFocus: true,
      interactionDisplay: DesktopSpacesTests.left,
      followsCursor: false,
      continuesCLIActivation: false,
      cliRequestID: nil,
      requestedAtUptime: ProcessInfo.processInfo.systemUptime,
    )
    let completions = LockIsolated<[String?]>([])
    let request = WorkspaceActivationFeature.CLIActivationRequest(
      target: .workspace(current.id),
      complete: { error in completions.withValue { $0.append(error) } },
    )
    let store = TestStore(initialState: initial) { WorkspaceActivationFeature() }
    store.exhaustivity = .off
    await store.send(.trackCLIActivation(request, joinCurrentActivation: false))
    await store.send(.managedDesktopPrepared(id: staleID, spaces: DesktopSpacesTests.spaces(), error: nil, cancelled: false))
    await store.finish()
    #expect(store.state.pendingManagedDesktopActivation == nil)
    #expect(store.state.pendingCLIActivation?.id == request.id)
    #expect(store.state.activeWorkspace(on: DesktopSpacesTests.left) == current.id)
    #expect(completions.value.isEmpty)
  }

  @Test
  func `a native check without mutations preserves the active workspace focus transfer`() throws {
    let workspace = Workspace(name: "Current")
    var state = Self.state([workspace])
    state.desktops.observe(DesktopSpacesTests.spaces(), displays: state.connectedDisplays)
    state.tilingTrees[workspace.id] = .leaf(WindowKey(pid: 1, windowID: 101, bundleId: "app.editor"))
    let id = UUID()
    state.pendingManagedDesktopActivation = .init(
      id: id,
      workspace: workspace,
      profileID: try #require(state.config.activeProfile?.id),
      display: DesktopSpacesTests.left,
      setFocus: true,
      interactionDisplay: DesktopSpacesTests.left,
      followsCursor: false,
      continuesCLIActivation: false,
      cliRequestID: nil,
      requestedAtUptime: ProcessInfo.processInfo.systemUptime,
      isPreparing: true,
    )
    _ = WorkspaceActivationFeature().completeManagedDesktopPreparation(
      id: id,
      spaces: DesktopSpacesTests.spaces(),
      error: nil,
      cancelled: false,
      requiresReconciliation: false,
      state: &state,
    )
    #expect(!state.isActivating)
    #expect(state.activeWorkspace(on: DesktopSpacesTests.left) == workspace.id)
    #expect(state.pendingManagedDesktopActivation == nil)
  }

  @Test(arguments: [
    (Bool?.some(true), Int32?.some(10), NativeWindowIdentityStatus.current),
    (Bool?.some(true), Int32?.none, NativeWindowIdentityStatus.unavailable),
    (Bool?.some(true), Int32?.some(20), NativeWindowIdentityStatus.changed),
    (Bool?.some(false), Int32?.some(10), NativeWindowIdentityStatus.changed),
    (Bool?.some(false), Int32?.none, NativeWindowIdentityStatus.changed),
    (Bool?.none, Int32?.some(10), NativeWindowIdentityStatus.unavailable),
    (Bool?.none, Int32?.some(20), NativeWindowIdentityStatus.changed),
  ])
  func `a transition gap cannot authorize replacement or reject a surviving process`(
    processMatches: Bool?,
    ownerPID: Int32?,
    expected: NativeWindowIdentityStatus,
  ) {
    #expect(NativeWindowIdentityStatus.observed(processMatches: processMatches, ownerPID: ownerPID, expectedPID: 10) == expected)
  }

  // MARK: Private

  private static func state(_ workspaces: [Workspace]) -> WorkspaceActivationFeature.State {
    var state = WorkspaceActivationFeature.State()
    state.$config.withLock {
      $0.profiles = [Profile(name: "Default", workspaces: IdentifiedArray(uniqueElements: workspaces))]
      $0.sharedApps = [SharedApp(bundleIdentifier: "app.shared", name: "Shared")]
    }
    state.connectedDisplays = [DesktopSpacesTests.left, DesktopSpacesTests.right]
    state.focusedDisplay = DesktopSpacesTests.left
    state.activeWorkspacesByDisplay[DesktopSpacesTests.left] = workspaces[0].id
    state.desktops.observe(DesktopSpacesTests.spaces(), displays: state.connectedDisplays)
    state.desktops.observe(DesktopSpacesTests.spaces(left: 3), displays: state.connectedDisplays)
    return state
  }

}
