import ComposableArchitecture
import Foundation
import Testing
@testable import TatamiKit

/// Reducer-level tests for the activation core. These became possible
/// once the live AppKit/AX reads moved behind `WindowSnapshotClient` /
/// `DisplayClient` — the reducer no longer touches the real window
/// server on the test host.
@MainActor
struct WorkspaceActivationFeatureTests {
  /// Matches `DisplayClient.testValue.current()`.
  private static let display = DisplayName("Test Display")

  private static func makeState(
    workspaces: [Workspace],
    mutate: (inout WorkspaceActivationFeature.State) -> Void = { _ in }
  ) -> WorkspaceActivationFeature.State {
    var state = WorkspaceActivationFeature.State()
    state.$config.withLock {
      $0.profiles = [Profile(name: "Default", workspaces: IdentifiedArray(uniqueElements: workspaces))]
    }
    mutate(&state)
    return state
  }

  // MARK: - Cycling

  @Test
  func cycleNextLoopsPastTheLastWorkspace() async {
    let ws1 = Workspace(name: "one")
    let ws2 = Workspace(name: "two")
    let ws3 = Workspace(name: "three")
    let state = Self.makeState(workspaces: [ws1, ws2, ws3]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = ws3.id
    }
    // The test pins the cycle decision; the activation pipeline the
    // dispatched `.activate` kicks off (latest-wins, never dropped) is
    // out of scope — stub its dependencies and skip its follow-ups.
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activateNext)
    await store.receive {
      guard case .activate(let id, let setFocus) = $0 else { return false }
      return id == ws1.id && setFocus
    }
  }

  @Test
  func cycleWithoutLoopStopsAtTheEnd() async {
    let ws1 = Workspace(name: "one")
    let ws2 = Workspace(name: "two")
    let state = Self.makeState(workspaces: [ws1, ws2]) {
      $0.$config.withLock { $0.settings.switching.loop = false }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = ws2.id
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    }

    // At the last workspace with looping off there is no eligible target.
    await store.send(.activateNext)
  }

  @Test
  func cycleSkipsWorkspacesWithNoRunningApp() async {
    let ws1 = Workspace(
      name: "one", apps: [AppAssignment(bundleIdentifier: "app.one", name: "One")]
    )
    let ws2 = Workspace(
      name: "two", apps: [AppAssignment(bundleIdentifier: "app.two", name: "Two")]
    )
    let ws3 = Workspace(
      name: "three", apps: [AppAssignment(bundleIdentifier: "app.three", name: "Three")]
    )
    let state = Self.makeState(workspaces: [ws1, ws2, ws3]) {
      $0.$config.withLock { $0.settings.switching.skipEmpty = true }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = ws1.id
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.windowSnapshot.runningBundleIds = { ["app.three"] }
      $0.continuousClock = TestClock()
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    // ws2 has no running app → the cycle lands on ws3.
    await store.send(.activateNext)
    await store.receive {
      guard case .activate(let id, _) = $0 else { return false }
      return id == ws3.id
    }
  }

  @Test
  func cycleAnchorsAtTheInFlightActivationTarget() async {
    let ws1 = Workspace(name: "one")
    let ws2 = Workspace(name: "two")
    let ws3 = Workspace(name: "three")
    // ws1 is the *completed* workspace, but a switch to ws2 is still in
    // flight. Cycling must advance from ws2 — anchoring at the completed
    // one made every rapid press re-target the same slow workspace.
    let state = Self.makeState(workspaces: [ws1, ws2, ws3]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = ws1.id
      $0.isActivating = true
      $0.activatingWorkspaceID = ws2.id
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activateNext)
    await store.receive {
      guard case .activate(let id, _) = $0 else { return false }
      return id == ws3.id
    }
  }

  // MARK: - Activation bookkeeping

  @Test
  func activateSupersedesTheInFlightActivation() async {
    let ws1 = Workspace(name: "one")
    let ws2 = Workspace(name: "two")
    let state = Self.makeState(workspaces: [ws1, ws2]) {
      $0.focusedDisplay = Self.display
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    // Latest-wins: the second press is never dropped — it re-enters the
    // pipeline and re-anchors the in-flight target.
    await store.send(.activate(workspaceId: ws1.id, setFocus: false))
    #expect(store.state.isActivating)
    #expect(store.state.activatingWorkspaceID == ws1.id)
    await store.send(.activate(workspaceId: ws2.id, setFocus: false))
    #expect(store.state.activatingWorkspaceID == ws2.id)
    await store.skipReceivedActions()
  }

  @Test
  func activationDiscoversARegisteredAndSharedAppOnce() async {
    let app = AppAssignment(bundleIdentifier: "app.shared", name: "Shared")
    let ws = Workspace(name: "one", apps: [app])
    let state = Self.makeState(workspaces: [ws]) {
      $0.$config.withLock {
        $0.sharedApps = [SharedApp(bundleIdentifier: "app.shared", name: "Shared")]
      }
      $0.focusedDisplay = Self.display
    }
    // An app registered to the workspace AND shared sits in both source
    // lists; discovering it twice tiled its window twice ([72, 72]).
    let discovered = LockIsolated<[String]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
      $0.windowSnapshot.cachedKeys = { bundleIds, _ in
        discovered.withValue { $0 += bundleIds }
        return []
      }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: ws.id, setFocus: false))
    await store.receive {
      guard case .activationCompleted = $0 else { return false }
      return true
    }
    #expect(discovered.value.filter { $0 == "app.shared" }.count == 1)
  }

  @Test
  func activationCompletedRecordsDisplayAndRecentWorkspace() async {
    let ws1 = Workspace(name: "one")
    let ws2 = Workspace(name: "two")
    let state = Self.makeState(workspaces: [ws1, ws2]) {
      $0.activeWorkspacesByDisplay[Self.display] = ws1.id
      $0.isActivating = true
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    }

    await store.send(.activationCompleted(workspaceId: ws2.id, display: Self.display)) {
      $0.isActivating = false
      $0.previousWorkspacesByDisplay[Self.display] = ws1.id
      $0.activeWorkspacesByDisplay[Self.display] = ws2.id
      $0.lastActiveDisplay[ws2.id] = Self.display
    }
  }

  @Test
  func activationWatchdogReleasesTheGate() async {
    let ws1 = Workspace(name: "one")
    let state = Self.makeState(workspaces: [ws1]) {
      $0.isActivating = true
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    }

    await store.send(.activationTimedOut) {
      $0.isActivating = false
    }
    // Idempotent when nothing is in flight.
    await store.send(.activationTimedOut)
  }

  // MARK: - Drag commit precedence

  @Test
  func moveEventsDoNotDemoteAPendingResize() async {
    let key = WindowKey(pid: 1, windowID: 100, bundleId: "app.one")
    let resizeFrame = CGRect(x: 0, y: 0, width: 500, height: 400)
    let store = TestStore(initialState: Self.makeState(workspaces: [])) {
      WorkspaceActivationFeature()
    } withDependencies: {
      // The drag pipeline drives the preview overlay on every event.
      $0.dragPreview.show = { _, _ in }
      $0.dragPreview.hide = {}
    }
    // `drag` is the assertion target; the full-state diff would drag the
    // (irrelevant) shared config into the comparison.
    store.exhaustivity = .off

    await store.send(.windowChanged(.windowResized(key: key, frame: resizeFrame)))
    #expect(store.state.drag == .resizing(.init(key: key, frame: resizeFrame)))
    // A top-left resize fires Moved interleaved with Resized — the move
    // must not replace the pending resize with a drop/snap-back.
    await store.send(
      .windowChanged(.windowMoved(key: key, frame: CGRect(x: 5, y: 5, width: 500, height: 400)))
    )
    #expect(store.state.drag == .resizing(.init(key: key, frame: resizeFrame)))
    // Mouse-up flushes and resets. (No active workspace here, so the
    // ratio sync itself is a no-op — the commit choice is what's pinned.)
    await store.send(.windowChanged(.windowDragEnded))
    #expect(store.state.drag == .idle)
  }

  @Test
  func plainMoveSnapsBackOnMouseUp() async {
    let key = WindowKey(pid: 1, windowID: 100, bundleId: "app.one")
    let store = TestStore(initialState: Self.makeState(workspaces: [])) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.dragPreview.show = { _, _ in }
      $0.dragPreview.hide = {}
    }
    store.exhaustivity = .off

    // No tree → no drop target → the drag is a bare move.
    await store.send(
      .windowChanged(.windowMoved(key: key, frame: CGRect(x: 5, y: 5, width: 500, height: 400)))
    )
    #expect(store.state.drag == .moving(key))
    await store.send(.windowChanged(.windowDragEnded))
    #expect(store.state.drag == .idle)
  }

  // MARK: - Membership

  @Test
  func togglingMembershipMovesTheAppToTheActiveWorkspace() async {
    let app = AppAssignment(bundleIdentifier: "app.one", name: "One")
    let ws1 = Workspace(name: "one", apps: [app])
    let ws2 = Workspace(name: "two")
    let state = Self.makeState(workspaces: [ws1, ws2]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = ws2.id
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.membershipEditResolved(bundleId: "app.one", name: "One", edit: .toggleInActiveWorkspace))

    let workspaces = store.state.config.activeProfile?.workspaces ?? []
    // Single-membership: adding to ws2 removed it from ws1.
    #expect(
      workspaces.first { $0.id == ws1.id }?.apps
        .contains { $0.bundleIdentifier == "app.one" } == false
    )
    #expect(
      workspaces.first { $0.id == ws2.id }?.apps
        .contains { $0.bundleIdentifier == "app.one" } == true
    )
    await store.skipReceivedActions()
  }

  @Test
  func togglingMembershipNeverAssignsTatamiItself() async {
    let ws1 = Workspace(name: "one")
    let state = Self.makeState(workspaces: [ws1]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = ws1.id
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    }

    await store.send(
      .membershipEditResolved(
        bundleId: "dev.PangMo5.Tatami.dev", name: "Tatami", edit: .toggleInActiveWorkspace
      )
    )
    #expect(store.state.config.activeProfile?.workspaces.first?.apps.isEmpty == true)
  }

  // MARK: - Display reconfiguration

  @Test
  func displaysReconfiguredDropsStateForDisconnectedDisplays() async {
    let gone = DisplayName("Gone Display")
    let ws1 = Workspace(name: "one")
    let state = Self.makeState(workspaces: [ws1]) {
      $0.activeWorkspacesByDisplay[gone] = ws1.id
      $0.previousWorkspacesByDisplay[gone] = ws1.id
      $0.lastActiveDisplay[ws1.id] = gone
      $0.focusedDisplay = gone
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    }

    await store.send(.displaysReconfigured([Self.display])) {
      $0.activeWorkspacesByDisplay = [:]
      $0.previousWorkspacesByDisplay = [:]
      $0.lastActiveDisplay = [:]
      $0.focusedDisplay = nil
    }
  }
}
