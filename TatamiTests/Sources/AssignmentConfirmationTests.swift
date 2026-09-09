// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import CustomDump
import Foundation
import Testing
@testable import TatamiKit

@MainActor
struct AssignmentConfirmationTests {

  // MARK: Internal

  @Test(arguments: [false, true])
  func `moving waits for confirmation and changes only the current profile`(confirmed: Bool) async {
    let fixture = makeFixture()
    var state = fixture.state
    state.isTilingPaused = true
    state.focusedDisplay = display
    state.activeWorkspacesByDisplay[display] = fixture.source.id
    state.$config.withLock {
      $0.mutateProfile(fixture.otherProfile.id) {
        $0.workspaces = [Workspace(id: UUID(8), name: "Independent", apps: fixture.source.apps)]
      }
      $0.mutateActiveProfile {
        $0.workspaces.append(fixture.target)
        $0.workspaces.append(Workspace(id: UUID(9), name: "Also Assigned", apps: fixture.source.apps))
      }
      $0.sharedApps = [SharedApp(bundleIdentifier: "app.source", name: "Source App", layout: .unmanaged)]
    }
    let replies = AsyncStream<Bool>.makeStream()
    let store = makeStore(
      Fixture(state: state, source: fixture.source, target: fixture.target, otherProfile: fixture.otherProfile),
      replies: replies.stream,
    )
    store.exhaustivity = .off
    let before = store.state.config
    await store.send(.membershipEditResolved(
      bundleId: "app.source",
      name: "Source App",
      edit: .move(to: fixture.target.id),
      pid: 42,
      interactionDisplay: display,
    ))
    expectNoDifference(store.state.config, before)
    #expect(store.state.pendingAssignment?.request.operation == .move)
    replies.continuation.yield(confirmed)
    await store.receive(\.assignmentConfirmationResponse)
    if confirmed {
      await store.receive(\.activate)
      await store.finish()
      var expected = before
      expected.moveApp(bundleId: "app.source", name: "Source App", to: fixture.target.id)
      expectNoDifference(store.state.config.profiles, expected.profiles)
      expectNoDifference(store.state.config.sharedApps, before.sharedApps)
    } else {
      await store.finish()
      expectNoDifference(store.state.config, before)
    }
  }

  @Test
  func `a move to an inactive profile never removes current memberships`() async {
    let fixture = makeFixture()
    let replies = AsyncStream<Bool>.makeStream()
    let store = makeStore(fixture, replies: replies.stream)
    store.exhaustivity = .off
    let before = store.state.config
    await store.send(.membershipEditResolved(
      bundleId: "app.source",
      name: "Source App",
      edit: .move(to: fixture.target.id),
      pid: 42,
    ))
    #expect(store.state.pendingAssignment == nil)
    expectNoDifference(store.state.config, before)
    await store.finish()
  }

  @Test(arguments: [false, true])
  func `assignment changes nothing until the captured request is confirmed`(confirmed: Bool) async throws {
    let fixture = makeFixture()
    let replies = AsyncStream<Bool>.makeStream()
    let store = makeStore(fixture, replies: replies.stream)
    store.exhaustivity = .off
    let before = store.state.config

    await store.send(.membershipEditResolved(
      bundleId: "app.source",
      name: "Source App",
      edit: .assign(to: fixture.target.id),
      pid: 42,
      interactionDisplay: display,
    ))
    expectNoDifference(store.state.config, before)
    #expect(store.state.pendingAssignment?.request.appName == "Source App")
    #expect(store.state.pendingAssignment?.request.workspaceName == "Target")
    #expect(store.state.pendingAssignment?.request.profileName == "Other Profile")
    #expect(store.state.pendingAssignment?.request.display == display)
    let id = try #require(store.state.pendingAssignment?.request.id)

    replies.continuation.yield(confirmed)
    await store.receive(\.assignmentConfirmationResponse)
    if confirmed {
      await store.receive {
        guard case .delegate(.profileSwitchRequested(let profileID, let workspaceID, let commandDisplay)) = $0
        else { return false }
        return profileID == fixture.otherProfile.id && workspaceID == fixture.target.id && commandDisplay == display
      }
      #expect(store.state.config.profiles.last?.workspaces[id: fixture.target.id]?.apps.map(\.bundleIdentifier) == ["app.source"])
      #expect(store.state.config.activeProfile?.workspaces[id: fixture.source.id]?.apps.map(\.bundleIdentifier) == ["app.source"])
    } else {
      expectNoDifference(store.state.config, before)
    }
    #expect(store.state.pendingAssignment == nil)
    // A duplicated callback cannot execute the same command again.
    let after = store.state.config
    await store.send(.assignmentConfirmationResponse(id: id, confirmed: true))
    expectNoDifference(store.state.config, after)
    await store.finish()
  }

  @Test(arguments: ["profile", "workspace", "rename", "app", "relaunch"])
  func `confirmation rejects a changed destination or source`(_ changed: String) async {
    let fixture = makeFixture()
    let replies = AsyncStream<Bool>.makeStream()
    let frontmost = LockIsolated(FrontmostApp(pid: 42, bundleId: "app.source", name: "Source App"))
    let store = makeStore(fixture, replies: replies.stream, frontmost: frontmost)
    store.exhaustivity = .off
    await store.send(.membershipEditResolved(
      bundleId: "app.source",
      name: "Source App",
      edit: .assign(to: fixture.target.id),
      pid: 42,
    ))
    switch changed {
    case "profile": fixture.state.$config.withLock { $0.activeProfileId = fixture.otherProfile.id }

    case "workspace": fixture.state.$config
      .withLock { $0.mutateProfile(fixture.otherProfile.id) { $0.workspaces.remove(id: fixture.target.id) } }

    case "rename": fixture.state.$config.withLock { $0.mutateWorkspace(fixture.target.id) { $0.name = "Changed" } }

    case "app": frontmost.setValue(FrontmostApp(pid: 43, bundleId: "app.other", name: "Other"))

    default: frontmost.setValue(FrontmostApp(pid: 44, bundleId: "app.source", name: "Source App"))
    }
    let before = store.state.config
    replies.continuation.yield(true)
    await store.receive(\.assignmentConfirmationResponse)
    await store.finish()
    expectNoDifference(store.state.config, before)
    #expect(store.state.pendingAssignment == nil)
  }

  @Test
  func `an older request cannot complete the current confirmation`() async {
    let fixture = makeFixture()
    let replies = AsyncStream<Bool>.makeStream()
    let store = makeStore(fixture, replies: replies.stream)
    store.exhaustivity = .off
    await store.send(.membershipEditResolved(
      bundleId: "app.source",
      name: "Source App",
      edit: .assign(to: fixture.target.id),
      pid: 42,
    ))
    let pending = store.state.pendingAssignment
    let before = store.state.config
    await store.send(.assignmentConfirmationResponse(id: UUID(999), confirmed: true))
    expectNoDifference(store.state.pendingAssignment, pending)
    expectNoDifference(store.state.config, before)
    replies.continuation.yield(false)
    await store.receive(\.assignmentConfirmationResponse)
    await store.finish()
  }

  @Test(arguments: [
    WorkspaceActivationFeature.MembershipEdit.toggleInActiveWorkspace,
    .toggleShared,
    .toggleFloating,
    .toggleSharedFloating,
  ], [false, true])
  func `persistent membership and layout commands wait for confirmation`(
    edit: WorkspaceActivationFeature.MembershipEdit,
    confirmed: Bool,
  ) async {
    let fixture = makeFixture()
    var state = fixture.state
    state.isTilingPaused = true
    state.focusedDisplay = display
    state.activeWorkspacesByDisplay[display] = fixture.source.id
    state.$config.withLock { $0.sharedApps = [SharedApp(bundleIdentifier: "app.source", name: "Source App")] }
    let before = state.config
    let replies = AsyncStream<Bool>.makeStream()
    let store = makeStore(
      Fixture(state: state, source: fixture.source, target: fixture.target, otherProfile: fixture.otherProfile),
      replies: replies.stream,
    )
    store.exhaustivity = .off
    await store.send(.membershipEditResolved(bundleId: "app.source", name: "Source App", edit: edit, pid: 42))
    #expect(store.state.pendingAssignment != nil)
    expectNoDifference(store.state.config, before)
    replies.continuation.yield(confirmed)
    await store.receive(\.assignmentConfirmationResponse)
    await store.finish()
    var expected = before
    if confirmed {
      switch edit {
      case .toggleInActiveWorkspace: _ = expected.toggleMembership(
          bundleId: "app.source",
          name: "Source App",
          in: fixture.source.id,
        )

      case .toggleShared: _ = expected.toggleSharedMembership(bundleId: "app.source", name: "Source App")

      case .toggleFloating: _ = expected.toggleFloating(bundleId: "app.source", name: "Source App", in: fixture.source.id)

      case .toggleSharedFloating: _ = expected.toggleSharedFloating(bundleId: "app.source", name: "Source App")

      default: break
      }
    }
    expectNoDifference(store.state.config.profiles, expected.profiles)
    expectNoDifference(store.state.config.sharedApps, expected.sharedApps)
  }

  @Test(arguments: [false, true])
  func `dont ask again is saved only on confirmation`(_ confirmed: Bool) async {
    let fixture = makeFixture()
    let replies = AsyncStream<Bool>.makeStream()
    let store = makeStore(fixture, replies: replies.stream, suppressFuture: true)
    store.exhaustivity = .off
    await store.send(.membershipEditResolved(
      bundleId: "app.source",
      name: "Source App",
      edit: .assign(to: fixture.target.id),
      pid: 42,
    ))
    replies.continuation.yield(confirmed)
    await store.receive(\.assignmentConfirmationResponse)
    await store.finish()
    #expect(store.state.config.settings.confirmations[.addWorkspaceApp] == !confirmed)
    #expect(store.state.config.settings.confirmations[.moveWorkspaceApp])
    #expect(store.state.config.settings.confirmations[.addSharedApp])
  }

  @Test
  func `a changed membership cannot invert the meaning of a pending toggle`() async {
    let fixture = makeFixture()
    var state = fixture.state
    state.focusedDisplay = display
    state.activeWorkspacesByDisplay[display] = fixture.source.id
    let replies = AsyncStream<Bool>.makeStream()
    let store = makeStore(
      Fixture(state: state, source: fixture.source, target: fixture.target, otherProfile: fixture.otherProfile),
      replies: replies.stream,
      suppressFuture: true,
    )
    store.exhaustivity = .off
    await store.send(.membershipEditResolved(bundleId: "app.source", name: "Source App", edit: .toggleInActiveWorkspace, pid: 42))
    #expect(store.state.pendingAssignment?.request.operation == .removeWorkspace)
    state.$config.withLock { $0.mutateWorkspace(fixture.source.id) { $0.apps = [] } }
    let changed = store.state.config
    replies.continuation.yield(true)
    await store.receive(\.assignmentConfirmationResponse)
    await store.finish()
    expectNoDifference(store.state.config, changed)
  }

  @Test(arguments: [-1, 1])
  func `move icon follows the requested direction even with the same destination`(_ direction: Int) async {
    let fixture = makeFixture()
    fixture.state.$config.withLock { $0.mutateActiveProfile { $0.workspaces.append(fixture.target) } }
    let replies = AsyncStream<Bool>.makeStream()
    let store = makeStore(fixture, replies: replies.stream)
    store.exhaustivity = .off
    await store.send(.membershipEditResolved(
      bundleId: "app.source",
      name: "Source App",
      edit: .move(to: fixture.target.id, direction: direction),
      pid: 42,
    ))
    #expect(store.state.pendingAssignment?.request.symbol == (direction < 0 ? "arrow.left.square" : "arrow.right.square"))
    replies.continuation.yield(false)
    await store.receive(\.assignmentConfirmationResponse)
    await store.finish()
  }

  @Test
  func `cancel during replacement lookup never reopens the confirmation`() async throws {
    let fixture = makeFixture()
    let replies = AsyncStream<Bool>.makeStream()
    let lookup = AsyncStream<FrontmostApp?>.makeStream()
    let store = makeStore(fixture, replies: replies.stream, lookup: {
      for await app in lookup.stream { return .value(app) }
      return .value(nil)
    })
    store.exhaustivity = .off
    let before = store.state.config
    await store.send(.membershipEditResolved(
      bundleId: "app.source",
      name: "Source App",
      edit: .assign(to: fixture.target.id),
      pid: 42,
    ))
    let oldID = try #require(store.state.pendingAssignment?.request.id)
    await store.send(.membershipEdit(.assign(to: fixture.target.id)))
    #expect(store.state.membershipRequestID != oldID)
    replies.continuation.yield(false)
    await store.receive(\.assignmentConfirmationResponse)
    lookup.continuation.yield(FrontmostApp(pid: 42, bundleId: "app.source", name: "Source App"))
    await store.finish()
    #expect(store.state.pendingAssignment == nil)
    #expect(store.state.membershipRequestID == nil)
    expectNoDifference(store.state.config, before)
  }

  @Test(arguments: [false, true])
  func `assignment shows a completed result only after accepting the current confirmation`(_ confirmed: Bool) async {
    let fixture = makeFixture()
    let replies = AsyncStream<Bool>.makeStream()
    let presentations = LockIsolated<[ActionHUDRequest]>([])
    let store = makeStore(fixture, replies: replies.stream, presentations: presentations)
    store.exhaustivity = .off
    await store.send(.membershipEditResolved(
      bundleId: "app.source",
      name: "Source App",
      edit: .assign(to: fixture.target.id),
      pid: 42,
    ))
    #expect(presentations.value.isEmpty)
    let pendingID = store.state.pendingAssignment?.request.id
    replies.continuation.yield(confirmed)
    await store.receive(\.assignmentConfirmationResponse)
    await store.finish()
    #expect(presentations.value.count == (confirmed ? 1 : 0))
    if confirmed {
      #expect(presentations.value.first?.priority == .completion)
      #expect(presentations.value.first?.contextID == fixture.target.id)
      #expect(presentations.value.first?.replacingConfirmationID == pendingID)
    }
  }

  // MARK: Private

  private struct Fixture {
    let state: WorkspaceActivationFeature.State
    let source: Workspace
    let target: Workspace
    let otherProfile: Profile
  }

  private let display = DisplayName(uuid: "command-display", name: "Command Display")

  private func makeFixture() -> Fixture {
    let source = Workspace(id: UUID(1), name: "Source", apps: [AppAssignment(bundleIdentifier: "app.source", name: "Source App")])
    let target = Workspace(id: UUID(2), name: "Target")
    let profile = Profile(id: UUID(3), name: "Current Profile", workspaces: [source])
    let otherProfile = Profile(id: UUID(4), name: "Other Profile", workspaces: [target])
    let state = WorkspaceActivationFeature.State()
    state.$config.withLock {
      $0.profiles = [profile, otherProfile]
      $0.activeProfileId = profile.id
      $0.settings.hud.enabled = false // Safety confirmation is not optional feedback.
    }
    return Fixture(state: state, source: source, target: target, otherProfile: otherProfile)
  }

  private func makeStore(
    _ fixture: Fixture,
    replies: AsyncStream<Bool>,
    suppressFuture: Bool = false,
    presentations: LockIsolated<[ActionHUDRequest]> = LockIsolated([]),
    lookup: @escaping @Sendable () async -> AsyncWindowSnapshot<FrontmostApp?> = { .unavailable },
    frontmost: LockIsolated<FrontmostApp> = LockIsolated(FrontmostApp(pid: 42, bundleId: "app.source", name: "Source App")),
  ) -> TestStoreOf<WorkspaceActivationFeature> {
    let display = display
    return TestStore(initialState: fixture.state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.displays.current = { display }
      $0.displays.all = { [display] }
      $0.workspaceManager.activate = { _ in }
      $0.screenRecording.isGranted = { true }
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
      $0.windowSnapshot.frontmostApp = { frontmost.value }
      $0.windowSnapshot.frontmostAppAsync = lookup
      $0.workspaceHUD.showAction = { request in presentations.withValue { $0.append(request) } }
      $0.workspaceHUD.confirmAssignment = { _ in
        for await reply in replies { return ActionConfirmationResult(confirmed: reply, suppressFuture: suppressFuture) }
        return .cancelled
      }
    }
  }

}
