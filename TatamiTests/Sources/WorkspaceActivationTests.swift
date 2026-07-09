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
      $0.displayWorkspaceHistory[Self.display] = [ws2.id]
      $0.workspaceMRU = [ws2.id]
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
      // Both were connected; the reconfigure below unplugs `gone`.
      $0.connectedDisplays = [gone, Self.display]
      $0.activeWorkspacesByDisplay[gone] = ws1.id
      $0.previousWorkspacesByDisplay[gone] = ws1.id
      $0.lastActiveDisplay[ws1.id] = gone
      $0.focusedDisplay = gone
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    }
    store.exhaustivity = .off

    // Disconnecting `gone` drops its per-display state (no new display → no
    // restore plan).
    await store.send(.displaysReconfigured([Self.display]))
    #expect(store.state.connectedDisplays == [Self.display])
    #expect(store.state.activeWorkspacesByDisplay.isEmpty)
    #expect(store.state.previousWorkspacesByDisplay.isEmpty)
    #expect(store.state.lastActiveDisplay.isEmpty)
    #expect(store.state.focusedDisplay == nil)
  }

  // MARK: - Display reconnect planning (pure)

  private func workspace(_ name: String, hint: DisplayName? = nil) -> Workspace {
    Workspace(name: name, displayHint: hint)
  }

  @Test
  func reconnectRestoresLastShownWhenPinnedOrFreeDynamic() {
    let b = DisplayName("B")
    let wB = workspace("wB", hint: b)
    #expect(
      WorkspaceActivationFeature.planDisplayRestore(
        connected: [b], newlyConnected: [b], workspaces: [wB], active: [:], history: [b: [wB.id]]
      ) == [DisplayAssignment(display: b, workspace: wB.id)]
    )
    // A dynamic last-shown IS restored — as long as it isn't in use elsewhere.
    let dyn = workspace("dyn")
    #expect(
      WorkspaceActivationFeature.planDisplayRestore(
        connected: [b], newlyConnected: [b], workspaces: [dyn], active: [:], history: [b: [dyn.id]]
      ) == [DisplayAssignment(display: b, workspace: dyn.id)]
    )
  }

  @Test
  func reconnectFallsBackToFirstPinnedThenMostRecentFreeDynamic() {
    let b = DisplayName("B")
    let pinned = workspace("pinned", hint: b)
    #expect(
      WorkspaceActivationFeature.planDisplayRestore(
        connected: [b], newlyConnected: [b], workspaces: [pinned], active: [:], history: [:]
      ) == [DisplayAssignment(display: b, workspace: pinned.id)]
    )
    // No pinned → rule 3: the most-recently-used free dynamic (MRU order).
    let a = DisplayName("A")
    let used = workspace("used")      // dynamic, currently on A
    let recent = workspace("recent")  // dynamic, free, more recent than `older`
    let older = workspace("older")    // dynamic, free
    let plan = WorkspaceActivationFeature.planDisplayRestore(
      connected: [a, b], newlyConnected: [b],
      workspaces: [used, recent, older],
      active: [a: used.id], history: [:],
      workspaceMRU: [used.id, recent.id, older.id]
    )
    #expect(plan == [
      DisplayAssignment(display: a, workspace: used.id),     // re-assert A
      DisplayAssignment(display: b, workspace: recent.id),   // used is elsewhere → recent
    ])
  }

  @Test
  func reconnectReAssertsConnectedDisplaysAndLeavesUnpinnedNewOnesEmpty() {
    // The Figma case: dynamic Figma on A; B reconnects with nothing pinned to
    // it. The plan re-asserts A→figma (overwriting macOS's shuffle) and leaves
    // B empty — Figma stays on A rather than drifting to B.
    let a = DisplayName("A"), b = DisplayName("B")
    let figma = workspace("figma")  // dynamic
    let plan = WorkspaceActivationFeature.planDisplayRestore(
      connected: [a, b], newlyConnected: [b],
      workspaces: [figma], active: [a: figma.id], history: [b: [figma.id]]
    )
    #expect(plan == [DisplayAssignment(display: a, workspace: figma.id)])
  }

  @Test
  func reconnectReclaimsPinnedFromAnotherDisplayAndRefillsIt() {
    let a = DisplayName("A"), b = DisplayName("B")
    let wB = workspace("wB", hint: b)          // pinned to B, currently up on A
    let wAprev = workspace("wAprev", hint: a)  // A's previous workspace
    let plan = WorkspaceActivationFeature.planDisplayRestore(
      connected: [a, b], newlyConnected: [b],
      workspaces: [wB, wAprev],
      active: [a: wB.id],
      history: [b: [wB.id], a: [wB.id, wAprev.id]]
    )
    #expect(plan == [
      DisplayAssignment(display: a, workspace: wAprev.id),
      DisplayAssignment(display: b, workspace: wB.id),
    ])
  }

  @Test
  func vacatedRefillWalksHistoryPastWorkspacesInUseElsewhere() {
    let a = DisplayName("A"), b = DisplayName("B"), c = DisplayName("C")
    let wB = workspace("wB", hint: b)          // reclaimed to B
    let wOnC = workspace("wOnC")               // dynamic, currently up on C
    let wOlder = workspace("wOlder", hint: a)  // A's older workspace
    let plan = WorkspaceActivationFeature.planDisplayRestore(
      connected: [a, b, c], newlyConnected: [b],
      workspaces: [wB, wOnC, wOlder],
      active: [a: wB.id, c: wOnC.id],
      history: [b: [wB.id], a: [wB.id, wOnC.id, wOlder.id]]
    )
    // B←wB; A skips wB (now on B) and wOnC (on C) → wOlder; C re-asserts wOnC.
    #expect(plan == [
      DisplayAssignment(display: a, workspace: wOlder.id),
      DisplayAssignment(display: b, workspace: wB.id),
      DisplayAssignment(display: c, workspace: wOnC.id),
    ])
  }
}
