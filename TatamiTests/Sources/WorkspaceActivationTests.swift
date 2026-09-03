// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import CoreGraphics
import CustomDump
import Foundation
import Testing
@testable import TatamiKit

/// Reducer-level tests for the activation core. These became possible
/// once the live AppKit/AX reads moved behind `WindowSnapshotClient` /
/// `DisplayClient` — the reducer no longer touches the real window
/// server on the test host.
@MainActor
struct WorkspaceActivationFeatureTests {

  // MARK: Internal

  @Test
  func `background overlay focus cannot change MRU or follow app focus`() async {
    let activeWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.active")
    let notionWindow = WindowKey(pid: 935, windowID: 70, bundleId: "notion.id")
    let active = Workspace(
      name: "Active",
      apps: [AppAssignment(bundleIdentifier: activeWindow.bundleId, name: "Active")],
    )
    let notion = Workspace(
      name: "Notion",
      apps: [AppAssignment(bundleIdentifier: notionWindow.bundleId, name: "Notion")],
    )
    let state = Self.makeState(workspaces: [active, notion]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = active.id
      $0.tilingTrees[active.id] = .leaf(activeWindow)
      $0.tilingTrees[notion.id] = .leaf(notionWindow)
      $0.lastObservedFocusedWindow = activeWindow
      $0.mruWindows[active.id] = [activeWindow]
    }
    let markerUpdates = LockIsolated(0)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.overlayAwareness.isBackgroundedBundle = { $0 == notionWindow.bundleId }
      $0.overlayAwareness.isBackgroundedProcess = { $0 == notionWindow.pid }
      $0.windowSnapshot.frontmostApp = {
        FrontmostApp(pid: notionWindow.pid, bundleId: notionWindow.bundleId, name: "Notion")
      }
      $0.marker.setFocused = { _ in markerUpdates.withValue { $0 += 1 } }
    }

    await store.send(
      .windowChanged(
        .windowFocused(bundleId: notionWindow.bundleId, key: notionWindow)
      )
    )
    await store.send(.appActivated(bundleId: notionWindow.bundleId))

    #expect(store.state.lastObservedFocusedWindow == activeWindow)
    #expect(store.state.mruWindows[active.id] == [activeWindow])
    #expect(store.state.mruWindows[notion.id] == nil)
    #expect(markerUpdates.value == 0)
  }

  @Test
  func `background overlay process is excluded from interaction commands`() async {
    let activeWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.active")
    let notionWindow = WindowKey(pid: 935, windowID: 70, bundleId: "notion.id")
    let workspace = Workspace(name: "Work")
    let state = Self.makeState(workspaces: [workspace]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = .branch(
        BSPBranch(
          split: .vertical,
          ratio: 0.5,
          left: .leaf(activeWindow),
          right: .leaf(notionWindow),
        )
      )
    }
    let focused = LockIsolated<[WindowKey]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.overlayAwareness.isBackgroundedBundle = { $0 == notionWindow.bundleId }
      $0.overlayAwareness.isBackgroundedProcess = { $0 == notionWindow.pid }
      $0.focusManager.focusWindow = { key in
        focused.withValue { $0.append(key) }
      }
    }

    await store.send(.cycleWindowResolved(windowKey: activeWindow, direction: .next))
    await store.send(.bspFocusResolved(windowKey: notionWindow, direction: .west))
    await store.send(
      .membershipEditResolved(
        bundleId: notionWindow.bundleId,
        name: "Notion",
        edit: .toggleInActiveWorkspace,
        pid: notionWindow.pid,
      )
    )
    await store.send(
      .windowChanged(
        .windowMoved(
          key: notionWindow,
          frame: CGRect(x: 0, y: 0, width: 600, height: 500),
        )
      )
    )

    #expect(focused.value.isEmpty)
    #expect(store.state.drag == .idle)
    #expect(
      store.state.config.activeProfile?.workspaces[id: workspace.id]?.apps.isEmpty == true
    )
  }

  @Test
  func `foreground sibling process focus is not excluded by background bundle`() async {
    let background = WindowKey(pid: 41, windowID: 410, bundleId: "notion.id")
    let foreground = WindowKey(pid: 42, windowID: 420, bundleId: background.bundleId)
    let previous = WindowKey(pid: 1, windowID: 101, bundleId: "app.previous")
    let workspace = Workspace(
      name: "Work",
      apps: [AppAssignment(bundleIdentifier: foreground.bundleId, name: "Notion")],
    )
    let state = Self.makeState(workspaces: [workspace]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.lastObservedFocusedWindow = previous
      $0.isTilingPaused = true
    }
    let markerUpdates = LockIsolated(0)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.overlayAwareness.isBackgroundedBundle = { $0 == background.bundleId }
      $0.overlayAwareness.isBackgroundedProcess = { $0 == background.pid }
      $0.marker.setFocused = { _ in markerUpdates.withValue { $0 += 1 } }
    }
    store.exhaustivity = .off

    await store.send(
      .windowChanged(
        .windowDestroyed(bundleId: background.bundleId, pid: background.pid)
      )
    )
    await store.send(
      .windowChanged(
        .windowFocused(bundleId: foreground.bundleId, pid: foreground.pid, key: nil)
      )
    )
    await store.finish()

    #expect(store.state.lastObservedFocusedWindow == nil)
    #expect(markerUpdates.value == 1)
  }

  @Test
  func `same bundle sync admits foreground pid but not background pid`() async {
    let background = WindowKey(pid: 41, windowID: 410, bundleId: "notion.id")
    let foreground = WindowKey(pid: 42, windowID: 420, bundleId: background.bundleId)
    let anchor = WindowKey(pid: 1, windowID: 101, bundleId: "app.anchor")
    let workspace = Workspace(
      name: "Work",
      apps: [
        AppAssignment(bundleIdentifier: anchor.bundleId, name: "Anchor"),
        AppAssignment(bundleIdentifier: foreground.bundleId, name: "Notion"),
      ],
    )
    let state = Self.makeState(workspaces: [workspace]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = .leaf(anchor)
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.overlayAwareness.isBackgroundedBundle = { $0 == background.bundleId }
      $0.overlayAwareness.isBackgroundedProcess = { $0 == background.pid }
      $0.displays.workArea = { _ in
        CGRect(x: 0, y: 0, width: 1_000, height: 800)
      }
    }
    store.exhaustivity = .off

    await store.send(.syncAppWindowsResolved(
      bundleId: foreground.bundleId,
      resizableKeys: [background, foreground],
      onScreenFrames: [
        background.windowID: CGRect(x: 0, y: 0, width: 500, height: 800),
        foreground.windowID: CGRect(x: 500, y: 0, width: 500, height: 800),
      ],
    ))
    await store.finish()

    let windows = store.state.tilingTrees[workspace.id]?.windows ?? []
    #expect(windows.contains(foreground))
    #expect(!windows.contains(background))
  }

  @Test
  func `delayed background activation cannot impersonate foreground sibling`() async {
    let background = WindowKey(pid: 41, windowID: 410, bundleId: "notion.id")
    let foreground = WindowKey(pid: 42, windowID: 420, bundleId: background.bundleId)
    let workspace = Workspace(name: "Work")
    let state = Self.makeState(workspaces: [workspace]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
    }
    let markerUpdates = LockIsolated(0)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.overlayAwareness.isBackgroundedProcess = { $0 == background.pid }
      $0.windowSnapshot.frontmostApp = {
        FrontmostApp(
          pid: foreground.pid,
          bundleId: foreground.bundleId,
          name: "Notion",
        )
      }
      $0.marker.setFocused = { _ in markerUpdates.withValue { $0 += 1 } }
    }

    await store.send(
      .appActivated(bundleId: background.bundleId, pid: background.pid)
    )

    #expect(markerUpdates.value == 0)
  }

  @Test
  func `termination removes only the exact process from shared bundle state`() async {
    let terminated = WindowKey(pid: 41, windowID: 410, bundleId: "notion.id")
    let survivor = WindowKey(pid: 42, windowID: 420, bundleId: terminated.bundleId)
    let workspace = Workspace(name: "Work")
    let state = Self.makeState(workspaces: [workspace]) {
      $0.mruWindows[workspace.id] = [terminated, survivor]
      $0.windowServerHiddenWindows = [terminated, survivor]
      $0.pendingWindowServerPresentationWindows = [terminated, survivor]
      $0.layoutSuspensionReasons = [.systemSleep]
    }
    let invalidated = LockIsolated<[(pid_t, String)]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.windowSnapshot.invalidateProcess = { pid, bundleId in
        invalidated.withValue { $0.append((pid, bundleId)) }
      }
    }

    await store.send(
      .appTerminated(bundleId: terminated.bundleId, pid: terminated.pid)
    ) {
      $0.mruWindows[workspace.id] = [survivor]
      $0.windowServerHiddenWindows = [survivor]
      $0.pendingWindowServerPresentationWindows = [survivor]
    }

    #expect(invalidated.value.count == 1)
    #expect(invalidated.value.first?.0 == terminated.pid)
    #expect(invalidated.value.first?.1 == terminated.bundleId)
  }

  @Test
  func `cycle next loops past the last workspace`() async {
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

    await store.send(.activateNext())
    await store.receive {
      guard case .activate(let id, let setFocus, _) = $0 else { return false }
      return id == ws1.id && setFocus
    }
  }

  @Test
  func `cycle next uses the captured pointer display after the live pointer moves`() async {
    let displayA = DisplayName("A")
    let liveDisplayA = DisplayName(uuid: "display-a", name: "A")
    let displayB = DisplayName("B")
    let a1 = Workspace(name: "A 1", displayHint: displayA)
    let a2 = Workspace(name: "A 2", displayHint: displayA)
    let b1 = Workspace(name: "B 1", displayHint: displayB)
    let b2 = Workspace(name: "B 2", displayHint: displayB)
    let state = Self.makeState(workspaces: [a1, a2, b1, b2]) {
      $0.$config.withLock { $0.settings.switching.cycleAcrossDisplays = false }
      $0.focusedDisplay = displayB
      $0.activeWorkspacesByDisplay = [displayA: a1.id, displayB: b1.id]
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      // Live identities have UUIDs even when restored state is name-only.
      $0.displays.current = { displayB }
      $0.continuousClock = TestClock()
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activateNext(interactionDisplay: liveDisplayA))
    await store.receive {
      guard case .activate(let id, let setFocus, let display) = $0 else { return false }
      return id == a2.id && setFocus && display?.matches(liveDisplayA) == true
    }
  }

  @Test
  func `cycle previous uses the captured pointer display after the live pointer moves`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let a1 = Workspace(name: "A 1", displayHint: displayA)
    let a2 = Workspace(name: "A 2", displayHint: displayA)
    let b1 = Workspace(name: "B 1", displayHint: displayB)
    let b2 = Workspace(name: "B 2", displayHint: displayB)
    let state = Self.makeState(workspaces: [a1, a2, b1, b2]) {
      $0.$config.withLock { $0.settings.switching.cycleAcrossDisplays = false }
      $0.focusedDisplay = displayB
      $0.activeWorkspacesByDisplay = [displayA: a2.id, displayB: b2.id]
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.current = { displayB }
      $0.continuousClock = TestClock()
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activatePrevious(interactionDisplay: displayA))
    await store.receive {
      guard case .activate(let id, let setFocus, let display) = $0 else { return false }
      return id == a1.id && setFocus && display?.matches(displayA) == true
    }
  }

  @Test
  func `local cycle starts at opposite ends when the pointer display is empty`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let first = Workspace(name: "First", displayHint: displayA)
    let middle = Workspace(name: "Middle", displayHint: displayA)
    let last = Workspace(name: "Last", displayHint: displayA)
    let outside = Workspace(name: "Outside", displayHint: displayB)
    let state = Self.makeState(workspaces: [first, middle, last, outside]) {
      $0.$config.withLock { $0.settings.switching.cycleAcrossDisplays = false }
      $0.focusedDisplay = displayB
      $0.activeWorkspacesByDisplay = [displayB: outside.id]
    }
    func makeStore() -> TestStoreOf<WorkspaceActivationFeature> {
      let store = TestStore(initialState: state) {
        WorkspaceActivationFeature()
      } withDependencies: {
        $0.displays.all = { [displayA, displayB] }
        $0.displays.current = { displayA }
        $0.displays.primary = { displayA }
        $0.continuousClock = TestClock()
        $0.floatingOverlay.retainOnly = { _ in }
        $0.floatingOverlay.setFloating = { _ in }
      }
      store.exhaustivity = .off
      return store
    }

    let nextStore = makeStore()
    await nextStore.send(.activateNext())
    await nextStore.receive {
      guard case .activate(let id, let setFocus, let display) = $0 else { return false }
      return id == first.id && setFocus && display?.matches(displayA) == true
    }

    let previousStore = makeStore()
    await previousStore.send(.activatePrevious())
    await previousStore.receive {
      guard case .activate(let id, let setFocus, let display) = $0 else { return false }
      return id == last.id && setFocus && display?.matches(displayA) == true
    }
  }

  @Test
  func `cycle across displays still anchors at the pointer display workspace`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let a1 = Workspace(name: "A 1")
    let b1 = Workspace(name: "B 1")
    let a2 = Workspace(name: "A 2")
    let state = Self.makeState(workspaces: [a1, b1, a2]) {
      $0.$config.withLock { $0.settings.switching.cycleAcrossDisplays = true }
      $0.focusedDisplay = displayB
      $0.activeWorkspacesByDisplay = [displayA: a1.id, displayB: b1.id]
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.current = { displayA }
      $0.continuousClock = TestClock()
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activateNext())
    await store.receive {
      guard case .activate(let id, let setFocus, let display) = $0 else { return false }
      return id == b1.id && setFocus && display?.matches(displayA) == true
    }
  }

  @Test
  func `global cycle keeps the global in flight anchor across displays`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let a1 = Workspace(name: "A 1")
    let a2 = Workspace(name: "A 2")
    let b1 = Workspace(name: "B 1")
    let state = Self.makeState(workspaces: [a1, a2, b1]) {
      $0.$config.withLock { $0.settings.switching.cycleAcrossDisplays = true }
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [displayA: a1.id, displayB: b1.id]
      $0.isActivating = true
      $0.activatingWorkspaceID = a2.id
      $0.activatingDisplay = displayA
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.current = { displayB }
      $0.continuousClock = TestClock()
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activateNext())
    await store.receive {
      guard case .activate(let id, let setFocus, let display) = $0 else { return false }
      return id == b1.id && setFocus && display?.matches(displayB) == true
    }
  }

  @Test
  func `local cycle ignores an in flight anchor on another display`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let a1 = Workspace(name: "A 1")
    let a2 = Workspace(name: "A 2")
    let b1 = Workspace(name: "B 1")
    let b2 = Workspace(name: "B 2")
    let state = Self.makeState(workspaces: [a1, a2, b1, b2]) {
      $0.$config.withLock { $0.settings.switching.cycleAcrossDisplays = false }
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [displayA: a1.id, displayB: b1.id]
      $0.lastActiveDisplay = [
        a1.id: displayA,
        a2.id: displayA,
        b1.id: displayB,
        b2.id: displayB,
      ]
      $0.isActivating = true
      $0.activatingWorkspaceID = a2.id
      $0.activatingDisplay = displayA
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.current = { displayB }
      $0.continuousClock = TestClock()
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activateNext())
    await store.receive {
      guard case .activate(let id, let setFocus, let display) = $0 else { return false }
      return id == b2.id && setFocus && display?.matches(displayB) == true
    }
  }

  @Test
  func `recent workspace uses the pointer display when keyboard focus is elsewhere`() async {
    let displayA = DisplayName("A")
    let liveDisplayA = DisplayName(uuid: "display-a", name: "A")
    let displayB = DisplayName("B")
    let currentA = Workspace(name: "Current A")
    let recentA = Workspace(name: "Recent A")
    let currentB = Workspace(name: "Current B")
    let recentB = Workspace(name: "Recent B")
    let state = Self.makeState(workspaces: [currentA, recentA, currentB, recentB]) {
      $0.$config.withLock { $0.settings.switching.recentAcrossDisplays = false }
      $0.focusedDisplay = displayB
      $0.activeWorkspacesByDisplay = [displayA: currentA.id, displayB: currentB.id]
      $0.previousWorkspacesByDisplay = [displayA: recentA.id, displayB: recentB.id]
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.current = { displayB }
      $0.continuousClock = TestClock()
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activateRecent(interactionDisplay: liveDisplayA))
    await store.receive {
      guard case .activate(let id, let setFocus, let display) = $0 else { return false }
      return id == recentA.id && setFocus && display?.matches(liveDisplayA) == true
    }
  }

  @Test
  func `recent assign and borrow targets use the pointer display`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let currentA = Workspace(name: "Current A")
    let recentA = Workspace(name: "Recent A")
    let currentB = Workspace(name: "Current B")
    let recentB = Workspace(name: "Recent B")
    let state = Self.makeState(workspaces: [currentA, recentA, currentB, recentB]) {
      $0.$config.withLock { $0.settings.switching.recentAcrossDisplays = false }
      $0.focusedDisplay = displayB
      $0.activeWorkspacesByDisplay = [displayA: currentA.id, displayB: currentB.id]
      $0.previousWorkspacesByDisplay = [displayA: recentA.id, displayB: recentB.id]
    }

    let assignStore = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.current = { displayB }
    }
    assignStore.exhaustivity = .off
    await assignStore.send(.assignFocusedAppToRecentWorkspace(
      interactionDisplay: displayA
    ))
    await assignStore.receive {
      guard case .membershipEdit(.assign(let id), let display) = $0 else { return false }
      return id == recentA.id && display?.matches(displayA) == true
    }

    let borrowStore = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.current = { displayB }
      $0.borrowChord.setArmed = { _ in }
      $0.continuousClock = TestClock()
      $0.workspaceHUD.showAction = { _ in }
    }
    borrowStore.exhaustivity = .off
    await borrowStore.send(.borrowRecentWorkspace(
      interactionDisplay: displayA
    ))
    await borrowStore.receive {
      guard case .beginBorrowDirection(let id, let display) = $0 else { return false }
      return id == recentA.id && display?.matches(displayA) == true
    }
  }

  @Test
  func `adjacent app edits use the pointer display when keyboard focus is elsewhere`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let a1 = Workspace(name: "A 1", displayHint: displayA)
    let a2 = Workspace(name: "A 2", displayHint: displayA)
    let b1 = Workspace(name: "B 1", displayHint: displayB)
    let b2 = Workspace(name: "B 2", displayHint: displayB)
    let state = Self.makeState(workspaces: [a1, a2, b1, b2]) {
      $0.$config.withLock { $0.settings.switching.cycleAcrossDisplays = false }
      $0.focusedDisplay = displayB
      $0.activeWorkspacesByDisplay = [displayA: a1.id, displayB: b1.id]
    }

    for (action, expectedEdit) in [
      (
        WorkspaceActivationFeature.Action.assignFocusedAppToAdjacentWorkspace(
          direction: 1,
          interactionDisplay: displayA,
        ),
        WorkspaceActivationFeature.MembershipEdit.assign(to: a2.id),
      ),
      (
        WorkspaceActivationFeature.Action.moveFocusedAppToAdjacent(
          direction: 1,
          interactionDisplay: displayA,
        ),
        WorkspaceActivationFeature.MembershipEdit.move(to: a2.id),
      ),
    ] {
      let store = TestStore(initialState: state) {
        WorkspaceActivationFeature()
      } withDependencies: {
        $0.displays.current = { displayB }
      }
      store.exhaustivity = .off

      await store.send(action)
      await store.receive {
        guard case .membershipEdit(let edit, let display) = $0 else { return false }
        return edit == expectedEdit && display?.matches(displayA) == true
      }
    }
  }

  @Test
  func `next and previous keep their pointer display through activation`() async {
    for movesForward in [true, false] {
      let displayA = DisplayName("A")
      let liveDisplayA = DisplayName(uuid: "display-a", name: "A")
      let displayB = DisplayName(uuid: "display-b", name: "B")
      let a1 = Workspace(name: "A 1")
      let a2 = Workspace(name: "A 2")
      let b1 = Workspace(name: "B 1")
      let start = movesForward ? a1 : a2
      let target = movesForward ? a2 : a1
      let state = Self.makeState(workspaces: [a1, a2, b1]) {
        $0.$config.withLock { $0.settings.switching.cycleAcrossDisplays = false }
        $0.isTilingPaused = true
        $0.focusedDisplay = displayB
        $0.activeWorkspacesByDisplay = [displayA: start.id, displayB: b1.id]
        $0.lastActiveDisplay = [a1.id: displayA, a2.id: displayA, b1.id: displayB]
      }
      let pointerDisplay = LockIsolated(liveDisplayA)
      let requests = LockIsolated<[ActivationRequest]>([])
      let store = TestStore(initialState: state) {
        WorkspaceActivationFeature()
      } withDependencies: {
        $0.displays.current = { pointerDisplay.value }
        $0.continuousClock = TestClock()
        $0.workspaceManager.activate = { request in
          requests.withValue { $0.append(request) }
        }
        $0.floatingOverlay.retainOnly = { _ in }
      }
      store.exhaustivity = .off

      await store.send(movesForward ? .activateNext() : .activatePrevious())
      // The continuation action has not run yet. Moving the pointer now must
      // not retarget the already-started command from A to B.
      pointerDisplay.setValue(displayB)
      await store.receive {
        guard case .activationCompleted(let id, let display, _) = $0 else { return false }
        return id == target.id && display?.matches(liveDisplayA) == true
      }
      await store.finish()

      #expect(requests.value.last?.workspace.id == target.id)
      #expect(requests.value.last?.targetDisplay?.matches(liveDisplayA) == true)
      #expect(store.state.activeWorkspace(on: liveDisplayA) == target.id)
      #expect(store.state.activeWorkspace(on: displayB) == b1.id)
    }
  }

  @Test
  func `recent keeps its pointer display through activation`() async {
    let displayA = DisplayName("A")
    let liveDisplayA = DisplayName(uuid: "display-a", name: "A")
    let displayB = DisplayName(uuid: "display-b", name: "B")
    let currentA = Workspace(name: "Current A")
    let recentA = Workspace(name: "Recent A")
    let currentB = Workspace(name: "Current B")
    let state = Self.makeState(workspaces: [currentA, recentA, currentB]) {
      $0.$config.withLock { $0.settings.switching.recentAcrossDisplays = false }
      $0.isTilingPaused = true
      $0.focusedDisplay = displayB
      $0.activeWorkspacesByDisplay = [displayA: currentA.id, displayB: currentB.id]
      $0.previousWorkspacesByDisplay = [displayA: recentA.id]
    }
    let pointerDisplay = LockIsolated(liveDisplayA)
    let requests = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.current = { pointerDisplay.value }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        requests.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activateRecent())
    pointerDisplay.setValue(displayB)
    await store.receive {
      guard case .activationCompleted(let id, let display, _) = $0 else { return false }
      return id == recentA.id && display?.matches(liveDisplayA) == true
    }
    await store.finish()

    #expect(requests.value.last?.targetDisplay?.matches(liveDisplayA) == true)
    #expect(store.state.activeWorkspace(on: displayB) == currentB.id)
  }

  @Test
  func `adjacent assign and move keep their pointer display through app resolution`() async {
    for movesMembership in [false, true] {
      let displayA = DisplayName("A")
      let liveDisplayA = DisplayName(uuid: "display-a", name: "A")
      let displayB = DisplayName(uuid: "display-b", name: "B")
      let bundleID = movesMembership ? "app.move" : "app.assign"
      let currentA = Workspace(
        name: "Current A",
        apps: [AppAssignment(bundleIdentifier: bundleID, name: "Focused")],
      )
      let targetA = Workspace(name: "Target A")
      let currentB = Workspace(name: "Current B")
      let state = Self.makeState(workspaces: [currentA, targetA, currentB]) {
        $0.$config.withLock { $0.settings.switching.cycleAcrossDisplays = false }
        $0.isTilingPaused = true
        $0.focusedDisplay = displayB
        $0.activeWorkspacesByDisplay = [displayA: currentA.id, displayB: currentB.id]
        $0.lastActiveDisplay = [
          currentA.id: displayA,
          targetA.id: displayA,
          currentB.id: displayB,
        ]
      }
      let pointerDisplay = LockIsolated(liveDisplayA)
      let requests = LockIsolated<[ActivationRequest]>([])
      let store = TestStore(initialState: state) {
        WorkspaceActivationFeature()
      } withDependencies: {
        $0.displays.current = { pointerDisplay.value }
        $0.continuousClock = TestClock()
        $0.windowSnapshot.frontmostApp = {
          FrontmostApp(pid: 42, bundleId: bundleID, name: "Focused")
        }
        $0.workspaceManager.activate = { request in
          requests.withValue { $0.append(request) }
        }
        $0.floatingOverlay.retainOnly = { _ in }
      }
      store.exhaustivity = .off

      await store.send(
        movesMembership
          ? .moveFocusedAppToAdjacent(direction: 1)
          : .assignFocusedAppToAdjacentWorkspace(direction: 1)
      )
      pointerDisplay.setValue(displayB)
      await store.receive {
        guard case .membershipEdit(let edit, let display) = $0 else { return false }
        let expected: WorkspaceActivationFeature.MembershipEdit = movesMembership
          ? .move(to: targetA.id)
          : .assign(to: targetA.id)
        return edit == expected && display?.matches(liveDisplayA) == true
      }
      await store.receive {
        guard
          case .membershipEditResolved(
            let resolvedBundleID,
            _,
            let edit,
            _,
            let display,
          ) = $0
        else { return false }
        let expected: WorkspaceActivationFeature.MembershipEdit = movesMembership
          ? .move(to: targetA.id)
          : .assign(to: targetA.id)
        return resolvedBundleID == bundleID
          && edit == expected
          && display?.matches(liveDisplayA) == true
      }
      await store.receive {
        guard case .activate(let id, let setFocus, let display) = $0 else { return false }
        return id == targetA.id
          && setFocus
          && display?.matches(liveDisplayA) == true
      }
      await store.receive {
        guard case .activationCompleted(let id, let display, _) = $0 else { return false }
        return id == targetA.id && display?.matches(liveDisplayA) == true
      }
      await store.finish()

      #expect(requests.value.last?.targetDisplay?.matches(liveDisplayA) == true)
      #expect(
        store.state.config.activeProfile?.workspaces[id: targetA.id]?
          .apps.contains(where: { $0.bundleIdentifier == bundleID }) == true
      )
    }
  }

  @Test
  func `recent borrow keeps its pointer display through direction resolution`() async {
    let displayA = DisplayName("A")
    let liveDisplayA = DisplayName(uuid: "display-a", name: "A")
    let displayB = DisplayName(uuid: "display-b", name: "B")
    let hostA = Workspace(name: "Host A")
    let borrowed = Workspace(name: "Borrowed")
    let hostB = Workspace(name: "Host B")
    let state = Self.makeState(workspaces: [hostA, borrowed, hostB]) {
      $0.$config.withLock {
        $0.settings.switching.recentAcrossDisplays = false
        $0.settings.switching.borrowDefaultEdge = .right
      }
      $0.focusedDisplay = displayB
      $0.activeWorkspacesByDisplay = [displayA: hostA.id, displayB: hostB.id]
      $0.previousWorkspacesByDisplay = [displayA: borrowed.id]
    }
    let pointerDisplay = LockIsolated(liveDisplayA)
    let requests = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.current = { pointerDisplay.value }
      $0.workspaceManager.activate = { request in
        requests.withValue { $0.append(request) }
      }
    }
    store.exhaustivity = .off

    await store.send(.borrowRecentWorkspace())
    pointerDisplay.setValue(displayB)
    await store.receive {
      guard case .beginBorrowDirection(let id, let display) = $0 else { return false }
      return id == borrowed.id && display?.matches(liveDisplayA) == true
    }
    await store.finish()

    let composition = store.state.compositionsByDisplay.first(where: {
      $0.key.matches(liveDisplayA)
    })?.value
    #expect(composition?.host == hostA.id)
    #expect(composition?.borrowed.first?.workspace == borrowed.id)
    #expect(requests.value.last?.targetDisplay?.matches(liveDisplayA) == true)
  }

  @Test
  func `adjacent display focus starts from the pointer monitor`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let displayC = DisplayName("C")
    let workspaceA = Workspace(name: "A")
    let workspaceB = Workspace(name: "B")
    let workspaceC = Workspace(name: "C")
    let windowB = WindowKey(pid: 2, windowID: 202, bundleId: "app.b")
    let windowC = WindowKey(pid: 3, windowID: 303, bundleId: "app.c")
    let state = Self.makeState(workspaces: [workspaceA, workspaceB, workspaceC]) {
      $0.focusedDisplay = displayC
      $0.activeWorkspacesByDisplay = [
        displayA: workspaceA.id,
        displayB: workspaceB.id,
        displayC: workspaceC.id,
      ]
      $0.tilingTrees[workspaceB.id] = .leaf(windowB)
      $0.tilingTrees[workspaceC.id] = .leaf(windowC)
    }
    let focused = LockIsolated<WindowKey?>(nil)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB, displayC] }
      $0.displays.current = { displayC }
      $0.focusManager.focusWindow = { key in focused.setValue(key) }
    }
    store.exhaustivity = .off

    await store.send(.focusAdjacentDisplay(
      direction: 1,
      interactionDisplay: displayA,
    ))
    await store.finish()

    #expect(focused.value == windowB)
    #expect(store.state.focusedDisplay == displayB)
  }

  @Test
  func `cycle without loop stops at the end`() async {
    let ws1 = Workspace(name: "one")
    let ws2 = Workspace(name: "two")
    let state = Self.makeState(workspaces: [ws1, ws2]) {
      $0.$config.withLock { $0.settings.switching.loop = false }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = ws2.id
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.floatingOverlay.setFloating = { _ in }
    }

    // At the last workspace with looping off there is no eligible target.
    await store.send(.activateNext())
  }

  @Test
  func `cycle skips workspaces with no running app`() async {
    let ws1 = Workspace(
      name: "one",
      apps: [AppAssignment(bundleIdentifier: "app.one", name: "One")],
    )
    let ws2 = Workspace(
      name: "two",
      apps: [AppAssignment(bundleIdentifier: "app.two", name: "Two")],
    )
    let ws3 = Workspace(
      name: "three",
      apps: [AppAssignment(bundleIdentifier: "app.three", name: "Three")],
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
    await store.send(.activateNext())
    await store.receive {
      guard case .activate(let id, _, _) = $0 else { return false }
      return id == ws3.id
    }
  }

  @Test
  func `cycle anchors at the in flight activation target`() async {
    let ws1 = Workspace(name: "one")
    let ws2 = Workspace(name: "two")
    let ws3 = Workspace(name: "three")
    // ws1 is the *completed* workspace, but a switch to ws2 is still in
    // flight. Cycling must advance from ws2 — anchoring at the completed
    // one made every rapid press re-target the same slow workspace.
    let liveDisplay = DisplayName(uuid: "test-display", name: Self.display.name)
    let state = Self.makeState(workspaces: [ws1, ws2, ws3]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = ws1.id
      $0.isActivating = true
      $0.activatingWorkspaceID = ws2.id
      $0.activatingDisplay = Self.display
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.current = { liveDisplay }
      $0.continuousClock = TestClock()
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activateNext())
    await store.receive {
      guard case .activate(let id, _, _) = $0 else { return false }
      return id == ws3.id
    }
  }

  @Test
  func `window cycle HUD follows app level cycle order`() async {
    let appA1 = WindowKey(pid: 1, windowID: 101, bundleId: "app.a")
    let appA2 = WindowKey(pid: 1, windowID: 102, bundleId: "app.a")
    let appB = WindowKey(pid: 2, windowID: 201, bundleId: "app.b")
    let workspace = Workspace(name: "Work")
    let state = Self.makeState(workspaces: [workspace]) {
      $0.$config.withLock {
        $0.sharedApps = [
          SharedApp(bundleIdentifier: appA1.bundleId, name: "A")
        ]
      }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = .branch(
        BSPBranch(
          split: .vertical,
          ratio: 0.5,
          left: .branch(
            BSPBranch(
              split: .horizontal,
              ratio: 0.5,
              left: .leaf(appA1),
              right: .leaf(appA2),
            )
          ),
          right: .leaf(appB),
        )
      )
      $0.fullscreenZoomed[workspace.id] = [appB]
    }
    let focused = LockIsolated<WindowKey?>(nil)
    let hudWindows = LockIsolated<[WindowKey]>([])
    let hudSelected = LockIsolated<WindowKey?>(nil)
    let hudByWindow = LockIsolated<Bool?>(nil)
    let hudDisplay = LockIsolated<DisplayName?>(nil)
    let hudIndicators = LockIsolated<[WindowKey: WindowSwitcherIndicators]>([:])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.focusManager.focusWindow = { key in focused.withValue { $0 = key } }
      $0.workspaceHUD.showWindowSwitcher = { windows, selected, byWindow, indicators, _, display in
        hudWindows.withValue { $0 = windows }
        hudSelected.withValue { $0 = selected }
        hudByWindow.withValue { $0 = byWindow }
        hudIndicators.withValue { $0 = indicators }
        hudDisplay.withValue { $0 = display }
      }
    }

    await store.send(.cycleWindowResolved(windowKey: appA1, direction: .next))
    await store.finish()

    #expect(focused.value == appB)
    #expect(hudWindows.value == [appA1, appB])
    #expect(hudSelected.value == appB)
    #expect(hudByWindow.value == false)
    #expect(hudIndicators.value[appA1]?.isShared == true)
    #expect(hudIndicators.value[appA1]?.isFocused == true)
    #expect(hudIndicators.value[appB]?.isFullscreen == true)
    #expect(hudIndicators.value[appB]?.isFocused == false)
    #expect(hudDisplay.value == Self.display)
  }

  @Test
  func `window cycle HUD preserves individual same app windows in window mode`() async {
    let appA1 = WindowKey(pid: 1, windowID: 101, bundleId: "app.a")
    let appA2 = WindowKey(pid: 1, windowID: 102, bundleId: "app.a")
    let workspace = Workspace(name: "Work")
    let state = Self.makeState(workspaces: [workspace]) {
      $0.$config.withLock { $0.settings.switching.cycleSameAppWindows = true }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = .branch(
        BSPBranch(split: .vertical, ratio: 0.5, left: .leaf(appA1), right: .leaf(appA2))
      )
    }
    let focused = LockIsolated<WindowKey?>(nil)
    let hudWindows = LockIsolated<[WindowKey]>([])
    let hudByWindow = LockIsolated<Bool?>(nil)
    let hudIndicators = LockIsolated<[WindowKey: WindowSwitcherIndicators]>([:])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.focusManager.focusWindow = { key in focused.withValue { $0 = key } }
      $0.workspaceHUD.showWindowSwitcher = { windows, _, byWindow, indicators, _, _ in
        hudWindows.withValue { $0 = windows }
        hudByWindow.withValue { $0 = byWindow }
        hudIndicators.withValue { $0 = indicators }
      }
    }

    await store.send(.cycleWindowResolved(windowKey: appA1, direction: .next))
    await store.finish()

    #expect(focused.value == appA2)
    #expect(hudWindows.value == [appA1, appA2])
    #expect(hudByWindow.value == true)
    #expect(hudIndicators.value[appA1]?.isFocused == true)
    #expect(hudIndicators.value[appA2]?.isFocused == false)
  }

  @Test(arguments: [
    (direction: CycleDirection.next, expectsFirst: true),
    (direction: CycleDirection.previous, expectsFirst: false),
  ])
  func `window cycle scopes candidates and HUD to the pointer display`(
    direction: CycleDirection,
    expectsFirst: Bool,
  ) async {
    let displayA = DisplayName(uuid: "display-a", name: "A")
    let displayB = DisplayName(uuid: "display-b", name: "B")
    let firstA = WindowKey(pid: 1, windowID: 101, bundleId: "app.a.first")
    let lastA = WindowKey(pid: 2, windowID: 201, bundleId: "app.a.last")
    let keyboardFocusedB = WindowKey(pid: 3, windowID: 301, bundleId: "app.b")
    let workspaceA = Workspace(name: "A")
    let workspaceB = Workspace(name: "B")
    let state = Self.makeState(workspaces: [workspaceA, workspaceB]) {
      $0.focusedDisplay = displayB
      $0.activeWorkspacesByDisplay = [
        displayA: workspaceA.id,
        displayB: workspaceB.id,
      ]
      $0.tilingTrees[workspaceA.id] = .branch(
        BSPBranch(
          split: .vertical,
          ratio: 0.5,
          left: .leaf(firstA),
          right: .leaf(lastA),
        )
      )
      $0.tilingTrees[workspaceB.id] = .leaf(keyboardFocusedB)
    }
    let focused = LockIsolated<WindowKey?>(nil)
    let hudWindows = LockIsolated<[WindowKey]>([])
    let hudDisplay = LockIsolated<DisplayName?>(nil)
    let hudIndicators = LockIsolated<[WindowKey: WindowSwitcherIndicators]>([:])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.focusManager.focusWindow = { key in focused.withValue { $0 = key } }
      $0.workspaceHUD.showWindowSwitcher = { windows, _, _, indicators, _, display in
        hudWindows.withValue { $0 = windows }
        hudDisplay.withValue { $0 = display }
        hudIndicators.withValue { $0 = indicators }
      }
    }
    store.exhaustivity = .off

    await store.send(.cycleWindowResolved(
      windowKey: keyboardFocusedB,
      direction: direction,
      interactionDisplay: displayA,
    ))
    await store.finish()

    #expect(focused.value == (expectsFirst ? firstA : lastA))
    #expect(hudWindows.value == [firstA, lastA])
    #expect(hudDisplay.value == displayA)
    #expect(hudIndicators.value.values.allSatisfy { !$0.isFocused })
  }

  @Test
  func `late window cycle resolution keeps the existing session display`() async {
    let displayA = DisplayName(uuid: "display-a", name: "A")
    let displayB = DisplayName(uuid: "display-b", name: "B")
    let firstA = WindowKey(pid: 1, windowID: 101, bundleId: "app.a.first")
    let lastA = WindowKey(pid: 2, windowID: 201, bundleId: "app.a.last")
    let staleAnchorB = WindowKey(pid: 3, windowID: 301, bundleId: "app.b")
    let workspaceA = Workspace(name: "A")
    let workspaceB = Workspace(name: "B")
    let state = Self.makeState(workspaces: [workspaceA, workspaceB]) {
      $0.focusedDisplay = displayB
      $0.activeWorkspacesByDisplay = [
        displayA: workspaceA.id,
        displayB: workspaceB.id,
      ]
      $0.tilingTrees[workspaceA.id] = .branch(
        BSPBranch(
          split: .vertical,
          ratio: 0.5,
          left: .leaf(firstA),
          right: .leaf(lastA),
        )
      )
      $0.tilingTrees[workspaceB.id] = .leaf(staleAnchorB)
      $0.windowCycleSession = WorkspaceActivationFeature.State.WindowCycleSession(
        workspaceId: workspaceA.id,
        windows: [firstA, lastA],
        selected: firstA,
        focusedWindow: staleAnchorB,
        byWindow: false,
        display: displayA,
        holdModifiers: .option,
        isHUDVisible: false,
      )
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    }
    store.exhaustivity = .off

    await store.send(.cycleWindowShortcutResolved(
      windowKey: staleAnchorB,
      direction: .next,
      holdModifiers: .option,
      interactionDisplay: displayB,
    ))
    await store.receive {
      guard
        case .cycleWindowShortcut(
          .next,
          holdModifiers: .option,
          interactionDisplay: displayA,
        ) = $0
      else {
        return false
      }
      return true
    }
    await store.finish()

    #expect(store.state.windowCycleSession?.selected == lastA)
    #expect(store.state.windowCycleSession?.display == displayA)
    #expect(store.state.windowCycleSession?.windows == [firstA, lastA])
  }

  @Test
  func `window cycle does not fall back when the pointer display is empty`() async {
    let emptyDisplay = DisplayName(uuid: "display-a", name: "Empty")
    let occupiedDisplay = DisplayName(uuid: "display-b", name: "Occupied")
    let first = WindowKey(pid: 1, windowID: 101, bundleId: "app.first")
    let second = WindowKey(pid: 2, windowID: 201, bundleId: "app.second")
    let workspace = Workspace(name: "Occupied")
    let state = Self.makeState(workspaces: [workspace]) {
      $0.focusedDisplay = occupiedDisplay
      $0.activeWorkspacesByDisplay[occupiedDisplay] = workspace.id
      $0.tilingTrees[workspace.id] = .branch(
        BSPBranch(
          split: .vertical,
          ratio: 0.5,
          left: .leaf(first),
          right: .leaf(second),
        )
      )
    }
    let focused = LockIsolated<[WindowKey]>([])
    let hudShows = LockIsolated(0)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.focusManager.focusWindow = { key in focused.withValue { $0.append(key) } }
      $0.workspaceHUD.showWindowSwitcher = { _, _, _, _, _, _ in
        hudShows.withValue { $0 += 1 }
      }
    }
    store.exhaustivity = .off

    await store.send(.cycleWindowResolved(
      windowKey: first,
      direction: .next,
      interactionDisplay: emptyDisplay,
    ))
    await store.finish()

    #expect(focused.value.isEmpty)
    #expect(hudShows.value == 0)
  }

  @Test
  func `uncomposed window cycle excludes shared non tiled windows on other displays`() async {
    let displayA = DisplayName(uuid: "display-a", name: "A")
    let displayB = DisplayName(uuid: "display-b", name: "B")
    let tiledA = WindowKey(pid: 1, windowID: 101, bundleId: "app.tiled")
    let floatingA = WindowKey(pid: 2, windowID: 201, bundleId: "app.floating")
    let floatingB = WindowKey(pid: 3, windowID: 202, bundleId: floatingA.bundleId)
    let unmanagedA = WindowKey(pid: 4, windowID: 301, bundleId: "app.unmanaged")
    let unmanagedB = WindowKey(pid: 5, windowID: 302, bundleId: unmanagedA.bundleId)
    let workspaceA = Workspace(name: "A")
    let workAreaA = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let workAreaB = CGRect(x: 1_000, y: 0, width: 1_000, height: 800)
    let state = Self.makeState(workspaces: [workspaceA]) {
      $0.$config.withLock {
        $0.sharedApps = [
          SharedApp(
            bundleIdentifier: floatingA.bundleId,
            name: "Floating",
            layout: .floating,
          ),
          SharedApp(
            bundleIdentifier: unmanagedA.bundleId,
            name: "Unmanaged",
            layout: .unmanaged,
          ),
        ]
      }
      $0.focusedDisplay = displayB
      $0.activeWorkspacesByDisplay[displayA] = workspaceA.id
      $0.tilingTrees[workspaceA.id] = .leaf(tiledA)
    }
    let focused = LockIsolated<WindowKey?>(nil)
    let hudWindows = LockIsolated<[WindowKey]>([])
    let hudDisplay = LockIsolated<DisplayName?>(nil)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { display in
        display == displayA ? workAreaA : workAreaB
      }
      $0.windowSnapshot.cachedKeys = { bundleIds, requireResizable in
        #expect(!requireResizable)
        switch bundleIds {
        case [floatingA.bundleId]:
          return [floatingB, floatingA]
        case [unmanagedA.bundleId]:
          return [unmanagedB, unmanagedA]
        default:
          Issue.record("Unexpected bundle lookup: \(bundleIds)")
          return []
        }
      }
      $0.windowSnapshot.onScreenWindowFrames = {
        [
          floatingA.windowID: CGRect(x: 100, y: 100, width: 300, height: 300),
          floatingB.windowID: CGRect(x: 1_100, y: 100, width: 300, height: 300),
          unmanagedA.windowID: CGRect(x: 500, y: 100, width: 300, height: 300),
          unmanagedB.windowID: CGRect(x: 1_500, y: 100, width: 300, height: 300),
        ]
      }
      $0.focusManager.focusWindow = { key in focused.withValue { $0 = key } }
      $0.workspaceHUD.showWindowSwitcher = { windows, _, _, _, _, display in
        hudWindows.withValue { $0 = windows }
        hudDisplay.withValue { $0 = display }
      }
    }
    store.exhaustivity = .off

    await store.send(.cycleWindowResolved(
      windowKey: tiledA,
      direction: .next,
      interactionDisplay: displayA,
    ))
    await store.finish()

    #expect(focused.value == floatingA)
    #expect(hudWindows.value == [tiledA, floatingA, unmanagedA])
    #expect(hudDisplay.value == displayA)
  }

  @Test
  func `window cycle MFF follows a shared floating window using its live frame`() async {
    let tiled = WindowKey(pid: 1, windowID: 101, bundleId: "app.tiled")
    let floating = WindowKey(pid: 2, windowID: 201, bundleId: "app.floating")
    let floatingFrame = CGRect(x: 120, y: 240, width: 600, height: 400)
    let workspace = Workspace(name: "Work")
    let state = Self.makeState(workspaces: [workspace]) {
      $0.$config.withLock {
        $0.settings.focus.mouseFollowsFocus = true
        $0.sharedApps = [
          SharedApp(
            bundleIdentifier: floating.bundleId,
            name: "Floating",
            layout: .floating,
          )
        ]
      }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = .leaf(tiled)
    }
    let order = LockIsolated<[String]>([])
    let warped = LockIsolated<[CGPoint]>([])
    let hudIndicators = LockIsolated<[WindowKey: WindowSwitcherIndicators]>([:])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.windowSnapshot.cachedKeys = { bundleIds, requireResizable in
        #expect(bundleIds == [floating.bundleId])
        #expect(requireResizable == false)
        return [floating]
      }
      $0.windowSnapshot.onScreenWindowFrames = {
        [floating.windowID: floatingFrame]
      }
      $0.windowSnapshot.windowFrame = { key in
        #expect(key == floating)
        order.withValue { $0.append("frame") }
        return floatingFrame
      }
      $0.focusManager.focusWindow = { key in
        #expect(key == floating)
        order.withValue { $0.append("focus") }
      }
      $0.mouse.warp = { point in
        order.withValue { $0.append("warp") }
        warped.withValue { $0.append(point) }
      }
      $0.workspaceHUD.showWindowSwitcher = { _, _, _, indicators, _, _ in
        hudIndicators.withValue { $0 = indicators }
      }
    }
    store.exhaustivity = .off

    await store.send(.cycleWindowResolved(windowKey: tiled, direction: .next))
    await store.finish()

    #expect(order.value == ["focus", "frame", "warp"])
    #expect(warped.value == [CGPoint(x: floatingFrame.midX, y: floatingFrame.midY)])
    #expect(hudIndicators.value[floating]?.isFloating == true)
    #expect(hudIndicators.value[floating]?.isShared == true)
  }

  @Test
  func `app cycle includes the borrowed block`() async {
    let hostWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.host")
    let borrowedWindow = WindowKey(pid: 2, windowID: 201, bundleId: "app.borrowed")
    let host = Workspace(name: "Host")
    let borrowed = Workspace(name: "Borrowed")
    let state = Self.makeState(workspaces: [host, borrowed]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = host.id
      $0.tilingTrees[host.id] = .leaf(hostWindow)
      $0.tilingTrees[borrowed.id] = .leaf(borrowedWindow)
      $0.compositionsByDisplay[Self.display] = Composition(
        host: host.id,
        borrowed: [BorrowedSlot(workspace: borrowed.id, edge: .right, fraction: 0.35)],
      )
    }
    let focused = LockIsolated<WindowKey?>(nil)
    let hudWindows = LockIsolated<[WindowKey]>([])
    let hudIndicators = LockIsolated<[WindowKey: WindowSwitcherIndicators]>([:])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.focusManager.focusWindow = { key in focused.withValue { $0 = key } }
      $0.workspaceHUD.showWindowSwitcher = { windows, _, _, indicators, _, _ in
        hudWindows.withValue { $0 = windows }
        hudIndicators.withValue { $0 = indicators }
      }
    }
    store.exhaustivity = .off

    await store.send(.cycleWindowResolved(windowKey: hostWindow, direction: .next))
    await store.finish()

    #expect(focused.value == borrowedWindow)
    #expect(hudWindows.value == [hostWindow, borrowedWindow])
    #expect(hudIndicators.value[hostWindow]?.isFocused == true)
    #expect(hudIndicators.value[borrowedWindow]?.isBorrowed == true)
  }

  @Test
  func `borrow app cycle includes shared non tiled apps by default`() async {
    let hostWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.host")
    let borrowedWindow = WindowKey(pid: 2, windowID: 201, bundleId: "app.borrowed")
    let sharedWindow = WindowKey(pid: 3, windowID: 301, bundleId: "app.shared")
    let sharedFloatingWindow = WindowKey(
      pid: 4,
      windowID: 401,
      bundleId: "app.shared-floating",
    )
    let host = Workspace(name: "Host")
    let borrowed = Workspace(name: "Borrowed")
    let workArea = CGRect(x: 0, y: 0, width: 1_200, height: 800)
    let expectedDisplay = Self.display
    let state = Self.makeState(workspaces: [host, borrowed]) {
      $0.$config.withLock {
        $0.sharedApps = [
          SharedApp(
            bundleIdentifier: sharedWindow.bundleId,
            name: "Shared",
            layout: .unmanaged,
          ),
          SharedApp(
            bundleIdentifier: sharedFloatingWindow.bundleId,
            name: "Shared Floating",
            layout: .floating,
          ),
        ]
      }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = host.id
      $0.tilingTrees[host.id] = .leaf(hostWindow)
      $0.tilingTrees[borrowed.id] = .leaf(borrowedWindow)
      $0.compositionsByDisplay[Self.display] = Composition(
        host: host.id,
        borrowed: [BorrowedSlot(workspace: borrowed.id, edge: .right, fraction: 0.35)],
      )
    }
    let focused = LockIsolated<WindowKey?>(nil)
    let hudWindows = LockIsolated<[WindowKey]>([])
    let hudIndicators = LockIsolated<[WindowKey: WindowSwitcherIndicators]>([:])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { display in
        #expect(display == expectedDisplay)
        return workArea
      }
      $0.windowSnapshot.cachedKeys = { bundleIds, requireResizable in
        #expect(bundleIds == [
          sharedFloatingWindow.bundleId,
          sharedWindow.bundleId,
        ])
        #expect(!requireResizable)
        return [sharedFloatingWindow, sharedWindow]
      }
      $0.windowSnapshot.onScreenWindowFrames = {
        [
          sharedFloatingWindow.windowID: CGRect(
            x: 600,
            y: 100,
            width: 400,
            height: 300,
          ),
          sharedWindow.windowID: CGRect(
            x: 100,
            y: 100,
            width: 400,
            height: 300,
          ),
        ]
      }
      $0.focusManager.focusWindow = { key in focused.withValue { $0 = key } }
      $0.workspaceHUD.showWindowSwitcher = { windows, _, _, indicators, _, _ in
        hudWindows.withValue { $0 = windows }
        hudIndicators.withValue { $0 = indicators }
      }
    }
    store.exhaustivity = .off

    await store.send(.cycleWindowResolved(windowKey: hostWindow, direction: .previous))
    await store.finish()

    #expect(focused.value == sharedWindow)
    #expect(hudWindows.value == [
      hostWindow,
      borrowedWindow,
      sharedFloatingWindow,
      sharedWindow,
    ])
    #expect(hudIndicators.value[sharedFloatingWindow]?.isShared == true)
    #expect(hudIndicators.value[sharedWindow]?.isShared == true)
  }

  @Test
  func `shared non tiled focus resolves the physical borrow display`() async {
    let displayA = DisplayName(uuid: "display-a", name: "A")
    let displayB = DisplayName(uuid: "display-b", name: "B")
    let windowA = WindowKey(pid: 1, windowID: 101, bundleId: "app.a")
    let hostWindow = WindowKey(pid: 2, windowID: 201, bundleId: "app.host")
    let borrowedWindow = WindowKey(pid: 3, windowID: 301, bundleId: "app.borrowed")
    let sharedWindow = WindowKey(pid: 4, windowID: 401, bundleId: "app.shared")
    let otherDisplaySharedWindow = WindowKey(
      pid: 5,
      windowID: 402,
      bundleId: sharedWindow.bundleId,
    )
    let workspaceA = Workspace(name: "A")
    let host = Workspace(name: "Host")
    let borrowed = Workspace(name: "Borrowed")
    let workAreaA = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let workAreaB = CGRect(x: 1_000, y: 0, width: 1_000, height: 800)
    let state = Self.makeState(workspaces: [workspaceA, host, borrowed]) {
      $0.$config.withLock {
        $0.sharedApps = [
          SharedApp(
            bundleIdentifier: sharedWindow.bundleId,
            name: "Shared",
            layout: .unmanaged,
          )
        ]
      }
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [
        displayA: workspaceA.id,
        displayB: host.id,
      ]
      $0.tilingTrees[workspaceA.id] = .leaf(windowA)
      $0.tilingTrees[host.id] = .leaf(hostWindow)
      $0.tilingTrees[borrowed.id] = .leaf(borrowedWindow)
      $0.compositionsByDisplay[displayB] = Composition(
        host: host.id,
        borrowed: [BorrowedSlot(workspace: borrowed.id, edge: .right, fraction: 0.35)],
      )
    }
    let focused = LockIsolated<WindowKey?>(nil)
    let hudWindows = LockIsolated<[WindowKey]>([])
    let hudDisplay = LockIsolated<DisplayName?>(nil)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB] }
      $0.displays.workArea = { display in
        display == displayB ? workAreaB : workAreaA
      }
      $0.windowSnapshot.cachedKeys = { bundleIds, requireResizable in
        #expect(bundleIds == [sharedWindow.bundleId])
        #expect(!requireResizable)
        return [otherDisplaySharedWindow, sharedWindow]
      }
      $0.windowSnapshot.onScreenWindowFrames = {
        [
          otherDisplaySharedWindow.windowID: CGRect(
            x: 100,
            y: 100,
            width: 400,
            height: 300,
          ),
          sharedWindow.windowID: CGRect(
            x: 1_100,
            y: 100,
            width: 400,
            height: 300,
          ),
        ]
      }
      $0.focusManager.focusWindow = { key in focused.withValue { $0 = key } }
      $0.workspaceHUD.showWindowSwitcher = { windows, _, _, _, _, display in
        hudWindows.withValue { $0 = windows }
        hudDisplay.withValue { $0 = display }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .cycleWindowResolved(windowKey: sharedWindow, direction: .previous)
    )
    await store.finish()

    #expect(focused.value == borrowedWindow)
    #expect(hudWindows.value == [hostWindow, borrowedWindow, sharedWindow])
    #expect(hudDisplay.value == displayB)
  }

  @Test
  func `window switcher option excludes shared tiled app during borrow`() async {
    let hostWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.host")
    let borrowedWindow = WindowKey(pid: 2, windowID: 201, bundleId: "app.borrowed")
    let sharedWindow = WindowKey(pid: 3, windowID: 301, bundleId: "app.shared")
    let host = Workspace(name: "Host")
    let borrowed = Workspace(name: "Borrowed")
    let state = Self.makeState(workspaces: [host, borrowed]) {
      $0.$config.withLock {
        $0.settings.switching.includeSharedAppsInWindowSwitcher = false
        $0.sharedApps = [
          SharedApp(
            bundleIdentifier: sharedWindow.bundleId,
            name: "Shared",
            layout: .tiled,
          )
        ]
      }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = host.id
      $0.tilingTrees[host.id] = .branch(
        BSPBranch(
          split: .vertical,
          ratio: 0.5,
          left: .leaf(hostWindow),
          right: .leaf(sharedWindow),
        )
      )
      $0.tilingTrees[borrowed.id] = .leaf(borrowedWindow)
      $0.compositionsByDisplay[Self.display] = Composition(
        host: host.id,
        borrowed: [BorrowedSlot(workspace: borrowed.id, edge: .right, fraction: 0.35)],
      )
    }
    let focused = LockIsolated<WindowKey?>(nil)
    let hudWindows = LockIsolated<[WindowKey]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.focusManager.focusWindow = { key in focused.withValue { $0 = key } }
      $0.workspaceHUD.showWindowSwitcher = { windows, _, _, _, _, _ in
        hudWindows.withValue { $0 = windows }
      }
    }
    store.exhaustivity = .off

    await store.send(.cycleWindowResolved(windowKey: hostWindow, direction: .previous))
    await store.finish()

    #expect(focused.value == borrowedWindow)
    #expect(hudWindows.value == [hostWindow, borrowedWindow])
  }

  @Test(arguments: [
    (direction: CycleDirection.next, expectsFirst: true),
    (direction: CycleDirection.previous, expectsFirst: false),
  ])
  func `window switcher option enters remaining apps from directional edge`(
    direction: CycleDirection,
    expectsFirst: Bool,
  ) async {
    let first = WindowKey(pid: 1, windowID: 101, bundleId: "app.first")
    let last = WindowKey(pid: 2, windowID: 201, bundleId: "app.last")
    let sharedWindow = WindowKey(pid: 3, windowID: 301, bundleId: "app.shared")
    let workspace = Workspace(name: "Work")
    let state = Self.makeState(workspaces: [workspace]) {
      $0.$config.withLock {
        $0.settings.switching.includeSharedAppsInWindowSwitcher = false
        $0.sharedApps = [
          SharedApp(
            bundleIdentifier: sharedWindow.bundleId,
            name: "Shared",
            layout: .floating,
          )
        ]
      }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = .branch(
        BSPBranch(
          split: .vertical,
          ratio: 0.5,
          left: .leaf(first),
          right: .leaf(last),
        )
      )
    }
    let focused = LockIsolated<WindowKey?>(nil)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.windowSnapshot.cachedKeys = { _, _ in [sharedWindow] }
      $0.focusManager.focusWindow = { key in focused.withValue { $0 = key } }
    }
    store.exhaustivity = .off

    await store.send(
      .cycleWindowResolved(windowKey: sharedWindow, direction: direction)
    )
    await store.finish()

    #expect(focused.value == (expectsFirst ? first : last))
  }

  @Test
  func `window cycle preserves borrowed windows from the same app`() async {
    let hostWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.shared")
    let borrowedWindow = WindowKey(pid: 1, windowID: 102, bundleId: "app.shared")
    let host = Workspace(name: "Host")
    let borrowed = Workspace(name: "Borrowed")
    let state = Self.makeState(workspaces: [host, borrowed]) {
      $0.$config.withLock { $0.settings.switching.cycleSameAppWindows = true }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = host.id
      $0.tilingTrees[host.id] = .leaf(hostWindow)
      $0.tilingTrees[borrowed.id] = .leaf(borrowedWindow)
      $0.compositionsByDisplay[Self.display] = Composition(
        host: host.id,
        borrowed: [BorrowedSlot(workspace: borrowed.id, edge: .right, fraction: 0.35)],
      )
    }
    let focused = LockIsolated<WindowKey?>(nil)
    let hudWindows = LockIsolated<[WindowKey]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.focusManager.focusWindow = { key in focused.withValue { $0 = key } }
      $0.workspaceHUD.showWindowSwitcher = { windows, _, _, _, _, _ in
        hudWindows.withValue { $0 = windows }
      }
    }
    store.exhaustivity = .off

    await store.send(.cycleWindowResolved(windowKey: hostWindow, direction: .next))
    await store.finish()

    #expect(focused.value == borrowedWindow)
    #expect(hudWindows.value == [hostWindow, borrowedWindow])
  }

  @Test
  func `quick window cycle shortcut commits on modifier release without HUD`() async {
    let appA = WindowKey(pid: 1, windowID: 101, bundleId: "app.a")
    let appB = WindowKey(pid: 2, windowID: 201, bundleId: "app.b")
    let workspace = Workspace(name: "Work")
    let state = Self.makeState(workspaces: [workspace]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = .branch(
        BSPBranch(split: .vertical, ratio: 0.5, left: .leaf(appA), right: .leaf(appB))
      )
    }
    let clock = TestClock()
    let modifiers = LockIsolated<HotKeyModifiers>(.option)
    let focused = LockIsolated<WindowKey?>(nil)
    let hudShows = LockIsolated(0)
    let hudDismisses = LockIsolated(0)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.modifierKeys.current = { modifiers.value }
      $0.focusManager.focusWindow = { key in focused.withValue { $0 = key } }
      $0.workspaceHUD.showWindowSwitcher = { _, _, _, _, _, _ in
        hudShows.withValue { $0 += 1 }
      }
      $0.workspaceHUD.dismissWindowSwitcher = { _ in
        hudDismisses.withValue { $0 += 1 }
      }
    }
    store.exhaustivity = .off

    await store.send(.cycleWindowShortcutResolved(
      windowKey: appA,
      direction: .next,
      holdModifiers: .option,
    ))
    #expect(store.state.windowCycleSession?.selected == appB)
    #expect(focused.value == nil)

    modifiers.withValue { $0 = [] }
    await clock.advance(by: .milliseconds(10))
    await store.receive(\.windowCycleModifierReleased)
    await store.finish()

    #expect(store.state.windowCycleSession == nil)
    #expect(focused.value == appB)
    #expect(hudShows.value == 0)
    #expect(hudDismisses.value == 0)
  }

  @Test
  func `held window cycle shortcut reveals HUD and fades it when released`() async {
    let appA = WindowKey(pid: 1, windowID: 101, bundleId: "app.a")
    let appB = WindowKey(pid: 2, windowID: 201, bundleId: "app.b")
    let workspace = Workspace(name: "Work")
    let state = Self.makeState(workspaces: [workspace]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = .branch(
        BSPBranch(split: .vertical, ratio: 0.5, left: .leaf(appA), right: .leaf(appB))
      )
    }
    let clock = TestClock()
    let modifiers = LockIsolated<HotKeyModifiers>(.option)
    let focused = LockIsolated<WindowKey?>(nil)
    let hudAutoDismiss = LockIsolated<Int??>(nil)
    let dismissedDisplay = LockIsolated<DisplayName??>(nil)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.modifierKeys.current = { modifiers.value }
      $0.focusManager.focusWindow = { key in focused.withValue { $0 = key } }
      $0.workspaceHUD.showWindowSwitcher = { _, _, _, _, autoDismiss, _ in
        hudAutoDismiss.withValue { $0 = .some(autoDismiss) }
      }
      $0.workspaceHUD.dismissWindowSwitcher = { display in
        dismissedDisplay.withValue { $0 = .some(display) }
      }
    }
    store.exhaustivity = .off

    await store.send(.cycleWindowShortcutResolved(
      windowKey: appA,
      direction: .next,
      holdModifiers: .option,
    ))
    await clock.advance(by: .milliseconds(150))
    await store.receive(\.windowCycleHUDDelayElapsed)
    #expect(store.state.windowCycleSession?.isHUDVisible == true)
    #expect(hudAutoDismiss.value == .some(nil))
    #expect(focused.value == nil)

    modifiers.withValue { $0 = [] }
    await clock.advance(by: .milliseconds(10))
    await store.receive(\.windowCycleModifierReleased)
    await store.finish()

    #expect(focused.value == appB)
    #expect(dismissedDisplay.value == .some(Self.display))
  }

  @Test
  func `window cycle HUD arrow moves logical selection without committing`() async {
    let appA = WindowKey(pid: 1, windowID: 101, bundleId: "app.a")
    let appB = WindowKey(pid: 2, windowID: 201, bundleId: "app.b")
    let appC = WindowKey(pid: 3, windowID: 301, bundleId: "app.c")
    let workspace = Workspace(name: "Work")
    let state = Self.makeState(workspaces: [workspace]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = .branch(
        BSPBranch(
          split: .vertical,
          ratio: 0.5,
          left: .leaf(appA),
          right: .branch(
            BSPBranch(split: .vertical, ratio: 0.5, left: .leaf(appB), right: .leaf(appC))
          ),
        )
      )
      $0.windowCycleSession = WorkspaceActivationFeature.State.WindowCycleSession(
        workspaceId: workspace.id,
        windows: [appA, appB, appC],
        selected: appB,
        focusedWindow: appA,
        byWindow: false,
        display: Self.display,
        holdModifiers: .command,
        isHUDVisible: true,
      )
    }
    let focused = LockIsolated<WindowKey?>(nil)
    let hudSelected = LockIsolated<WindowKey?>(nil)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.focusManager.focusWindow = { key in focused.withValue { $0 = key } }
      $0.workspaceHUD.showWindowSwitcher = { _, selected, _, _, _, _ in
        hudSelected.withValue { $0 = selected }
      }
    }
    store.exhaustivity = .off

    await store.send(.windowCycleHUDInteraction(.move(.next)))
    await store.finish()

    #expect(store.state.windowCycleSession?.selected == appC)
    #expect(store.state.windowCycleSession?.focusedWindow == appA)
    #expect(hudSelected.value == appC)
    #expect(focused.value == nil)
  }

  @Test
  func `window cycle HUD arrow commits exact same app window`() async {
    let appA1 = WindowKey(pid: 1, windowID: 101, bundleId: "app.a")
    let appA2 = WindowKey(pid: 1, windowID: 102, bundleId: "app.a")
    let workspace = Workspace(name: "Work")
    let state = Self.makeState(workspaces: [workspace]) {
      $0.$config.withLock { $0.settings.switching.cycleSameAppWindows = true }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = .branch(
        BSPBranch(split: .vertical, ratio: 0.5, left: .leaf(appA1), right: .leaf(appA2))
      )
      $0.windowCycleSession = WorkspaceActivationFeature.State.WindowCycleSession(
        workspaceId: workspace.id,
        windows: [appA1, appA2],
        selected: appA1,
        focusedWindow: appA1,
        byWindow: true,
        display: Self.display,
        holdModifiers: .option,
        isHUDVisible: true,
      )
    }
    let focused = LockIsolated<WindowKey?>(nil)
    let hudSelected = LockIsolated<WindowKey?>(nil)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.focusManager.focusWindow = { key in focused.withValue { $0 = key } }
      $0.workspaceHUD.showWindowSwitcher = { _, selected, _, _, _, _ in
        hudSelected.withValue { $0 = selected }
      }
    }
    store.exhaustivity = .off

    await store.send(.windowCycleHUDInteraction(.move(.next)))

    #expect(store.state.windowCycleSession?.selected == appA2)
    #expect(store.state.windowCycleSession?.focusedWindow == appA1)
    #expect(hudSelected.value == appA2)
    #expect(focused.value == nil)

    await store.send(.windowCycleHUDInteraction(.commitSelected))
    await store.finish()

    #expect(store.state.windowCycleSession == nil)
    #expect(focused.value == appA2)
  }

  @Test
  func `window cycle HUD enter commits current selection once`() async {
    let appA = WindowKey(pid: 1, windowID: 101, bundleId: "app.a")
    let appB = WindowKey(pid: 2, windowID: 201, bundleId: "app.b")
    let workspace = Workspace(name: "Work")
    let state = Self.makeState(workspaces: [workspace]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = .branch(
        BSPBranch(split: .vertical, ratio: 0.5, left: .leaf(appA), right: .leaf(appB))
      )
      $0.windowCycleSession = WorkspaceActivationFeature.State.WindowCycleSession(
        workspaceId: workspace.id,
        windows: [appA, appB],
        selected: appB,
        focusedWindow: appA,
        byWindow: false,
        display: Self.display,
        holdModifiers: .command,
        isHUDVisible: true,
      )
    }
    let focused = LockIsolated<[WindowKey]>([])
    let hudDismisses = LockIsolated(0)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.focusManager.focusWindow = { key in focused.withValue { $0.append(key) } }
      $0.workspaceHUD.dismissWindowSwitcher = { _ in
        hudDismisses.withValue { $0 += 1 }
      }
    }
    store.exhaustivity = .off

    await store.send(.windowCycleHUDInteraction(.commitSelected))
    await store.finish()

    #expect(store.state.windowCycleSession == nil)
    #expect(focused.value == [appB])
    #expect(hudDismisses.value == 1)
  }

  @Test
  func `window cycle HUD pointer selection commits exact same app window`() async {
    let appA1 = WindowKey(pid: 1, windowID: 101, bundleId: "app.a")
    let appA2 = WindowKey(pid: 1, windowID: 102, bundleId: "app.a")
    let workspace = Workspace(name: "Work")
    let state = Self.makeState(workspaces: [workspace]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = .branch(
        BSPBranch(split: .vertical, ratio: 0.5, left: .leaf(appA1), right: .leaf(appA2))
      )
      $0.windowCycleSession = WorkspaceActivationFeature.State.WindowCycleSession(
        workspaceId: workspace.id,
        windows: [appA1, appA2],
        selected: appA1,
        focusedWindow: appA1,
        byWindow: true,
        display: Self.display,
        holdModifiers: .option,
        isHUDVisible: true,
      )
    }
    let focused = LockIsolated<WindowKey?>(nil)
    let hudSelected = LockIsolated<WindowKey?>(nil)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.focusManager.focusWindow = { key in focused.withValue { $0 = key } }
      $0.workspaceHUD.showWindowSwitcher = { _, selected, _, _, _, _ in
        hudSelected.withValue { $0 = selected }
      }
    }
    store.exhaustivity = .off

    await store.send(.windowCycleHUDInteraction(.select(appA2)))

    #expect(store.state.windowCycleSession?.selected == appA2)
    #expect(hudSelected.value == appA2)

    await store.send(.windowCycleHUDInteraction(.commitSelected))
    await store.finish()

    #expect(store.state.windowCycleSession == nil)
    #expect(focused.value == appA2)
  }

  @Test
  func `window cycle HUD click commits the clicked item`() async {
    let appA = WindowKey(pid: 1, windowID: 101, bundleId: "app.a")
    let appB = WindowKey(pid: 2, windowID: 201, bundleId: "app.b")
    let workspace = Workspace(name: "Work")
    let state = Self.makeState(workspaces: [workspace]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = .branch(
        BSPBranch(split: .vertical, ratio: 0.5, left: .leaf(appA), right: .leaf(appB))
      )
      $0.windowCycleSession = WorkspaceActivationFeature.State.WindowCycleSession(
        workspaceId: workspace.id,
        windows: [appA, appB],
        selected: appB,
        focusedWindow: appA,
        byWindow: false,
        display: Self.display,
        holdModifiers: .command,
        isHUDVisible: true,
      )
    }
    let focused = LockIsolated<WindowKey?>(nil)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.focusManager.focusWindow = { key in focused.withValue { $0 = key } }
    }
    store.exhaustivity = .off

    await store.send(.windowCycleHUDInteraction(.commit(appA)))
    await store.finish()

    #expect(store.state.windowCycleSession == nil)
    #expect(focused.value == appA)
  }

  @Test
  func `window cycle HUD escape dismisses without committing`() async {
    let appA = WindowKey(pid: 1, windowID: 101, bundleId: "app.a")
    let appB = WindowKey(pid: 2, windowID: 201, bundleId: "app.b")
    let workspace = Workspace(name: "Work")
    let state = Self.makeState(workspaces: [workspace]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = .branch(
        BSPBranch(split: .vertical, ratio: 0.5, left: .leaf(appA), right: .leaf(appB))
      )
      $0.windowCycleSession = WorkspaceActivationFeature.State.WindowCycleSession(
        workspaceId: workspace.id,
        windows: [appA, appB],
        selected: appB,
        focusedWindow: appA,
        byWindow: false,
        display: Self.display,
        holdModifiers: .command,
        isHUDVisible: true,
      )
    }
    let focused = LockIsolated<WindowKey?>(nil)
    let hudDismisses = LockIsolated(0)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.focusManager.focusWindow = { key in focused.withValue { $0 = key } }
      $0.workspaceHUD.dismissWindowSwitcher = { _ in
        hudDismisses.withValue { $0 += 1 }
      }
    }
    store.exhaustivity = .off

    await store.send(.windowCycleHUDInteraction(.cancel))
    await store.finish()

    #expect(store.state.windowCycleSession == nil)
    #expect(focused.value == nil)
    #expect(hudDismisses.value == 1)
  }

  @Test
  func `assigning to another profile carries its command display into the switch`() async {
    let commandDisplay = DisplayName(uuid: "display-a", name: "A")
    let currentWorkspace = Workspace(name: "Current")
    let targetWorkspace = Workspace(name: "Target")
    let currentProfile = Profile(name: "Default", workspaces: [currentWorkspace])
    let targetProfile = Profile(name: "Dual", workspaces: [targetWorkspace])
    let state = WorkspaceActivationFeature.State()
    state.$config.withLock {
      $0.profiles = [currentProfile, targetProfile]
      $0.activeProfileId = currentProfile.id
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    }
    store.exhaustivity = .off

    await store.send(.membershipEditResolved(
      bundleId: "app.example",
      name: "Example",
      edit: .assign(to: targetWorkspace.id),
      interactionDisplay: commandDisplay,
    ))
    await store.receive {
      guard
        case .delegate(.profileSwitchRequested(
          let id,
          let focus,
          let interactionDisplay,
        )) = $0
      else {
        return false
      }
      return id == targetProfile.id
        && focus == targetWorkspace.id
        && interactionDisplay == commandDisplay
    }

    #expect(
      store.state.config.profiles
        .first(where: { $0.id == targetProfile.id })?
        .workspaces[id: targetWorkspace.id]?
        .apps.contains(where: { $0.bundleIdentifier == "app.example" }) == true
    )
  }

  @Test
  func `focus adjacent display keeps workspace and shows HUDs on both displays`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let wsA = Workspace(name: "A")
    let wsB = Workspace(name: "B")
    let windowA = WindowKey(pid: 1, windowID: 101, bundleId: "app.a")
    let windowB = WindowKey(pid: 2, windowID: 201, bundleId: "app.b")
    let state = Self.makeState(workspaces: [wsA, wsB]) {
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [displayA: wsA.id, displayB: wsB.id]
      $0.tilingTrees = [wsA.id: .leaf(windowA), wsB.id: .leaf(windowB)]
    }
    state.$config.withLock {
      $0.settings.hud.position = .bottomTrailing
      $0.settings.hud.size = .large
    }
    let requests = LockIsolated<[ActivationRequest]>([])
    let focused = LockIsolated<[WindowKey]>([])
    let hudCalls = LockIsolated<Set<String>>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB] }
      $0.displays.current = { displayA }
      $0.workspaceManager.activate = { request in
        requests.withValue { $0.append(request) }
      }
      $0.focusManager.focusWindow = { key in
        focused.withValue { $0.append(key) }
      }
      $0.workspaceHUD.showAction = { request in
        hudCalls.withValue {
          _ = $0.insert(
            "\(request.display?.name ?? "nil")|\(request.name)|"
              + "\(request.subtitle ?? "nil")|\(request.position.rawValue)|\(request.size.rawValue)"
          )
        }
      }
    }
    store.exhaustivity = .off

    await store.send(.focusAdjacentDisplay(direction: 1))
    await store.finish()

    #expect(requests.value.isEmpty)
    #expect(focused.value == [windowB])
    #expect(store.state.focusedDisplay == displayB)
    #expect(store.state.activeWorkspacesByDisplay[displayB] == wsB.id)
    #expect(store.state.activeWorkspacesByDisplay[displayA] == wsA.id)
    #expect(hudCalls.value == [
      "\(displayB.name)|\(wsB.name)|nil|bottomTrailing|large",
      "\(displayA.name)|\(String(localized: "Focus moved"))|"
        + String(localized: "\(wsB.name) is on \(displayB.name)")
        + "|bottomTrailing|large",
    ])
  }

  @Test
  func `focus between displays preserves borrowed workspace on return`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let browser = Workspace(name: "Browser")
    let terminal = Workspace(name: "Terminal")
    let figma = Workspace(name: "Figma")
    let browserWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.browser")
    let terminalWindow = WindowKey(pid: 2, windowID: 201, bundleId: "app.terminal")
    let figmaWindow = WindowKey(pid: 3, windowID: 301, bundleId: "app.figma")
    let composition = Composition(
      host: browser.id,
      borrowed: [
        BorrowedSlot(workspace: figma.id, edge: .right, fraction: 0.4)
      ],
    )
    let state = Self.makeState(workspaces: [browser, terminal, figma]) {
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [
        displayA: browser.id,
        displayB: terminal.id,
      ]
      $0.tilingTrees = [
        browser.id: .leaf(browserWindow),
        terminal.id: .leaf(terminalWindow),
        figma.id: .leaf(figmaWindow),
      ]
      $0.compositionsByDisplay[displayA] = composition
    }
    let activations = LockIsolated<[ActivationRequest]>([])
    let focused = LockIsolated<[WindowKey]>([])
    let pointerDisplay = LockIsolated(displayA)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB] }
      $0.displays.current = { pointerDisplay.value }
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
      $0.focusManager.focusWindow = { key in
        focused.withValue { $0.append(key) }
      }
    }
    store.exhaustivity = .off

    await store.send(.focusAdjacentDisplay(direction: 1))
    await store.finish()
    #expect(store.state.focusedDisplay == displayB)
    #expect(store.state.compositionsByDisplay[displayA] == composition)

    pointerDisplay.setValue(displayB)
    await store.send(.focusAdjacentDisplay(direction: -1))
    await store.finish()

    #expect(store.state.focusedDisplay == displayA)
    #expect(store.state.compositionsByDisplay[displayA] == composition)
    #expect(activations.value.isEmpty)
    #expect(focused.value == [terminalWindow, browserWindow])
  }

  @Test
  func `activating visible host across displays preserves borrowed workspace`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    // Pinned, so activation resolves each workspace back to the display it is
    // already on — the round trip is a pure focus transfer.
    let browser = Workspace(name: "Browser", displayHint: displayA)
    let terminal = Workspace(name: "Terminal", displayHint: displayB)
    let figma = Workspace(name: "Figma", displayHint: displayA)
    let browserWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.browser")
    let terminalWindow = WindowKey(pid: 2, windowID: 201, bundleId: "app.terminal")
    let figmaWindow = WindowKey(pid: 3, windowID: 301, bundleId: "app.figma")
    let composition = Composition(
      host: browser.id,
      borrowed: [
        BorrowedSlot(workspace: figma.id, edge: .right, fraction: 0.4)
      ],
    )
    let state = Self.makeState(workspaces: [browser, terminal, figma]) {
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [
        displayA: browser.id,
        displayB: terminal.id,
      ]
      $0.tilingTrees = [
        browser.id: .leaf(browserWindow),
        terminal.id: .leaf(terminalWindow),
        figma.id: .leaf(figmaWindow),
      ]
      $0.compositionsByDisplay[displayA] = composition
    }
    let activations = LockIsolated<[ActivationRequest]>([])
    let focused = LockIsolated<[WindowKey]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
      $0.focusManager.focusWindow = { key in
        focused.withValue { $0.append(key) }
      }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: terminal.id, setFocus: true))
    await store.finish()
    #expect(store.state.focusedDisplay == displayB)
    #expect(store.state.compositionsByDisplay[displayA] == composition)

    await store.send(.activate(workspaceId: browser.id, setFocus: true))
    await store.finish()

    #expect(store.state.focusedDisplay == displayA)
    #expect(store.state.compositionsByDisplay[displayA] == composition)
    #expect(activations.value.isEmpty)
    #expect(focused.value == [terminalWindow, browserWindow])
  }

  @Test
  func `workspace chain subtitle keeps visible chain identity as the first fact`() {
    let feature = WorkspaceActivationFeature()

    let visibleChain = feature.workspaceChainHUDSubtitle(
      visibleChainName: "Test",
      resultFacts: ["Coding", "Returned KakaoTalk"],
      secondLine: "Focus moved: Browser is on Display B",
    )
    let hiddenChain = feature.workspaceChainHUDSubtitle(
      visibleChainName: nil,
      resultFacts: ["Coding", "Returned KakaoTalk"],
      secondLine: "Focus moved: Browser is on Display B",
    )

    #expect(
      visibleChain.text
        == "Test · Coding · Returned KakaoTalk\nFocus moved: Browser is on Display B"
    )
    #expect(visibleChain.symbolIconName == "link")
    #expect(
      hiddenChain.text
        == "Coding · Returned KakaoTalk\nFocus moved: Browser is on Display B"
    )
    #expect(hiddenChain.symbolIconName == nil)
  }

  @Test
  func `uncovered chain focus HUD includes the visible chain name and link`() throws {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let workspace = Workspace(name: "Browser")
    let context = WorkspaceChainHUDContext(
      name: "Test",
      role: .chainMember,
      profileSwitch: nil,
      coveredDisplays: [displayB],
      focusTransfer: WorkspaceChainFocusTransfer(
        from: displayA,
        to: displayB,
        workspaceName: workspace.name,
      ),
      destinationReturnedBorrowNames: [],
      sourceCompositionHUDs: [],
      deferredCleanupHUDs: [],
      vacatedHUDs: [],
      cleanupTransaction: nil,
    )

    let request = try #require(
      WorkspaceActivationFeature().uncoveredWorkspaceChainFocusMovedHUDRequest(
        workspace: workspace,
        context: context,
        state: Self.makeState(workspaces: [workspace]),
      )
    )

    #expect(request.name == String(localized: "Focus moved"))
    #expect(
      request.subtitle
        == "Test · \(String(localized: "\(workspace.name) is on \(displayB.name)"))"
    )
    #expect(request.subtitleSymbolIconName == "link")
    #expect(request.display == displayA)
  }

  @Test
  func `workspace chain restores peers before returning focus to selected workspace`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let code = Workspace(name: "Code", displayHint: displayA)
    let slack = Workspace(name: "Slack", displayHint: displayB)
    let old = Workspace(name: "Old", displayHint: displayB)
    let codeWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.code")
    let slackWindow = WindowKey(pid: 2, windowID: 201, bundleId: "app.slack")
    let chain = WorkspaceChain(
      name: "Coding",
      workspaceIDs: [code.id, slack.id],
    )
    let state = Self.makeState(workspaces: [code, slack, old]) {
      $0.isTilingPaused = true
      $0.focusedDisplay = displayB
      $0.connectedDisplays = [displayA, displayB]
      $0.activeWorkspacesByDisplay = [displayA: code.id, displayB: old.id]
      $0.tilingTrees = [code.id: .leaf(codeWindow), slack.id: .leaf(slackWindow)]
      $0.$config.withLock { $0.mutateActiveProfile { $0.workspaceChains = [chain] } }
    }
    let activations = LockIsolated<[ActivationRequest]>([])
    let focused = LockIsolated<[WindowKey]>([])
    let hudRequests = LockIsolated<[ActionHUDRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB] }
      $0.displays.current = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
      $0.focusManager.focusWindow = { key in
        focused.withValue { $0.append(key) }
      }
      $0.workspaceHUD.showAction = { request in
        hudRequests.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: code.id, setFocus: true))
    await store.receive {
      guard case .activationCompleted(let workspaceId, let display, _) = $0 else { return false }
      return workspaceId == slack.id && display?.matches(displayB) == true
    }
    #expect(store.state.activeWorkspacesByDisplay[displayB] == slack.id)
    await store.receive {
      guard case .activationTailFinished = $0 else { return false }
      return true
    }
    await store.receive(\.processDisplayRestores)
    await store.receive {
      guard case .restoreDisplay(let assignment) = $0 else { return false }
      return assignment.workspace == code.id && assignment.display.matches(displayA)
    }
    #expect(store.state.focusedDisplay == displayA)
    await store.finish()

    #expect(activations.value.map(\.workspace.id) == [slack.id])
    #expect(activations.value.allSatisfy { !$0.setFocus })
    #expect(focused.value == [codeWindow])
    #expect(store.state.focusedDisplay == displayA)
    #expect(store.state.activeWorkspacesByDisplay == [displayA: code.id, displayB: slack.id])
    #expect(store.state.compositionsByDisplay.isEmpty)
    #expect(hudRequests.value.map(\.name) == [slack.name, code.name])
    #expect(hudRequests.value.map(\.display) == [displayB, displayA])
    expectNoDifference(
      hudRequests.value.map(\.subtitle),
      [chain.name, chain.name],
    )
    #expect(hudRequests.value.allSatisfy { $0.subtitleSymbolIconName == "link" })
  }

  @Test
  func `ordinary fallback HUD does not inherit workspace chain identity`() async throws {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let disconnected = DisplayName("Disconnected")
    let coding = Workspace(name: "Coding", displayHint: displayA)
    let browser = Workspace(name: "Browser", displayHint: disconnected)
    let figma = Workspace(name: "Figma")
    let browserWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.browser")
    let figmaWindow = WindowKey(pid: 2, windowID: 201, bundleId: "app.figma")
    let chain = WorkspaceChain(
      name: "Work",
      workspaceIDs: [coding.id, browser.id],
    )
    let state = Self.makeState(workspaces: [coding, browser, figma]) {
      $0.isTilingPaused = true
      $0.focusedDisplay = displayA
      $0.connectedDisplays = [displayA, displayB]
      $0.activeWorkspacesByDisplay = [displayA: figma.id]
      $0.displayWorkspaceHistory[displayB] = [figma.id]
      $0.workspaceMRU = [figma.id]
      $0.tilingTrees = [
        browser.id: .leaf(browserWindow),
        figma.id: .leaf(figmaWindow),
      ]
      $0.$config.withLock { $0.mutateActiveProfile { $0.workspaceChains = [chain] } }
    }
    let hudRequests = LockIsolated<[ActionHUDRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB] }
      $0.displays.current = { displayA }
      $0.displays.primary = { displayA }
      $0.displays.connected = { reference in
        [displayA, displayB].first { $0.matches(reference) }
      }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { _ in }
      $0.focusManager.focusWindow = { _ in }
      $0.workspaceHUD.showAction = { request in
        hudRequests.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: browser.id, setFocus: true))
    await Self.receiveActivationCompletion(store, workspaceID: figma.id, display: displayB)
    await store.receive(\.processDisplayRestores)
    await store.receive {
      guard case .restoreDisplay(let assignment) = $0 else { return false }
      return assignment.workspace == browser.id && assignment.display.matches(displayA)
    }
    await Self.receiveActivationCompletion(store, workspaceID: browser.id, display: displayA)
    await store.finish()

    let figmaHUD = try #require(hudRequests.value.first {
      $0.display?.matches(displayB) == true
    })
    #expect(figmaHUD.name == figma.name)
    #expect(figmaHUD.subtitle == nil)
    #expect(figmaHUD.subtitleSymbolIconName == nil)
    let browserHUD = try #require(hudRequests.value.first {
      $0.display?.matches(displayA) == true
    })
    #expect(browserHUD.name == browser.name)
    #expect(browserHUD.subtitle == chain.name)
    #expect(browserHUD.subtitleSymbolIconName == "link")
  }

  @Test
  func `satisfied chain focus uses the captured pointer display instead of stale focus`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let codeWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.code")
    let slackWindow = WindowKey(pid: 2, windowID: 201, bundleId: "app.slack")
    let code = Workspace(name: "Code", displayHint: displayA)
    let slack = Workspace(name: "Slack", displayHint: displayB)
    let chain = WorkspaceChain(
      name: "Work",
      workspaceIDs: [code.id, slack.id],
    )
    let state = Self.makeState(workspaces: [code, slack]) {
      $0.isTilingPaused = true
      $0.focusedDisplay = displayA
      $0.connectedDisplays = [displayA, displayB]
      $0.activeWorkspacesByDisplay = [displayA: code.id, displayB: slack.id]
      $0.tilingTrees = [code.id: .leaf(codeWindow), slack.id: .leaf(slackWindow)]
      $0.$config.withLock { $0.mutateActiveProfile { $0.workspaceChains = [chain] } }
    }
    let hudRequests = LockIsolated<[ActionHUDRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB] }
      $0.displays.current = { displayB }
      $0.displays.primary = { displayA }
      $0.displays.connected = { reference in
        [displayA, displayB].first { $0.matches(reference) }
      }
      $0.focusManager.focusWindow = { _ in }
      $0.workspaceHUD.showAction = { request in
        hudRequests.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: slack.id, setFocus: true))
    await store.receive(\.processDisplayRestores)
    await store.receive {
      guard case .restoreDisplay(let assignment) = $0 else { return false }
      return assignment.workspace == slack.id && assignment.display.matches(displayB)
    }
    await store.finish()

    #expect(store.state.focusedDisplay == displayB)
    #expect(hudRequests.value.count == 1)
    #expect(hudRequests.value.first?.display == displayB)
    #expect(hudRequests.value.first?.name == slack.name)
    #expect(hudRequests.value.first?.subtitle == chain.name)
    #expect(hudRequests.value.first?.subtitleSymbolIconName == "link")
    #expect(!hudRequests.value.contains {
      $0.name == String(localized: "Focus moved")
    })
  }

  @Test
  func `workspace chain stacks destination return and focus facts on the source display HUD`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let browserWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.browser")
    let codingWindow = WindowKey(pid: 2, windowID: 201, bundleId: "app.coding")
    let slackWindow = WindowKey(pid: 3, windowID: 301, bundleId: "app.slack")
    let kakaoWindow = WindowKey(pid: 4, windowID: 401, bundleId: "app.kakao")
    let browser = Workspace(name: "Browser", displayHint: displayB)
    let coding = Workspace(name: "Coding", displayHint: displayA)
    let slack = Workspace(name: "Slack", displayHint: displayA)
    let kakaoTalk = Workspace(name: "KakaoTalk")
    let chain = WorkspaceChain(
      name: "Test",
      workspaceIDs: [browser.id, coding.id],
    )
    let state = Self.makeState(workspaces: [browser, coding, slack, kakaoTalk]) {
      $0.isTilingPaused = true
      $0.focusedDisplay = displayA
      $0.connectedDisplays = [displayA, displayB]
      $0.activeWorkspacesByDisplay = [
        displayA: slack.id,
        displayB: browser.id,
      ]
      $0.tilingTrees = [
        browser.id: .leaf(browserWindow),
        coding.id: .leaf(codingWindow),
        slack.id: .leaf(slackWindow),
        kakaoTalk.id: .leaf(kakaoWindow),
      ]
      $0.compositionsByDisplay[displayA] = Composition(
        host: slack.id,
        borrowed: [
          BorrowedSlot(workspace: kakaoTalk.id, edge: .right, fraction: 0.4)
        ],
      )
      $0.$config.withLock { $0.mutateActiveProfile { $0.workspaceChains = [chain] } }
    }
    let hudRequests = LockIsolated<[ActionHUDRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB] }
      $0.displays.current = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { _ in }
      $0.focusManager.focusWindow = { _ in }
      $0.workspaceHUD.showAction = { request in
        hudRequests.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: browser.id, setFocus: true))
    await Self.receiveActivationCompletion(store, workspaceID: coding.id, display: displayA)
    await store.receive(\.processDisplayRestores)
    await store.receive {
      guard case .restoreDisplay(let assignment) = $0 else { return false }
      return assignment.workspace == browser.id && assignment.display.matches(displayB)
    }
    await store.finish()

    let returned = String(localized: "Returned \(kakaoTalk.name)")
    let focusTransfer = "\(String(localized: "Focus moved")): "
      + String(localized: "\(browser.name) is on \(displayB.name)")
    expectNoDifference(
      hudRequests.value.map {
        "\($0.display?.name ?? "nil")|\($0.name)|\($0.subtitle ?? "nil")|"
          + "\($0.subtitleSymbolIconName ?? "nil")"
      },
      [
        "\(displayA.name)|\(coding.name)|\(chain.name!) · \(returned)\n\(focusTransfer)|link",
        "\(displayB.name)|\(browser.name)|\(chain.name!)|link",
      ],
    )
    #expect(store.state.focusedDisplay == displayB)
    #expect(store.state.activeWorkspacesByDisplay == [
      displayA: coding.id,
      displayB: browser.id,
    ])
    #expect(store.state.compositionsByDisplay[displayA] == nil)
  }

  @Test
  func `workspace chain keeps source and destination borrow returns on their own displays`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let displayC = DisplayName("C")
    let movingHost = Workspace(name: "Moving Host")
    let peer = Workspace(name: "Peer", displayHint: displayC)
    let destinationHost = Workspace(name: "Destination Host", displayHint: displayB)
    let sourceBorrow = Workspace(name: "Source Borrow", kind: .scratchpad)
    let destinationBorrow = Workspace(name: "Destination Borrow", kind: .scratchpad)
    let chain = WorkspaceChain(
      name: "Move Together",
      workspaceIDs: [movingHost.id, peer.id],
    )
    let state = Self.makeState(
      workspaces: [movingHost, peer, destinationHost, sourceBorrow, destinationBorrow]
    ) {
      $0.isTilingPaused = true
      $0.focusedDisplay = displayB
      $0.connectedDisplays = [displayA, displayB, displayC]
      $0.activeWorkspacesByDisplay = [
        displayA: movingHost.id,
        displayB: destinationHost.id,
        displayC: peer.id,
      ]
      $0.compositionsByDisplay = [
        displayA: Composition(
          host: movingHost.id,
          borrowed: [
            BorrowedSlot(workspace: sourceBorrow.id, edge: .right, fraction: 0.4)
          ],
        ),
        displayB: Composition(
          host: destinationHost.id,
          borrowed: [
            BorrowedSlot(workspace: destinationBorrow.id, edge: .right, fraction: 0.4)
          ],
        ),
      ]
      $0.$config.withLock { $0.mutateActiveProfile { $0.workspaceChains = [chain] } }
    }
    let hudRequests = LockIsolated<[ActionHUDRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB, displayC] }
      $0.displays.current = { displayB }
      $0.displays.primary = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { _ in }
      $0.workspaceHUD.showAction = { request in
        hudRequests.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: movingHost.id, setFocus: true))
    await Self.receiveActivationCompletion(store, workspaceID: movingHost.id, display: displayB)
    await store.finish()

    let destinationReturned = String(localized: "Returned \(destinationBorrow.name)")
    let sourceReturned = String(localized: "Returned \(sourceBorrow.name)")
    let moved = String(localized: "\(movingHost.name) is on \(displayB.name)")
    let records = Set(hudRequests.value.map { request in
      "\(request.display?.name ?? "nil")|\(request.name)|\(request.subtitle ?? "nil")|"
        + "\(request.subtitleExtendsDuration)"
    })
    #expect(hudRequests.value.count == 2)
    #expect(records == [
      "\(displayB.name)|\(movingHost.name)|\(chain.name!) · \(destinationReturned)|true",
      "\(displayA.name)|\(String(localized: "Workspace moved"))|"
        + "\(chain.name!) · \(moved) · \(sourceReturned)|true",
    ])
    #expect(store.state.compositionsByDisplay.isEmpty)
  }

  @Test
  func `moving a borrowed chain member reports the return on its source host display`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let displayC = DisplayName("C")
    let host = Workspace(name: "Host", displayHint: displayA)
    let selected = Workspace(name: "Selected")
    let peer = Workspace(name: "Peer", displayHint: displayB)
    let old = Workspace(name: "Old", displayHint: displayC)
    let chain = WorkspaceChain(
      name: "Linked",
      workspaceIDs: [selected.id, peer.id],
    )
    let state = Self.makeState(workspaces: [host, selected, peer, old]) {
      $0.isTilingPaused = true
      $0.focusedDisplay = displayC
      $0.connectedDisplays = [displayA, displayB, displayC]
      $0.activeWorkspacesByDisplay = [
        displayA: host.id,
        displayB: peer.id,
        displayC: old.id,
      ]
      $0.compositionsByDisplay[displayA] = Composition(
        host: host.id,
        borrowed: [
          BorrowedSlot(workspace: selected.id, edge: .right, fraction: 0.4)
        ],
      )
      $0.$config.withLock { $0.mutateActiveProfile { $0.workspaceChains = [chain] } }
    }
    let hudRequests = LockIsolated<[ActionHUDRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB, displayC] }
      $0.displays.current = { displayC }
      $0.displays.primary = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { _ in }
      $0.workspaceHUD.showAction = { request in
        hudRequests.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: selected.id, setFocus: true))
    await Self.receiveActivationCompletion(store, workspaceID: selected.id, display: displayC)
    await store.finish()

    let returned = String(localized: "Returned \(selected.name)")
    let records = Set(hudRequests.value.map { request in
      "\(request.display?.name ?? "nil")|\(request.name)|\(request.subtitle ?? "nil")"
    })
    #expect(hudRequests.value.count == 2)
    #expect(records == [
      "\(displayC.name)|\(selected.name)|\(chain.name!)",
      "\(displayA.name)|\(host.name)|\(chain.name!) · \(returned)",
    ])
    #expect(hudRequests.value.allSatisfy { $0.subtitleSymbolIconName == "link" })
    #expect(store.state.compositionsByDisplay[displayA] == nil)
  }

  @Test
  func `final visible chain host keeps a precomputed borrow return in its HUD`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let hostWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.host")
    let memberWindow = WindowKey(pid: 2, windowID: 201, bundleId: "app.member")
    let host = Workspace(name: "Host", displayHint: displayA)
    let member = Workspace(name: "Member")
    let old = Workspace(name: "Old", displayHint: displayB)
    let chain = WorkspaceChain(
      name: "Linked",
      workspaceIDs: [host.id, member.id],
    )
    let state = Self.makeState(workspaces: [host, member, old]) {
      $0.isTilingPaused = true
      $0.focusedDisplay = displayA
      $0.connectedDisplays = [displayA, displayB]
      $0.activeWorkspacesByDisplay = [displayA: host.id, displayB: old.id]
      $0.tilingTrees = [
        host.id: .leaf(hostWindow),
        member.id: .leaf(memberWindow),
      ]
      $0.compositionsByDisplay[displayA] = Composition(
        host: host.id,
        borrowed: [
          BorrowedSlot(workspace: member.id, edge: .right, fraction: 0.4)
        ],
      )
      $0.$config.withLock { $0.mutateActiveProfile { $0.workspaceChains = [chain] } }
    }
    let activations = LockIsolated<[ActivationRequest]>([])
    let hudRequests = LockIsolated<[ActionHUDRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB] }
      $0.displays.current = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
      $0.focusManager.focusWindow = { _ in }
      $0.workspaceHUD.showAction = { request in
        hudRequests.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: host.id, setFocus: true))
    await Self.receiveActivationCompletion(store, workspaceID: member.id, display: displayB)
    await store.receive(\.processDisplayRestores)
    await store.receive {
      guard case .restoreDisplay(let assignment) = $0 else { return false }
      return assignment.workspace == host.id && assignment.display.matches(displayA)
    }
    await store.finish()

    #expect(activations.value.map(\.workspace.id) == [member.id])
    #expect(store.state.compositionsByDisplay[displayA] == nil)
    let hostHUD = hudRequests.value.first { $0.display == displayA }
    #expect(hostHUD?.name == host.name)
    #expect(
      hostHUD?.subtitle
        == "\(chain.name!) · \(String(localized: "Returned \(member.name)"))"
    )
    #expect(hostHUD?.subtitleExtendsDuration == true)
  }

  @Test
  func `borrow-only chain result omits hidden chain identity`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let browserWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.browser")
    let browser = Workspace(name: "Browser", displayHint: displayB)
    let coding = Workspace(name: "Coding", displayHint: displayA)
    let slack = Workspace(name: "Slack", displayHint: displayA)
    let borrowed = Workspace(name: "Borrowed")
    let chain = WorkspaceChain(
      name: "Test",
      workspaceIDs: [browser.id, coding.id],
    )
    let state = Self.makeState(workspaces: [browser, coding, slack, borrowed]) {
      $0.isTilingPaused = true
      $0.focusedDisplay = displayA
      $0.connectedDisplays = [displayA, displayB]
      $0.activeWorkspacesByDisplay = [displayA: slack.id, displayB: browser.id]
      $0.tilingTrees[browser.id] = .leaf(browserWindow)
      $0.compositionsByDisplay[displayA] = Composition(
        host: slack.id,
        borrowed: [
          BorrowedSlot(workspace: borrowed.id, edge: .right, fraction: 0.4)
        ],
      )
      $0.$config.withLock {
        $0.settings.hud.workspaceSwitch = false
        $0.settings.hud.borrow = true
        $0.mutateActiveProfile { $0.workspaceChains = [chain] }
      }
    }
    let hudRequests = LockIsolated<[ActionHUDRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB] }
      $0.displays.current = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { _ in }
      $0.focusManager.focusWindow = { _ in }
      $0.workspaceHUD.showAction = { request in
        hudRequests.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: browser.id, setFocus: true))
    await Self.receiveActivationCompletion(store, workspaceID: coding.id, display: displayA)
    await store.receive(\.processDisplayRestores)
    await store.receive {
      guard case .restoreDisplay(let assignment) = $0 else { return false }
      return assignment.workspace == browser.id && assignment.display.matches(displayB)
    }
    await store.finish()

    #expect(hudRequests.value.count == 1)
    #expect(hudRequests.value.first?.display == displayA)
    #expect(hudRequests.value.first?.name == coding.name)
    #expect(
      hudRequests.value.first?.subtitle
        == String(localized: "Returned \(borrowed.name)")
    )
    #expect(hudRequests.value.first?.subtitleSymbolIconName == nil)
    #expect(hudRequests.value.first?.subtitleExtendsDuration == true)
  }

  @Test
  func `workspace chain HUD describes destination and vacated displays`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let displayC = DisplayName("C")
    let code = Workspace(name: "Code", displayHint: displayA)
    let slack = Workspace(name: "Slack")
    let old = Workspace(name: "Old", displayHint: displayB)
    let codeWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.code")
    let chain = WorkspaceChain(
      name: "Coding",
      workspaceIDs: [code.id, slack.id],
    )
    let state = Self.makeState(workspaces: [code, slack, old]) {
      $0.isTilingPaused = true
      $0.focusedDisplay = displayC
      $0.connectedDisplays = [displayA, displayB, displayC]
      $0.activeWorkspacesByDisplay = [
        displayA: code.id,
        displayB: old.id,
        displayC: slack.id,
      ]
      $0.tilingTrees[code.id] = .leaf(codeWindow)
      $0.$config.withLock { $0.mutateActiveProfile { $0.workspaceChains = [chain] } }
    }
    let hudRequests = LockIsolated<[ActionHUDRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB, displayC] }
      $0.displays.current = { displayA }
      $0.displays.primary = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { _ in }
      $0.focusManager.focusWindow = { _ in }
      $0.workspaceHUD.showAction = { request in
        hudRequests.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: code.id, setFocus: true))
    await Self.receiveActivationCompletion(store, workspaceID: slack.id, display: displayB)
    await store.receive(\.processDisplayRestores)
    await store.receive {
      guard case .restoreDisplay(let assignment) = $0 else { return false }
      return assignment.workspace == code.id && assignment.display.matches(displayA)
    }
    await store.finish()

    let records = Set(hudRequests.value.map { request in
      "\(request.display?.name ?? "nil")|\(request.name)|\(request.subtitle ?? "nil")"
    })
    #expect(hudRequests.value.count == 3)
    #expect(records == [
      "\(displayA.name)|\(code.name)|Coding",
      "\(displayB.name)|\(slack.name)|Coding",
      "\(displayC.name)|\(String(localized: "Workspace moved"))|"
        + "Coding · \(String(localized: "\(slack.name) is on \(displayB.name)"))",
    ])
    #expect(hudRequests.value.allSatisfy { $0.subtitleSymbolIconName == "link" })
  }

  @Test
  func `workspace-chain trigger promotes a borrowed member instead of focus-transferring`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let host = Workspace(name: "Host", displayHint: displayA)
    let selected = Workspace(name: "Selected", displayHint: displayA)
    let peer = Workspace(name: "Peer", displayHint: displayB)
    let selectedWindow = WindowKey(pid: 2, windowID: 201, bundleId: "app.selected")
    let composition = Composition(
      host: host.id,
      borrowed: [BorrowedSlot(workspace: selected.id, edge: .right, fraction: 0.4)],
    )
    let chain = WorkspaceChain(workspaceIDs: [selected.id, peer.id])
    let state = Self.makeState(workspaces: [host, selected, peer]) {
      $0.isTilingPaused = true
      $0.focusedDisplay = displayB
      $0.connectedDisplays = [displayA, displayB]
      $0.activeWorkspacesByDisplay = [displayA: host.id, displayB: peer.id]
      $0.tilingTrees[selected.id] = .leaf(selectedWindow)
      $0.compositionsByDisplay[displayA] = composition
      $0.$config.withLock { $0.mutateActiveProfile { $0.workspaceChains = [chain] } }
    }
    let activations = LockIsolated<[ActivationRequest]>([])
    let focused = LockIsolated<[WindowKey]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB] }
      $0.displays.current = { displayA }
      $0.displays.primary = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
      $0.focusManager.focusWindow = { key in
        focused.withValue { $0.append(key) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: selected.id, setFocus: true))
    await Self.receiveActivationCompletion(store, workspaceID: selected.id, display: displayA)
    await store.finish()

    #expect(activations.value.map(\.workspace.id) == [selected.id])
    #expect(activations.value.map(\.targetDisplay) == [displayA])
    #expect(focused.value.isEmpty)
    #expect(store.state.compositionsByDisplay[displayA] == nil)
    #expect(store.state.activeWorkspacesByDisplay == [displayA: selected.id, displayB: peer.id])
  }

  @Test
  func `workspace-chain duplicate pin skips the lower priority peer and continues`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let code = Workspace(name: "Code", displayHint: displayA)
    let slack = Workspace(name: "Slack", displayHint: displayA)
    let terminal = Workspace(name: "Terminal")
    let old = Workspace(name: "Old", displayHint: displayB)
    let chain = WorkspaceChain(workspaceIDs: [code.id, slack.id, terminal.id])
    let state = Self.makeState(workspaces: [code, slack, terminal, old]) {
      $0.isTilingPaused = true
      $0.focusedDisplay = displayB
      $0.activeWorkspacesByDisplay = [displayB: old.id]
      $0.$config.withLock { $0.mutateActiveProfile { $0.workspaceChains = [chain] } }
    }
    let activations = LockIsolated<[ActivationRequest]>([])
    let hudRequests = LockIsolated<[ActionHUDRequest]>([])
    let logs = LockIsolated<[(String, String)]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB] }
      $0.displays.current = { displayA }
      $0.displays.primary = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
      $0.workspaceHUD.showAction = { request in
        hudRequests.withValue { $0.append(request) }
      }
      $0.debugLog.log = { category, message in
        logs.withValue { $0.append((category, message)) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: code.id, setFocus: true))
    await Self.receiveActivationCompletion(
      store,
      workspaceID: terminal.id,
      display: displayB,
    )
    await store.receive(\.processDisplayRestores)
    await store.receive {
      guard case .restoreDisplay(let assignment) = $0 else { return false }
      return assignment.workspace == code.id && assignment.display.matches(displayA)
    }
    await Self.receiveActivationCompletion(store, workspaceID: code.id, display: displayA)
    await store.finish()

    #expect(activations.value.map(\.workspace.id) == [terminal.id, code.id])
    #expect(activations.value.map(\.setFocus) == [false, true])
    #expect(store.state.activeWorkspacesByDisplay == [displayA: code.id, displayB: terminal.id])
    #expect(hudRequests.value.count == 2)
    #expect(hudRequests.value.map(\.name) == [terminal.name, code.name])
    #expect(hudRequests.value.allSatisfy { $0.subtitleSymbolIconName == "link" })
    #expect(logs.value.contains { category, message in
      category == "WorkspaceChain"
        && message.contains("plan=")
        && message.contains(terminal.id.uuidString)
        && !message.contains(slack.id.uuidString)
    })
  }

  @Test
  func `three-member workspace chain uses stored priority on two displays`() async {
    let displayA = DisplayName(uuid: "display-a", name: "A")
    let displayB = DisplayName(uuid: "display-b", name: "B")
    let browser = Workspace(name: "Browser")
    let coding = Workspace(name: "Coding")
    let terminal = Workspace(name: "Terminal")
    let old = Workspace(name: "Old", displayHint: displayB)
    let chain = WorkspaceChain(
      name: "Three Up",
      workspaceIDs: [browser.id, coding.id, terminal.id],
    )
    let state = Self.makeState(workspaces: [browser, coding, terminal, old]) {
      $0.isTilingPaused = true
      $0.focusedDisplay = displayB
      $0.activeWorkspacesByDisplay = [displayB: old.id]
      $0.$config.withLock { $0.mutateActiveProfile { $0.workspaceChains = [chain] } }
    }
    let activations = LockIsolated<[ActivationRequest]>([])
    let hudRequests = LockIsolated<[ActionHUDRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB] }
      $0.displays.current = { displayA }
      $0.displays.primary = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
      $0.workspaceHUD.showAction = { request in
        hudRequests.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: browser.id, setFocus: true))
    await Self.receiveActivationCompletion(store, workspaceID: coding.id, display: displayB)
    await store.receive(\.processDisplayRestores)
    await store.receive {
      guard case .restoreDisplay(let assignment) = $0 else { return false }
      return assignment.workspace == browser.id && assignment.display.matches(displayA)
    }
    await Self.receiveActivationCompletion(store, workspaceID: browser.id, display: displayA)
    await store.finish()

    #expect(activations.value.map(\.workspace.id) == [coding.id, browser.id])
    #expect(activations.value.map(\.targetDisplay) == [displayB, displayA])
    #expect(activations.value.map(\.setFocus) == [false, true])
    #expect(store.state.activeWorkspacesByDisplay == [displayA: browser.id, displayB: coding.id])
    #expect(hudRequests.value.count == 2)
    #expect(hudRequests.value.map(\.name) == [coding.name, browser.name])
    #expect(hudRequests.value.allSatisfy { $0.subtitleSymbolIconName == "link" })
    #expect(!activations.value.contains { $0.workspace.id == terminal.id })
  }

  @Test
  func `partial workspace chain obeys workspace switch HUD setting`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let code = Workspace(name: "Code", displayHint: displayA)
    let slack = Workspace(name: "Slack", displayHint: displayA)
    let old = Workspace(name: "Old", displayHint: displayB)
    let chain = WorkspaceChain(workspaceIDs: [code.id, slack.id])
    let state = Self.makeState(workspaces: [code, slack, old]) {
      $0.isTilingPaused = true
      $0.focusedDisplay = displayB
      $0.activeWorkspacesByDisplay = [displayB: old.id]
      $0.$config.withLock { $0.mutateActiveProfile { $0.workspaceChains = [chain] } }
    }
    state.$config.withLock { $0.settings.hud.workspaceSwitch = false }
    let activations = LockIsolated<[ActivationRequest]>([])
    let hudRequests = LockIsolated<[ActionHUDRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB] }
      $0.displays.current = { displayA }
      $0.displays.primary = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
      $0.workspaceHUD.showAction = { request in
        hudRequests.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: code.id, setFocus: true))
    await Self.receiveActivationCompletion(store, workspaceID: code.id, display: displayA)
    await store.finish()

    #expect(activations.value.map(\.workspace.id) == [code.id])
    #expect(hudRequests.value.isEmpty)
  }

  @Test
  func `priority-skipped active host is hidden when its display has no fallback`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let displayC = DisplayName("C")
    let first = Workspace(
      name: "First",
      displayHint: displayA,
      apps: [AppAssignment(bundleIdentifier: "app.first", name: "First")],
    )
    let skipped = Workspace(
      name: "Skipped",
      displayHint: displayA,
      apps: [AppAssignment(bundleIdentifier: "app.skipped", name: "Skipped")],
    )
    let dynamic = Workspace(
      name: "Dynamic",
      apps: [AppAssignment(bundleIdentifier: "app.dynamic", name: "Dynamic")],
    )
    let chain = WorkspaceChain(
      name: "Priority",
      workspaceIDs: [first.id, skipped.id, dynamic.id],
    )
    let state = Self.makeState(workspaces: [first, skipped, dynamic]) {
      $0.isTilingPaused = true
      $0.connectedDisplays = [displayA, displayB, displayC]
      $0.activeWorkspacesByDisplay = [displayC: skipped.id]
      $0.$config.withLock { $0.mutateActiveProfile { $0.workspaceChains = [chain] } }
    }
    let activations = LockIsolated<[ActivationRequest]>([])
    let returns = LockIsolated<[(Set<String>, DisplayName)]>([])
    let hudRequests = LockIsolated<[ActionHUDRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB, displayC] }
      $0.displays.current = { displayA }
      $0.displays.primary = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
      $0.workspaceManager.returnBorrowed = { bundleIDs, display in
        returns.withValue { $0.append((bundleIDs, display)) }
        return true
      }
      $0.workspaceHUD.showAction = { request in
        hudRequests.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: first.id, setFocus: true))
    await Self.receiveActivationCompletion(store, workspaceID: dynamic.id, display: displayB)
    await store.receive(\.processDisplayRestores)
    await store.receive {
      guard case .restoreDisplay(let assignment) = $0 else { return false }
      return assignment.workspace == first.id && assignment.display.matches(displayA)
    }
    await Self.receiveActivationCompletion(store, workspaceID: first.id, display: displayA)
    await store.finish()

    #expect(activations.value.map(\.workspace.id) == [dynamic.id, first.id])
    #expect(!store.state.activeWorkspacesByDisplay.values.contains(skipped.id))
    #expect(returns.value.count == 1)
    #expect(returns.value.first?.0 == ["app.skipped"])
    #expect(returns.value.first?.1 == displayC)
    #expect(hudRequests.value.contains { request in
      request.display == displayC
        && request.name == skipped.name
        && request.subtitle
        == "\(chain.name!) · "
        + String(localized: "Skipped by chain priority: \(skipped.name)")
        && request.subtitleSymbolIconName == "link"
    })
  }

  @Test
  func `priority-skipped borrowed member returns without dropping the remaining composition`() async {
    let display = DisplayName("A")
    let hostWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.host")
    let skippedWindow = WindowKey(pid: 2, windowID: 201, bundleId: "app.skipped")
    let remainingWindow = WindowKey(pid: 3, windowID: 301, bundleId: "app.retained")
    let host = Workspace(
      name: "Host",
      displayHint: display,
      apps: [AppAssignment(bundleIdentifier: hostWindow.bundleId, name: "Host")],
    )
    let skipped = Workspace(
      name: "Skipped",
      displayHint: display,
      apps: [
        AppAssignment(bundleIdentifier: skippedWindow.bundleId, name: "Skipped"),
        AppAssignment(bundleIdentifier: remainingWindow.bundleId, name: "Overlap"),
      ],
    )
    let remaining = Workspace(
      name: "Remaining",
      apps: [AppAssignment(bundleIdentifier: remainingWindow.bundleId, name: "Remaining")],
    )
    let chain = WorkspaceChain(
      name: "Priority",
      workspaceIDs: [host.id, skipped.id],
    )
    let remainingSlot = BorrowedSlot(workspace: remaining.id, edge: .right)
    let state = Self.makeState(workspaces: [host, skipped, remaining]) {
      $0.isTilingPaused = true
      $0.connectedDisplays = [display]
      $0.activeWorkspacesByDisplay = [display: host.id]
      $0.tilingTrees = [
        host.id: .leaf(hostWindow),
        skipped.id: .leaf(skippedWindow),
        remaining.id: .leaf(remainingWindow),
      ]
      $0.mruWindows[host.id] = [hostWindow]
      $0.compositionsByDisplay[display] = Composition(
        host: host.id,
        borrowed: [
          BorrowedSlot(workspace: skipped.id, edge: .left),
          remainingSlot,
        ],
      )
      $0.$config.withLock { $0.mutateActiveProfile { $0.workspaceChains = [chain] } }
    }
    let activations = LockIsolated<[ActivationRequest]>([])
    let returns = LockIsolated<[Set<String>]>([])
    let appliedKeys = LockIsolated<[Set<WindowKey>]>([])
    let hudRequests = LockIsolated<[ActionHUDRequest]>([])
    let logs = LockIsolated<[String]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [display] }
      $0.displays.current = { display }
      $0.displays.primary = { display }
      $0.displays.workArea = { _ in CGRect(x: 0, y: 0, width: 1200, height: 800) }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
      $0.workspaceManager.returnBorrowed = { bundleIDs, _ in
        returns.withValue { $0.append(bundleIDs) }
        return true
      }
      $0.windowTiler.apply = { application in
        appliedKeys.withValue { $0.append(Set(application.windowFrames.keys)) }
      }
      $0.workspaceHUD.showAction = { request in
        hudRequests.withValue { $0.append(request) }
      }
      $0.debugLog.log = { category, message in
        logs.withValue { $0.append("\(category):\(message)") }
      }
      $0.focusManager.focusWindow = { _ in }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: host.id, setFocus: true))
    await store.receive {
      guard
        case .commitWorkspaceChainCleanup(let transaction, let cleanupDisplay, _) = $0
      else { return false }
      return transaction.skippedWorkspaceIDs == [skipped.id]
        && cleanupDisplay.matches(display)
    }
    await store.finish()

    #expect(activations.value.isEmpty)
    #expect(
      store.state.compositionsByDisplay[display]
        == Composition(host: host.id, borrowed: [remainingSlot])
    )
    #expect(returns.value == [[skippedWindow.bundleId]])
    #expect(appliedKeys.value.contains([hostWindow, remainingWindow]))
    #expect(logs.value.contains { $0.contains("commit priority cleanup") })
    #expect(hudRequests.value.count == 1)
    #expect(hudRequests.value.first.map { request in
      request.display == display
        && request.name == host.name
        && request.subtitle == "\(chain.name!) · \(String(localized: "Returned \(skipped.name)"))"
        && request.subtitleSymbolIconName == "link"
    } == true)
  }

  @Test
  func `app-focus workspace chain keeps the originating dynamic display and never refocuses`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let displayC = DisplayName("C")
    let code = Workspace(name: "Code", displayHint: displayA)
    let skipped = Workspace(
      name: "Skipped",
      displayHint: displayA,
      apps: [AppAssignment(bundleIdentifier: "app.skipped", name: "Skipped")],
    )
    let slack = Workspace(name: "Slack")
    let old = Workspace(name: "Old", displayHint: displayA)
    let slackWindow = WindowKey(pid: 2, windowID: 201, bundleId: "app.slack")
    let chain = WorkspaceChain(workspaceIDs: [code.id, skipped.id, slack.id])
    let state = Self.makeState(workspaces: [code, skipped, slack, old]) {
      $0.isTilingPaused = true
      $0.focusedDisplay = displayB
      $0.connectedDisplays = [displayA, displayB, displayC]
      $0.activeWorkspacesByDisplay = [
        displayA: old.id,
        displayB: slack.id,
        displayC: skipped.id,
      ]
      $0.tilingTrees[slack.id] = .leaf(slackWindow)
      $0.$config.withLock { $0.mutateActiveProfile { $0.workspaceChains = [chain] } }
    }
    let activations = LockIsolated<[ActivationRequest]>([])
    let focused = LockIsolated<[WindowKey]>([])
    let returns = LockIsolated<[(Set<String>, DisplayName)]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB, displayC] }
      // The pointer may already have moved, while the system-focused Slack
      // window still authoritatively belongs to display B.
      $0.displays.current = { displayA }
      $0.displays.primary = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
      $0.workspaceManager.returnBorrowed = { bundleIDs, display in
        returns.withValue { $0.append((bundleIDs, display)) }
        return true
      }
      $0.focusManager.focusWindow = { key in
        focused.withValue { $0.append(key) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activateFollowingAppFocus(workspaceId: slack.id))
    await Self.receiveActivationCompletion(store, workspaceID: code.id, display: displayA)
    await Self.receiveActivationCompletion(store, workspaceID: slack.id, display: displayB)
    await store.finish()

    #expect(activations.value.map(\.workspace.id) == [code.id, slack.id])
    #expect(activations.value.allSatisfy { !$0.setFocus })
    #expect(focused.value.isEmpty)
    #expect(store.state.focusedDisplay == displayB)
    #expect(store.state.activeWorkspacesByDisplay == [displayA: code.id, displayB: slack.id])
    #expect(returns.value.count == 1)
    #expect(returns.value.first?.0 == ["app.skipped"])
    #expect(returns.value.first?.1 == displayC)
  }

  @Test
  func `app focus freezes its pointer display before child activation`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let oldWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.old")
    let slackWindow = WindowKey(pid: 2, windowID: 201, bundleId: "app.slack")
    let old = Workspace(
      name: "Old",
      apps: [AppAssignment(bundleIdentifier: oldWindow.bundleId, name: "Old")],
    )
    let slack = Workspace(
      name: "Slack",
      apps: [AppAssignment(bundleIdentifier: slackWindow.bundleId, name: "Slack")],
    )
    let state = Self.makeState(workspaces: [old, slack]) {
      $0.$config.withLock { $0.settings.switching.followAppFocus = true }
      $0.isTilingPaused = true
      $0.focusedDisplay = displayB
      $0.activeWorkspacesByDisplay[displayB] = old.id
      $0.tilingTrees[old.id] = .leaf(oldWindow)
    }
    let pointerDisplay = LockIsolated(displayA)
    let activations = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB] }
      $0.displays.current = { pointerDisplay.value }
      $0.continuousClock = TestClock()
      $0.windowSnapshot.frontmostApp = {
        FrontmostApp(
          pid: slackWindow.pid,
          bundleId: slackWindow.bundleId,
          name: slack.name,
        )
      }
      $0.windowSnapshot.focusedWindowKey = { nil }
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.appActivated(
      bundleId: slackWindow.bundleId,
      pid: slackWindow.pid,
    ))
    pointerDisplay.setValue(displayB)
    await store.receive {
      guard
        case .activateFollowingAppFocus(let workspaceID, let interactionDisplay) = $0
      else { return false }
      return workspaceID == slack.id && interactionDisplay == displayA
    }
    await Self.receiveActivationCompletion(store, workspaceID: slack.id, display: displayA)
    await store.finish()

    #expect(activations.value.map(\.targetDisplay) == [displayA])
  }

  @Test
  func `inactive dynamic app-focus chain follows pointer before stale focused display`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let displayC = DisplayName("C")
    let old = Workspace(name: "Old", displayHint: displayA)
    let code = Workspace(name: "Code", displayHint: displayC)
    let slack = Workspace(name: "Slack")
    let chain = WorkspaceChain(workspaceIDs: [code.id, slack.id])
    let state = Self.makeState(workspaces: [old, code, slack]) {
      $0.isTilingPaused = true
      // Stale keyboard focus still says A, but the app-focus interaction is
      // happening under the pointer on B and Slack is not currently visible.
      $0.focusedDisplay = displayA
      $0.connectedDisplays = [displayA, displayB, displayC]
      $0.activeWorkspacesByDisplay = [displayA: old.id]
      $0.$config.withLock { $0.mutateActiveProfile { $0.workspaceChains = [chain] } }
    }
    let activations = LockIsolated<[ActivationRequest]>([])
    let hudRequests = LockIsolated<[ActionHUDRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB, displayC] }
      $0.displays.current = { displayB }
      $0.displays.primary = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
      $0.workspaceHUD.showAction = { request in
        hudRequests.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activateFollowingAppFocus(workspaceId: slack.id))
    await Self.receiveActivationCompletion(store, workspaceID: code.id, display: displayC)
    await Self.receiveActivationCompletion(store, workspaceID: slack.id, display: displayB)
    await store.finish()

    #expect(activations.value.map(\.workspace.id) == [code.id, slack.id])
    #expect(activations.value.map(\.targetDisplay) == [displayC, displayB])
    #expect(activations.value.allSatisfy { !$0.setFocus })
    #expect(store.state.activeWorkspacesByDisplay == [
      displayA: old.id,
      displayB: slack.id,
      displayC: code.id,
    ])
    #expect(hudRequests.value.count == 2)
    #expect(!hudRequests.value.contains {
      $0.name == String(localized: "Focus moved")
    })
  }

  @Test
  func `inactive standalone dynamic app-focus follows pointer before stale focused display`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let slack = Workspace(name: "Slack")
    let state = Self.makeState(workspaces: [slack]) {
      $0.isTilingPaused = true
      $0.focusedDisplay = displayA
    }
    let activations = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB] }
      $0.displays.current = { displayB }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activateFollowingAppFocus(workspaceId: slack.id))
    await Self.receiveActivationCompletion(store, workspaceID: slack.id, display: displayB)
    await store.finish()

    #expect(activations.value.map(\.workspace.id) == [slack.id])
    #expect(activations.value.map(\.targetDisplay) == [displayB])
    #expect(activations.value.allSatisfy { !$0.setFocus })
    #expect(store.state.activeWorkspacesByDisplay == [displayB: slack.id])
  }

  @Test
  func `activating a visible dynamic workspace pulls it to the pointer display`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let browser = Workspace(name: "Browser")
    let terminal = Workspace(name: "Terminal")
    let browserWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.browser")
    let terminalWindow = WindowKey(pid: 2, windowID: 201, bundleId: "app.terminal")
    let state = Self.makeState(workspaces: [browser, terminal]) {
      $0.isTilingPaused = true
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [
        displayA: terminal.id,
        displayB: browser.id,
      ]
      $0.tilingTrees = [
        browser.id: .leaf(browserWindow),
        terminal.id: .leaf(terminalWindow),
      ]
    }
    let activations = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB] }
      $0.displays.current = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: browser.id, setFocus: true))
    await store.receive {
      guard case .activationCompleted(let workspaceId, let display, _) = $0 else { return false }
      return workspaceId == browser.id && display == displayA
    }
    await store.finish()

    // Already visible on B, but dynamic and the pointer is on A: it moves.
    // Shortcutting to a focus transfer here is what pinned dynamic
    // workspaces to whichever monitor they last landed on.
    #expect(activations.value.count == 1)
    #expect(activations.value.first?.workspace.id == browser.id)
    #expect(activations.value.first?.targetDisplay == displayA)
    #expect(store.state.focusedDisplay == displayA)
    #expect(store.state.activeWorkspacesByDisplay[displayA] == browser.id)
    #expect(store.state.activeWorkspacesByDisplay[displayB] == nil)
  }

  @Test
  func `activating a visible dynamic workspace under the pointer stays a focus transfer`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let browser = Workspace(name: "Browser")
    let terminal = Workspace(name: "Terminal")
    let figma = Workspace(name: "Figma")
    let browserWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.browser")
    let terminalWindow = WindowKey(pid: 2, windowID: 201, bundleId: "app.terminal")
    let figmaWindow = WindowKey(pid: 3, windowID: 301, bundleId: "app.figma")
    let composition = Composition(
      host: browser.id,
      borrowed: [
        BorrowedSlot(workspace: figma.id, edge: .right, fraction: 0.4)
      ],
    )
    let state = Self.makeState(workspaces: [browser, terminal, figma]) {
      $0.focusedDisplay = displayB
      $0.activeWorkspacesByDisplay = [
        displayA: browser.id,
        displayB: terminal.id,
      ]
      $0.tilingTrees = [
        browser.id: .leaf(browserWindow),
        terminal.id: .leaf(terminalWindow),
        figma.id: .leaf(figmaWindow),
      ]
      $0.compositionsByDisplay[displayA] = composition
    }
    let activations = LockIsolated<[ActivationRequest]>([])
    let focused = LockIsolated<[WindowKey]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB] }
      $0.displays.current = { displayA }
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
      $0.focusManager.focusWindow = { key in
        focused.withValue { $0.append(key) }
      }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: browser.id, setFocus: true))
    await store.finish()

    // The pointer is already on the host's display, so activation would not
    // move it — the Borrow composition must survive the switch.
    #expect(activations.value.isEmpty)
    #expect(focused.value == [browserWindow])
    #expect(store.state.focusedDisplay == displayA)
    #expect(store.state.compositionsByDisplay[displayA] == composition)
  }

  @Test
  func `a workspace pinned to a missing display activates onto the only one`() async {
    let only = DisplayName("Laptop")
    let gone = DisplayName("Studio Display")
    let homeless = Workspace(name: "Slack", displayHint: gone)
    let other = Workspace(name: "Terminal", displayHint: only)
    let state = Self.makeState(workspaces: [homeless, other]) {
      $0.isTilingPaused = true
      $0.focusedDisplay = only
      $0.activeWorkspacesByDisplay = [only: other.id]
    }
    let activations = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [only] }
      $0.displays.current = { only }
      // The pinned display is not connected.
      $0.displays.connected = { $0.matches(only) ? only : nil }
      $0.displays.primary = { only }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: homeless.id, setFocus: true))
    await store.receive {
      guard case .activationCompleted(let workspaceId, let display, _) = $0 else { return false }
      return workspaceId == homeless.id && display == only
    }
    await store.finish()

    // One monitor: every workspace has to be reachable on it, pinned to a
    // display that isn't plugged in or not. The vacated-display rules never
    // apply here — nothing can be vacated when there is only one display.
    #expect(activations.value.count == 1)
    #expect(activations.value.first?.targetDisplay == only)
    #expect(store.state.activeWorkspacesByDisplay[only] == homeless.id)
  }

  @Test
  func `pulling a composition host to another display returns the borrowed block`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let browser = Workspace(
      name: "Browser",
      apps: [AppAssignment(bundleIdentifier: "app.browser", name: "Browser")],
    )
    let figma = Workspace(
      name: "Figma",
      apps: [AppAssignment(bundleIdentifier: "app.figma", name: "Figma")],
    )
    let browserWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.browser")
    let figmaWindow = WindowKey(pid: 3, windowID: 301, bundleId: "app.figma")
    let composition = Composition(
      host: browser.id,
      borrowed: [BorrowedSlot(workspace: figma.id, edge: .right, fraction: 0.4)],
    )
    let state = Self.makeState(workspaces: [browser, figma]) {
      $0.isTilingPaused = true
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [displayB: browser.id]
      $0.tilingTrees = [browser.id: .leaf(browserWindow), figma.id: .leaf(figmaWindow)]
      $0.compositionsByDisplay[displayB] = composition
    }
    let returned = LockIsolated<[(Set<String>, DisplayName)]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB] }
      $0.displays.current = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { _ in }
      $0.workspaceManager.returnBorrowed = { bundleIds, display in
        returned.withValue { $0.append((bundleIds, display)) }
        return true
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    // Browser is dynamic and the pointer is on A, so it leaves B.
    await store.send(.activate(workspaceId: browser.id, setFocus: true))
    await store.receive {
      guard case .activationCompleted(let workspaceId, let display, _) = $0 else { return false }
      return workspaceId == browser.id && display == displayA
    }
    await store.receive {
      guard case .processWorkspaceChainCleanupStep(_, let cleanup, _) = $0 else { return false }
      return cleanup.display.matches(displayB) && cleanup.bundleIDs == ["app.figma"]
    }
    await store.receive {
      guard case .commitWorkspaceChainCleanup(_, let display, _) = $0 else { return false }
      return display.matches(displayB)
    }
    await store.finish()

    #expect(returned.value.count == 1)
    #expect(returned.value.first?.0 == ["app.figma"])
    #expect(returned.value.first?.1 == displayB)
    #expect(store.state.compositionsByDisplay[displayB] == nil)
  }

  @Test
  func `returning a borrow leaves unregistered apps alone`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let browser = Workspace(
      name: "Browser",
      apps: [AppAssignment(bundleIdentifier: "app.browser", name: "Browser")],
    )
    // Registered in no workspace: a floating utility the user parked next to
    // the borrow. It must survive the return.
    let figma = Workspace(name: "Figma")
    let browserWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.browser")
    let strayWindow = WindowKey(pid: 9, windowID: 901, bundleId: "app.stray")
    let composition = Composition(
      host: browser.id,
      borrowed: [BorrowedSlot(workspace: figma.id, edge: .right, fraction: 0.4)],
    )
    let state = Self.makeState(workspaces: [browser, figma]) {
      $0.isTilingPaused = true
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [displayB: browser.id]
      $0.tilingTrees = [browser.id: .leaf(browserWindow), figma.id: .leaf(strayWindow)]
      $0.compositionsByDisplay[displayB] = composition
    }
    let returned = LockIsolated<[(Set<String>, DisplayName)]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB] }
      $0.displays.current = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { _ in }
      $0.workspaceManager.returnBorrowed = { bundleIds, display in
        returned.withValue { $0.append((bundleIds, display)) }
        return true
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: browser.id, setFocus: true))
    await store.finish()

    // Nothing managed to return → no hide call at all.
    #expect(returned.value.isEmpty)
  }

  @Test
  func `a display focus transfer returns nothing and keeps its composition`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let browser = Workspace(
      name: "Browser",
      apps: [AppAssignment(bundleIdentifier: "app.browser", name: "Browser")],
    )
    let figma = Workspace(
      name: "Figma",
      apps: [AppAssignment(bundleIdentifier: "app.figma", name: "Figma")],
    )
    let browserWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.browser")
    let figmaWindow = WindowKey(pid: 3, windowID: 301, bundleId: "app.figma")
    let composition = Composition(
      host: browser.id,
      borrowed: [BorrowedSlot(workspace: figma.id, edge: .right, fraction: 0.4)],
    )
    let state = Self.makeState(workspaces: [browser, figma]) {
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [displayB: browser.id]
      $0.tilingTrees = [browser.id: .leaf(browserWindow), figma.id: .leaf(figmaWindow)]
      $0.compositionsByDisplay[displayB] = composition
    }
    let returned = LockIsolated<[(Set<String>, DisplayName)]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB] }
      // Pointer already on the host's display → activation would not move it.
      $0.displays.current = { displayB }
      $0.workspaceManager.activate = { _ in }
      $0.workspaceManager.returnBorrowed = { bundleIds, display in
        returned.withValue { $0.append((bundleIds, display)) }
        return true
      }
      $0.focusManager.focusWindow = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: browser.id, setFocus: true))
    await store.finish()

    // b6f8ec2's contract: a focus transfer preserves the Borrow composition.
    #expect(returned.value.isEmpty)
    #expect(store.state.compositionsByDisplay[displayB] == composition)
  }

  @Test
  func `an app focus jump warps to the window the system actually raised`() async {
    let display = Self.display
    let first = WindowKey(pid: 7, windowID: 701, bundleId: "com.mitchellh.ghostty")
    let second = WindowKey(pid: 7, windowID: 702, bundleId: first.bundleId)
    let terminal = Workspace(
      name: "Terminal",
      apps: [AppAssignment(bundleIdentifier: first.bundleId, name: "Ghostty")],
    )
    let workArea = await MainActor.run { ScreenGeometry.workArea(for: display) }
    let tree = BSPNode.branch(
      BSPBranch(split: .vertical, ratio: 0.5, left: .leaf(first), right: .leaf(second))
    )
    let frames = tree.frames(in: workArea, gap: 0)
    let state = Self.makeState(workspaces: [terminal]) {
      $0.$config.withLock {
        $0.settings.focus.mouseFollowsFocus = true
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
      }
      $0.focusedDisplay = display
      $0.tilingTrees[terminal.id] = tree
      // The workspace last used `first`, but the user just clicked the app in
      // the Dock and the system raised `second`.
      $0.mruWindows[terminal.id] = [first, second]
    }
    let warps = LockIsolated<[CGPoint]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [display] }
      $0.displays.current = { display }
      $0.displays.workArea = { _ in workArea }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { _ in }
      $0.windowTiler.apply = { _ in }
      $0.windowSnapshot.cachedKeysAsync = { _, _ in .value([first, second]) }
      $0.windowSnapshot.onScreenWindowFrames = {
        Dictionary(uniqueKeysWithValues: frames.map { ($0.key.windowID, $0.value) })
      }
      $0.windowSnapshot.focusedWindowKeyAsync = { .value(second) }
      $0.windowSnapshot.focusedWindowKey = { second }
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
      $0.windowObserver.observe = { _ in }
      $0.profileSessionStore.saveWorkspaceState = { _, _ in }
      $0.sls.isActiveSpaceFullscreen = { false }
      $0.focusManager.focusWindow = { _ in }
      $0.mouse.warp = { point in warps.withValue { $0.append(point) } }
    }
    store.exhaustivity = .off

    await store.send(.activateFollowingAppFocus(workspaceId: terminal.id))
    await store.finish()

    // Follows the raised window, not the workspace's MRU pick — otherwise a
    // multi-window app gives no clue which window took focus.
    let target = frames[second]
    #expect(target != nil)
    #expect(warps.value == [CGPoint(x: target?.midX ?? 0, y: target?.midY ?? 0)])
  }

  @Test
  func `activating a visible workspace with no window still activates it`() async {
    let displayA = DisplayName("A")
    let browser = Workspace(name: "Browser", displayHint: displayA)
    let state = Self.makeState(workspaces: [browser]) {
      $0.isTilingPaused = true
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [displayA: browser.id]
    }
    let activations = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA] }
      $0.displays.current = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: browser.id, setFocus: true))
    await store.receive {
      guard case .activationCompleted(let workspaceId, let display, _) = $0 else { return false }
      return workspaceId == browser.id && display == displayA
    }
    await store.finish()

    // A focus transfer has no window to hand focus to here, so it would
    // swallow the switch whole — no app activation, no hide pass, no HUD.
    #expect(activations.value.count == 1)
    #expect(activations.value.first?.workspace.id == browser.id)
  }

  @Test
  func `global recent focuses the workspace on its existing display`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let wsA = Workspace(name: "A")
    let wsB = Workspace(name: "B")
    let windowB = WindowKey(pid: 2, windowID: 201, bundleId: "app.b")
    let state = Self.makeState(workspaces: [wsA, wsB]) {
      $0.$config.withLock { $0.settings.switching.recentAcrossDisplays = true }
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [displayA: wsA.id, displayB: wsB.id]
      $0.workspaceMRU = [wsA.id, UUID(), wsB.id]
      $0.tilingTrees[wsB.id] = .leaf(windowB)
    }
    let requests = LockIsolated<[ActivationRequest]>([])
    let focused = LockIsolated<[WindowKey]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.current = { displayA }
      $0.workspaceManager.activate = { request in
        requests.withValue { $0.append(request) }
      }
      $0.focusManager.focusWindow = { key in
        focused.withValue { $0.append(key) }
      }
    }
    store.exhaustivity = .off

    await store.send(.activateRecent())
    await store.finish()

    #expect(requests.value.isEmpty)
    #expect(focused.value == [windowB])
    #expect(store.state.focusedDisplay == displayB)
    #expect(store.state.activeWorkspacesByDisplay[displayA] == wsA.id)
    #expect(store.state.activeWorkspacesByDisplay[displayB] == wsB.id)
  }

  @Test
  func `global recent restores a visible workspace-chain member's stale peer`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let code = Workspace(name: "Code", displayHint: displayA)
    let slack = Workspace(name: "Slack", displayHint: displayB)
    let old = Workspace(name: "Old", displayHint: displayB)
    let codeWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.code")
    let chain = WorkspaceChain(workspaceIDs: [code.id, slack.id])
    let state = Self.makeState(workspaces: [code, slack, old]) {
      $0.$config.withLock {
        $0.settings.switching.recentAcrossDisplays = true
        $0.mutateActiveProfile { $0.workspaceChains = [chain] }
      }
      $0.isTilingPaused = true
      $0.focusedDisplay = displayB
      $0.connectedDisplays = [displayA, displayB]
      $0.activeWorkspacesByDisplay = [displayA: code.id, displayB: old.id]
      $0.workspaceMRU = [old.id, code.id, slack.id]
      $0.tilingTrees[code.id] = .leaf(codeWindow)
    }
    let activations = LockIsolated<[ActivationRequest]>([])
    let focused = LockIsolated<[WindowKey]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB] }
      $0.displays.current = { displayB }
      $0.displays.primary = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
      $0.focusManager.focusWindow = { key in
        focused.withValue { $0.append(key) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activateRecent())
    await Self.receiveActivationCompletion(store, workspaceID: slack.id, display: displayB)
    await store.receive(\.processDisplayRestores)
    await store.receive {
      guard case .restoreDisplay(let assignment) = $0 else { return false }
      return assignment.workspace == code.id && assignment.display.matches(displayA)
    }
    await store.finish()

    #expect(activations.value.map(\.workspace.id) == [slack.id])
    #expect(activations.value.allSatisfy { !$0.setFocus })
    #expect(focused.value == [codeWindow])
    #expect(store.state.focusedDisplay == displayA)
    #expect(store.state.activeWorkspacesByDisplay == [displayA: code.id, displayB: slack.id])
  }

  @Test
  func `global recent moves a visible pinned chain target back to its hint`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let code = Workspace(name: "Code", displayHint: displayB)
    let slack = Workspace(name: "Slack", displayHint: displayA)
    let old = Workspace(name: "Old", displayHint: displayB)
    let chain = WorkspaceChain(workspaceIDs: [code.id, slack.id])
    let state = Self.makeState(workspaces: [code, slack, old]) {
      $0.$config.withLock {
        $0.settings.switching.recentAcrossDisplays = true
        $0.mutateActiveProfile { $0.workspaceChains = [chain] }
      }
      $0.isTilingPaused = true
      $0.focusedDisplay = displayB
      $0.connectedDisplays = [displayA, displayB]
      // Simulate changing Code's pin while it is still visible on A.
      $0.activeWorkspacesByDisplay = [displayA: code.id, displayB: old.id]
      $0.workspaceMRU = [old.id, code.id, slack.id]
    }
    let activations = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB] }
      // Global recent still excludes the workspace on the pointer display;
      // Code is the preceding visible workspace from Old on B.
      $0.displays.current = { displayB }
      $0.displays.connected = { reference in
        [displayA, displayB].first { reference.matches($0) }
      }
      $0.displays.primary = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activateRecent())
    await Self.receiveActivationCompletion(store, workspaceID: slack.id, display: displayA)
    await store.receive(\.processDisplayRestores)
    await store.receive {
      guard case .restoreDisplay(let assignment) = $0 else { return false }
      return assignment.workspace == code.id && assignment.display.matches(displayB)
    }
    await Self.receiveActivationCompletion(store, workspaceID: code.id, display: displayB)
    await store.finish()

    #expect(activations.value.map(\.workspace.id) == [slack.id, code.id])
    #expect(activations.value.map(\.targetDisplay) == [displayA, displayB])
    #expect(activations.value.map(\.setFocus) == [false, true])
    #expect(store.state.focusedDisplay == displayB)
    #expect(store.state.activeWorkspacesByDisplay == [displayA: slack.id, displayB: code.id])
  }

  @Test
  func `global recent keeps a visible dynamic chain target on its current display`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let displayC = DisplayName("C")
    let code = Workspace(name: "Code")
    let slack = Workspace(name: "Slack", displayHint: displayC)
    let old = Workspace(name: "Old", displayHint: displayC)
    let codeWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.code")
    let chain = WorkspaceChain(workspaceIDs: [code.id, slack.id])
    let state = Self.makeState(workspaces: [code, slack, old]) {
      $0.$config.withLock {
        $0.settings.switching.recentAcrossDisplays = true
        $0.mutateActiveProfile { $0.workspaceChains = [chain] }
      }
      $0.isTilingPaused = true
      $0.focusedDisplay = displayC
      $0.connectedDisplays = [displayA, displayB, displayC]
      $0.activeWorkspacesByDisplay = [displayA: code.id, displayC: old.id]
      $0.workspaceMRU = [old.id, code.id, slack.id]
      $0.tilingTrees[code.id] = .leaf(codeWindow)
    }
    let activations = LockIsolated<[ActivationRequest]>([])
    let focused = LockIsolated<[WindowKey]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB, displayC] }
      // Pointer B must not pull the already-visible dynamic recent target away
      // from its current owner A.
      $0.displays.current = { displayB }
      $0.displays.primary = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
      $0.focusManager.focusWindow = { key in
        focused.withValue { $0.append(key) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activateRecent())
    await Self.receiveActivationCompletion(store, workspaceID: slack.id, display: displayC)
    await store.receive(\.processDisplayRestores)
    await store.receive {
      guard case .restoreDisplay(let assignment) = $0 else { return false }
      return assignment.workspace == code.id && assignment.display.matches(displayA)
    }
    await store.finish()

    #expect(activations.value.map(\.workspace.id) == [slack.id])
    #expect(activations.value.map(\.targetDisplay) == [displayC])
    #expect(activations.value.allSatisfy { !$0.setFocus })
    #expect(focused.value == [codeWindow])
    #expect(store.state.focusedDisplay == displayA)
    #expect(store.state.activeWorkspacesByDisplay == [displayA: code.id, displayC: slack.id])
  }

  @Test
  func `recent stays scoped to the focused display when across displays is off`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let current = Workspace(name: "Current")
    let localRecent = Workspace(name: "Local Recent")
    let otherDisplayRecent = Workspace(name: "Other Display Recent")
    let state = Self.makeState(workspaces: [current, localRecent, otherDisplayRecent]) {
      $0.$config.withLock { $0.settings.switching.recentAcrossDisplays = false }
      $0.isTilingPaused = true
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [displayA: current.id, displayB: otherDisplayRecent.id]
      $0.previousWorkspacesByDisplay[displayA] = localRecent.id
      $0.workspaceMRU = [current.id, otherDisplayRecent.id, localRecent.id]
    }
    let requests = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.current = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        requests.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activateRecent())
    await store.receive {
      guard case .activationCompleted(let workspaceId, let display, _) = $0 else { return false }
      return workspaceId == localRecent.id && display == displayA
    }
    await store.finish()

    #expect(requests.value.last?.workspace.id == localRecent.id)
    #expect(requests.value.last?.targetDisplay == displayA)
  }

  @Test
  func `per display recent does not fall back to another monitor`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let wsA = Workspace(name: "A")
    let wsB = Workspace(name: "B")
    let state = Self.makeState(workspaces: [wsA, wsB]) {
      $0.$config.withLock { $0.settings.switching.recentAcrossDisplays = false }
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [displayA: wsA.id, displayB: wsB.id]
      $0.previousWorkspacesByDisplay[displayB] = wsA.id
      $0.workspaceMRU = [wsA.id, wsB.id]
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    }

    await store.send(.activateRecent())
  }

  @Test
  func `activate supersedes the in flight activation`() async {
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
  func `activation discovers A registered and shared app once`() async {
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
    #expect(discovered.value.count(where: { $0 == "app.shared" }) == 1)
  }

  @Test(arguments: AutoBalanceMode.allCases)
  func `fresh activation initializes a missing layout from auto balance`(
    mode: AutoBalanceMode
  ) async throws {
    let keys = [
      WindowKey(pid: 1, windowID: 101, bundleId: "app.one"),
      WindowKey(pid: 2, windowID: 202, bundleId: "app.two"),
      WindowKey(pid: 3, windowID: 303, bundleId: "app.three"),
      WindowKey(pid: 4, windowID: 404, bundleId: "app.four"),
    ]
    let workspace = Workspace(
      name: "Fresh",
      apps: keys.map {
        AppAssignment(bundleIdentifier: $0.bundleId, name: $0.bundleId)
      },
    )
    let workArea = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let initial = try #require(WorkspaceActivationFeature.mergeTree(
      existing: nil,
      target: keys,
      focused: { nil },
      insertionPoint: nil,
      workArea: workArea,
      settings: AppSettings(),
    ))
    let expected = initial.balancedForCommand(
      autoBalance: mode,
      in: workArea,
      gap: 0,
      splitAxis: nil,
    )
    let state = Self.makeState(workspaces: [workspace]) {
      $0.$config.withLock {
        $0.settings.layout.autoBalance = mode
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
        $0.settings.layout.splitType = .auto
      }
      $0.focusedDisplay = Self.display
    }
    let keyByBundle = Dictionary(uniqueKeysWithValues: keys.map { ($0.bundleId, $0) })
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.displays.workArea = { _ in workArea }
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
      $0.windowSnapshot.cachedKeys = { bundleIds, _ in
        bundleIds.compactMap { keyByBundle[$0] }
      }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: workspace.id, setFocus: false))
    await store.receive {
      guard case .activationCompleted(let workspaceId, _, _) = $0 else { return false }
      return workspaceId == workspace.id
    }
    await store.finish()

    #expect(store.state.tilingTrees[workspace.id] == expected)
  }

  @Test
  func `activation completed records display and recent workspace`() async {
    let ws1 = Workspace(name: "one")
    let ws2 = Workspace(name: "two")
    let state = Self.makeState(workspaces: [ws1, ws2]) {
      $0.activeWorkspacesByDisplay[Self.display] = ws1.id
      $0.isActivating = true
      $0.activationGeneration = 1
      $0.activeActivationGeneration = 1
    }
    let savedHistory = LockIsolated<[DisplayName: [UUID]]?>(nil)
    let savedMRU = LockIsolated<[UUID]?>(nil)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.profileSessionStore.saveWorkspaceState = { history, mru in
        savedHistory.setValue(history)
        savedMRU.setValue(mru)
      }
    }

    await store.send(.activationCompleted(
      workspaceId: ws2.id,
      display: Self.display,
      generation: 1,
    )) {
      $0.isActivating = false
      $0.previousWorkspacesByDisplay[Self.display] = ws1.id
      $0.activeWorkspacesByDisplay[Self.display] = ws2.id
      $0.lastActiveDisplay[ws2.id] = Self.display
      $0.displayWorkspaceHistory[Self.display] = [ws2.id]
      $0.workspaceMRU = [ws2.id]
    }
    await store.finish()

    #expect(savedHistory.value == [Self.display: [ws2.id]])
    #expect(savedMRU.value == [ws2.id])
  }

  @Test
  func `activation completion canonicalizes legacy display state to the live UUID`() async {
    let legacyDisplay = DisplayName("Studio")
    let liveDisplay = DisplayName(uuid: "studio-display", name: "Studio")
    let previous = Workspace(name: "Previous")
    let older = Workspace(name: "Older")
    let current = Workspace(name: "Current")
    let state = Self.makeState(workspaces: [previous, older, current]) {
      $0.connectedDisplays = [liveDisplay]
      $0.activeWorkspacesByDisplay = [legacyDisplay: previous.id]
      $0.previousWorkspacesByDisplay = [legacyDisplay: older.id]
      $0.displayWorkspaceHistory = [legacyDisplay: [previous.id, older.id]]
      $0.lastActiveDisplay = [previous.id: legacyDisplay, older.id: legacyDisplay]
      $0.isActivating = true
      $0.activatingWorkspaceID = current.id
      $0.activatingDisplay = liveDisplay
      $0.activationGeneration = 1
      $0.activeActivationGeneration = 1
    }
    let savedHistory = LockIsolated<[DisplayName: [UUID]]?>(nil)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.profileSessionStore.saveWorkspaceState = { history, _ in
        savedHistory.setValue(history)
      }
    }
    store.exhaustivity = .off

    await store.send(.activationCompleted(
      workspaceId: current.id,
      display: liveDisplay,
      generation: 1,
    ))
    await store.finish()

    #expect(store.state.activeWorkspacesByDisplay == [liveDisplay: current.id])
    #expect(store.state.previousWorkspacesByDisplay == [liveDisplay: previous.id])
    #expect(
      store.state.displayWorkspaceHistory
        == [liveDisplay: [current.id, previous.id, older.id]]
    )
    #expect(store.state.lastActiveDisplay[current.id] == liveDisplay)
    #expect(store.state.lastActiveDisplay[previous.id] == liveDisplay)
    #expect(store.state.lastActiveDisplay[older.id] == liveDisplay)
    #expect(savedHistory.value == store.state.displayWorkspaceHistory)
    #expect(store.state.activatingDisplay == nil)
  }

  @Test
  func `name only completion preserves the one known UUID display key`() {
    let legacyDisplay = DisplayName("Studio")
    let liveDisplay = DisplayName(uuid: "studio-display", name: "Studio")
    let previousID = UUID()
    let currentID = UUID()
    let profile = Profile(name: "Default", workspaces: [
      Workspace(id: previousID, name: "Previous"),
      Workspace(id: currentID, name: "Current"),
    ])
    var state = WorkspaceActivationFeature.State()
    state.$config.withLock {
      $0.profiles = [profile]
      $0.activeProfileId = profile.id
    }
    state.connectedDisplays = [liveDisplay]
    state.activeWorkspacesByDisplay = [liveDisplay: previousID]
    state.displayWorkspaceHistory = [liveDisplay: [previousID]]

    _ = state.recordCompletedActivation(
      workspaceId: currentID,
      display: legacyDisplay,
    )

    #expect(state.activeWorkspacesByDisplay == [liveDisplay: currentID])
    #expect(state.previousWorkspacesByDisplay == [liveDisplay: previousID])
    #expect(state.displayWorkspaceHistory == [liveDisplay: [currentID, previousID]])
  }

  @Test
  func `ambiguous name only display does not collapse distinct UUID monitors`() {
    let nameOnly = DisplayName("Studio")
    let displayA = DisplayName(uuid: "studio-a", name: "Studio")
    let displayB = DisplayName(uuid: "studio-b", name: "Studio")
    let workspaceA = UUID()
    let workspaceB = UUID()
    let replacementA = UUID()
    var state = WorkspaceActivationFeature.State()
    state.connectedDisplays = [displayA, displayB]
    state.activeWorkspacesByDisplay = [
      nameOnly: workspaceA,
      displayA: workspaceA,
      displayB: workspaceB,
    ]
    state.displayWorkspaceHistory = [
      nameOnly: [workspaceA],
      displayA: [workspaceA],
      displayB: [workspaceB],
    ]

    _ = state.recordCompletedActivation(
      workspaceId: replacementA,
      display: displayA,
    )

    #expect(state.activeWorkspacesByDisplay[displayA] == replacementA)
    #expect(state.activeWorkspacesByDisplay[displayB] == workspaceB)
    #expect(state.displayWorkspaceHistory[displayB] == [workspaceB])
    #expect(state.activeWorkspacesByDisplay[nameOnly] == workspaceA)
    #expect(state.displayWorkspaceHistory[nameOnly] == [workspaceA])
  }

  @Test
  func `CLI activation completes only after the activation tail`() async {
    let workspace = Workspace(name: "CLI")
    let state = Self.makeState(workspaces: [workspace]) {
      $0.isActivating = true
      $0.activationGeneration = 1
      $0.activeActivationGeneration = 1
    }
    let completions = LockIsolated<[String?]>([])
    let request = WorkspaceActivationFeature.CLIActivationRequest(
      target: .workspace(workspace.id),
      complete: { error in completions.withValue { $0.append(error) } },
    )
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    await store.send(.trackCLIActivation(request, joinCurrentActivation: true))
    await store.send(.activationCompleted(
      workspaceId: workspace.id,
      display: Self.display,
      generation: 1,
    ))
    #expect(completions.value.isEmpty)

    await store.send(.activationTailFinished(generation: 1))
    await store.finish()

    #expect(completions.value == [nil])
  }

  @Test
  func `CLI chain dispatch does not complete before its final restore starts`() async {
    let workspace = Workspace(name: "CLI Chain")
    let completions = LockIsolated<[String?]>([])
    let request = WorkspaceActivationFeature.CLIActivationRequest(
      target: .workspace(workspace.id),
      complete: { error in completions.withValue { $0.append(error) } },
    )
    let state = Self.makeState(workspaces: [workspace]) {
      $0.pendingCLIActivation = request
      $0.focusWorkspaceOnRestore = workspace.id
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    }
    store.exhaustivity = .off

    await store.send(.cliActivationEffectFinished(
      workspaceId: workspace.id,
      requestID: request.id,
    ))
    await store.finish()

    #expect(completions.value.isEmpty)
    #expect(store.state.pendingCLIActivation?.id == request.id)
  }

  @Test
  func `CLI workspace-chain activation completes after the queued trigger becomes active`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let code = Workspace(name: "Code", displayHint: displayA)
    let browser = Workspace(name: "Browser", displayHint: displayB)
    let old = Workspace(name: "Old", displayHint: displayA)
    let chain = WorkspaceChain(workspaceIDs: [browser.id, code.id])
    let completions = LockIsolated<[String?]>([])
    let request = WorkspaceActivationFeature.CLIActivationRequest(
      target: .workspace(code.id),
      complete: { error in completions.withValue { $0.append(error) } },
    )
    let state = Self.makeState(workspaces: [code, browser, old]) {
      $0.connectedDisplays = [displayA, displayB]
      $0.activeWorkspacesByDisplay = [displayA: old.id, displayB: browser.id]
      $0.$config.withLock { $0.mutateActiveProfile { $0.workspaceChains = [chain] } }
      $0.isTilingPaused = true
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB] }
      $0.displays.current = { displayA }
      $0.displays.primary = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { _ in }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.trackCLIActivation(request, joinCurrentActivation: false))
    await store.send(.activateFromCLI(workspaceId: code.id, requestID: request.id))
    await Self.receiveActivationCompletion(store, workspaceID: code.id, display: displayA)
    await store.finish()

    #expect(completions.value == [nil])
    #expect(store.state.activeWorkspacesByDisplay == [displayA: code.id, displayB: browser.id])
    #expect(store.state.pendingCLIActivation == nil)
  }

  @Test
  func `external deliberate activation supersedes profile CLI restore exactly once`() async throws {
    let display = Self.display
    let current = Workspace(name: "Current")
    let target = Workspace(name: "Target")
    let state = Self.makeState(workspaces: [current, target]) {
      $0.isActivating = true
      $0.activationGeneration = 1
      $0.activeActivationGeneration = 1
      $0.activeWorkspacesByDisplay[display] = target.id
      $0.focusedDisplay = display
      $0.tilingTrees[target.id] = .leaf(
        WindowKey(pid: 1, windowID: 101, bundleId: "app.target")
      )
    }
    let completions = LockIsolated<[String?]>([])
    let request = WorkspaceActivationFeature.CLIActivationRequest(
      target: .profile(try #require(state.config.activeProfile?.id)),
      complete: { error in completions.withValue { $0.append(error) } },
    )
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.displays.current = { display }
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.trackCLIActivation(request, joinCurrentActivation: true))
    await store.send(.activate(workspaceId: target.id, setFocus: true))
    await store.finish()

    #expect(completions.value.count == 1)
    #expect(completions.value.compactMap { $0 }.first?.contains("superseded") == true)
    #expect(store.state.pendingCLIActivation == nil)
    #expect(store.state.pendingCLIActivationBinding == nil)
  }

  @Test
  func `stale completion and watchdog cannot terminate the current activation`() async {
    let current = Workspace(name: "Current")
    let stale = Workspace(name: "Stale")
    let state = Self.makeState(workspaces: [current, stale]) {
      $0.isActivating = true
      $0.activationGeneration = 2
      $0.activeActivationGeneration = 2
      $0.activatingWorkspaceID = current.id
      $0.activeWorkspacesByDisplay[Self.display] = current.id
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    }

    await store.send(.activationCompleted(
      workspaceId: stale.id,
      display: Self.display,
      generation: 1,
    ))
    await store.send(.activationTimedOut(generation: 1))

    #expect(store.state.isActivating)
    #expect(store.state.activeActivationGeneration == 2)
    #expect(store.state.activatingWorkspaceID == current.id)
    #expect(store.state.activeWorkspacesByDisplay[Self.display] == current.id)
  }

  @Test
  func `removed workspace cannot complete from a stale active display mapping`() async {
    let live = Workspace(name: "Live")
    let removedID = UUID()
    let completions = LockIsolated<[String?]>([])
    let request = WorkspaceActivationFeature.CLIActivationRequest(
      target: .workspace(removedID),
      complete: { error in completions.withValue { $0.append(error) } },
    )
    let state = Self.makeState(workspaces: [live]) {
      $0.activeWorkspacesByDisplay[Self.display] = removedID
      $0.pendingCLIActivation = request
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    }
    store.exhaustivity = .off

    await store.send(.cliActivationEffectFinished(
      workspaceId: removedID,
      requestID: request.id,
    ))
    await store.finish()

    #expect(completions.value == ["The requested workspace no longer exists"])
    #expect(store.state.pendingCLIActivation == nil)
  }

  @Test(arguments: [false, true])
  func `visible CLI activation supersedes an active generation`(
    coreAlreadyCompleted: Bool
  ) async {
    let display = Self.display
    let visible = Workspace(name: "Visible")
    let inFlight = Workspace(name: "In Flight")
    let window = WindowKey(pid: 1, windowID: 101, bundleId: "app.visible")
    let profile = Profile(name: "Default", workspaces: [visible, inFlight])
    let sharedConfig = Shared(value: AppConfig(
      profiles: [profile],
      activeProfileId: profile.id,
    ))
    var state = WorkspaceActivationFeature.State()
    state.$config = sharedConfig
    state.activeWorkspacesByDisplay[display] = visible.id
    state.focusedDisplay = display
    state.tilingTrees[visible.id] = .leaf(window)
    state.isActivating = !coreAlreadyCompleted
    state.activatingWorkspaceID = coreAlreadyCompleted ? nil : inFlight.id
    state.activationGeneration = 1
    state.activeActivationGeneration = 1
    let completions = LockIsolated<[String?]>([])
    let request = WorkspaceActivationFeature.CLIActivationRequest(
      target: .workspace(visible.id),
      complete: { error in completions.withValue { $0.append(error) } },
    )
    let (activationGate, activationGateContinuation) = AsyncStream<Void>.makeStream()
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.displays.current = { display }
      $0.displays.workArea = { _ in CGRect(x: 0, y: 0, width: 1_000, height: 800) }
      $0.workspaceManager.activate = { _ in
        for await _ in activationGate { break }
      }
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.trackCLIActivation(request, joinCurrentActivation: false))
    await store.send(.activateFromCLI(workspaceId: visible.id, requestID: request.id))

    #expect(store.state.activationGeneration == 2)
    #expect(store.state.activeActivationGeneration == 2)
    #expect(store.state.activatingWorkspaceID == visible.id)
    #expect(store.state.pendingCLIActivationBinding == .init(
      requestID: request.id,
      activationGeneration: 2,
    ))
    #expect(completions.value.isEmpty)

    await store.send(.activationTailFinished(generation: 1))
    #expect(completions.value.isEmpty)
    await store.send(.activationTimedOut(generation: 2))
    activationGateContinuation.finish()
    await store.finish()

    #expect(completions.value == ["Workspace activation timed out"])
  }

  @Test(arguments: [false, true])
  func `missing restore fails its CLI request once and drains valid work`(
    requestTargetWasRemoved: Bool
  ) async {
    let missingID = UUID()
    let live = Workspace(name: "Live")
    let profile = Profile(name: "Default", workspaces: [live])
    let sharedConfig = Shared(value: AppConfig(
      profiles: [profile],
      activeProfileId: profile.id,
    ))
    let requestTarget: WorkspaceActivationFeature.CLIActivationRequest.Target =
      requestTargetWasRemoved ? .workspace(missingID) : .profile(profile.id)
    let expectedError = requestTargetWasRemoved
      ? "The requested workspace no longer exists"
      : "Configuration changed while activation was in progress"
    let completions = LockIsolated<[String?]>([])
    let request = WorkspaceActivationFeature.CLIActivationRequest(
      target: requestTarget,
      complete: { error in completions.withValue { $0.append(error) } },
    )
    let liveDisplay = DisplayName("Live Display")
    var state = WorkspaceActivationFeature.State()
    state.$config = sharedConfig
    state.pendingCLIActivation = request
    state.pendingDisplayRestores = [
      DisplayAssignment(display: liveDisplay, workspace: live.id)
    ]
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.displays.workArea = { _ in CGRect(x: 0, y: 0, width: 1_000, height: 800) }
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.restoreDisplay(DisplayAssignment(
      display: Self.display,
      workspace: missingID,
    )))
    await store.receive(\.processDisplayRestores)
    await store.receive {
      guard case .restoreDisplay(let assignment) = $0 else { return false }
      return assignment.workspace == live.id && assignment.display == liveDisplay
    }
    await store.receive {
      guard case .activationCompleted(let workspaceID, let display, _) = $0 else { return false }
      return workspaceID == live.id && display == liveDisplay
    }
    await store.finish()

    #expect(completions.value == [expectedError])
    #expect(store.state.pendingCLIActivation == nil)
    #expect(store.state.pendingDisplayRestores.isEmpty)
    #expect(store.state.activeWorkspacesByDisplay[liveDisplay] == live.id)
  }

  @Test(arguments: [false, true])
  func `empty profile reactivation invalidates the outgoing generation`(
    hasOnlyScratchpad: Bool
  ) async {
    let display = Self.display
    let removedWorkspaceID = UUID()
    let scratchpad = Workspace(name: "Scratchpad", kind: .scratchpad)
    let replacement = Profile(
      name: "Replacement",
      workspaces: hasOnlyScratchpad ? [scratchpad] : [],
    )
    let sharedConfig = Shared(value: AppConfig(
      profiles: [replacement],
      activeProfileId: replacement.id,
    ))
    let completions = LockIsolated<[String?]>([])
    let request = WorkspaceActivationFeature.CLIActivationRequest(
      target: .profile(replacement.id),
      complete: { error in completions.withValue { $0.append(error) } },
    )
    var state = WorkspaceActivationFeature.State()
    state.$config = sharedConfig
    state.isActivating = true
    state.activatingWorkspaceID = removedWorkspaceID
    state.activationGeneration = 1
    state.activeActivationGeneration = 1
    state.activeWorkspacesByDisplay[display] = removedWorkspaceID
    state.pendingCLIActivation = request
    state.pendingDisplayRestores = [
      DisplayAssignment(display: display, workspace: removedWorkspaceID)
    ]
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [display] }
    }
    store.exhaustivity = .off

    await store.send(.reactivateActiveProfile(focus: nil))
    await store.finish()

    #expect(completions.value == [nil])
    #expect(!store.state.isActivating)
    #expect(store.state.activatingWorkspaceID == nil)
    #expect(store.state.activeActivationGeneration == nil)
    #expect(store.state.activeWorkspacesByDisplay.isEmpty)
    #expect(store.state.pendingDisplayRestores.isEmpty)
    #expect(store.state.pendingCLIActivation == nil)

    await store.send(.activationCompleted(
      workspaceId: removedWorkspaceID,
      display: display,
      generation: 1,
    ))
    await store.send(.activationTailFinished(generation: 1))

    #expect(completions.value == [nil])
    #expect(store.state.activeWorkspacesByDisplay.isEmpty)
  }

  @Test
  func `profile cleanup focuses a successor and preserves profile-local recent history`() async {
    let displayA = DisplayName("A")
    let displayC = DisplayName("C")
    let oldA = Workspace(
      name: "Old A",
      apps: [AppAssignment(bundleIdentifier: "app.old-a", name: "Old A")],
    )
    let oldC = Workspace(
      name: "Old C",
      apps: [AppAssignment(bundleIdentifier: "app.old-c", name: "Old C")],
    )
    let outgoing = Profile(name: "Outgoing", workspaces: [oldA, oldC])
    let recent = Workspace(name: "Recent", displayHint: displayA)
    let other = Workspace(name: "Other", displayHint: displayA)
    let incoming = Profile(name: "Incoming", workspaces: [recent, other])
    let sharedConfig = Shared(value: AppConfig(
      profiles: [outgoing, incoming],
      activeProfileId: incoming.id,
    ))
    var state = WorkspaceActivationFeature.State()
    state.$config = sharedConfig
    state.$config.withLock { $0.settings.switching.recentAcrossDisplays = false }
    state.connectedDisplays = [displayA, displayC]
    state.focusedDisplay = displayC
    state.activeWorkspacesByDisplay = [displayA: oldA.id, displayC: oldC.id]
    state.displayWorkspaceHistory[displayA] = [oldA.id, recent.id, other.id]
    let activations = LockIsolated<[ActivationRequest]>([])
    let returns = LockIsolated<[(Set<String>, DisplayName)]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayC] }
      $0.displays.current = { displayC }
      $0.displays.primary = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
      $0.workspaceManager.returnBorrowed = { bundleIDs, display in
        returns.withValue { $0.append((bundleIDs, display)) }
        return true
      }
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.reactivateActiveProfile(focus: nil))
    await Self.receiveActivationCompletion(store, workspaceID: recent.id, display: displayA)
    await store.finish()

    #expect(activations.value.map(\.workspace.id) == [recent.id])
    #expect(activations.value.map(\.setFocus) == [true])
    #expect(returns.value.count == 1)
    #expect(returns.value.first?.0 == ["app.old-c"])
    #expect(returns.value.first?.1 == displayC)
    #expect(store.state.activeWorkspacesByDisplay == [displayA: recent.id])
    #expect(store.state.previousWorkspacesByDisplay[displayA] == nil)
    #expect(store.state.displayWorkspaceHistory[displayA]?.contains(oldA.id) == true)
    #expect(
      WorkspaceActivationFeature().recentWorkspaceId(
        state: store.state,
        display: displayA,
      ) == other.id
    )
  }

  @Test
  func `focused profile restore applies a partial priority chain and cleans an unfilled source`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let displayC = DisplayName("C")
    let outgoingWorkspace = Workspace(
      name: "Outgoing",
      apps: [AppAssignment(bundleIdentifier: "app.outgoing", name: "Outgoing")],
    )
    let outgoing = Profile(name: "Outgoing", workspaces: [outgoingWorkspace])
    let first = Workspace(name: "First", displayHint: displayA)
    let skipped = Workspace(name: "Skipped", displayHint: displayA)
    let dynamic = Workspace(name: "Dynamic")
    let chain = WorkspaceChain(workspaceIDs: [first.id, skipped.id, dynamic.id])
    let incoming = Profile(
      name: "Incoming",
      workspaceChains: [chain],
      workspaces: [first, skipped, dynamic],
    )
    let sharedConfig = Shared(value: AppConfig(
      profiles: [outgoing, incoming],
      activeProfileId: incoming.id,
    ))
    var state = WorkspaceActivationFeature.State()
    state.$config = sharedConfig
    state.connectedDisplays = [displayA, displayB, displayC]
    state.activeWorkspacesByDisplay = [displayC: outgoingWorkspace.id]
    let activations = LockIsolated<[ActivationRequest]>([])
    let returns = LockIsolated<[(Set<String>, DisplayName)]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB, displayC] }
      $0.displays.current = { displayA }
      $0.displays.primary = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
      $0.workspaceManager.returnBorrowed = { bundleIDs, display in
        returns.withValue { $0.append((bundleIDs, display)) }
        return true
      }
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.reactivateActiveProfile(focus: first.id))
    await Self.receiveActivationCompletion(store, workspaceID: dynamic.id, display: displayB)
    await store.receive(\.processDisplayRestores)
    await store.receive {
      guard case .restoreDisplay(let assignment) = $0 else { return false }
      return assignment.workspace == first.id && assignment.display.matches(displayA)
    }
    await Self.receiveActivationCompletion(store, workspaceID: first.id, display: displayA)
    await store.finish()

    #expect(activations.value.map(\.workspace.id) == [dynamic.id, first.id])
    #expect(activations.value.map(\.setFocus) == [false, true])
    #expect(!activations.value.contains { $0.workspace.id == skipped.id })
    #expect(returns.value.count == 1)
    #expect(returns.value.first?.0 == ["app.outgoing"])
    #expect(returns.value.first?.1 == displayC)
    #expect(store.state.activeWorkspacesByDisplay == [
      displayA: first.id,
      displayB: dynamic.id,
    ])
  }

  @Test(arguments: [false, true])
  func `focused profile chain publishes one complete HUD per affected display`(
    showsWorkspaceSwitchHUD: Bool
  ) async throws {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let displayC = DisplayName("C")
    let outgoingHost = Workspace(
      name: "Slack",
      apps: [AppAssignment(bundleIdentifier: "app.slack", name: "Slack")],
    )
    let outgoingBorrow = Workspace(
      name: "KakaoTalk",
      apps: [AppAssignment(bundleIdentifier: "app.kakao", name: "KakaoTalk")],
    )
    let outgoing = Profile(
      name: "Outgoing",
      workspaces: [outgoingHost, outgoingBorrow],
    )
    let coding = Workspace(name: "Coding", displayHint: displayA)
    let skipped = Workspace(name: "Skipped", displayHint: displayA)
    let browser = Workspace(name: "Browser", displayHint: displayB)
    let chain = WorkspaceChain(
      name: "Test",
      workspaceIDs: [coding.id, skipped.id, browser.id],
    )
    let incoming = Profile(
      name: "Incoming",
      symbolIconName: "sparkles",
      workspaceChains: [chain],
      workspaces: [coding, skipped, browser],
    )
    let sharedConfig = Shared(value: AppConfig(
      profiles: [outgoing, incoming],
      activeProfileId: incoming.id,
    ))
    var state = WorkspaceActivationFeature.State()
    state.$config = sharedConfig
    state.$config.withLock {
      $0.settings.hud.workspaceSwitch = showsWorkspaceSwitchHUD
    }
    state.isTilingPaused = true
    state.connectedDisplays = [displayA, displayB, displayC]
    state.focusedDisplay = displayC
    state.activeWorkspacesByDisplay = [displayC: outgoingHost.id]
    state.compositionsByDisplay[displayC] = Composition(
      host: outgoingHost.id,
      borrowed: [BorrowedSlot(workspace: outgoingBorrow.id, edge: .right)],
    )
    let cleanupStarted = AsyncStream<Void>.makeStream()
    let releaseCleanup = AsyncStream<Void>.makeStream()
    let returned = LockIsolated<[(Set<String>, DisplayName)]>([])
    let hudRequests = LockIsolated<[ActionHUDRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB, displayC] }
      $0.displays.current = { displayA }
      $0.displays.primary = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { _ in }
      $0.workspaceManager.returnBorrowed = { bundleIDs, display in
        returned.withValue { $0.append((bundleIDs, display)) }
        cleanupStarted.continuation.yield()
        var iterator = releaseCleanup.stream.makeAsyncIterator()
        _ = await iterator.next()
        return true
      }
      $0.workspaceHUD.showAction = { request in
        hudRequests.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off
    var cleanupStartedIterator = cleanupStarted.stream.makeAsyncIterator()

    await store.send(.reactivateActiveProfile(
      focus: browser.id,
      interactionDisplay: displayA,
    ))
    await Self.receiveActivationCompletion(store, workspaceID: coding.id, display: displayA)
    await store.receive(\.processDisplayRestores)
    await store.receive {
      guard case .restoreDisplay(let assignment) = $0 else { return false }
      return assignment.workspace == browser.id && assignment.display.matches(displayB)
    }
    await store.receive {
      guard case .activationCompleted(let workspaceID, let display, _) = $0 else { return false }
      return workspaceID == browser.id && display?.matches(displayB) == true
    }
    await store.receive {
      guard case .processWorkspaceChainCleanupStep(_, let cleanup, _) = $0 else { return false }
      return cleanup.display.matches(displayC)
        && cleanup.bundleIDs == ["app.kakao", "app.slack"]
    }
    #expect(await cleanupStartedIterator.next() != nil)
    let sourceHUDsBeforeCommit = hudRequests.value.filter {
      $0.display?.matches(displayC) == true
    }
    #expect(sourceHUDsBeforeCommit.isEmpty)

    releaseCleanup.continuation.yield()
    releaseCleanup.continuation.finish()
    cleanupStarted.continuation.finish()
    await store.receive {
      guard case .commitWorkspaceChainCleanup(_, let display, _) = $0 else { return false }
      return display.matches(displayC)
    }
    await store.receive {
      guard case .activationTailFinished = $0 else { return false }
      return true
    }
    await store.finish()

    #expect(returned.value.count == 1)
    #expect(returned.value.first?.0 == ["app.kakao", "app.slack"])
    #expect(returned.value.first?.1 == displayC)
    #expect(hudRequests.value.count == 3)
    let codingHUD = try #require(hudRequests.value.first {
      $0.display?.matches(displayA) == true
    })
    #expect(codingHUD.name == incoming.name)
    #expect(codingHUD.symbolIconName == incoming.symbolIconName)
    let focusMoved = "\(String(localized: "Focus moved")): "
      + String(localized: "\(browser.name) is on \(displayB.name)")
    #expect(
      codingHUD.subtitle
        == (showsWorkspaceSwitchHUD
          ? "\(chain.name!) · \(coding.name)\n\(focusMoved)"
          : coding.name)
    )
    #expect(codingHUD.subtitleSymbolIconName == (showsWorkspaceSwitchHUD ? "link" : nil))
    let browserHUD = try #require(hudRequests.value.first {
      $0.display?.matches(displayB) == true
    })
    #expect(browserHUD.name == incoming.name)
    #expect(browserHUD.symbolIconName == incoming.symbolIconName)
    #expect(
      browserHUD.subtitle
        == (showsWorkspaceSwitchHUD ? "\(chain.name!) · \(browser.name)" : browser.name)
    )
    #expect(browserHUD.subtitleSymbolIconName == (showsWorkspaceSwitchHUD ? "link" : nil))
    let sourceHUDs = hudRequests.value.filter {
      $0.display?.matches(displayC) == true
    }
    let sourceHUD = try #require(sourceHUDs.first)
    #expect(sourceHUDs.count == 1)
    #expect(sourceHUD.name == incoming.name)
    #expect(sourceHUD.symbolIconName == incoming.symbolIconName)
    #expect(
      sourceHUD.subtitle
        == "\(outgoingHost.name) · "
        + String(localized: "Returned \(outgoingBorrow.name)")
    )
    #expect(sourceHUD.subtitleSymbolIconName == nil)
    #expect(sourceHUD.subtitleExtendsDuration)
  }

  @Test(arguments: [false, true])
  func `focused chain restore keeps its captured dynamic display and respects pins`(
    pinsTrigger: Bool
  ) async {
    let displayA = DisplayName(uuid: "display-a", name: "A")
    let displayB = DisplayName(uuid: "display-b", name: "B")
    let peer = Workspace(name: "Peer")
    let trigger = Workspace(
      name: "Trigger",
      displayHint: pinsTrigger ? displayB : nil,
    )
    let chain = WorkspaceChain(workspaceIDs: [peer.id, trigger.id])
    let profile = Profile(
      name: "Incoming",
      workspaceChains: [chain],
      workspaces: [peer, trigger],
    )
    let sharedConfig = Shared(value: AppConfig(
      profiles: [profile],
      activeProfileId: profile.id,
    ))
    var state = WorkspaceActivationFeature.State()
    state.$config = sharedConfig
    state.isTilingPaused = true
    state.connectedDisplays = [displayA, displayB]
    state.focusedDisplay = displayB
    let pointerDisplay = LockIsolated(displayA)
    let activations = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB] }
      $0.displays.current = { pointerDisplay.value }
      $0.displays.primary = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.reactivateActiveProfile(
      focus: trigger.id,
      interactionDisplay: displayA,
    ))
    pointerDisplay.setValue(displayB)

    let triggerDisplay = pinsTrigger ? displayB : displayA
    let peerDisplay = pinsTrigger ? displayA : displayB
    await Self.receiveActivationCompletion(
      store,
      workspaceID: peer.id,
      display: peerDisplay,
    )
    await store.receive(\.processDisplayRestores)
    await store.receive {
      guard case .restoreDisplay(let assignment) = $0 else { return false }
      return assignment.workspace == trigger.id
        && assignment.display.matches(triggerDisplay)
    }
    await Self.receiveActivationCompletion(
      store,
      workspaceID: trigger.id,
      display: triggerDisplay,
    )
    await store.finish()

    #expect(activations.value.map(\.workspace.id) == [peer.id, trigger.id])
    #expect(activations.value.map(\.targetDisplay) == [peerDisplay, triggerDisplay])
    #expect(activations.value.map(\.setFocus) == [false, true])
    #expect(store.state.activeWorkspace(on: triggerDisplay) == trigger.id)
  }

  @Test
  func `focused standalone restore moves its dynamic workspace to the captured display`() async {
    let displayA = DisplayName(uuid: "display-a", name: "A")
    let displayB = DisplayName(uuid: "display-b", name: "B")
    let peer = Workspace(name: "Peer")
    // The ordinary restore order puts the second dynamic workspace on B.
    // Explicit focus must swap it onto the command-entry display A instead.
    let trigger = Workspace(name: "Trigger")
    let profile = Profile(name: "Incoming", workspaces: [peer, trigger])
    let sharedConfig = Shared(value: AppConfig(
      profiles: [profile],
      activeProfileId: profile.id,
    ))
    var state = WorkspaceActivationFeature.State()
    state.$config = sharedConfig
    state.isTilingPaused = true
    state.connectedDisplays = [displayA, displayB]
    state.focusedDisplay = displayB
    let pointerDisplay = LockIsolated(displayA)
    let activations = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB] }
      $0.displays.current = { pointerDisplay.value }
      $0.displays.primary = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.reactivateActiveProfile(
      focus: trigger.id,
      interactionDisplay: displayA,
    ))
    pointerDisplay.setValue(displayB)
    await Self.receiveActivationCompletion(
      store,
      workspaceID: peer.id,
      display: displayB,
    )
    await store.receive(\.processDisplayRestores)
    await store.receive {
      guard case .restoreDisplay(let assignment) = $0 else { return false }
      return assignment.workspace == trigger.id
        && assignment.display.matches(displayA)
    }
    await Self.receiveActivationCompletion(
      store,
      workspaceID: trigger.id,
      display: displayA,
    )
    await store.finish()

    #expect(activations.value.map(\.workspace.id) == [peer.id, trigger.id])
    #expect(activations.value.map(\.targetDisplay) == [displayB, displayA])
    #expect(activations.value.map(\.setFocus) == [false, true])
    #expect(store.state.activeWorkspace(on: displayA) == trigger.id)
  }

  @Test
  func `stale chain cleanup transaction never starts its physical return`() async {
    let displayA = DisplayName("A")
    let displayC = DisplayName("C")
    let expected = Workspace(name: "Expected")
    let newer = Workspace(name: "Newer")
    let skipped = Workspace(name: "Skipped")
    let state = Self.makeState(workspaces: [expected, newer, skipped]) {
      $0.connectedDisplays = [displayA, displayC]
      $0.activeWorkspacesByDisplay = [displayA: newer.id, displayC: skipped.id]
    }
    let transaction = WorkspaceChainCleanupTransaction(
      skippedWorkspaceIDs: [skipped.id],
      retainedWorkspaceIDs: [expected.id],
      placements: [WorkspaceChainPlacement(display: displayA, workspace: expected.id)],
      sourcePlacements: [
        WorkspaceChainPlacement(display: displayC, workspace: skipped.id)
      ],
      sourceSnapshots: [WorkspaceChainCleanupSourceSnapshot(
        display: displayC,
        activeWorkspace: skipped.id,
        composition: nil,
        borrowGeneration: 0,
      )],
      requiresFocusSuccessor: true,
      cleanupHUDRequests: [],
    )
    let returnCalls = LockIsolated(0)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.workspaceManager.returnBorrowed = { _, _ in
        returnCalls.withValue { $0 += 1 }
        return true
      }
    }
    store.exhaustivity = .off

    await store.send(.processWorkspaceChainCleanup(
      transaction,
      cleanups: [WorkspaceChainVisibilityCleanup(
        display: displayC,
        bundleIDs: ["app.skipped"],
      )],
    ))
    await store.finish()

    #expect(store.state.activeWorkspacesByDisplay == [
      displayA: newer.id,
      displayC: skipped.id,
    ])
    #expect(returnCalls.value == 0)
  }

  @Test(arguments: ["activate", "cli", "app-focus", "recent", "next", "focus-display"])
  func `replacement activation cancels unfinished multi-display cleanup before starting`(
    entryPath: String
  ) async {
    let displayA = DisplayName("A")
    let displayC = DisplayName("C")
    let displayD = DisplayName("D")
    let expected = Workspace(name: "Expected", displayHint: displayA)
    let newer = Workspace(name: "Newer", displayHint: displayA)
    let skippedC = Workspace(
      name: "Skipped C",
      apps: [AppAssignment(bundleIdentifier: "app.skipped-c", name: "Skipped C")],
    )
    let skippedD = Workspace(
      name: "Skipped D",
      apps: [AppAssignment(bundleIdentifier: "app.skipped-d", name: "Skipped D")],
    )
    let skippedDWindow = WindowKey(
      pid: 4,
      windowID: 404,
      bundleId: "app.skipped-d",
    )
    var state = Self.makeState(workspaces: [expected, newer, skippedC, skippedD]) {
      $0.isTilingPaused = true
      $0.$config.withLock {
        $0.settings.switching.cycleAcrossDisplays = false
        $0.settings.switching.recentAcrossDisplays = true
      }
      $0.connectedDisplays = [displayA, displayC, displayD]
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [
        displayA: expected.id,
        displayC: skippedC.id,
        displayD: skippedD.id,
      ]
      $0.workspaceMRU = [expected.id, newer.id]
      $0.tilingTrees[skippedD.id] = .leaf(skippedDWindow)
    }
    let cliRequest = WorkspaceActivationFeature.CLIActivationRequest(
      target: .workspace(newer.id),
      complete: { _ in },
    )
    if entryPath == "cli" {
      state.pendingCLIActivation = cliRequest
    }
    let hudSettings = state.config.settings.hud
    let transaction = WorkspaceChainCleanupTransaction(
      skippedWorkspaceIDs: [skippedC.id, skippedD.id],
      retainedWorkspaceIDs: [expected.id],
      placements: [WorkspaceChainPlacement(display: displayA, workspace: expected.id)],
      sourcePlacements: [
        WorkspaceChainPlacement(display: displayC, workspace: skippedC.id),
        WorkspaceChainPlacement(display: displayD, workspace: skippedD.id),
      ],
      sourceSnapshots: [
        WorkspaceChainCleanupSourceSnapshot(
          display: displayC,
          activeWorkspace: skippedC.id,
          composition: nil,
          borrowGeneration: 0,
        ),
        WorkspaceChainCleanupSourceSnapshot(
          display: displayD,
          activeWorkspace: skippedD.id,
          composition: nil,
          borrowGeneration: 0,
        ),
      ],
      requiresFocusSuccessor: true,
      cleanupHUDRequests: [
        ActionHUDRequest(
          name: "C cleaned",
          symbolIconName: nil,
          subtitle: nil,
          durationMs: hudSettings.durationMs,
          position: hudSettings.position,
          size: hudSettings.size,
          display: displayC,
        ),
        ActionHUDRequest(
          name: "D cleaned",
          symbolIconName: nil,
          subtitle: nil,
          durationMs: hudSettings.durationMs,
          position: hudSettings.position,
          size: hudSettings.size,
          display: displayD,
        ),
      ],
    )
    let secondStarted = AsyncStream<Void>.makeStream()
    let holdSecond = AsyncStream<Void>.makeStream()
    let outcomes = LockIsolated<[(DisplayName, Bool)]>([])
    let hudRequests = LockIsolated<[ActionHUDRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayC, displayD] }
      $0.displays.current = { displayA }
      $0.displays.primary = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { _ in }
      $0.workspaceManager.returnBorrowed = { _, display in
        if display.matches(displayD) {
          secondStarted.continuation.yield()
          var iterator = holdSecond.stream.makeAsyncIterator()
          _ = await iterator.next()
        }
        let completed = !Task.isCancelled
        outcomes.withValue { $0.append((display, completed)) }
        return completed
      }
      $0.workspaceHUD.showAction = { request in
        hudRequests.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off
    var secondStartedIterator = secondStarted.stream.makeAsyncIterator()

    await store.send(.processWorkspaceChainCleanup(
      transaction,
      cleanups: [
        WorkspaceChainVisibilityCleanup(
          display: displayC,
          bundleIDs: ["app.skipped-c"],
        ),
        WorkspaceChainVisibilityCleanup(
          display: displayD,
          bundleIDs: ["app.skipped-d"],
        ),
      ],
    ))
    await store.receive {
      guard case .processWorkspaceChainCleanupStep(_, let cleanup, _) = $0 else { return false }
      return cleanup.display.matches(displayC) && cleanup.bundleIDs == ["app.skipped-c"]
    }
    await store.receive {
      guard case .commitWorkspaceChainCleanup(_, let display, _) = $0 else { return false }
      return display.matches(displayC)
    }
    await store.receive {
      guard case .processWorkspaceChainCleanupStep(_, let cleanup, _) = $0 else { return false }
      return cleanup.display.matches(displayD) && cleanup.bundleIDs == ["app.skipped-d"]
    }
    #expect(await secondStartedIterator.next() != nil)
    #expect(store.state.activeWorkspacesByDisplay[displayC] == nil)
    #expect(store.state.activeWorkspacesByDisplay[displayD] == skippedD.id)

    switch entryPath {
    case "cli":
      await store.send(.activateFromCLI(
        workspaceId: newer.id,
        requestID: cliRequest.id,
        interactionDisplay: displayA,
      ))

    case "app-focus":
      await store.send(.activateFollowingAppFocus(workspaceId: newer.id))

    case "recent":
      await store.send(.activateRecent(interactionDisplay: displayA))

    case "next":
      await store.send(.activateNext(interactionDisplay: displayA))

    case "focus-display":
      await store.send(.focusAdjacentDisplay(
        direction: -1,
        interactionDisplay: displayA,
      ))

    default:
      await store.send(.activate(
        workspaceId: newer.id,
        setFocus: true,
        interactionDisplay: displayA,
      ))
    }
    if entryPath != "focus-display" {
      await Self.receiveActivationCompletion(store, workspaceID: newer.id, display: displayA)
    }
    holdSecond.continuation.finish()
    secondStarted.continuation.finish()
    await store.finish()

    #expect(outcomes.value.count == 2)
    #expect(outcomes.value[0].0 == displayC && outcomes.value[0].1)
    #expect(outcomes.value[1].0 == displayD && !outcomes.value[1].1)
    #expect(store.state.activeWorkspacesByDisplay == (
      entryPath == "focus-display"
        ? [displayA: expected.id, displayD: skippedD.id]
        : [displayA: newer.id, displayD: skippedD.id]
    ))
    // C's committed cleanup feedback survives; D never reaches its commit.
    // The deliberate replacement activation is independent and presents its
    // ordinary workspace HUD after it takes over the display.
    let expectedHUDNames =
      switch entryPath {
      case "app-focus": ["C cleaned"]
      case "focus-display": ["C cleaned", "Skipped D", String(localized: "Focus moved")]
      default: ["C cleaned", "Newer"]
      }
    #expect(hudRequests.value.map(\.name) == expectedHUDNames)
  }

  @Test
  func `skipped host cleanup returns its unrelated borrowed workspace before removing composition`() async throws {
    let displayA = DisplayName("A")
    let displayC = DisplayName("C")
    let trigger = Workspace(name: "Trigger", displayHint: displayA)
    let skippedHost = Workspace(
      name: "Skipped Host",
      apps: [AppAssignment(bundleIdentifier: "app.skipped-host", name: "Host")],
    )
    let borrowed = Workspace(
      name: "Borrowed",
      apps: [AppAssignment(bundleIdentifier: "app.borrowed", name: "Borrowed")],
    )
    let state = Self.makeState(workspaces: [trigger, skippedHost, borrowed]) {
      $0.connectedDisplays = [displayA, displayC]
      $0.activeWorkspacesByDisplay = [displayA: trigger.id, displayC: skippedHost.id]
      $0.compositionsByDisplay[displayC] = Composition(
        host: skippedHost.id,
        borrowed: [BorrowedSlot(workspace: borrowed.id, edge: .right)],
      )
    }
    let assignment = DisplayAssignment(display: displayA, workspace: trigger.id)
    let feature = WorkspaceActivationFeature()
    let transaction = try #require(feature.makeWorkspaceCleanupTransaction(
      prioritySkippedWorkspaceIDs: [skippedHost.id],
      retainedWorkspaceIDs: [trigger.id],
      assignments: [assignment],
      state: state,
    ))
    let cleanups = feature.workspaceChainVisibilityCleanups(transaction, state: state)
    #expect(cleanups == [WorkspaceChainVisibilityCleanup(
      display: displayC,
      bundleIDs: ["app.borrowed", "app.skipped-host"],
    )])
    let returned = LockIsolated<[(Set<String>, DisplayName)]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.workspaceManager.returnBorrowed = { bundleIDs, display in
        returned.withValue { $0.append((bundleIDs, display)) }
        return true
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.processWorkspaceChainCleanup(
      transaction,
      cleanups: cleanups,
    ))
    await store.receive {
      guard case .processWorkspaceChainCleanupStep(_, let cleanup, _) = $0 else { return false }
      return cleanup.display.matches(displayC)
        && cleanup.bundleIDs == ["app.borrowed", "app.skipped-host"]
    }
    await store.receive {
      guard case .commitWorkspaceChainCleanup(_, let display, _) = $0 else { return false }
      return display.matches(displayC)
    }
    await store.finish()

    #expect(returned.value.count == 1)
    #expect(returned.value.first?.0 == ["app.borrowed", "app.skipped-host"])
    #expect(returned.value.first?.1 == displayC)
    #expect(store.state.activeWorkspacesByDisplay[displayC] == nil)
    #expect(store.state.compositionsByDisplay[displayC] == nil)
  }

  @Test
  func `superseded profile restore carries the unfilled outgoing source forward`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let displayC = DisplayName("C")
    let outgoingWorkspace = Workspace(
      name: "Outgoing",
      apps: [AppAssignment(bundleIdentifier: "app.outgoing", name: "Outgoing")],
    )
    let first = Workspace(name: "First", displayHint: displayA)
    let second = Workspace(name: "Second", displayHint: displayB)
    let outgoing = Profile(name: "Outgoing", workspaces: [outgoingWorkspace])
    let firstProfile = Profile(name: "First", workspaces: [first])
    let secondProfile = Profile(name: "Second", workspaces: [second])
    let sharedConfig = Shared(value: AppConfig(
      profiles: [outgoing, firstProfile, secondProfile],
      activeProfileId: firstProfile.id,
    ))
    var state = WorkspaceActivationFeature.State()
    state.$config = sharedConfig
    state.connectedDisplays = [displayA, displayB, displayC]
    state.activeWorkspacesByDisplay = [displayC: outgoingWorkspace.id]
    let firstActivationStarted = AsyncStream<Void>.makeStream()
    let releaseFirstActivation = AsyncStream<Void>.makeStream()
    let activationCount = LockIsolated(0)
    let activations = LockIsolated<[ActivationRequest]>([])
    let returns = LockIsolated<[(Set<String>, DisplayName)]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB, displayC] }
      $0.displays.current = { displayA }
      $0.displays.primary = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
        let index = activationCount.withValue { count in
          defer { count += 1 }
          return count
        }
        if index == 0 {
          firstActivationStarted.continuation.yield()
          var iterator = releaseFirstActivation.stream.makeAsyncIterator()
          _ = await iterator.next()
        }
      }
      $0.workspaceManager.returnBorrowed = { bundleIDs, display in
        returns.withValue { $0.append((bundleIDs, display)) }
        return true
      }
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off
    var startedIterator = firstActivationStarted.stream.makeAsyncIterator()

    await store.send(.reactivateActiveProfile(focus: nil))
    #expect(await startedIterator.next() != nil)
    sharedConfig.withLock { $0.activeProfileId = secondProfile.id }
    await store.send(.reactivateActiveProfile(focus: nil))
    await Self.receiveActivationCompletion(store, workspaceID: second.id, display: displayB)
    releaseFirstActivation.continuation.finish()
    firstActivationStarted.continuation.finish()
    await store.finish()

    #expect(activations.value.map(\.workspace.id) == [first.id, second.id])
    #expect(returns.value.count == 1)
    #expect(returns.value.first?.0 == ["app.outgoing"])
    #expect(returns.value.first?.1 == displayC)
    #expect(store.state.activeWorkspacesByDisplay == [displayB: second.id])
  }

  @Test
  func `restored workspace history keeps only valid normal workspaces`() async throws {
    let liveDisplay = DisplayName(uuid: "display-1", name: "Renamed Display")
    let savedDisplay = DisplayName(uuid: "display-1", name: "Old Display Name")
    let first = Workspace(name: "First")
    let second = Workspace(name: "Second")
    let scratchpad = Workspace(name: "Scratchpad", kind: .scratchpad)
    let removed = UUID()
    let state = Self.makeState(workspaces: [first, second, scratchpad])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [liveDisplay] }
    }
    let activeProfileId = try #require(store.state.config.activeProfile?.id)

    await store.send(.restoreStartupSession(
      lastUsedProfileId: activeProfileId,
      displayWorkspaceHistory: [
        savedDisplay: [removed, scratchpad.id, first.id, first.id, second.id]
      ],
      workspaceMRU: [removed, scratchpad.id, first.id, first.id, second.id],
    )) {
      $0.$config.withLock { $0.activeProfileId = activeProfileId }
      $0.displayWorkspaceHistory[liveDisplay] = [first.id, second.id]
      $0.workspaceMRU = [first.id, second.id]
      $0.previousWorkspacesByDisplay[liveDisplay] = second.id
    }

    #expect(store.state.displayWorkspaceHistory.keys.first?.name == liveDisplay.name)
  }

  @Test
  func `startup session restores the last eligible profile before its workspace history`() async {
    let display = DisplayName(uuid: "display-a", name: "Built-in")
    let defaultWorkspace = Workspace(name: "Default")
    let recent = Workspace(name: "Interview Recent")
    let previous = Workspace(name: "Interview Previous")
    let defaultProfile = Profile(
      name: "Default",
      autoActivation: .init(displayCount: .exactly(1)),
      workspaces: [defaultWorkspace],
    )
    let interviewProfile = Profile(
      name: "Interview",
      workspaces: [recent, previous],
    )
    let state = WorkspaceActivationFeature.State()
    state.$config.withLock {
      $0.profiles = [defaultProfile, interviewProfile]
      $0.activeProfileId = defaultProfile.id
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [display] }
    }
    store.exhaustivity = .off

    await store.send(.restoreStartupSession(
      lastUsedProfileId: interviewProfile.id,
      displayWorkspaceHistory: [
        display: [recent.id, defaultWorkspace.id, previous.id]
      ],
      workspaceMRU: [recent.id, defaultWorkspace.id, previous.id],
    ))

    #expect(store.state.config.activeProfileId == interviewProfile.id)
    #expect(store.state.previousWorkspacesByDisplay[display] == previous.id)
    #expect(store.state.displayWorkspaceHistory[display] == [
      recent.id,
      defaultWorkspace.id,
      previous.id,
    ])
  }

  @Test
  func `startup session falls back when the last profile condition does not match`() async {
    let display = DisplayName(uuid: "display-a", name: "Built-in")
    let laptop = Profile(
      name: "Laptop",
      autoActivation: .init(displayCount: .exactly(1)),
      workspaces: [Workspace(name: "Laptop")],
    )
    let dual = Profile(
      name: "Dual",
      autoActivation: .init(displayCount: .exactly(2)),
      workspaces: [Workspace(name: "Dual")],
    )
    let state = WorkspaceActivationFeature.State()
    state.$config.withLock {
      $0.profiles = [laptop, dual]
      $0.activeProfileId = dual.id
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [display] }
    }
    store.exhaustivity = .off

    await store.send(.restoreStartupSession(
      lastUsedProfileId: dual.id,
      displayWorkspaceHistory: [:],
      workspaceMRU: [],
    ))
    await store.receive {
      guard case .delegate(.startupProfileResolved(let id)) = $0 else { return false }
      return id == laptop.id
    }

    #expect(store.state.config.activeProfileId == laptop.id)
  }

  @Test
  func `initial activation restores the last workspace on every display`() async {
    let displayA = DisplayName(uuid: "display-a", name: "A")
    let displayB = DisplayName(uuid: "display-b", name: "B")
    let workspaceA = Workspace(name: "Workspace A")
    let workspaceB = Workspace(name: "Workspace B")
    let state = Self.makeState(workspaces: [workspaceA, workspaceB]) {
      $0.isTilingPaused = true
      $0.displayWorkspaceHistory = [
        displayA: [workspaceA.id],
        displayB: [workspaceB.id],
      ]
      $0.workspaceMRU = [workspaceB.id, workspaceA.id]
    }
    let requests = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.displays.all = { [displayA, displayB] }
      $0.workspaceManager.activate = { request in
        requests.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activateInitial)
    await store.receive(\.processDisplayRestores)
    await store.receive {
      guard case .restoreDisplay(let assignment) = $0 else { return false }
      return assignment.workspace == workspaceA.id && assignment.display == displayA
    }
    await store.receive {
      guard case .activationCompleted(let workspaceId, let display, _) = $0 else { return false }
      return workspaceId == workspaceA.id && display == displayA
    }
    await store.receive(\.processDisplayRestores)
    await store.receive {
      guard case .restoreDisplay(let assignment) = $0 else { return false }
      return assignment.workspace == workspaceB.id && assignment.display == displayB
    }
    await store.receive {
      guard case .activationCompleted(let workspaceId, let display, _) = $0 else { return false }
      return workspaceId == workspaceB.id && display == displayB
    }
    await store.finish()

    #expect(store.state.connectedDisplays == [displayA, displayB])
    #expect(store.state.activeWorkspacesByDisplay == [
      displayA: workspaceA.id,
      displayB: workspaceB.id,
    ])
    #expect(requests.value.map { $0.targetDisplay } == [displayA, displayB])
    #expect(requests.value.map(\.workspace.id) == [workspaceA.id, workspaceB.id])
  }

  @Test
  func `initial activation seeds an empty legacy session from the frontmost app`() async {
    let display = DisplayName(uuid: "display-a", name: "A")
    let first = Workspace(
      name: "First",
      apps: [AppAssignment(bundleIdentifier: "app.first", name: "First")],
    )
    let frontmost = Workspace(
      name: "Frontmost",
      apps: [AppAssignment(bundleIdentifier: "app.frontmost", name: "Frontmost")],
    )
    let state = Self.makeState(workspaces: [first, frontmost]) {
      $0.isTilingPaused = true
    }
    let requests = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.displays.all = { [display] }
      $0.displays.current = { display }
      $0.windowSnapshot.frontmostApp = {
        FrontmostApp(pid: 1, bundleId: "app.frontmost", name: "Frontmost")
      }
      $0.workspaceManager.activate = { request in
        requests.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activateInitial)
    await store.receive(\.processDisplayRestores)
    await store.receive {
      guard case .restoreDisplay(let assignment) = $0 else { return false }
      return assignment.workspace == frontmost.id && assignment.display == display
    }
    await store.receive {
      guard case .activationCompleted(let workspaceId, let owner, _) = $0 else { return false }
      return workspaceId == frontmost.id && owner == display
    }
    await store.finish()

    #expect(requests.value.last?.workspace.id == frontmost.id)
  }

  @Test
  func `activation watchdog releases the gate`() async {
    let ws1 = Workspace(name: "one")
    let state = Self.makeState(workspaces: [ws1]) {
      $0.isActivating = true
      $0.activationGeneration = 1
      $0.activeActivationGeneration = 1
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    }

    await store.send(.activationTimedOut(generation: 1)) {
      $0.isActivating = false
      $0.activeActivationGeneration = nil
    }
    // Idempotent when nothing is in flight.
    await store.send(.activationTimedOut(generation: 1))
  }

  @Test
  func `delayed shared outgoing focus snapshot repairs captured workspace MRU`() async {
    let displayB = DisplayName("B")
    let outgoing = WindowKey(pid: 1, windowID: 101, bundleId: "app.shared")
    let target = WindowKey(pid: 2, windowID: 202, bundleId: "app.target")
    let oldWorkspace = Workspace(name: "Old")
    let targetWorkspace = Workspace(
      name: "Target",
      apps: [AppAssignment(bundleIdentifier: target.bundleId, name: "Target")],
    )
    let state = Self.makeState(workspaces: [oldWorkspace, targetWorkspace]) {
      $0.$config.withLock {
        $0.sharedApps = [
          SharedApp(bundleIdentifier: outgoing.bundleId, name: "Shared", layout: .tiled)
        ]
      }
      $0.focusedDisplay = displayB
      $0.activeWorkspacesByDisplay = [displayB: targetWorkspace.id]
      $0.tilingTrees[oldWorkspace.id] = .leaf(outgoing)
      $0.tilingTrees[targetWorkspace.id] = .branch(
        BSPBranch(split: .vertical, ratio: 0.5, left: .leaf(target), right: .leaf(outgoing))
      )
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    }

    await store.send(.activationFocusSnapshotResolved(
      workspaceId: oldWorkspace.id,
      key: outgoing,
    )) {
      $0.insertionPoint[oldWorkspace.id] = outgoing
      $0.mruWindows[oldWorkspace.id] = [outgoing]
    }

    #expect(store.state.focusedDisplay == displayB)
  }

  @Test
  func `shared focus during activation updates target workspace MRU`() async {
    let figma = WindowKey(pid: 1, windowID: 101, bundleId: "com.figma.Desktop")
    let notion = WindowKey(pid: 2, windowID: 202, bundleId: "notion.id")
    let pulse = WindowKey(pid: 3, windowID: 303, bundleId: "kean.studio.pulse")
    let figmaWorkspace = Workspace(
      name: "Figma",
      apps: [AppAssignment(bundleIdentifier: figma.bundleId, name: "Figma")],
    )
    let notionWorkspace = Workspace(
      name: "Notion",
      apps: [AppAssignment(bundleIdentifier: notion.bundleId, name: "Notion")],
    )
    let state = Self.makeState(workspaces: [figmaWorkspace, notionWorkspace]) {
      $0.$config.withLock {
        $0.sharedApps = [
          SharedApp(bundleIdentifier: pulse.bundleId, name: "Pulse", layout: .tiled)
        ]
        $0.settings.focus.mouseFollowsFocus = false
      }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = figmaWorkspace.id
      $0.tilingTrees[figmaWorkspace.id] = .branch(
        BSPBranch(split: .vertical, ratio: 0.5, left: .leaf(figma), right: .leaf(pulse))
      )
      $0.tilingTrees[notionWorkspace.id] = .branch(
        BSPBranch(split: .vertical, ratio: 0.5, left: .leaf(notion), right: .leaf(pulse))
      )
      $0.mruWindows[figmaWorkspace.id] = [figma, pulse]
      $0.mruWindows[notionWorkspace.id] = [notion, pulse]
      $0.lastObservedFocusedWindow = figma
      $0.isActivating = true
      $0.activatingWorkspaceID = notionWorkspace.id
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    }

    await store.send(
      .windowChanged(.windowFocused(bundleId: pulse.bundleId, key: pulse))
    ) {
      $0.insertionPoint[notionWorkspace.id] = pulse
      $0.mruWindows[notionWorkspace.id] = [pulse, notion]
      $0.lastObservedFocusedWindow = pulse
    }
  }

  @Test
  func `in flight focus keeps the captured activation display before placement commits`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let figma = WindowKey(pid: 1, windowID: 101, bundleId: "com.figma.Desktop")
    let pulse = WindowKey(pid: 2, windowID: 202, bundleId: "kean.studio.pulse")
    let figmaWorkspace = Workspace(
      name: "Figma",
      apps: [AppAssignment(bundleIdentifier: figma.bundleId, name: "Figma")],
    )
    let targetWorkspace = Workspace(name: "Target")
    let state = Self.makeState(workspaces: [figmaWorkspace, targetWorkspace]) {
      $0.$config.withLock {
        $0.sharedApps = [
          SharedApp(bundleIdentifier: pulse.bundleId, name: "Pulse", layout: .tiled)
        ]
        $0.settings.focus.mouseFollowsFocus = false
      }
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay[displayA] = figmaWorkspace.id
      $0.tilingTrees[figmaWorkspace.id] = .branch(
        BSPBranch(split: .vertical, ratio: 0.5, left: .leaf(figma), right: .leaf(pulse))
      )
      $0.tilingTrees[targetWorkspace.id] = .leaf(pulse)
      $0.isActivating = true
      $0.activatingWorkspaceID = targetWorkspace.id
      $0.activatingDisplay = displayB
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    }

    await store.send(
      .windowChanged(.windowFocused(bundleId: pulse.bundleId, key: pulse))
    ) {
      $0.focusedDisplay = displayB
      $0.insertionPoint[targetWorkspace.id] = pulse
      $0.mruWindows[targetWorkspace.id] = [pulse]
      $0.lastObservedFocusedWindow = pulse
    }
  }

  @Test
  func `shared only floating focus does not replace workspace MRU`() async {
    let own = WindowKey(pid: 1, windowID: 101, bundleId: "app.own")
    let shared = WindowKey(pid: 2, windowID: 202, bundleId: "app.shared")
    let ws = Workspace(
      name: "one",
      apps: [AppAssignment(bundleIdentifier: own.bundleId, name: "Own")],
    )
    let state = Self.makeState(workspaces: [ws]) {
      $0.$config.withLock {
        $0.sharedApps = [
          SharedApp(bundleIdentifier: shared.bundleId, name: "Shared", layout: .floating)
        ]
      }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = ws.id
      $0.tilingTrees[ws.id] = .leaf(own)
      $0.mruWindows[ws.id] = [own]
    }
    let scans = LockIsolated(0)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.windowSnapshot.discoverKeys = { _, _ in
        scans.withValue { $0 += 1 }
        return [shared]
      }
    }
    store.exhaustivity = .off

    await store.send(
      .windowChanged(.windowFocused(bundleId: shared.bundleId, key: shared))
    )

    #expect(store.state.mruWindows[ws.id] == [own])
    #expect(scans.value == 0)
  }

  @Test
  func `tree replacement prunes closed windows from MRU`() async {
    let closed = WindowKey(pid: 1, windowID: 101, bundleId: "app.one")
    let survivor = WindowKey(pid: 1, windowID: 102, bundleId: "app.one")
    let ws = Workspace(name: "one")
    let state = Self.makeState(workspaces: [ws]) {
      $0.tilingTrees[ws.id] = .branch(
        BSPBranch(
          split: .vertical,
          ratio: 0.5,
          left: .leaf(closed),
          right: .leaf(survivor),
        )
      )
      $0.mruWindows[ws.id] = [closed, survivor]
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    }
    store.exhaustivity = .off

    await store.send(.tilingTreeUpdated(workspaceId: ws.id, tree: .leaf(survivor)))

    #expect(store.state.mruWindows[ws.id] == [survivor])
  }

  @Test
  func `app termination prunes non tiled MRU windows`() async {
    let floating = WindowKey(pid: 1, windowID: 101, bundleId: "app.float")
    let survivor = WindowKey(pid: 2, windowID: 202, bundleId: "app.own")
    let ws = Workspace(name: "one")
    let state = Self.makeState(workspaces: [ws]) {
      $0.mruWindows[ws.id] = [floating, survivor]
    }
    let invalidatedBundles = LockIsolated<[String]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.windowSnapshot.invalidateBundle = { bundleId in
        invalidatedBundles.withValue { $0.append(bundleId) }
      }
    }
    store.exhaustivity = .off

    await store.send(.appTerminated(bundleId: floating.bundleId))

    #expect(store.state.mruWindows[ws.id] == [survivor])
    #expect(invalidatedBundles.value == [floating.bundleId])
    await store.skipReceivedActions()
  }

  @Test
  func `focus echo does not replace pending center warp`() async {
    let key = WindowKey(pid: 1, windowID: 101, bundleId: "app.one")
    let ws = Workspace(
      name: "one",
      apps: [AppAssignment(bundleIdentifier: key.bundleId, name: "One")],
    )
    let state = Self.makeState(workspaces: [ws]) {
      $0.$config.withLock { $0.settings.focus.mouseFollowsFocus = true }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = ws.id
      $0.tilingTrees[ws.id] = .leaf(key)
      $0.pendingCenterWarps[ws.id] = key
    }
    let warped = LockIsolated<[CGPoint]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.mouse.axLocation = { CGPoint(x: 960, y: 540) }
      $0.mouse.warp = { point in warped.withValue { $0.append(point) } }
    }
    store.exhaustivity = .off

    await store.send(.windowChanged(.windowFocused(bundleId: key.bundleId, key: key)))

    #expect(warped.value.isEmpty)
    #expect(store.state.pendingCenterWarps[ws.id] == key)
  }

  @Test
  func `observer readiness recovers first focus for mouse follows focus`() async {
    let terminal = WindowKey(pid: 1, windowID: 101, bundleId: "org.alacritty")
    let notion = WindowKey(pid: 2, windowID: 202, bundleId: "com.cron.electron")
    let workspace = Workspace(
      name: "Terminal",
      apps: [
        AppAssignment(bundleIdentifier: terminal.bundleId, name: "Alacritty"),
        AppAssignment(bundleIdentifier: notion.bundleId, name: "Notion Calendar"),
      ],
    )
    let state = Self.makeState(workspaces: [workspace]) {
      $0.$config.withLock { $0.settings.focus.mouseFollowsFocus = true }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = .branch(
        BSPBranch(
          split: .vertical,
          ratio: 0.5,
          left: .leaf(terminal),
          right: .leaf(notion),
        )
      )
      $0.lastObservedFocusedWindow = terminal
      // Keep the membership reconcile inert; this test isolates the focus edge
      // recovered when the observer becomes ready.
      $0.isTilingPaused = true
    }
    let warped = LockIsolated<[CGPoint]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.windowSnapshot.focusedWindowKeyAsync = { .value(notion) }
      $0.displays.workArea = { _ in
        CGRect(x: 0, y: 0, width: 1_000, height: 800)
      }
      $0.mouse.axLocation = { .zero }
      $0.mouse.warp = { point in warped.withValue { $0.append(point) } }
    }
    store.exhaustivity = .off

    await store.send(
      .windowChanged(.observationReady(bundleId: notion.bundleId))
    )
    await store.receive {
      guard
        case .windowChanged(
          .windowFocused(bundleId: let bundleId, pid: _, key: let key)
        ) = $0
      else { return false }
      return bundleId == notion.bundleId && key == notion
    }
    await store.finish()

    #expect(store.state.lastObservedFocusedWindow == notion)
    #expect(warped.value == [CGPoint(x: 748, y: 400)])
  }

  @Test
  func `first focused transient enters MRU when its sync inserts it`() async {
    let slack = WindowKey(pid: 1, windowID: 101, bundleId: "com.tinyspeck.slackmacgap")
    let notion = WindowKey(pid: 2, windowID: 202, bundleId: "com.cron.electron")
    let workspace = Workspace(
      name: "Slack",
      apps: [AppAssignment(bundleIdentifier: slack.bundleId, name: "Slack")],
    )
    let state = Self.makeState(workspaces: [workspace]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = .leaf(slack)
      $0.mruWindows[workspace.id] = [slack]
      // Notion's first AX focus arrived before its unregistered window became
      // an authoritative transient member of this tree.
      $0.lastObservedFocusedWindow = notion
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in
        CGRect(x: 0, y: 0, width: 1_000, height: 800)
      }
    }
    store.exhaustivity = .off

    await store.send(.syncAppWindowsResolved(
      bundleId: notion.bundleId,
      resizableKeys: [notion],
      onScreenFrames: [
        slack.windowID: CGRect(x: 0, y: 0, width: 1_000, height: 800),
        notion.windowID: CGRect(x: 500, y: 0, width: 500, height: 800),
      ],
    ))
    await store.finish()

    #expect(store.state.tilingTrees[workspace.id]?.windows.contains(notion) == true)
    #expect(store.state.mruWindows[workspace.id] == [notion, slack])
  }

  @Test
  func `first valid sync restores fullscreen slots missed by startup discovery`() async {
    let first = WindowKey(pid: 42, windowID: 101, bundleId: "company.thebrowser.dia")
    let second = WindowKey(pid: 42, windowID: 202, bundleId: first.bundleId)
    let workspace = Workspace(
      name: "Browser",
      apps: [AppAssignment(bundleIdentifier: first.bundleId, name: "Dia")],
    )
    let state = Self.makeState(workspaces: [workspace]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
    }
    let persistedSlots: Set<SlotID> = [
      SlotID(bundleId: first.bundleId, occurrence: 0),
      SlotID(bundleId: first.bundleId, occurrence: 1),
    ]
    let applications = LockIsolated<[FrameApplication]>([])
    let saved = LockIsolated<[LayoutSnapshot]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in
        CGRect(x: 0, y: 0, width: 1_000, height: 800)
      }
      $0.windowTiler.apply = { request in
        applications.withValue { $0.append(request) }
      }
      $0.layoutStore.save = { _, snapshot in
        saved.withValue { $0.append(snapshot) }
      }
    }
    store.exhaustivity = .off

    await store.send(.persistedFullscreenZoomRestored(
      workspaceId: workspace.id,
      keys: [],
      unresolvedSlots: persistedSlots,
    ))
    await store.send(.syncAppWindowsResolved(
      bundleId: first.bundleId,
      resizableKeys: [first, second],
      onScreenFrames: [
        first.windowID: CGRect(x: 0, y: 0, width: 500, height: 800),
        second.windowID: CGRect(x: 500, y: 0, width: 500, height: 800),
      ],
    ))
    await store.finish()

    #expect(store.state.tilingTrees[workspace.id]?.windows == [first, second])
    #expect(store.state.fullscreenZoomed[workspace.id] == [first, second])
    #expect(store.state.unresolvedFullscreenZoomSlots[workspace.id] == nil)
    #expect(
      applications.value.last?.windowFrames[first]
        == applications.value.last?.windowFrames[second]
    )
    #expect(applications.value.last?.forceAllFrames == true)
    #expect(Set(saved.value.last?.fullscreenZoomedSlots ?? []) == persistedSlots)
  }

  @Test
  func `stale focus echo cannot cancel newer center warp`() async {
    let target = WindowKey(pid: 1, windowID: 101, bundleId: "app.one")
    let stale = WindowKey(pid: 2, windowID: 202, bundleId: "app.two")
    let ws = Workspace(
      name: "one",
      apps: [
        AppAssignment(bundleIdentifier: target.bundleId, name: "One"),
        AppAssignment(bundleIdentifier: stale.bundleId, name: "Two"),
      ],
    )
    let state = Self.makeState(workspaces: [ws]) {
      $0.$config.withLock { $0.settings.focus.mouseFollowsFocus = true }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = ws.id
      $0.tilingTrees[ws.id] = .branch(
        BSPBranch(
          split: .vertical,
          ratio: 0.5,
          left: .leaf(target),
          right: .leaf(stale),
        )
      )
      $0.pendingCenterWarps[ws.id] = target
    }
    let warped = LockIsolated<[CGPoint]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.mouse.axLocation = { .zero }
      $0.mouse.warp = { point in warped.withValue { $0.append(point) } }
    }
    store.exhaustivity = .off

    await store.send(.windowChanged(.windowFocused(bundleId: stale.bundleId, key: stale)))

    #expect(store.state.pendingCenterWarps[ws.id] == target)
    #expect(warped.value.isEmpty)
  }

  @Test
  func `duplicate focused window notification cannot revive MFF`() async {
    let focused = WindowKey(pid: 1, windowID: 101, bundleId: "app.one")
    let other = WindowKey(pid: 2, windowID: 202, bundleId: "app.two")
    let ws = Workspace(
      name: "one",
      apps: [
        AppAssignment(bundleIdentifier: focused.bundleId, name: "One"),
        AppAssignment(bundleIdentifier: other.bundleId, name: "Two"),
      ],
    )
    let state = Self.makeState(workspaces: [ws]) {
      $0.$config.withLock { $0.settings.focus.mouseFollowsFocus = true }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = ws.id
      $0.tilingTrees[ws.id] = .branch(
        BSPBranch(
          split: .vertical,
          ratio: 0.5,
          left: .leaf(focused),
          right: .leaf(other),
        )
      )
    }
    let cursor = LockIsolated(CGPoint(x: 960, y: 540))
    let warped = LockIsolated<[CGPoint]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.mouse.axLocation = { cursor.value }
      $0.mouse.warp = { point in
        warped.withValue { $0.append(point) }
        cursor.setValue(point)
      }
    }
    store.exhaustivity = .off

    await store.send(.windowChanged(.windowFocused(bundleId: focused.bundleId, key: focused)))
    #expect(warped.value.count == 1)

    // The user moves after the first focus transition. A delayed duplicate AX
    // notification must not interpret that pointer movement as a new MFF job.
    cursor.setValue(CGPoint(x: 960, y: 540))
    await store.send(.windowChanged(.windowFocused(bundleId: focused.bundleId, key: focused)))

    #expect(warped.value.count == 1)
    #expect(store.state.lastObservedFocusedWindow == focused)
  }

  @Test
  func `FFM focus echo never feeds back into MFF`() async {
    let focused = WindowKey(pid: 1, windowID: 101, bundleId: "app.one")
    let other = WindowKey(pid: 2, windowID: 202, bundleId: "app.two")
    let ws = Workspace(
      name: "one",
      apps: [
        AppAssignment(bundleIdentifier: focused.bundleId, name: "One"),
        AppAssignment(bundleIdentifier: other.bundleId, name: "Two"),
      ],
    )
    let state = Self.makeState(workspaces: [ws]) {
      $0.$config.withLock { $0.settings.focus.mouseFollowsFocus = true }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = ws.id
      $0.tilingTrees[ws.id] = .branch(
        BSPBranch(
          split: .vertical,
          ratio: 0.5,
          left: .leaf(focused),
          right: .leaf(other),
        )
      )
      $0.lastObservedFocusedWindow = other
    }
    let warped = LockIsolated<[CGPoint]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.displays.workArea = { _ in CGRect(x: 0, y: 0, width: 1_000, height: 800) }
      $0.focusEventOrigin.consumePointerDrivenFocus = { windowID in
        windowID == focused.windowID
      }
      $0.mouse.axLocation = { .zero }
      $0.mouse.warp = { point in warped.withValue { $0.append(point) } }
    }
    store.exhaustivity = .off

    await store.send(.windowChanged(.windowFocused(bundleId: focused.bundleId, key: focused)))

    #expect(warped.value.isEmpty)
    #expect(store.state.lastObservedFocusedWindow == focused)
  }

  @Test
  func `post layout MFF drops a target that no longer owns focus`() async {
    let stale = WindowKey(pid: 1, windowID: 101, bundleId: "app.one")
    let live = WindowKey(pid: 2, windowID: 202, bundleId: "app.two")
    let ws = Workspace(
      name: "one",
      apps: [
        AppAssignment(bundleIdentifier: stale.bundleId, name: "One"),
        AppAssignment(bundleIdentifier: live.bundleId, name: "Two"),
      ],
    )
    let state = Self.makeState(workspaces: [ws]) {
      $0.$config.withLock { $0.settings.focus.mouseFollowsFocus = true }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = ws.id
      $0.tilingTrees[ws.id] = .branch(
        BSPBranch(
          split: .vertical,
          ratio: 0.5,
          left: .leaf(stale),
          right: .leaf(live),
        )
      )
    }
    let warped = LockIsolated<[CGPoint]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.windowSnapshot.focusedWindowKey = { live }
      $0.windowSnapshot.windowFrame = { _ in
        CGRect(x: 0, y: 0, width: 500, height: 800)
      }
      $0.mouse.warp = { point in warped.withValue { $0.append(point) } }
    }
    store.exhaustivity = .off

    await store.send(
      .settleFocusAfterLayout(
        windowKey: stale,
        workspaceId: ws.id,
        shouldFocus: false,
      )
    )
    await store.receive {
      guard case .cursorWarpFinished(let workspaceId, let target) = $0 else {
        return false
      }
      return workspaceId == ws.id && target == stale
    }

    #expect(warped.value.isEmpty)
    #expect(store.state.pendingCenterWarps[ws.id] == nil)
  }

  @Test
  func `app assigned only in inactive profile tiles transiently`() async {
    let key = WindowKey(pid: 1, windowID: 101, bundleId: "app.inactive-profile")
    let activeWorkspace = Workspace(name: "Active")
    let inactiveWorkspace = Workspace(
      name: "Inactive",
      apps: [AppAssignment(bundleIdentifier: key.bundleId, name: "Inactive app")],
    )
    let inactiveProfile = Profile(
      name: "Inactive",
      workspaces: IdentifiedArray(uniqueElements: [inactiveWorkspace]),
    )
    let state = Self.makeState(workspaces: [activeWorkspace]) {
      $0.$config.withLock {
        $0.activeProfileId = $0.profiles.first?.id
        $0.profiles.append(inactiveProfile)
      }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = activeWorkspace.id
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.windowSnapshot.discoverKeys = { _, _ in [key] }
      $0.windowSnapshot.focusedWindowKey = { key }
    }

    await store.send(.syncAppWindows(bundleId: key.bundleId)) {
      $0.windowSyncBundleIdsInFlight.insert(key.bundleId)
    }
    await store.receive(\.syncAppWindowsResolved) {
      $0.windowSyncBundleIdsInFlight.remove(key.bundleId)
      $0.insertionPoint[activeWorkspace.id] = key
      $0.tilingTrees[activeWorkspace.id] = .leaf(key)
      $0.layoutWriteGeneration = 1
      $0.activeLayoutWriteGenerations.insert(1)
    }
    await store.receive(\.layoutWriteFinished) {
      $0.activeLayoutWriteGenerations.remove(1)
    }
    await store.finish()
  }

  @Test
  func `mixed tiled and unmanaged sync requests one capability discovery`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let bundleId = "app.mixed-capabilities"
    let tiledWorkspace = Workspace(
      name: "Tiled",
      apps: [AppAssignment(bundleIdentifier: bundleId, name: "Mixed")],
    )
    let unmanagedWorkspace = Workspace(
      name: "Unmanaged",
      apps: [
        AppAssignment(
          bundleIdentifier: bundleId,
          name: "Mixed",
          layout: .unmanaged,
        )
      ],
    )
    let sentinel = WindowKey(pid: 2, windowID: 200, bundleId: "app.sentinel")
    let state = Self.makeState(workspaces: [tiledWorkspace, unmanagedWorkspace]) {
      $0.connectedDisplays = [displayA, displayB]
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [
        displayA: tiledWorkspace.id,
        displayB: unmanagedWorkspace.id,
      ]
      // Keep the unmanaged workspace non-empty so this test observes only the
      // app-sync discovery, not its separate empty-workspace presence check.
      $0.tilingTrees[unmanagedWorkspace.id] = .leaf(sentinel)
    }
    let capabilityCalls = LockIsolated(0)
    let legacyCalls = LockIsolated<[Bool]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.windowSnapshot.discoverCapabilitiesAsync = { bundleIds in
        #expect(bundleIds == [bundleId])
        capabilityCalls.withValue { $0 += 1 }
        return .value(WindowCapabilitySnapshot(
          movableKeys: [],
          resizableKeys: [],
        ))
      }
      $0.windowSnapshot.discoverKeysAsync = { _, requireResizable in
        legacyCalls.withValue { $0.append(requireResizable) }
        return .value([])
      }
      $0.windowSnapshot.discoverKeys = { _, requireResizable in
        legacyCalls.withValue { $0.append(requireResizable) }
        return []
      }
    }

    await store.send(.syncAppWindows(bundleId: bundleId)) {
      $0.windowSyncBundleIdsInFlight.insert(bundleId)
    }
    await store.receive(\.syncAppWindowsResolved) {
      $0.windowSyncBundleIdsInFlight.remove(bundleId)
    }
    await store.finish()

    #expect(capabilityCalls.value == 1)
    #expect(legacyCalls.value.isEmpty)
  }

  @Test
  func `capability discovery preserves legacy dependency fallback`() async {
    let movableOnly = WindowKey(pid: 1, windowID: 101, bundleId: "app.fixed")
    let resizable = WindowKey(pid: 1, windowID: 102, bundleId: movableOnly.bundleId)
    let calls = LockIsolated<[Bool]>([])
    var snapshot = WindowSnapshotClient.testValue
    snapshot.discoverKeys = { _, requireResizable in
      calls.withValue { $0.append(requireResizable) }
      return requireResizable ? [resizable] : [movableOnly, resizable]
    }

    let capabilities = await snapshot.discoverCapabilitiesOffMain([
      movableOnly.bundleId
    ])

    #expect(capabilities.movableKeys == [movableOnly, resizable])
    #expect(capabilities.resizableKeys == [resizable])
    #expect(calls.value.count == 2)
    #expect(Set(calls.value) == [false, true])
  }

  @Test
  func `dirty app sync skips stale result and applies one trailing discovery`() async {
    let stale = WindowKey(pid: 1, windowID: 101, bundleId: "app.sync")
    let fresh = WindowKey(pid: 1, windowID: 102, bundleId: stale.bundleId)
    let workspace = Workspace(
      name: "Active",
      apps: [AppAssignment(bundleIdentifier: stale.bundleId, name: "Sync")],
    )
    let state = Self.makeState(workspaces: [workspace]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.windowSyncBundleIdsInFlight.insert(stale.bundleId)
      $0.dirtyWindowSyncBundleIds.insert(stale.bundleId)
    }
    let frame = CGRect(x: 0, y: 0, width: 500, height: 800)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.windowSnapshot.discoverKeys = { _, _ in [fresh] }
      $0.windowSnapshot.onScreenWindowFrames = { [fresh.windowID: frame] }
    }

    await store.send(.syncAppWindowsResolved(
      bundleId: stale.bundleId,
      resizableKeys: [stale],
      onScreenFrames: [stale.windowID: frame],
    )) {
      $0.windowSyncBundleIdsInFlight.remove(stale.bundleId)
      $0.dirtyWindowSyncBundleIds.remove(stale.bundleId)
    }
    await store.receive(\.syncAppWindows) {
      $0.windowSyncBundleIdsInFlight.insert(stale.bundleId)
    }
    await store.receive(\.syncAppWindowsResolved) {
      $0.windowSyncBundleIdsInFlight.remove(stale.bundleId)
      $0.insertionPoint[workspace.id] = fresh
      $0.tilingTrees[workspace.id] = .leaf(fresh)
      $0.layoutWriteGeneration = 1
      $0.activeLayoutWriteGenerations.insert(1)
    }
    await store.receive(\.layoutWriteFinished) {
      $0.activeLayoutWriteGenerations.remove(1)
    }
    await store.finish()
  }

  @Test
  func `close sync retiles then focuses and warps to live center`() async {
    let closed = WindowKey(pid: 1, windowID: 101, bundleId: "app.one")
    let survivor = WindowKey(pid: 1, windowID: 102, bundleId: "app.one")
    let ws = Workspace(
      name: "one",
      apps: [AppAssignment(bundleIdentifier: closed.bundleId, name: "One")],
    )
    let state = Self.makeState(workspaces: [ws]) {
      $0.$config.withLock {
        $0.settings.focus.mouseFollowsFocus = true
        $0.settings.focus.refocusOnClose = true
      }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = ws.id
      $0.tilingTrees[ws.id] = .branch(
        BSPBranch(
          split: .vertical,
          ratio: 0.5,
          left: .leaf(closed),
          right: .leaf(survivor),
        )
      )
      $0.mruWindows[ws.id] = [closed, survivor]
    }
    let order = LockIsolated<[String]>([])
    let warped = LockIsolated<[CGPoint]>([])
    let liveFrame = CGRect(x: 120, y: 240, width: 600, height: 400)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.windowSnapshot.discoverKeys = { _, _ in [survivor] }
      $0.windowSnapshot.focusedWindowKey = { nil }
      $0.windowSnapshot.windowFrame = { key in
        #expect(key == survivor)
        order.withValue { $0.append("frame") }
        return liveFrame
      }
      $0.windowTiler.apply = { request in
        #expect(Set(request.windowFrames.keys) == [survivor])
        order.withValue { $0.append("layout") }
      }
      $0.focusManager.focusWindow = { key in
        #expect(key == survivor)
        order.withValue { $0.append("focus") }
      }
      $0.mouse.warp = { point in
        order.withValue { $0.append("warp") }
        warped.withValue { $0.append(point) }
      }
    }
    store.exhaustivity = .off

    await store.send(.syncAppWindows(bundleId: closed.bundleId))
    await store.receive {
      guard case .cursorWarpFinished(let workspaceId, let target) = $0 else { return false }
      return workspaceId == ws.id && target == survivor
    }
    await store.finish()

    #expect(order.value == ["layout", "focus", "frame", "warp"])
    #expect(warped.value == [CGPoint(x: liveFrame.midX, y: liveFrame.midY)])
    #expect(store.state.pendingCenterWarps[ws.id] == nil)
  }

  @Test
  func `hidden close prune retiles then warps focused survivor to live center`() async {
    let closed = WindowKey(pid: 1, windowID: 101, bundleId: "app.one")
    let survivor = WindowKey(pid: 1, windowID: 102, bundleId: "app.one")
    let ws = Workspace(
      name: "one",
      apps: [AppAssignment(bundleIdentifier: closed.bundleId, name: "One")],
    )
    let state = Self.makeState(workspaces: [ws]) {
      $0.$config.withLock {
        $0.settings.focus.mouseFollowsFocus = true
        $0.settings.focus.refocusOnClose = true
      }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = ws.id
      $0.tilingTrees[ws.id] = .branch(
        BSPBranch(
          split: .vertical,
          ratio: 0.5,
          left: .leaf(closed),
          right: .leaf(survivor),
        )
      )
      $0.mruWindows[ws.id] = [closed, survivor]
      $0.lastObservedFocusedWindow = survivor
    }
    let order = LockIsolated<[String]>([])
    let warped = LockIsolated<[CGPoint]>([])
    let invalidated = LockIsolated<Set<CGWindowID>>([])
    let liveFrame = CGRect(x: -1680, y: 90, width: 800, height: 700)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.windowSnapshot.onScreenWindowIDs = { [survivor.windowID] }
      $0.windowSnapshot.focusedWindowKey = { survivor }
      $0.windowSnapshot.invalidateWindowIDs = { ids in
        invalidated.withValue { $0.formUnion(ids) }
      }
      $0.windowSnapshot.windowFrame = { key in
        #expect(key == survivor)
        order.withValue { $0.append("frame") }
        return liveFrame
      }
      $0.windowTiler.apply = { request in
        #expect(Set(request.windowFrames.keys) == [survivor])
        order.withValue { $0.append("layout") }
      }
      $0.focusManager.focusWindow = { key in
        #expect(key == survivor)
        order.withValue { $0.append("focus") }
      }
      $0.mouse.warp = { point in
        order.withValue { $0.append("warp") }
        warped.withValue { $0.append(point) }
      }
    }
    store.exhaustivity = .off

    await store.send(.pruneOffscreenWindows)
    await store.receive {
      guard case .cursorWarpFinished(let workspaceId, let target) = $0 else { return false }
      return workspaceId == ws.id && target == survivor
    }
    await store.finish()

    #expect(order.value == ["layout", "frame", "warp"])
    #expect(warped.value == [CGPoint(x: liveFrame.midX, y: liveFrame.midY)])
    #expect(invalidated.value == [closed.windowID])
    #expect(store.state.pendingCenterWarps[ws.id] == nil)
  }

  @Test
  func `no-op sync preserves a resized ratio with auto balance enabled`() async {
    let slack = WindowKey(pid: 1, windowID: 101, bundleId: "app.slack")
    let discord = WindowKey(pid: 2, windowID: 202, bundleId: "app.discord")
    let workspace = Workspace(
      name: "Chat",
      apps: [
        AppAssignment(bundleIdentifier: slack.bundleId, name: "Slack"),
        AppAssignment(bundleIdentifier: discord.bundleId, name: "Discord"),
      ],
    )
    let tree = BSPNode<WindowKey>.branch(
      BSPBranch(
        split: .vertical,
        ratio: 0.6,
        left: .leaf(slack),
        right: .leaf(discord),
      )
    )
    let workArea = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let state = Self.makeState(workspaces: [workspace]) {
      $0.$config.withLock {
        $0.settings.layout.autoBalance = .both
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
      }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = tree
    }
    let applications = LockIsolated<[FrameApplication]>([])
    let saved = LockIsolated<[LayoutSnapshot]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in workArea }
      $0.windowTiler.apply = { application in
        applications.withValue { $0.append(application) }
      }
      $0.layoutStore.save = { _, snapshot in
        saved.withValue { $0.append(snapshot) }
      }
    }
    store.exhaustivity = .off

    await store.send(.syncAppWindowsResolved(
      bundleId: slack.bundleId,
      resizableKeys: [slack],
      onScreenFrames: [
        slack.windowID: CGRect(x: 0, y: 0, width: 600, height: 800),
        discord.windowID: CGRect(x: 600, y: 0, width: 400, height: 800),
      ],
    ))
    await store.finish()

    #expect(store.state.tilingTrees[workspace.id] == tree)
    #expect(applications.value.isEmpty)
    #expect(saved.value.isEmpty)
  }

  @Test
  func `surface replacement preserves a resized ratio with auto balance enabled`() async throws {
    let survivor = WindowKey(pid: 1, windowID: 101, bundleId: "app.survivor")
    let retired = WindowKey(pid: 2, windowID: 202, bundleId: "app.tabs")
    let replacement = WindowKey(pid: 2, windowID: 303, bundleId: retired.bundleId)
    let workspace = Workspace(
      name: "Work",
      apps: [
        AppAssignment(bundleIdentifier: survivor.bundleId, name: "Survivor"),
        AppAssignment(bundleIdentifier: retired.bundleId, name: "Tabs"),
      ],
    )
    let oldTree = BSPNode<WindowKey>.branch(
      BSPBranch(
        split: .vertical,
        ratio: 0.37,
        left: .leaf(survivor),
        right: .leaf(retired),
      )
    )
    let expectedTree = oldTree.mapWindows { $0 == retired ? replacement : $0 }
    let workArea = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let state = Self.makeState(workspaces: [workspace]) {
      $0.$config.withLock {
        $0.settings.layout.autoBalance = .both
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
      }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = oldTree
      $0.insertionPoint[workspace.id] = retired
      $0.mruWindows[workspace.id] = [retired, survivor]
    }
    let applications = LockIsolated<[FrameApplication]>([])
    let saved = LockIsolated<[LayoutSnapshot]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in workArea }
      $0.windowTiler.apply = { application in
        applications.withValue { $0.append(application) }
      }
      $0.layoutStore.save = { _, snapshot in
        saved.withValue { $0.append(snapshot) }
      }
    }
    store.exhaustivity = .off

    await store.send(.syncAppWindowsResolved(
      bundleId: retired.bundleId,
      resizableKeys: [replacement],
      onScreenFrames: [
        survivor.windowID: CGRect(x: 0, y: 0, width: 370, height: 800),
        replacement.windowID: CGRect(x: 370, y: 0, width: 630, height: 800),
      ],
    ))
    await store.finish()

    #expect(store.state.tilingTrees[workspace.id] == expectedTree)
    #expect(store.state.insertionPoint[workspace.id] == replacement)
    #expect(store.state.mruWindows[workspace.id] == [replacement, survivor])
    #expect(applications.value.count == 1)
    let application = try #require(applications.value.last)
    let survivorFrame = try #require(application.windowFrames[survivor])
    let replacementFrame = try #require(application.windowFrames[replacement])
    let totalWidth = survivorFrame.width + replacementFrame.width
    #expect(abs(survivorFrame.width / totalWidth - 0.37) < 0.001)
    let slots = slotAssignment(expectedTree.windows)
    #expect(saved.value.count == 1)
    #expect(saved.value.last?.tree == expectedTree.mapWindows { slots[$0]! })
  }

  @Test
  func `new window sync still applies auto balance`() async {
    let first = WindowKey(pid: 1, windowID: 101, bundleId: "app.first")
    let second = WindowKey(pid: 2, windowID: 202, bundleId: "app.second")
    let inserted = WindowKey(pid: 3, windowID: 303, bundleId: "app.inserted")
    let workspace = Workspace(
      name: "Work",
      apps: [
        AppAssignment(bundleIdentifier: first.bundleId, name: "First"),
        AppAssignment(bundleIdentifier: second.bundleId, name: "Second"),
        AppAssignment(bundleIdentifier: inserted.bundleId, name: "Inserted"),
      ],
    )
    let oldTree = BSPNode<WindowKey>.branch(
      BSPBranch(
        split: .vertical,
        ratio: 0.8,
        left: .leaf(first),
        right: .leaf(second),
      )
    )
    let workArea = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let unbalancedTree = oldTree.inserting(
      inserted,
      near: second,
      in: workArea,
      viewSplitType: .vertical,
      globalPlacement: .second,
    )
    let expectedTree = unbalancedTree.balanced(axis: .both)
    let state = Self.makeState(workspaces: [workspace]) {
      $0.$config.withLock {
        $0.settings.layout.autoBalance = .both
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
        $0.settings.layout.splitType = .vertical
        $0.settings.layout.windowPlacement = .second
      }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = oldTree
      $0.insertionPoint[workspace.id] = second
      $0.lastObservedFocusedWindow = second
    }
    let applications = LockIsolated<[FrameApplication]>([])
    let saved = LockIsolated<[LayoutSnapshot]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in workArea }
      $0.windowTiler.apply = { application in
        applications.withValue { $0.append(application) }
      }
      $0.layoutStore.save = { _, snapshot in
        saved.withValue { $0.append(snapshot) }
      }
    }
    store.exhaustivity = .off

    await store.send(.syncAppWindowsResolved(
      bundleId: inserted.bundleId,
      resizableKeys: [inserted],
      onScreenFrames: [
        first.windowID: CGRect(x: 0, y: 0, width: 800, height: 800),
        second.windowID: CGRect(x: 800, y: 0, width: 200, height: 800),
        inserted.windowID: CGRect(x: 800, y: 0, width: 200, height: 800),
      ],
    ))
    await store.finish()

    #expect(unbalancedTree != expectedTree)
    #expect(store.state.tilingTrees[workspace.id] == expectedTree)
    #expect(applications.value.count == 1)
    let slots = slotAssignment(expectedTree.windows)
    #expect(saved.value.count == 1)
    #expect(saved.value.last?.tree == expectedTree.mapWindows { slots[$0]! })
  }

  @Test
  func `system suspend preserves the live tree through WindowServer teardown`() async {
    let first = WindowKey(pid: 1, windowID: 101, bundleId: "app.first")
    let second = WindowKey(pid: 2, windowID: 202, bundleId: "app.second")
    let workspace = Workspace(name: "Sleep")
    let tree = BSPNode<WindowKey>.branch(
      BSPBranch(
        split: .vertical,
        ratio: 0.7,
        left: .leaf(first),
        right: .leaf(second),
      )
    )
    let state = Self.makeState(workspaces: [workspace]) {
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = tree
    }
    let invalidated = LockIsolated<Set<CGWindowID>>([])
    let saved = LockIsolated<[LayoutSnapshot]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.layoutStore.save = { _, snapshot in
        saved.withValue { $0.append(snapshot) }
      }
      $0.windowSnapshot.invalidateWindowIDs = { ids in
        invalidated.withValue { $0.formUnion(ids) }
      }
      $0.windowSnapshot.onScreenWindowIDs = { [] }
    }

    await store.send(.systemWillSuspend) {
      $0.layoutSuspensionReasons = [.systemSleep]
      $0.suspendedLayoutWindows[workspace.id] = [first, second]
    }
    await store.send(.windowServerWindowEvent(.terminated(first.windowID)))
    await store.send(.windowServerWindowEvent(.becameInvisible(second.windowID)))
    await store.finish()

    #expect(store.state.tilingTrees[workspace.id] == tree)
    #expect(invalidated.value == [first.windowID])
    #expect(saved.value.isEmpty)
  }

  @Test
  func `screen lock rejects transient empty AX snapshots`() async {
    let slack = WindowKey(pid: 1, windowID: 101, bundleId: "app.slack")
    let discord = WindowKey(pid: 2, windowID: 202, bundleId: "app.discord")
    let workspace = Workspace(name: "Chat")
    let tree = BSPNode<WindowKey>.branch(
      BSPBranch(
        split: .vertical,
        ratio: 0.5,
        left: .leaf(slack),
        right: .leaf(discord),
      )
    )
    let state = Self.makeState(workspaces: [workspace]) {
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = tree
      $0.windowSyncBundleIdsInFlight = [slack.bundleId, discord.bundleId]
    }
    let saved = LockIsolated<[LayoutSnapshot]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.layoutStore.save = { _, snapshot in
        saved.withValue { $0.append(snapshot) }
      }
    }

    await store.send(.screenWillLock) {
      $0.layoutSuspensionReasons = [.screenLock]
      $0.suspendedLayoutWindows[workspace.id] = [slack, discord]
    }
    await store.send(.syncAppWindowsResolved(
      bundleId: slack.bundleId,
      resizableKeys: [],
      onScreenFrames: [:],
    )) {
      $0.windowSyncBundleIdsInFlight.remove(slack.bundleId)
    }
    await store.send(.syncAppWindowsResolved(
      bundleId: discord.bundleId,
      resizableKeys: [],
      onScreenFrames: [:],
    )) {
      $0.windowSyncBundleIdsInFlight.remove(discord.bundleId)
    }
    await store.finish()

    #expect(store.state.tilingTrees[workspace.id] == tree)
    #expect(saved.value.isEmpty)
  }

  @Test
  func `system wake waits for an overlapping screen lock`() async {
    let window = WindowKey(pid: 1, windowID: 101, bundleId: "app.one")
    let workspace = Workspace(name: "Sleep")
    let state = Self.makeState(workspaces: [workspace]) {
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = .leaf(window)
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    }

    await store.send(.systemWillSuspend) {
      $0.layoutSuspensionReasons = [.systemSleep]
      $0.suspendedLayoutWindows[workspace.id] = [window]
    }
    await store.send(.screenWillLock) {
      $0.layoutSuspensionReasons.insert(.screenLock)
    }
    await store.send(.systemDidWake) {
      $0.layoutSuspensionReasons.remove(.systemSleep)
    }
    await store.finish()

    #expect(store.state.layoutSuspensionReasons == [.screenLock])
    #expect(!store.state.isRecoveringSystemLayout)
    #expect(store.state.tilingTrees[workspace.id] == .leaf(window))
  }

  @Test(arguments: AutoBalanceMode.allCases)
  func `resume resets a fully recycled layout using auto balance`(
    mode: AutoBalanceMode
  ) async {
    let old = [
      WindowKey(pid: 1, windowID: 1, bundleId: "new.one"),
      WindowKey(pid: 2, windowID: 2, bundleId: "new.two"),
    ]
    let windows = [
      WindowKey(pid: 11, windowID: 101, bundleId: "new.one"),
      WindowKey(pid: 12, windowID: 102, bundleId: "new.two"),
      WindowKey(pid: 13, windowID: 103, bundleId: "new.three"),
      WindowKey(pid: 14, windowID: 104, bundleId: "new.four"),
    ]
    let workspace = Workspace(name: "Recovered")
    let current = BSPNode<WindowKey>.branch(
      BSPBranch(
        split: .horizontal,
        ratio: 0.8,
        left: .branch(
          BSPBranch(
            split: .vertical,
            ratio: 0.2,
            left: .leaf(windows[0]),
            right: .leaf(windows[1]),
          )
        ),
        right: .branch(
          BSPBranch(
            split: .vertical,
            ratio: 0.75,
            left: .leaf(windows[2]),
            right: .leaf(windows[3]),
          )
        ),
      )
    )
    let workArea = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let expected = current.balancedForCommand(
      autoBalance: mode,
      in: workArea,
      gap: 0,
      splitAxis: nil,
    )
    let state = Self.makeState(workspaces: [workspace]) {
      $0.$config.withLock {
        $0.settings.layout.autoBalance = mode
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
        $0.settings.layout.splitType = .auto
      }
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = current
      $0.isRecoveringSystemLayout = true
      $0.suspendedLayoutWindows[workspace.id] = Set(old)
      $0.pendingSystemLayoutBundleIds = ["new.one"]
    }
    let saved = LockIsolated<[LayoutSnapshot]>([])
    let applications = LockIsolated<[FrameApplication]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in workArea }
      $0.layoutStore.save = { _, snapshot in
        saved.withValue { $0.append(snapshot) }
      }
      $0.windowTiler.apply = { application in
        applications.withValue { $0.append(application) }
      }
    }
    store.exhaustivity = .off

    await store.send(.systemLayoutBundleReconciled(bundleId: "new.one"))
    await store.finish()

    #expect(store.state.tilingTrees[workspace.id] == expected)
    #expect(!store.state.isRecoveringSystemLayout)
    #expect(store.state.suspendedLayoutWindows.isEmpty)
    #expect(store.state.pendingSystemLayoutBundleIds.isEmpty)
    #expect(applications.value.last?.windowFrames.keys.count == windows.count)
    let slots = slotAssignment(expected.windows)
    #expect(saved.value.last?.tree == expected.mapWindows { slots[$0]! })
  }

  @Test
  func `wake reconciliation persists only the completed replacement layout`() async {
    let old = WindowKey(pid: 1, windowID: 101, bundleId: "app.one")
    let replacement = WindowKey(pid: 1, windowID: 202, bundleId: old.bundleId)
    let workspace = Workspace(
      name: "Recovered",
      apps: [AppAssignment(bundleIdentifier: old.bundleId, name: "One")],
    )
    let workArea = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let state = Self.makeState(workspaces: [workspace]) {
      $0.$config.withLock {
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
      }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = .leaf(old)
      $0.isRecoveringSystemLayout = true
      $0.suspendedLayoutWindows[workspace.id] = [old]
      $0.pendingSystemLayoutBundleIds = [old.bundleId]
      $0.windowSyncBundleIdsInFlight = [old.bundleId]
    }
    let saved = LockIsolated<[LayoutSnapshot]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in workArea }
      $0.layoutStore.save = { _, snapshot in
        saved.withValue { $0.append(snapshot) }
      }
    }
    store.exhaustivity = .off

    await store.send(.syncAppWindowsResolved(
      bundleId: old.bundleId,
      resizableKeys: [replacement],
      onScreenFrames: [replacement.windowID: workArea],
    ))
    await store.receive {
      guard case .systemLayoutBundleReconciled(let bundleId) = $0 else { return false }
      return bundleId == old.bundleId
    }
    await store.finish()

    #expect(store.state.tilingTrees[workspace.id]?.windows == [replacement])
    #expect(!store.state.isRecoveringSystemLayout)
    #expect(saved.value.count == 1)
  }

  @Test
  func `window invisible removes the tile without tombstoning its live surface`() async {
    let hidden = WindowKey(pid: 1, windowID: 101, bundleId: "com.cron.electron")
    let survivor = WindowKey(pid: 2, windowID: 202, bundleId: "app.survivor")
    let workArea = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let ws = Workspace(name: "one")
    let state = Self.makeState(workspaces: [ws]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = ws.id
      $0.tilingTrees[ws.id] = .branch(
        BSPBranch(
          split: .vertical,
          ratio: 0.5,
          left: .leaf(hidden),
          right: .leaf(survivor),
        )
      )
    }
    let invalidated = LockIsolated<Set<CGWindowID>>([])
    let applied = LockIsolated<[Set<WindowKey>]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in workArea }
      // Prove the 816 edge itself is authoritative even if the next list
      // snapshot still contains the surface.
      $0.windowSnapshot.onScreenWindowIDs = {
        [hidden.windowID, survivor.windowID]
      }
      // A same-process window on another display and an in-display popup are
      // not native-tab replacements for this tile.
      $0.windowSnapshot.onScreenWindowSurfaces = {
        [
          301: WindowServerSurface(
            ownerPID: hidden.pid,
            layer: 0,
            frame: CGRect(x: 1_200, y: 0, width: 800, height: 800),
          ),
          302: WindowServerSurface(
            ownerPID: hidden.pid,
            layer: 1,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
          ),
        ]
      }
      $0.windowSnapshot.cachedWindowKey = { windowID in
        windowID == hidden.windowID ? hidden : nil
      }
      $0.windowSnapshot.discoverKeys = { bundleIds, requireResizable in
        #expect(bundleIds == [hidden.bundleId])
        #expect(requireResizable)
        return []
      }
      $0.windowSnapshot.onScreenWindowFrames = { [:] }
      $0.windowSnapshot.invalidateWindowIDs = { ids in
        invalidated.withValue { $0.formUnion(ids) }
      }
      $0.windowTiler.apply = { request in
        applied.withValue { $0.append(Set(request.windowFrames.keys)) }
      }
    }
    store.exhaustivity = .off

    await store.send(.windowServerWindowEvent(.becameInvisible(hidden.windowID)))
    await store.receive(\.syncAppWindows)
    await store.receive(\.syncAppWindowsResolved)
    await store.finish()

    #expect(store.state.tilingTrees[ws.id]?.windows == [survivor])
    #expect(store.state.windowServerHiddenWindows == [hidden])
    #expect(invalidated.value.isEmpty)
    #expect(applied.value == [[survivor]])
  }

  @Test
  func `native tab visibility swap replaces the surface in one layout transaction`() async {
    let oldTab = WindowKey(
      pid: 1,
      windowID: 101,
      bundleId: "com.mitchellh.ghostty",
    )
    let newTab = WindowKey(
      pid: 1,
      windowID: 102,
      bundleId: oldTab.bundleId,
    )
    let survivor = WindowKey(pid: 2, windowID: 202, bundleId: "org.alacritty")
    let workspace = Workspace(
      name: "Terminal",
      apps: [AppAssignment(bundleIdentifier: oldTab.bundleId, name: "Ghostty")],
    )
    let workArea = CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
    let oldTree = BSPNode<WindowKey>.branch(
      BSPBranch(
        split: .vertical,
        ratio: 0.37,
        left: .leaf(survivor),
        right: .leaf(oldTab),
      )
    )
    let expectedTree = oldTree.mapWindows { $0 == oldTab ? newTab : $0 }
    let state = Self.makeState(workspaces: [workspace]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = oldTree
      $0.insertionPoint[workspace.id] = oldTab
      $0.mruWindows[workspace.id] = [oldTab, survivor]
    }
    let newFrame = CGRect(x: 600, y: 0, width: 1_000, height: 1_000)
    let surfaces = [
      newTab.windowID: WindowServerSurface(
        ownerPID: newTab.pid,
        layer: 0,
        frame: newFrame,
      ),
      survivor.windowID: WindowServerSurface(
        ownerPID: survivor.pid,
        layer: 0,
        frame: CGRect(x: 0, y: 0, width: 600, height: 1_000),
      ),
    ]
    let applications = LockIsolated<[Set<WindowKey>]>([])
    let saved = LockIsolated<[LayoutSnapshot]>([])
    let dirtied = LockIsolated<[String]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in workArea }
      $0.windowSnapshot.cachedWindowKey = { windowID in
        windowID == oldTab.windowID ? oldTab : nil
      }
      $0.windowSnapshot.onScreenWindowSurfaces = { surfaces }
      $0.windowSnapshot.onScreenWindowFrames = { surfaces.mapValues(\.frame) }
      $0.windowSnapshot.markBundleDirty = { bundleId in
        dirtied.withValue { $0.append(bundleId) }
      }
      $0.windowSnapshot.discoverKeys = { bundleIds, requireResizable in
        #expect(bundleIds == [oldTab.bundleId])
        #expect(requireResizable)
        return [newTab]
      }
      $0.windowTiler.apply = { application in
        applications.withValue { $0.append(Set(application.windowFrames.keys)) }
      }
      $0.layoutStore.save = { _, snapshot in
        saved.withValue { $0.append(snapshot) }
      }
    }
    store.exhaustivity = .off

    await store.send(.windowServerWindowEvent(.becameInvisible(oldTab.windowID)))
    await store.finish()

    #expect(store.state.tilingTrees[workspace.id] == expectedTree)
    #expect(store.state.insertionPoint[workspace.id] == newTab)
    #expect(store.state.mruWindows[workspace.id] == [newTab, survivor])
    #expect(store.state.windowServerHiddenWindows.isEmpty)
    #expect(store.state.presentationConvergenceWindows.contains(newTab))
    #expect(!applications.value.isEmpty)
    #expect(applications.value.allSatisfy { $0 == [newTab, survivor] })
    #expect(saved.value.count == 1)
    #expect(dirtied.value == [oldTab.bundleId])
  }

  @Test
  func `rapid native tab intermediate invisibility never expands its sibling`() async {
    let residentTab = WindowKey(
      pid: 1,
      windowID: 101,
      bundleId: "com.mitchellh.ghostty",
    )
    let intermediateTab = WindowKey(
      pid: residentTab.pid,
      windowID: 102,
      bundleId: residentTab.bundleId,
    )
    let latestTab = WindowKey(
      pid: residentTab.pid,
      windowID: 103,
      bundleId: residentTab.bundleId,
    )
    let alacritty = WindowKey(pid: 2, windowID: 202, bundleId: "org.alacritty")
    let workspace = Workspace(
      name: "Terminal",
      apps: [AppAssignment(bundleIdentifier: residentTab.bundleId, name: "Ghostty")],
    )
    let workArea = CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
    let oldTree = BSPNode<WindowKey>.branch(
      BSPBranch(
        split: .vertical,
        ratio: 0.37,
        left: .leaf(alacritty),
        right: .leaf(residentTab),
      )
    )
    let expectedTree = oldTree.mapWindows { $0 == residentTab ? latestTab : $0 }
    let state = Self.makeState(workspaces: [workspace]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = oldTree
      $0.insertionPoint[workspace.id] = residentTab
      $0.mruWindows[workspace.id] = [residentTab, alacritty]
    }
    let frames = [
      latestTab.windowID: CGRect(x: 600, y: 0, width: 1_000, height: 1_000),
      alacritty.windowID: CGRect(x: 0, y: 0, width: 600, height: 1_000),
    ]
    let applications = LockIsolated<[Set<WindowKey>]>([])
    let dirtied = LockIsolated<[String]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in workArea }
      $0.windowSnapshot.cachedWindowKey = { windowID in
        windowID == intermediateTab.windowID ? intermediateTab : nil
      }
      $0.windowSnapshot.markBundleDirty = { bundleId in
        dirtied.withValue { $0.append(bundleId) }
      }
      $0.windowSnapshot.discoverKeys = { bundleIds, requireResizable in
        #expect(bundleIds == [residentTab.bundleId])
        #expect(requireResizable)
        return [latestTab]
      }
      $0.windowSnapshot.onScreenWindowFrames = { frames }
      $0.windowTiler.apply = { application in
        applications.withValue { $0.append(Set(application.windowFrames.keys)) }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .windowServerWindowEvent(.becameInvisible(intermediateTab.windowID))
    )
    await store.receive(\.syncAppWindows)
    await store.receive(\.syncAppWindowsResolved)
    await store.finish()

    #expect(store.state.tilingTrees[workspace.id] == expectedTree)
    #expect(store.state.insertionPoint[workspace.id] == latestTab)
    #expect(store.state.mruWindows[workspace.id] == [latestTab, alacritty])
    #expect(store.state.windowServerHiddenWindows.isEmpty)
    #expect(!applications.value.isEmpty)
    #expect(applications.value.allSatisfy { $0 == [latestTab, alacritty] })
    #expect(dirtied.value == [residentTab.bundleId])
  }

  @Test
  func `surface replacement pairing keeps multiple native tab groups in their original slots`() {
    let oldLeft = WindowKey(pid: 7, windowID: 101, bundleId: "com.mitchellh.ghostty")
    let oldRight = WindowKey(pid: 7, windowID: 102, bundleId: oldLeft.bundleId)
    let newLeft = WindowKey(pid: 7, windowID: 201, bundleId: oldLeft.bundleId)
    let newRight = WindowKey(pid: 7, windowID: 202, bundleId: oldLeft.bundleId)
    let leftFrame = CGRect(x: 0, y: 0, width: 500, height: 800)
    let rightFrame = CGRect(x: 500, y: 0, width: 500, height: 800)

    let replacements = WorkspaceActivationFeature.surfaceReplacements(
      outgoing: [oldLeft, oldRight],
      incoming: [newRight, newLeft],
      expectedFrames: [oldLeft: leftFrame, oldRight: rightFrame],
      liveFrames: [newLeft.windowID: leftFrame, newRight.windowID: rightFrame],
    )

    #expect(replacements == [oldLeft: newLeft, oldRight: newRight])
  }

  @Test
  func `reappearing hidden surface repairs its delayed pre-close frame restore`() async throws {
    let slack = WindowKey(pid: 1, windowID: 101, bundleId: "com.tinyspeck.slackmacgap")
    let notion = WindowKey(pid: 2, windowID: 202, bundleId: "com.cron.electron")
    let workspace = Workspace(
      name: "Slack",
      apps: [AppAssignment(bundleIdentifier: slack.bundleId, name: "Slack")],
    )
    let workArea = await MainActor.run {
      ScreenGeometry.workArea(for: Self.display)
    }
    let staleHalfFrame = CGRect(
      x: workArea.minX,
      y: workArea.minY,
      width: workArea.width / 2,
      height: workArea.height,
    )
    let state = Self.makeState(workspaces: [workspace]) {
      $0.$config.withLock {
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
      }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = .leaf(slack)
      $0.fullscreenZoomed[workspace.id] = [slack]
      $0.windowServerHiddenWindows = [notion]
    }
    let liveFrames = LockIsolated([
      slack.windowID: workArea,
      notion.windowID: staleHalfFrame,
    ])
    let applications = LockIsolated<[FrameApplication]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in workArea }
      $0.windowSnapshot.cachedWindowKey = { windowID in
        windowID == notion.windowID ? notion : nil
      }
      $0.windowSnapshot.discoverKeys = { bundleIds, requireResizable in
        #expect(bundleIds == [notion.bundleId])
        #expect(requireResizable)
        return [notion]
      }
      $0.windowSnapshot.onScreenWindowFrames = { liveFrames.value }
      $0.windowTiler.apply = { application in
        applications.withValue { $0.append(application) }
        liveFrames.withValue { frames in
          for (key, frame) in application.windowFrames {
            frames[key.windowID] = frame
          }
        }
      }
    }
    store.exhaustivity = .off

    await store.send(.windowServerWindowEvent(.becameVisible(notion.windowID)))
    await store.receive(\.syncAppWindows)
    await store.receive(\.syncAppWindowsResolved)
    await store.finish()

    #expect(store.state.windowServerHiddenWindows.isEmpty)
    #expect(store.state.presentationConvergenceWindows.contains(notion))
    let targetFrame = try #require(
      applications.value.last?.windowFrames[notion]
    )
    #expect(applications.value.last?.forceAllFrames == true)
    #expect(targetFrame != staleHalfFrame)
    #expect(targetFrame.width > staleHalfFrame.width)

    liveFrames.withValue { $0[notion.windowID] = staleHalfFrame }
    await store.send(
      .windowChanged(
        .windowFrameChanged(key: notion, frame: staleHalfFrame)
      )
    )
    await store.finish()

    #expect(applications.value.last?.windowFrames[notion] == targetFrame)
    #expect(liveFrames.value[notion.windowID] == targetFrame)
  }

  @Test
  func `focused AX edge restores a hidden Electron surface without SLS visible`() async {
    let survivor = WindowKey(pid: 1, windowID: 101, bundleId: "org.alacritty")
    let notion = WindowKey(pid: 2, windowID: 202, bundleId: "com.cron.electron")
    let workspace = Workspace(name: "Terminal")
    let workArea = CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
    let state = Self.makeState(workspaces: [workspace]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = .leaf(survivor)
      $0.windowServerHiddenWindows = [notion]
    }
    let frames = [
      survivor.windowID: CGRect(x: 0, y: 0, width: 800, height: 1_000),
      notion.windowID: CGRect(x: 800, y: 0, width: 800, height: 1_000),
    ]
    let applications = LockIsolated<[Set<WindowKey>]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in workArea }
      $0.windowSnapshot.discoverKeys = { bundleIds, requireResizable in
        #expect(bundleIds == [notion.bundleId])
        #expect(requireResizable)
        return [notion]
      }
      $0.windowSnapshot.onScreenWindowFrames = { frames }
      $0.windowTiler.apply = { application in
        applications.withValue { $0.append(Set(application.windowFrames.keys)) }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .windowChanged(.windowFocused(bundleId: notion.bundleId, key: notion))
    )
    await store.receive(\.syncAppWindows)
    await store.receive(\.syncAppWindowsResolved)
    await store.finish()

    #expect(store.state.tilingTrees[workspace.id]?.windows == [survivor, notion])
    #expect(store.state.windowServerHiddenWindows.isEmpty)
    #expect(store.state.pendingWindowServerPresentationWindows.isEmpty)
    #expect(store.state.presentationConvergenceWindows.contains(notion))
    #expect(applications.value.allSatisfy { $0 == [survivor, notion] })
  }

  @Test
  func `window visible reconciles only its cached owner`() async {
    let key = WindowKey(pid: 1, windowID: 101, bundleId: "com.cron.electron")
    let state = Self.makeState(workspaces: []) {
      $0.isActivating = true
    }
    let dirtied = LockIsolated<[String]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.windowSnapshot.cachedWindowKey = { windowID in
        windowID == key.windowID ? key : nil
      }
      $0.windowSnapshot.markBundleDirty = { bundleId in
        dirtied.withValue { $0.append(bundleId) }
      }
    }

    await store.send(.windowServerWindowEvent(.becameVisible(key.windowID)))
    await store.receive(\.syncAppWindows) {
      $0.pendingWindowSyncBundleIds.insert(key.bundleId)
    }
    await store.finish()

    #expect(dirtied.value == [key.bundleId])
  }

  @Test
  func `window invisible during activation preserves the outgoing surface before deferred prune`() async {
    let key = WindowKey(pid: 1, windowID: 101, bundleId: "app.one")
    let ws = Workspace(name: "one")
    let state = Self.makeState(workspaces: [ws]) {
      $0.isActivating = true
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = ws.id
      $0.tilingTrees[ws.id] = .leaf(key)
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.windowSnapshot.cachedWindowKey = { windowID in
        windowID == key.windowID ? key : nil
      }
    }

    await store.send(.windowServerWindowEvent(.becameInvisible(key.windowID))) {
      $0.windowServerHiddenWindows = [key]
      $0.pendingWindowServerPrune = true
    }

    #expect(store.state.tilingTrees[ws.id]?.windows == [key])
  }

  @Test
  func `late outgoing invisibility preserves the surface after active mapping changed`() async {
    let notion = WindowKey(pid: 1, windowID: 101, bundleId: "com.cron.electron")
    let slack = WindowKey(pid: 2, windowID: 202, bundleId: "com.tinyspeck.slackmacgap")
    let terminalWorkspace = Workspace(name: "Terminal")
    let slackWorkspace = Workspace(name: "Slack")
    let state = Self.makeState(workspaces: [terminalWorkspace, slackWorkspace]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = slackWorkspace.id
      $0.tilingTrees[terminalWorkspace.id] = .leaf(notion)
      $0.tilingTrees[slackWorkspace.id] = .leaf(slack)
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.windowSnapshot.cachedWindowKey = { windowID in
        windowID == notion.windowID ? notion : nil
      }
      $0.windowSnapshot.onScreenWindowIDs = { [slack.windowID] }
    }
    store.exhaustivity = .off

    await store.send(.windowServerWindowEvent(.becameInvisible(notion.windowID)))
    await store.finish()

    #expect(store.state.windowServerHiddenWindows == [notion])
    #expect(store.state.tilingTrees[terminalWorkspace.id]?.windows == [notion])
    #expect(store.state.tilingTrees[slackWorkspace.id]?.windows == [slack])
  }

  @Test(arguments: [true, false])
  func `window server close immediately reflows either borrowed sibling and repairs a restore`(
    closedComesFirst: Bool
  ) async {
    let hostWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.host")
    let closed = WindowKey(pid: 2, windowID: 201, bundleId: "app.borrowed")
    let survivor = WindowKey(pid: 2, windowID: 202, bundleId: "app.borrowed")
    let host = Workspace(name: "Host")
    let borrowed = Workspace(
      name: "Borrowed",
      apps: [AppAssignment(bundleIdentifier: closed.bundleId, name: "Borrowed")],
    )
    let workArea = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let state = Self.makeState(workspaces: [host, borrowed]) {
      $0.$config.withLock {
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
        $0.settings.focus.mouseFollowsFocus = true
      }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = host.id
      $0.tilingTrees[host.id] = .leaf(hostWindow)
      $0.tilingTrees[borrowed.id] = .branch(
        BSPBranch(
          split: .horizontal,
          ratio: 0.5,
          left: .leaf(closedComesFirst ? closed : survivor),
          right: .leaf(closedComesFirst ? survivor : closed),
        )
      )
      $0.compositionsByDisplay[Self.display] = Composition(
        host: host.id,
        borrowed: [BorrowedSlot(workspace: borrowed.id, edge: .right, fraction: 0.4)],
      )
      $0.lastObservedFocusedWindow = survivor
    }
    let frameReadCount = LockIsolated(0)
    let applied = LockIsolated<[FrameApplication]>([])
    let warped = LockIsolated<[CGPoint]>([])
    let staleHalfFrame = CGRect(x: 600, y: 0, width: 400, height: 400)
    let settledFullFrame = CGRect(x: 600, y: 0, width: 400, height: 800)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in workArea }
      $0.windowSnapshot.onScreenWindowIDs = {
        [hostWindow.windowID, closed.windowID, survivor.windowID]
      }
      $0.windowSnapshot.onScreenWindowFrames = {
        [
          survivor.windowID: applied.value.count <= 1
            ? staleHalfFrame
            : settledFullFrame
        ]
      }
      $0.windowSnapshot.focusedWindowKey = { survivor }
      $0.windowSnapshot.windowFrame = { key in
        #expect(key == survivor)
        return frameReadCount.withValue { count in
          defer { count += 1 }
          return count == 0 ? staleHalfFrame : settledFullFrame
        }
      }
      $0.windowTiler.apply = { request in
        applied.withValue { $0.append(request) }
      }
      $0.mouse.warp = { point in
        warped.withValue { $0.append(point) }
      }
    }
    store.exhaustivity = .off

    await store.send(.windowServerWindowEvent(.terminated(closed.windowID)))
    await store.finish()

    #expect(store.state.tilingTrees[borrowed.id]?.windows == [survivor])
    #expect(applied.value.count == 2)
    #expect(
      applied.value.last?.windowFrames[survivor]
        == settledFullFrame
    )
    #expect(warped.value.last == CGPoint(x: settledFullFrame.midX, y: settledFullFrame.midY))
  }

  @Test
  func `focused window moves display ownership to its actual workspace`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let keyA = WindowKey(pid: 1, windowID: 101, bundleId: "app.a")
    let keyB = WindowKey(pid: 2, windowID: 202, bundleId: "app.b")
    let wsA = Workspace(
      name: "A",
      apps: [AppAssignment(bundleIdentifier: keyA.bundleId, name: "A")],
    )
    let wsB = Workspace(
      name: "B",
      apps: [AppAssignment(bundleIdentifier: keyB.bundleId, name: "B")],
    )
    let state = Self.makeState(workspaces: [wsA, wsB]) {
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [displayA: wsA.id, displayB: wsB.id]
      $0.tilingTrees = [wsA.id: .leaf(keyA), wsB.id: .leaf(keyB)]
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    await store.send(.windowChanged(.windowFocused(bundleId: keyB.bundleId, key: keyB)))

    #expect(store.state.focusedDisplay == displayB)
    #expect(store.state.mruWindows[wsB.id] == [keyB])
    #expect(store.state.mruWindows[wsA.id] == nil)
  }

  @Test
  func `activation reconciles a missed same app focus before leaving`() async {
    let personal = WindowKey(pid: 1, windowID: 101, bundleId: "company.browser")
    let work = WindowKey(pid: 1, windowID: 102, bundleId: "company.browser")
    let browser = Workspace(
      name: "Browser",
      apps: [AppAssignment(bundleIdentifier: personal.bundleId, name: "Browser")],
    )
    let other = Workspace(name: "Other")
    let state = Self.makeState(workspaces: [browser, other]) {
      $0.isTilingPaused = true
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = browser.id
      $0.tilingTrees[browser.id] = .branch(
        BSPBranch(
          split: .vertical,
          ratio: 0.5,
          left: .leaf(personal),
          right: .leaf(work),
        )
      )
      // The focus notification for Personal → Work was missed.
      $0.mruWindows[browser.id] = [personal, work]
    }
    let liveFocus = LockIsolated<WindowKey?>(work)
    let requests = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.floatingOverlay.retainOnly = { _ in }
      $0.windowSnapshot.frontmostApp = {
        FrontmostApp(
          pid: work.pid,
          bundleId: work.bundleId,
          name: "Browser",
        )
      }
      $0.windowSnapshot.focusedWindowKey = { liveFocus.value }
      $0.workspaceManager.activate = { request in
        requests.withValue { $0.append(request) }
      }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: other.id, setFocus: true))
    await store.receive {
      guard case .activationCompleted(let workspaceId, _, _) = $0 else { return false }
      return workspaceId == other.id
    }
    #expect(store.state.mruWindows[browser.id] == [work, personal])

    liveFocus.withValue { $0 = nil }
    await store.send(.activate(workspaceId: browser.id, setFocus: true))
    await store.receive {
      guard case .activationCompleted(let workspaceId, _, _) = $0 else { return false }
      return workspaceId == browser.id
    }
    await store.finish()

    #expect(requests.value.last?.windowKeyToFocus == work)
  }

  @Test
  func `activation focus snapshot requires exact visible tree membership`() async {
    let remembered = WindowKey(pid: 1, windowID: 101, bundleId: "company.browser")
    let hidden = WindowKey(pid: 1, windowID: 202, bundleId: "company.browser")
    let browser = Workspace(
      name: "Browser",
      apps: [AppAssignment(bundleIdentifier: remembered.bundleId, name: "Browser")],
    )
    let other = Workspace(name: "Other")
    let state = Self.makeState(workspaces: [browser, other]) {
      $0.isTilingPaused = true
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = browser.id
      $0.tilingTrees[browser.id] = .leaf(remembered)
      $0.mruWindows[browser.id] = [remembered]
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.floatingOverlay.retainOnly = { _ in }
      $0.windowSnapshot.focusedWindowKey = { hidden }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: other.id, setFocus: true))
    await store.receive {
      guard case .activationCompleted(let workspaceId, _, _) = $0 else { return false }
      return workspaceId == other.id
    }
    await store.finish()

    #expect(store.state.mruWindows[browser.id] == [remembered])
  }

  @Test
  func `background activation keeps the focused window display when cursor is elsewhere`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let wsA = Workspace(name: "A")
    let wsB = Workspace(name: "B")
    let target = Workspace(name: "Target")
    let state = Self.makeState(workspaces: [wsA, wsB, target]) {
      $0.isTilingPaused = true
      // An earlier exact window-focus event established B as keyboard focus.
      $0.focusedDisplay = displayB
      $0.activeWorkspacesByDisplay = [displayA: wsA.id, displayB: wsB.id]
    }
    let requests = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.current = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        requests.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    // The pointer is still on A. The activation belongs to the keyboard-focused
    // workspace on B and must not be pulled back to the pointer monitor.
    await store.send(.activate(workspaceId: target.id, setFocus: false))
    await store.receive {
      guard case .activationCompleted(let workspaceId, let display, _) = $0 else { return false }
      return workspaceId == target.id && display == displayB
    }
    await store.finish()

    #expect(requests.value.last?.targetDisplay == displayB)
    #expect(store.state.activeWorkspacesByDisplay[displayB] == target.id)
    #expect(store.state.activeWorkspacesByDisplay[displayA] == wsA.id)
  }

  @Test
  func `focused dynamic activation follows the cursor display`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let wsA = Workspace(name: "A")
    let wsB = Workspace(name: "B")
    let target = Workspace(name: "Target")
    let state = Self.makeState(workspaces: [wsA, wsB, target]) {
      $0.isTilingPaused = true
      // Keyboard focus is still on B, while the pointer moved to A before the
      // dynamic workspace shortcut was invoked.
      $0.focusedDisplay = displayB
      $0.activeWorkspacesByDisplay = [displayA: wsA.id, displayB: wsB.id]
    }
    let requests = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.current = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        requests.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: target.id, setFocus: true))
    await store.receive {
      guard case .activationCompleted(let workspaceId, let display, _) = $0 else { return false }
      return workspaceId == target.id && display == displayA
    }
    await store.finish()

    #expect(requests.value.last?.targetDisplay == displayA)
    #expect(store.state.focusedDisplay == displayA)
    #expect(store.state.activeWorkspacesByDisplay[displayA] == target.id)
    #expect(store.state.activeWorkspacesByDisplay[displayB] == wsB.id)
  }

  @Test
  func `dismissing a background borrow restores its own display`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let host = Workspace(name: "Host")
    let borrowed = Workspace(name: "Borrowed")
    let state = Self.makeState(workspaces: [host, borrowed]) {
      $0.isTilingPaused = true
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay[displayB] = host.id
      $0.compositionsByDisplay[displayB] = Composition(
        host: host.id,
        borrowed: [BorrowedSlot(workspace: borrowed.id, edge: .right, fraction: 0.35)],
      )
    }
    let requests = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.current = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        requests.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.dismissBorrow(display: displayB))
    await store.receive {
      guard case .activationCompleted(let workspaceId, let display, _) = $0 else { return false }
      return workspaceId == host.id && display == displayB
    }
    await store.finish()

    #expect(store.state.compositionsByDisplay[displayB] == nil)
    #expect(requests.value.last?.targetDisplay == displayB)
    #expect(store.state.activeWorkspacesByDisplay[displayB] == host.id)
  }

  @Test
  func `activating a borrowed workspace clears its badge before activation completes`() async {
    let hostWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.host")
    let borrowedWindow = WindowKey(pid: 2, windowID: 202, bundleId: "company.thebrowser.dia")
    let host = Workspace(name: "Host")
    let borrowed = Workspace(name: "Browser")
    let state = Self.makeState(workspaces: [host, borrowed]) {
      $0.$config.withLock {
        $0.settings.marker.fullscreenEnabled = true
        $0.settings.marker.borrowEnabled = true
      }
      $0.isTilingPaused = true
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = host.id
      $0.tilingTrees[host.id] = .leaf(hostWindow)
      $0.tilingTrees[borrowed.id] = .leaf(borrowedWindow)
      $0.fullscreenZoomed[borrowed.id] = [borrowedWindow]
      $0.compositionsByDisplay[Self.display] = Composition(
        host: host.id,
        borrowed: [
          BorrowedSlot(workspace: borrowed.id, edge: .right, fraction: 0.35)
        ],
      )
    }
    let activationGate = AsyncStream<Void>.makeStream()
    let markerEvents = AsyncStream<[WindowKey: MarkerTarget]>.makeStream()
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { _ in
        var iterator = activationGate.stream.makeAsyncIterator()
        _ = await iterator.next()
      }
      $0.marker.setTargets = { targets, _, _, _ in
        markerEvents.continuation.yield(targets)
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off
    var markerIterator = markerEvents.stream.makeAsyncIterator()

    await store.send(.activate(workspaceId: borrowed.id, setFocus: true))

    // The activation manager is still blocked. This replacement is what
    // removes the old always-visible, symbol-sized Borrow badge immediately.
    let targetsBeforeCompletion = await markerIterator.next()
    #expect(targetsBeforeCompletion?[borrowedWindow] == nil)

    activationGate.continuation.yield()
    await store.receive {
      guard case .activationCompleted(let workspaceId, _, _) = $0 else { return false }
      return workspaceId == borrowed.id
    }
    let targetsAfterCompletion = await markerIterator.next()
    await store.finish()

    #expect(targetsAfterCompletion?[borrowedWindow]?.symbol == nil)
    #expect(targetsAfterCompletion?[borrowedWindow]?.alwaysVisible == false)
  }

  @Test
  func `summoning the same borrowed workspace dismisses it by default`() async {
    let display = DisplayName("A")
    let host = Workspace(name: "Host")
    let borrowed = Workspace(name: "Borrowed")
    let state = Self.makeState(workspaces: [host, borrowed]) {
      $0.isTilingPaused = true
      $0.focusedDisplay = display
      $0.activeWorkspacesByDisplay[display] = host.id
      $0.compositionsByDisplay[display] = Composition(
        host: host.id,
        borrowed: [BorrowedSlot(workspace: borrowed.id, edge: .right, fraction: 0.4)],
      )
    }
    let requests = LockIsolated<[ActivationRequest]>([])
    let hudRequests = LockIsolated<[ActionHUDRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.current = { display }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        requests.withValue { $0.append(request) }
      }
      $0.workspaceHUD.showAction = { request in
        hudRequests.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.beginBorrowDirection(workspaceId: borrowed.id))
    await store.receive {
      guard case .activationCompleted(let workspaceId, let owner, _) = $0 else { return false }
      return workspaceId == host.id && owner == display
    }
    await store.finish()

    #expect(store.state.compositionsByDisplay[display] == nil)
    #expect(requests.value.last?.workspace.id == host.id)
    #expect(requests.value.last?.targetDisplay == display)
    #expect(hudRequests.value.count == 1)
    #expect(hudRequests.value.first?.name == host.name)
    #expect(
      hudRequests.value.first?.subtitle
        == String(localized: "Returned \(borrowed.name)")
    )
    #expect(hudRequests.value.first?.subtitleSymbolIconName == nil)
  }

  @Test
  func `Borrow observes and refreshes a warm-empty scratchpad cache`() async {
    let display = Self.display
    let hostWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.host")
    let retired = WindowKey(pid: 2, windowID: 201, bundleId: "app.scratchpad")
    let replacement = WindowKey(pid: 2, windowID: 202, bundleId: "app.scratchpad")
    let host = Workspace(name: "Host")
    let scratchpad = Workspace(
      name: "Scratchpad",
      kind: .scratchpad,
      apps: [AppAssignment(bundleIdentifier: replacement.bundleId, name: "Scratchpad")],
    )
    let state = Self.makeState(workspaces: [host, scratchpad]) {
      $0.focusedDisplay = display
      $0.activeWorkspacesByDisplay[display] = host.id
      $0.tilingTrees[host.id] = .leaf(hostWindow)
    }
    let observed = LockIsolated<[[String]]>([])
    let freshScans = LockIsolated(0)
    let applications = LockIsolated<[FrameApplication]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.current = { display }
      $0.displays.workArea = { _ in CGRect(x: 0, y: 0, width: 1_000, height: 800) }
      $0.workspaceManager.activate = { _ in }
      $0.windowObserver.observe = { bundleIds in
        observed.withValue { $0.append(bundleIds) }
      }
      // Reproduces KakaoTalk after its previous WindowServer surface was
      // destroyed: the cache entry exists but contains no live key.
      $0.windowSnapshot.cachedKeys = { _, _ in [] }
      $0.windowSnapshot.cachedKeysOnlyAsync = { _, _ in .hit([]) }
      $0.windowSnapshot.discoverKeys = { bundleIds, requireResizable in
        #expect(bundleIds == [replacement.bundleId])
        #expect(requireResizable)
        freshScans.withValue { $0 += 1 }
        // The app replaced its surface as the AX scan completed. The final
        // WindowServer validation must keep only the live key.
        return [retired, replacement]
      }
      $0.windowSnapshot.onScreenWindowIDs = {
        [hostWindow.windowID, replacement.windowID]
      }
      $0.windowSnapshot.existingWindowKeys = { keys in
        Set(keys.filter { $0 == replacement })
      }
      $0.windowTiler.apply = { request in
        applications.withValue { $0.append(request) }
      }
    }
    store.exhaustivity = .off

    await store.send(.borrow(workspaceId: scratchpad.id, edge: .right))
    await store.receive {
      guard
        case .borrowedTilingTreeHydrated(
          let owner,
          let workspaceId,
          let generation,
          let previousTree,
          let tree,
        ) = $0
      else { return false }
      return owner == display && generation == 1
        && workspaceId == scratchpad.id && tree?.windows == [replacement]
        && previousTree == nil
    }
    await store.finish()

    #expect(observed.value.contains([replacement.bundleId]))
    #expect(freshScans.value == 1)
    #expect(store.state.tilingTrees[scratchpad.id]?.windows == [replacement])
    #expect(applications.value.last?.windowFrames[replacement] != nil)
  }

  @Test
  func `Borrow keeps a live hidden cached window before on-screen publication`() async {
    let display = Self.display
    let hostWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.host")
    let cached = WindowKey(
      pid: 2,
      windowID: 201,
      bundleId: "com.kakao.KakaoTalkMac",
    )
    let host = Workspace(name: "Host")
    let scratchpad = Workspace(
      name: "KakaoTalk",
      kind: .scratchpad,
      apps: [AppAssignment(bundleIdentifier: cached.bundleId, name: "KakaoTalk")],
    )
    let state = Self.makeState(workspaces: [host, scratchpad]) {
      $0.$config.withLock {
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
      }
      $0.focusedDisplay = display
      $0.activeWorkspacesByDisplay[display] = host.id
      $0.tilingTrees[host.id] = .leaf(hostWindow)
      $0.tilingTrees[scratchpad.id] = .leaf(cached)
    }
    let freshScans = LockIsolated(0)
    let applications = LockIsolated<[FrameApplication]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.current = { display }
      $0.displays.workArea = { _ in
        CGRect(x: 0, y: 0, width: 1_000, height: 800)
      }
      $0.workspaceManager.activate = { _ in }
      $0.windowObserver.observe = { _ in }
      $0.windowSnapshot.cachedKeysOnlyAsync = { _, _ in .hit([cached]) }
      $0.windowSnapshot.discoverKeys = { _, _ in
        freshScans.withValue { $0 += 1 }
        return []
      }
      // This is the runtime failure: `unhide()` has returned, but the reused
      // KakaoTalk surface is not in `.optionOnScreenOnly` yet.
      $0.windowSnapshot.onScreenWindowIDs = { [hostWindow.windowID] }
      $0.windowSnapshot.existingWindowKeys = { Set($0) }
      $0.windowTiler.apply = { application in
        applications.withValue { $0.append(application) }
      }
    }
    store.exhaustivity = .off

    await store.send(.borrow(workspaceId: scratchpad.id, edge: .right))
    await store.receive {
      guard
        case .borrowedTilingTreeHydrated(
          let owner,
          let workspaceId,
          let generation,
          let previousTree,
          let tree,
        ) = $0
      else { return false }
      return owner == display
        && workspaceId == scratchpad.id
        && generation == 1
        && previousTree?.windows == [cached]
        && tree?.windows == [cached]
    }
    await store.finish()

    #expect(freshScans.value == 0)
    #expect(store.state.tilingTrees[scratchpad.id]?.windows == [cached])
    #expect(applications.value.last?.windowFrames[cached] != nil)
  }

  @Test
  func `rapid re-dock keeps the in-flight Borrow generation valid`() async {
    let display = Self.display
    let host = Workspace(name: "Host")
    let scratchpad = Workspace(name: "Scratchpad", kind: .scratchpad)
    let state = Self.makeState(workspaces: [host, scratchpad]) {
      $0.$config.withLock {
        $0.settings.switching.toggleBorrowOnRepeat = false
      }
      $0.focusedDisplay = display
      $0.activeWorkspacesByDisplay[display] = host.id
      $0.compositionsByDisplay[display] = Composition(
        host: host.id,
        borrowed: [
          BorrowedSlot(workspace: scratchpad.id, edge: .right, fraction: 0.4)
        ],
      )
      // Represents the first Borrow discovery still in flight.
      $0.borrowGenerationByDisplay[display] = 7
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.current = { display }
    }
    store.exhaustivity = .off

    await store.send(.borrow(workspaceId: scratchpad.id, edge: .left))
    await store.finish()

    #expect(store.state.borrowGenerationByDisplay[display] == 7)
    #expect(store.state.compositionsByDisplay[display]?.borrowed.first?.edge == .left)
  }

  @Test
  func `observer sync wins over stale Borrow hydration`() async {
    let display = Self.display
    let host = Workspace(name: "Host")
    let workspace = Workspace(name: "Scratchpad", kind: .scratchpad)
    let old = WindowKey(pid: 2, windowID: 201, bundleId: "app.scratchpad")
    let replacement = WindowKey(pid: 2, windowID: 202, bundleId: old.bundleId)
    let state = Self.makeState(workspaces: [host, workspace]) {
      // Observer-driven sync published the replacement after Borrow captured
      // `old`, but before its hydration result reached the reducer.
      $0.tilingTrees[workspace.id] = .leaf(replacement)
      $0.compositionsByDisplay[display] = Composition(
        host: host.id,
        borrowed: [BorrowedSlot(workspace: workspace.id, edge: .right, fraction: 0.4)],
      )
      $0.borrowGenerationByDisplay[display] = 2
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    }

    await store.send(
      .borrowedTilingTreeHydrated(
        display: display,
        workspaceId: workspace.id,
        generation: 1,
        previousTree: .leaf(old),
        tree: nil,
      )
    )

    #expect(store.state.tilingTrees[workspace.id]?.windows == [replacement])
  }

  @Test
  func `cancelled Borrow layout never reaches its old focus or arm phases`() async {
    let display = Self.display
    let hostWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.host")
    let borrowedWindow = WindowKey(pid: 2, windowID: 201, bundleId: "app.borrowed")
    let host = Workspace(name: "Host")
    let borrowed = Workspace(name: "Borrowed", kind: .scratchpad)
    let state = Self.makeState(workspaces: [host, borrowed]) {
      $0.$config.withLock {
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
      }
      $0.focusedDisplay = display
      $0.activeWorkspacesByDisplay[display] = host.id
      $0.tilingTrees[host.id] = .leaf(hostWindow)
      $0.tilingTrees[borrowed.id] = .leaf(borrowedWindow)
      $0.compositionsByDisplay[display] = Composition(
        host: host.id,
        borrowed: [BorrowedSlot(workspace: borrowed.id, edge: .right, fraction: 0.4)],
      )
      $0.borrowGenerationByDisplay[display] = 7
      $0.pendingBorrowCompletionByDisplay[display] = .init(
        workspaceId: borrowed.id,
        generation: 7,
      )
    }
    let applyCount = LockIsolated(0)
    let focused = LockIsolated<[WindowKey]>([])
    let (firstLayoutStarted, firstLayoutStartedContinuation) =
      AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let (releaseFirstLayout, releaseFirstLayoutContinuation) =
      AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in CGRect(x: 0, y: 0, width: 1_000, height: 800) }
      $0.windowTiler.apply = { _ in
        let ordinal = applyCount.withValue {
          $0 += 1
          return $0
        }
        if ordinal == 1 {
          firstLayoutStartedContinuation.yield(())
          firstLayoutStartedContinuation.finish()
          for await _ in releaseFirstLayout { break }
        }
      }
      $0.focusManager.focusWindow = { key in
        focused.withValue { $0.append(key) }
      }
    }
    store.exhaustivity = .off

    var firstLayoutStartedIterator = firstLayoutStarted.makeAsyncIterator()
    await store.send(
      .flushCompositionAndFocus(
        display: display,
        workspaceId: borrowed.id,
        generation: 7,
      )
    )
    #expect(await firstLayoutStartedIterator.next() != nil)

    // This ordinary composition flush owns the same display-scoped layout
    // cancellation ID. Cancelling the old writer must end its phase chain;
    // Effect.concatenate used to continue into both focus and arm here.
    await store.send(.flushComposition(display: display))
    releaseFirstLayoutContinuation.finish()
    await store.finish()

    #expect(applyCount.value == 2)
    #expect(focused.value.isEmpty)
  }

  @Test
  func `stale Borrow phase actions cannot focus or arm a replaced composition`() async {
    let display = Self.display
    let hostWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.host")
    let borrowedWindow = WindowKey(pid: 2, windowID: 201, bundleId: "app.borrowed")
    let host = Workspace(name: "Host")
    let borrowed = Workspace(name: "Borrowed", kind: .scratchpad)
    let currentComposition = Composition(
      host: host.id,
      borrowed: [BorrowedSlot(workspace: borrowed.id, edge: .left, fraction: 0.4)],
    )
    let staleComposition = Composition(
      host: host.id,
      borrowed: [BorrowedSlot(workspace: borrowed.id, edge: .right, fraction: 0.4)],
    )
    let state = Self.makeState(workspaces: [host, borrowed]) {
      $0.tilingTrees[host.id] = .leaf(hostWindow)
      $0.tilingTrees[borrowed.id] = .leaf(borrowedWindow)
      $0.compositionsByDisplay[display] = currentComposition
      $0.borrowGenerationByDisplay[display] = 2
    }
    let focused = LockIsolated<[WindowKey]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.focusManager.focusWindow = { key in
        focused.withValue { $0.append(key) }
      }
    }

    // The Borrow generation still matches, but a re-dock replaced the exact
    // composition whose layout completed.
    await store.send(
      .borrowCompositionLayoutCompleted(
        display: display,
        workspaceId: borrowed.id,
        generation: 2,
        composition: staleComposition,
      )
    )
    // The composition still matches, but a newer Borrow transaction owns it.
    // A stale post-focus action must not emit presentationLayoutApplied.
    await store.send(
      .borrowFocusCompleted(
        display: display,
        workspaceId: borrowed.id,
        generation: 1,
        composition: currentComposition,
      )
    )
    await store.finish()

    #expect(focused.value.isEmpty)
  }

  @Test
  func `empty workspace recent switch keeps the emptied display`() async {
    let displayA = DisplayName(uuid: "display-a", name: "A")
    let displayB = DisplayName(uuid: "display-b", name: "B")
    let current = Workspace(name: "Current")
    let recent = Workspace(name: "Recent")
    let other = Workspace(name: "Other")
    let state = Self.makeState(workspaces: [current, recent, other]) {
      $0.$config.withLock {
        $0.settings.switching.switchToRecentWhenEmpty = true
      }
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [displayA: current.id, displayB: other.id]
      $0.previousWorkspacesByDisplay[displayA] = recent.id
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      // Presence resolution belongs to A even if the pointer has reached B by
      // the time its asynchronous result is reduced.
      $0.displays.current = { displayB }
      $0.continuousClock = TestClock()
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.emptyWorkspacePresenceResolved(
      workspaceId: current.id,
      hasOnScreenMembers: false,
      hasFloatingWindows: false,
      borrowDisplay: nil,
      borrowGeneration: nil,
      borrowComposition: nil,
    ))
    await store.receive {
      guard case .activate(let workspaceID, let setFocus, let display) = $0 else {
        return false
      }
      return workspaceID == recent.id && setFocus && display == displayA
    }
  }

  @Test
  func `stale empty presence result cannot dismiss a new Borrow generation`() async {
    let display = Self.display
    let host = Workspace(name: "Host")
    let borrowed = Workspace(name: "Borrowed", kind: .scratchpad)
    let composition = Composition(
      host: host.id,
      borrowed: [BorrowedSlot(workspace: borrowed.id, edge: .right, fraction: 0.4)],
    )
    let state = Self.makeState(workspaces: [host, borrowed]) {
      $0.activeWorkspacesByDisplay[display] = host.id
      $0.compositionsByDisplay[display] = composition
      $0.borrowGenerationByDisplay[display] = 2
      $0.pendingBorrowCompletionByDisplay[display] = .init(
        workspaceId: borrowed.id,
        generation: 2,
      )
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    }

    await store.send(
      .emptyWorkspacePresenceResolved(
        workspaceId: borrowed.id,
        hasOnScreenMembers: false,
        hasFloatingWindows: false,
        borrowDisplay: display,
        borrowGeneration: 1,
        borrowComposition: composition,
      )
    )

    #expect(store.state.compositionsByDisplay[display] == composition)
    #expect(store.state.borrowGenerationByDisplay[display] == 2)
    #expect(
      store.state.pendingBorrowCompletionByDisplay[display]
        == .init(workspaceId: borrowed.id, generation: 2)
    )
  }

  @Test
  func `borrow finishes composition layout before focusing its block`() async {
    let display = Self.display
    let hostWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.host")
    let borrowedWindow = WindowKey(pid: 2, windowID: 201, bundleId: "app.borrowed")
    let host = Workspace(name: "Host")
    let borrowed = Workspace(
      name: "Borrowed",
      kind: .scratchpad,
      apps: [AppAssignment(bundleIdentifier: borrowedWindow.bundleId, name: "Borrowed")],
    )
    let state = Self.makeState(workspaces: [host, borrowed]) {
      $0.$config.withLock {
        $0.settings.focus.mouseFollowsFocus = true
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
        $0.settings.switching.borrowFraction = 0.4
      }
      $0.focusedDisplay = display
      $0.activeWorkspacesByDisplay[display] = host.id
      $0.tilingTrees[host.id] = .leaf(hostWindow)
    }
    let borrowedFrame = CGRect(x: 600, y: 0, width: 400, height: 800)
    let restoredFrame = CGRect(x: 600, y: 0, width: 400, height: 400)
    let order = LockIsolated<[String]>([])
    let liveFrames = LockIsolated([borrowedWindow.windowID: borrowedFrame])
    let cursor = LockIsolated(CGPoint.zero)
    let warped = LockIsolated<[CGPoint]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.current = { display }
      $0.displays.workArea = { _ in CGRect(x: 0, y: 0, width: 1000, height: 800) }
      $0.workspaceManager.activate = { _ in }
      $0.windowSnapshot.cachedKeys = { bundleIDs, _ in
        bundleIDs.contains(borrowedWindow.bundleId) ? [borrowedWindow] : []
      }
      $0.windowSnapshot.cachedKeysOnlyAsync = { bundleIDs, _ in
        .hit(bundleIDs.contains(borrowedWindow.bundleId) ? [borrowedWindow] : [])
      }
      $0.windowSnapshot.focusedWindowKey = { borrowedWindow }
      $0.windowSnapshot.windowFrame = { key in
        #expect(key == borrowedWindow)
        order.withValue { $0.append("frame") }
        return borrowedFrame
      }
      $0.windowSnapshot.onScreenWindowIDs = {
        Set(liveFrames.value.keys)
      }
      $0.windowSnapshot.existingWindowKeys = { Set($0) }
      $0.windowSnapshot.onScreenWindowFrames = { liveFrames.value }
      $0.windowTiler.apply = { application in
        liveFrames.withValue { frames in
          for (key, frame) in application.windowFrames {
            frames[key.windowID] = frame
          }
        }
        order.withValue { $0.append("layout") }
      }
      $0.focusManager.focusWindow = { key in
        #expect(key == borrowedWindow)
        order.withValue { $0.append("focus") }
      }
      $0.mouse.axLocation = { cursor.value }
      $0.mouse.warp = { point in
        warped.withValue { $0.append(point) }
        cursor.setValue(point)
        order.withValue { $0.append("warp") }
      }
    }
    store.exhaustivity = .off

    await store.send(.borrow(workspaceId: borrowed.id, edge: .right))
    await store.receive {
      guard case .cursorWarpFinished(let workspaceId, let target) = $0 else { return false }
      return workspaceId == borrowed.id && target == borrowedWindow
    }

    // KakaoTalk-like behavior: the app restores a stale half-height frame
    // after the first layout. Its real AX geometry event repairs immediately;
    // no clock advance or delayed settlement action is involved.
    liveFrames.setValue([borrowedWindow.windowID: restoredFrame])
    await store.send(
      .windowChanged(.windowFrameChanged(key: borrowedWindow, frame: restoredFrame))
    )
    await store.finish()

    #expect(order.value == ["layout", "focus", "frame", "warp", "layout"])
    #expect(warped.value == [CGPoint(x: borrowedFrame.midX, y: borrowedFrame.midY)])
    #expect(store.state.compositionsByDisplay[display]?.host == host.id)
  }

  @Test
  func `pointer-driven Borrow repair preserves the pointer`() async {
    let display = Self.display
    let hostWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.host")
    let borrowedWindow = WindowKey(pid: 2, windowID: 201, bundleId: "app.borrowed")
    let host = Workspace(name: "Host")
    let borrowed = Workspace(
      name: "Borrowed",
      kind: .scratchpad,
      apps: [AppAssignment(bundleIdentifier: borrowedWindow.bundleId, name: "Borrowed")],
    )
    let state = Self.makeState(workspaces: [host, borrowed]) {
      $0.$config.withLock {
        $0.settings.focus.mouseFollowsFocus = true
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
      }
      $0.focusedDisplay = display
      $0.activeWorkspacesByDisplay[display] = host.id
      $0.tilingTrees[host.id] = .leaf(hostWindow)
      $0.tilingTrees[borrowed.id] = .leaf(borrowedWindow)
      $0.compositionsByDisplay[display] = Composition(
        host: host.id,
        borrowed: [BorrowedSlot(workspace: borrowed.id, edge: .right, fraction: 0.4)],
      )
      $0.lastObservedFocusedWindow = borrowedWindow
      $0.presentationConvergenceWindows = [borrowedWindow]
      $0.presentationPreservesPointerWindows = [borrowedWindow]
    }
    let staleFrame = CGRect(x: 600, y: 0, width: 400, height: 400)
    let liveFrame = LockIsolated(staleFrame)
    let applications = LockIsolated<[FrameApplication]>([])
    let warped = LockIsolated<[CGPoint]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in CGRect(x: 0, y: 0, width: 1000, height: 800) }
      $0.windowSnapshot.onScreenWindowFrames = {
        [borrowedWindow.windowID: liveFrame.value]
      }
      $0.mouse.warp = { point in warped.withValue { $0.append(point) } }
      $0.windowTiler.apply = { application in
        applications.withValue { $0.append(application) }
        if let frame = application.windowFrames[borrowedWindow] {
          liveFrame.setValue(frame)
        }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .windowChanged(.windowFrameChanged(key: borrowedWindow, frame: staleFrame))
    )
    await store.finish()

    #expect(applications.value.count == 1)
    #expect(warped.value.isEmpty)
  }

  @Test
  func `Borrow layout verification reflows immediately without delayed MFF`() async {
    let display = Self.display
    let hostWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.host")
    let borrowedWindow = WindowKey(pid: 2, windowID: 201, bundleId: "app.borrowed")
    let host = Workspace(name: "Host")
    let borrowed = Workspace(
      name: "Borrowed",
      kind: .scratchpad,
      apps: [AppAssignment(bundleIdentifier: borrowedWindow.bundleId, name: "Borrowed")],
    )
    let state = Self.makeState(workspaces: [host, borrowed]) {
      $0.$config.withLock {
        $0.settings.focus.mouseFollowsFocus = true
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
      }
      $0.focusedDisplay = display
      $0.activeWorkspacesByDisplay[display] = host.id
      $0.tilingTrees[host.id] = .leaf(hostWindow)
      $0.tilingTrees[borrowed.id] = .leaf(borrowedWindow)
      $0.compositionsByDisplay[display] = Composition(
        host: host.id,
        borrowed: [BorrowedSlot(workspace: borrowed.id, edge: .right, fraction: 0.4)],
      )
    }
    let applications = LockIsolated<[FrameApplication]>([])
    let warped = LockIsolated<[CGPoint]>([])
    let staleFrame = CGRect(x: 600, y: 0, width: 400, height: 400)
    let liveFrame = LockIsolated(staleFrame)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in CGRect(x: 0, y: 0, width: 1_000, height: 800) }
      $0.windowSnapshot.onScreenWindowFrames = {
        [borrowedWindow.windowID: liveFrame.value]
      }
      $0.mouse.warp = { point in warped.withValue { $0.append(point) } }
      $0.windowTiler.apply = { application in
        applications.withValue { $0.append(application) }
        if let frame = application.windowFrames[borrowedWindow] {
          liveFrame.setValue(frame)
        }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .presentationLayoutApplied(
        keys: [borrowedWindow],
        preservesPointer: true,
      )
    )
    await store.finish()

    #expect(applications.value.count == 1)
    #expect(warped.value.isEmpty)
  }

  @Test
  func `a drag inside a Borrow arms the pointer exemption`() async {
    let display = Self.display
    let hostWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.host")
    let borrowedWindow = WindowKey(pid: 2, windowID: 201, bundleId: "app.borrowed")
    let host = Workspace(name: "Host")
    let borrowed = Workspace(
      name: "Borrowed",
      kind: .scratchpad,
      apps: [AppAssignment(bundleIdentifier: borrowedWindow.bundleId, name: "Borrowed")],
    )
    let workArea = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let state = Self.makeState(workspaces: [host, borrowed]) {
      $0.$config.withLock {
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
      }
      $0.focusedDisplay = display
      $0.activeWorkspacesByDisplay[display] = host.id
      $0.tilingTrees[host.id] = .leaf(hostWindow)
      $0.tilingTrees[borrowed.id] = .leaf(borrowedWindow)
      $0.compositionsByDisplay[display] = Composition(
        host: host.id,
        borrowed: [BorrowedSlot(workspace: borrowed.id, edge: .right, fraction: 0.4)],
      )
      $0.drag = .dropping(.init(dragged: hostWindow, target: hostWindow, zone: .right))
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in workArea }
      $0.dragPreview.hide = { }
      $0.windowSnapshot.onScreenWindowFrames = { [:] }
      $0.windowTiler.apply = { _ in }
      $0.mouse.warp = { _ in }
    }
    store.exhaustivity = .off

    await store.send(
      .windowChanged(
        .windowDragEnded(
          trackedWindowID: hostWindow.windowID,
          key: nil,
          frame: nil,
          pointerMoved: true,
        )
      )
    )
    await store.finish()

    // A drag is still a drag when a Borrow is up: the pointer exemption has to
    // cross the composition boundary, or the drop repair warps the cursor away.
    #expect(store.state.presentationPreservesPointerWindows.contains(hostWindow))
  }

  @Test
  func `notification activation reflows an unchanged borrowed tree`() async {
    let display = Self.display
    let hostWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.host")
    let borrowedWindow = WindowKey(pid: 2, windowID: 201, bundleId: "app.borrowed")
    let host = Workspace(name: "Host")
    let borrowed = Workspace(
      name: "Borrowed",
      kind: .scratchpad,
      apps: [AppAssignment(bundleIdentifier: borrowedWindow.bundleId, name: "Borrowed")],
    )
    let workArea = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let state = Self.makeState(workspaces: [host, borrowed]) {
      $0.$config.withLock {
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
        $0.settings.switching.followAppFocus = true
      }
      $0.focusedDisplay = display
      $0.activeWorkspacesByDisplay[display] = host.id
      $0.tilingTrees[host.id] = .leaf(hostWindow)
      $0.tilingTrees[borrowed.id] = .leaf(borrowedWindow)
      $0.compositionsByDisplay[display] = Composition(
        host: host.id,
        borrowed: [BorrowedSlot(workspace: borrowed.id, edge: .right, fraction: 0.4)],
      )
    }
    let staleFrame = CGRect(x: 600, y: 0, width: 400, height: 400)
    let liveFrame = LockIsolated(staleFrame)
    let applications = LockIsolated<[FrameApplication]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in workArea }
      $0.windowSnapshot.discoverKeys = { bundleIds, _ in
        bundleIds.contains(borrowedWindow.bundleId) ? [borrowedWindow] : []
      }
      $0.windowSnapshot.focusedWindowKey = { borrowedWindow }
      $0.windowSnapshot.frontmostApp = {
        FrontmostApp(
          pid: borrowedWindow.pid,
          bundleId: borrowedWindow.bundleId,
          name: "Borrowed",
        )
      }
      $0.windowSnapshot.onScreenWindowIDs = {
        [hostWindow.windowID, borrowedWindow.windowID]
      }
      $0.windowSnapshot.onScreenWindowFrames = {
        [borrowedWindow.windowID: liveFrame.value]
      }
      $0.windowTiler.apply = { application in
        applications.withValue { $0.append(application) }
        if let frame = application.windowFrames[borrowedWindow] {
          liveFrame.setValue(frame)
        }
      }
    }
    store.exhaustivity = .off

    // Clicking a notification activates an already-managed window without
    // changing tree membership. The focus event arms the geometry observer and
    // immediately detects KakaoTalk's already-restored half frame.
    await store.send(.appActivated(bundleId: borrowedWindow.bundleId))
    await store.finish()

    #expect(applications.value.count == 1)
    #expect(
      applications.value[0].windowFrames[borrowedWindow]
        == CGRect(x: 600, y: 0, width: 400, height: 800)
    )
    #expect(store.state.compositionsByDisplay[display]?.host == host.id)
  }

  @Test
  func `stale app activation cannot resurrect a dismissed scratchpad`() async {
    let display = Self.display
    let hostWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.host")
    let kakaoWindow = WindowKey(
      pid: 2,
      windowID: 201,
      bundleId: "com.kakao.KakaoTalkMac",
    )
    let host = Workspace(
      name: "Host",
      apps: [AppAssignment(bundleIdentifier: hostWindow.bundleId, name: "Host")],
    )
    let scratchpad = Workspace(
      name: "KakaoTalk",
      kind: .scratchpad,
      apps: [AppAssignment(bundleIdentifier: kakaoWindow.bundleId, name: "KakaoTalk")],
    )
    let state = Self.makeState(workspaces: [host, scratchpad]) {
      $0.$config.withLock {
        $0.settings.switching.followAppFocus = true
      }
      $0.focusedDisplay = display
      $0.activeWorkspacesByDisplay[display] = host.id
      $0.tilingTrees[host.id] = .leaf(hostWindow)
    }
    let activations = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.windowSnapshot.frontmostApp = {
        FrontmostApp(
          pid: hostWindow.pid,
          bundleId: hostWindow.bundleId,
          name: "Host",
        )
      }
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
    }
    store.exhaustivity = .off

    // KakaoTalk's delayed didActivate arrives after the host is already front.
    await store.send(.appActivated(bundleId: kakaoWindow.bundleId))
    await store.finish()

    #expect(store.state.compositionsByDisplay[display] == nil)
    #expect(activations.value.isEmpty)
  }

  @Test
  func `first late unhidden borrowed window resumes focus MFF and presentation arm`() async {
    let display = Self.display
    let hostWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.host")
    let kakaoWindow = WindowKey(
      pid: 2,
      windowID: 201,
      bundleId: "com.kakao.KakaoTalkMac",
    )
    let host = Workspace(name: "Host")
    let scratchpad = Workspace(
      name: "KakaoTalk",
      kind: .scratchpad,
      apps: [AppAssignment(bundleIdentifier: kakaoWindow.bundleId, name: "KakaoTalk")],
    )
    let generation: UInt64 = 7
    let composition = Composition(
      host: host.id,
      borrowed: [
        BorrowedSlot(
          workspace: scratchpad.id,
          edge: .right,
          fraction: 0.4,
        )
      ],
    )
    let state = Self.makeState(workspaces: [host, scratchpad]) {
      $0.$config.withLock {
        $0.settings.focus.mouseFollowsFocus = true
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
      }
      $0.focusedDisplay = display
      $0.activeWorkspacesByDisplay[display] = host.id
      $0.tilingTrees[host.id] = .leaf(hostWindow)
      $0.compositionsByDisplay[display] = composition
      $0.borrowGenerationByDisplay[display] = generation
      $0.pendingBorrowCompletionByDisplay[display] = .init(
        workspaceId: scratchpad.id,
        generation: generation,
      )
    }
    let borrowedFrame = CGRect(x: 600, y: 0, width: 400, height: 800)
    let dirtyBundles = LockIsolated<[String]>([])
    let observed = LockIsolated<[[String]]>([])
    let applications = LockIsolated<[FrameApplication]>([])
    let focused = LockIsolated<[WindowKey]>([])
    let warped = LockIsolated<[CGPoint]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in
        CGRect(x: 0, y: 0, width: 1_000, height: 800)
      }
      $0.windowSnapshot.markBundleDirty = { bundleId in
        dirtyBundles.withValue { $0.append(bundleId) }
      }
      $0.windowSnapshot.discoverKeys = { bundleIds, requireResizable in
        #expect(bundleIds == [kakaoWindow.bundleId])
        #expect(requireResizable)
        return [kakaoWindow]
      }
      $0.windowSnapshot.onScreenWindowFrames = {
        [kakaoWindow.windowID: borrowedFrame]
      }
      $0.windowSnapshot.focusedWindowKey = { kakaoWindow }
      $0.windowSnapshot.windowFrame = { key in
        #expect(key == kakaoWindow)
        return borrowedFrame
      }
      $0.windowObserver.observe = { bundleIds in
        observed.withValue { $0.append(bundleIds) }
      }
      $0.windowTiler.apply = { application in
        applications.withValue { $0.append(application) }
      }
      $0.focusManager.focusWindow = { key in
        focused.withValue { $0.append(key) }
      }
      $0.mouse.warp = { point in
        warped.withValue { $0.append(point) }
      }
    }
    store.exhaustivity = .off

    await store.send(.appUnhidden(bundleId: kakaoWindow.bundleId))
    await store.receive(\.syncAppWindows)
    await store.receive(\.syncAppWindowsResolved)
    await store.receive {
      guard
        case .flushCompositionAndFocus(
          let owner,
          let workspaceId,
          let receivedGeneration,
        ) = $0
      else { return false }
      return owner == display && workspaceId == scratchpad.id
        && receivedGeneration == generation
    }

    // The first write is allowed to provoke an immediate app-owned restore.
    // Both halves of the composition must therefore be monitored before the
    // layout effect begins, not only after focus finishes.
    #expect(
      store.state.presentationConvergenceWindows
        == Set([hostWindow, kakaoWindow])
    )
    await store.receive {
      guard
        case .borrowCompositionLayoutCompleted(
          let owner,
          let workspaceId,
          let receivedGeneration,
          let receivedComposition,
        ) = $0
      else { return false }
      return owner == display && workspaceId == scratchpad.id
        && receivedGeneration == generation
        && receivedComposition == composition
    }
    await store.receive {
      guard case .cursorWarpFinished(let workspaceId, let target) = $0 else {
        return false
      }
      return workspaceId == scratchpad.id && target == kakaoWindow
    }
    await store.receive {
      guard
        case .borrowFocusCompleted(
          let owner,
          let workspaceId,
          let receivedGeneration,
          let receivedComposition,
        ) = $0
      else { return false }
      return owner == display && workspaceId == scratchpad.id
        && receivedGeneration == generation
        && receivedComposition == composition
    }
    await store.receive(\.presentationLayoutApplied)
    await store.finish()

    #expect(dirtyBundles.value == [kakaoWindow.bundleId])
    #expect(observed.value.contains([kakaoWindow.bundleId]))
    #expect(store.state.tilingTrees[scratchpad.id]?.windows == [kakaoWindow])
    #expect(store.state.compositionsByDisplay[display]?.host == host.id)
    #expect(applications.value.last?.windowFrames[kakaoWindow] != nil)
    #expect(focused.value == [kakaoWindow])
    #expect(warped.value == [CGPoint(x: borrowedFrame.midX, y: borrowedFrame.midY)])
    #expect(store.state.pendingBorrowCompletionByDisplay[display] == nil)
    #expect(
      store.state.presentationConvergenceWindows
        == Set([hostWindow, kakaoWindow])
    )
  }

  @Test
  func `first late borrowed window repairs an immediate restore without a followup event`() async {
    let display = Self.display
    let hostWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.host")
    let kakaoWindow = WindowKey(
      pid: 2,
      windowID: 201,
      bundleId: "com.kakao.KakaoTalkMac",
    )
    let host = Workspace(name: "Host")
    let scratchpad = Workspace(
      name: "KakaoTalk",
      kind: .scratchpad,
      apps: [AppAssignment(bundleIdentifier: kakaoWindow.bundleId, name: "KakaoTalk")],
    )
    let generation: UInt64 = 3
    let composition = Composition(
      host: host.id,
      borrowed: [
        BorrowedSlot(
          workspace: scratchpad.id,
          edge: .right,
          fraction: 0.4,
        )
      ],
    )
    let state = Self.makeState(workspaces: [host, scratchpad]) {
      $0.$config.withLock {
        $0.settings.focus.mouseFollowsFocus = false
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
      }
      $0.focusedDisplay = display
      $0.activeWorkspacesByDisplay[display] = host.id
      $0.tilingTrees[host.id] = .leaf(hostWindow)
      $0.compositionsByDisplay[display] = composition
      $0.borrowGenerationByDisplay[display] = generation
      $0.pendingBorrowCompletionByDisplay[display] = .init(
        workspaceId: scratchpad.id,
        generation: generation,
      )
    }
    let borrowedFrame = CGRect(x: 600, y: 0, width: 400, height: 800)
    let restoredFrame = CGRect(x: 600, y: 0, width: 400, height: 400)
    let liveFrame = LockIsolated(borrowedFrame)
    let applications = LockIsolated<[FrameApplication]>([])
    let kakaoWriteCount = LockIsolated(0)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in
        CGRect(x: 0, y: 0, width: 1_000, height: 800)
      }
      $0.windowSnapshot.discoverKeys = { bundleIds, requireResizable in
        #expect(bundleIds == [kakaoWindow.bundleId])
        #expect(requireResizable)
        return [kakaoWindow]
      }
      $0.windowSnapshot.onScreenWindowFrames = {
        [kakaoWindow.windowID: liveFrame.value]
      }
      $0.windowObserver.observe = { _ in }
      $0.windowTiler.apply = { application in
        applications.withValue { $0.append(application) }
        guard let target = application.windowFrames[kakaoWindow] else { return }
        let ordinal = kakaoWriteCount.withValue {
          $0 += 1
          return $0
        }
        // KakaoTalk can restore its saved frame synchronously with the first
        // authoritative AX write. No later moved/resized event is assumed.
        liveFrame.setValue(ordinal == 1 ? restoredFrame : target)
      }
      $0.focusManager.focusWindow = { key in
        #expect(key == kakaoWindow)
      }
    }
    store.exhaustivity = .off

    await store.send(.appUnhidden(bundleId: kakaoWindow.bundleId))
    await store.receive(\.syncAppWindows)
    await store.receive(\.syncAppWindowsResolved)
    await store.receive {
      guard
        case .presentationFramesResolved(_, let frames, _) = $0
      else { return false }
      return frames[kakaoWindow.windowID] == restoredFrame
    }
    await store.receive {
      guard
        case .presentationFramesResolved(_, let frames, _) = $0
      else { return false }
      return frames[kakaoWindow.windowID] == borrowedFrame
    }
    await store.finish()

    let kakaoApplications = applications.value.filter {
      $0.windowFrames[kakaoWindow] != nil
    }
    #expect(kakaoApplications.count == 2)
    #expect(
      kakaoApplications.allSatisfy {
        $0.windowFrames[kakaoWindow] == borrowedFrame
      }
    )
    #expect(liveFrame.value == borrowedFrame)
    #expect(store.state.presentationRepairAttempts[kakaoWindow] == nil)
  }

  @Test
  func `focused registered window absent from the live tree triggers sync`() async {
    let display = Self.display
    let hostWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.host")
    let kakaoWindow = WindowKey(
      pid: 2,
      windowID: 201,
      bundleId: "com.kakao.KakaoTalkMac",
    )
    let host = Workspace(name: "Host")
    let scratchpad = Workspace(
      name: "KakaoTalk",
      kind: .scratchpad,
      apps: [AppAssignment(bundleIdentifier: kakaoWindow.bundleId, name: "KakaoTalk")],
    )
    let state = Self.makeState(workspaces: [host, scratchpad]) {
      $0.focusedDisplay = display
      $0.activeWorkspacesByDisplay[display] = host.id
      $0.tilingTrees[host.id] = .leaf(hostWindow)
      $0.compositionsByDisplay[display] = Composition(
        host: host.id,
        borrowed: [
          BorrowedSlot(
            workspace: scratchpad.id,
            edge: .right,
            fraction: 0.4,
          )
        ],
      )
    }
    let scans = LockIsolated(0)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in
        CGRect(x: 0, y: 0, width: 1_000, height: 800)
      }
      $0.windowSnapshot.discoverKeys = { _, _ in
        scans.withValue { $0 += 1 }
        return [kakaoWindow]
      }
      $0.windowSnapshot.onScreenWindowFrames = {
        [kakaoWindow.windowID: CGRect(x: 600, y: 0, width: 400, height: 800)]
      }
    }
    store.exhaustivity = .off

    await store.send(
      .windowChanged(
        .windowFocused(
          bundleId: kakaoWindow.bundleId,
          key: kakaoWindow,
        )
      )
    )
    await store.receive(\.syncAppWindows)
    await store.receive(\.syncAppWindowsResolved)
    await store.finish()

    #expect(scans.value == 1)
    #expect(store.state.tilingTrees[scratchpad.id]?.windows == [kakaoWindow])
  }

  @Test
  func `multi-stage app restore converges without a settlement delay`() async {
    let display = Self.display
    let window = WindowKey(pid: 1, windowID: 101, bundleId: "app.restore")
    let workspace = Workspace(name: "Restore")
    let state = Self.makeState(workspaces: [workspace]) {
      $0.$config.withLock {
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
      }
      $0.focusedDisplay = display
      $0.activeWorkspacesByDisplay[display] = workspace.id
      $0.tilingTrees[workspace.id] = .leaf(window)
      $0.presentationConvergenceWindows = [window]
    }
    let firstRestore = CGRect(x: 0, y: 0, width: 700, height: 500)
    let secondRestore = CGRect(x: 0, y: 0, width: 800, height: 600)
    let target = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let liveFrame = LockIsolated(firstRestore)
    let applications = LockIsolated<[FrameApplication]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in target }
      $0.windowSnapshot.onScreenWindowFrames = {
        [window.windowID: liveFrame.value]
      }
      $0.windowTiler.apply = { application in
        let count = applications.withValue {
          $0.append(application)
          return $0.count
        }
        // The app rejects/restores the first correction, then accepts the
        // second. Completion verification must see both without clock advance.
        liveFrame.setValue(count == 1 ? secondRestore : target)
      }
    }
    store.exhaustivity = .off

    await store.send(
      .windowChanged(.windowFrameChanged(key: window, frame: firstRestore))
    )
    await store.receive {
      guard
        case .presentationFramesResolved(let keys, let frames, _) = $0
      else { return false }
      return keys == [window] && frames[window.windowID] == secondRestore
    }
    await store.receive {
      guard
        case .presentationFramesResolved(let keys, let frames, _) = $0
      else { return false }
      return keys == [window] && frames[window.windowID] == target
    }
    await store.finish()

    #expect(applications.value.count == 2)
    #expect(store.state.presentationConvergenceWindows.contains(window))
    #expect(store.state.presentationRepairAttempts[window] == nil)
  }

  @Test
  func `dirty presentation verification waits for the current repair writer`() async throws {
    let display = Self.display
    let window = WindowKey(pid: 1, windowID: 101, bundleId: "app.restore")
    let workspace = Workspace(name: "Restore")
    let target = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let drifted = CGRect(x: 0, y: 0, width: 700, height: 500)
    let state = Self.makeState(workspaces: [workspace]) {
      $0.$config.withLock {
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
      }
      $0.focusedDisplay = display
      $0.activeWorkspacesByDisplay[display] = workspace.id
      $0.tilingTrees[workspace.id] = .leaf(window)
      $0.presentationConvergenceWindows = [window]
      $0.isPresentationSnapshotInFlight = true
      $0.dirtyPresentationSnapshotWindows = [window]
    }
    let events = LockIsolated<[String]>([])
    let (repairStarted, repairStartedContinuation) =
      AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let (releaseRepair, releaseRepairContinuation) =
      AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in target }
      $0.windowTiler.apply = { _ in
        events.withValue { $0.append("repair-started") }
        repairStartedContinuation.yield(())
        repairStartedContinuation.finish()
        for await _ in releaseRepair { break }
        events.withValue { $0.append("repair-finished") }
      }
      $0.windowSnapshot.onScreenWindowFrames = {
        events.withValue { $0.append("snapshot") }
        return [window.windowID: target]
      }
    }
    store.exhaustivity = .off

    var repairStartedIterator = repairStarted.makeAsyncIterator()
    await store.send(
      .presentationFramesResolved(
        keys: [window],
        currentFrames: [window.windowID: drifted],
        layoutGeneration: 0,
      )
    )
    #expect(await repairStartedIterator.next() != nil)
    #expect(events.value == ["repair-started"])

    releaseRepairContinuation.finish()
    await store.finish()

    let completedEvents = events.value
    let repairFinishedIndex = try #require(
      completedEvents.firstIndex(of: "repair-finished")
    )
    let firstSnapshotIndex = try #require(
      completedEvents.firstIndex(of: "snapshot")
    )
    #expect(repairFinishedIndex < firstSnapshotIndex)
  }

  @Test
  func `stale presentation snapshot waits for the replacement writer`() async {
    let display = Self.display
    let window = WindowKey(pid: 1, windowID: 101, bundleId: "app.restore")
    let workspace = Workspace(name: "Restore")
    let target = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let drifted = CGRect(x: 0, y: 0, width: 700, height: 500)
    let state = Self.makeState(workspaces: [workspace]) {
      $0.$config.withLock {
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
      }
      $0.focusedDisplay = display
      $0.activeWorkspacesByDisplay[display] = workspace.id
      $0.tilingTrees[workspace.id] = .leaf(window)
      $0.presentationConvergenceWindows = [window]
      $0.isPresentationSnapshotInFlight = true
      $0.layoutWriteGeneration = 2
      $0.activeLayoutWriteGenerations = [2]
    }
    let snapshotCount = LockIsolated(0)
    let applications = LockIsolated<[FrameApplication]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in target }
      $0.windowSnapshot.onScreenWindowFrames = {
        snapshotCount.withValue { $0 += 1 }
        return [window.windowID: target]
      }
      $0.windowTiler.apply = { application in
        applications.withValue { $0.append(application) }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .presentationFramesResolved(
        keys: [window],
        currentFrames: [window.windowID: drifted],
        layoutGeneration: 1,
      )
    )
    #expect(store.state.dirtyPresentationSnapshotWindows == [window])
    #expect(snapshotCount.value == 0)
    #expect(applications.value.isEmpty)

    await store.send(
      .layoutWriteFinished(generation: 2, verificationKeys: [])
    )
    await store.receive {
      guard
        case .presentationFramesResolved(
          let keys,
          let frames,
          let layoutGeneration,
        ) = $0
      else { return false }
      return keys == [window]
        && frames[window.windowID] == target
        && layoutGeneration == 2
    }
    await store.finish()

    #expect(snapshotCount.value == 1)
    #expect(applications.value.isEmpty)
    #expect(store.state.activeLayoutWriteGenerations.isEmpty)
    #expect(store.state.dirtyPresentationSnapshotWindows.isEmpty)
    #expect(!store.state.isPresentationSnapshotInFlight)
  }

  @Test
  func `cancelled repair retains verification through its replacement writer`() async {
    let window = WindowKey(pid: 1, windowID: 101, bundleId: "app.restore")
    let workspace = Workspace(name: "Restore")
    let target = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let state = Self.makeState(workspaces: [workspace]) {
      $0.$config.withLock {
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
      }
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = .leaf(window)
      $0.presentationConvergenceWindows = [window]
      $0.layoutWriteGeneration = 2
      $0.activeLayoutWriteGenerations = [1, 2]
    }
    let snapshotCount = LockIsolated(0)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in target }
      $0.windowSnapshot.onScreenWindowFrames = {
        snapshotCount.withValue { $0 += 1 }
        return [window.windowID: target]
      }
    }
    store.exhaustivity = .off

    // Generation 1 is the repair writer cancelled by generation 2. Its keys
    // must remain behind the shared writer barrier until the replacement ends.
    await store.send(
      .layoutWriteFinished(
        generation: 1,
        verificationKeys: [window],
      )
    )
    #expect(store.state.activeLayoutWriteGenerations == [2])
    #expect(store.state.dirtyPresentationSnapshotWindows == [window])
    #expect(snapshotCount.value == 0)

    await store.send(
      .layoutWriteFinished(generation: 2, verificationKeys: [])
    )
    await store.receive {
      guard
        case .presentationFramesResolved(
          let keys,
          let frames,
          let layoutGeneration,
        ) = $0
      else { return false }
      return keys == [window]
        && frames[window.windowID] == target
        && layoutGeneration == 2
    }
    await store.finish()

    #expect(snapshotCount.value == 1)
    #expect(store.state.activeLayoutWriteGenerations.isEmpty)
    #expect(store.state.dirtyPresentationSnapshotWindows.isEmpty)
    #expect(!store.state.isPresentationSnapshotInFlight)
  }

  @Test
  func `balance with auto balance off rebuilds canonical BSP topology`() async {
    let left = WindowKey(pid: 1, windowID: 101, bundleId: "app.left")
    let topRight = WindowKey(pid: 2, windowID: 201, bundleId: "app.top-right")
    let bottomRight = WindowKey(pid: 3, windowID: 301, bundleId: "app.bottom-right")
    let workspace = Workspace(name: "Work")
    let workArea = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let state = Self.makeState(workspaces: [workspace]) {
      $0.$config.withLock {
        $0.settings.layout.autoBalance = .none
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
      }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = .branch(
        BSPBranch(
          split: .vertical,
          ratio: 0.34,
          left: .branch(BSPBranch(
            split: .horizontal,
            ratio: 0.72,
            left: .leaf(left),
            right: .leaf(topRight),
          )),
          right: .leaf(bottomRight),
        )
      )
    }
    let applications = LockIsolated<[FrameApplication]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in workArea }
      $0.windowTiler.apply = { request in
        applications.withValue { $0.append(request) }
      }
    }
    store.exhaustivity = .off

    await store.send(.bspOpResolved(windowKey: left, op: .balance))
    await store.finish()

    guard
      case .branch(let root) = store.state.tilingTrees[workspace.id],
      case .branch(let right) = root.right
    else {
      Issue.record("Expected master-and-remainder BSP topology")
      return
    }
    #expect(root.split == .vertical)
    #expect(root.ratio == 0.5)
    #expect(right.split == .horizontal)
    #expect(right.ratio == 0.5)
    #expect(root.left.windows == [left])
    #expect(root.right.windows == [topRight, bottomRight])
    #expect(applications.value.last?.forceAllFrames == true)
  }

  @Test
  func `borrowed swap commits the newest complete composition before MFF`() async {
    let display = Self.display
    let hostWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.host")
    let left = WindowKey(pid: 2, windowID: 201, bundleId: "app.terminal")
    let right = WindowKey(pid: 2, windowID: 202, bundleId: "app.terminal")
    let host = Workspace(name: "Host")
    let borrowed = Workspace(
      name: "Terminal",
      apps: [AppAssignment(bundleIdentifier: left.bundleId, name: "Terminal")],
    )
    let workArea = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let state = Self.makeState(workspaces: [host, borrowed]) {
      $0.$config.withLock {
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
        $0.settings.focus.mouseFollowsFocus = true
      }
      $0.focusedDisplay = display
      $0.activeWorkspacesByDisplay[display] = host.id
      $0.tilingTrees[host.id] = .leaf(hostWindow)
      $0.tilingTrees[borrowed.id] = .branch(
        BSPBranch(
          split: .vertical,
          ratio: 0.5,
          left: .leaf(left),
          right: .leaf(right),
        )
      )
      $0.compositionsByDisplay[display] = Composition(
        host: host.id,
        borrowed: [BorrowedSlot(workspace: borrowed.id, edge: .right, fraction: 0.4)],
      )
    }
    let liveFrame = CGRect(x: 800, y: 0, width: 200, height: 800)
    let order = LockIsolated<[String]>([])
    let applications = LockIsolated<[FrameApplication]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in workArea }
      $0.windowTiler.apply = { request in
        order.withValue { $0.append("layout") }
        applications.withValue { $0.append(request) }
      }
      $0.windowSnapshot.focusedWindowKey = { left }
      $0.windowSnapshot.windowFrame = { key in
        #expect(key == left)
        order.withValue { $0.append("frame") }
        return liveFrame
      }
      $0.mouse.warp = { point in
        #expect(point == CGPoint(x: liveFrame.midX, y: liveFrame.midY))
        order.withValue { $0.append("warp") }
      }
    }
    store.exhaustivity = .off

    await store.send(
      WorkspaceActivationFeature.Action.bspOpResolved(
        windowKey: left,
        op: .swap(.east),
      )
    )
    await store.receive {
      guard case .settleFocusAfterLayout(let key, let workspaceId, let shouldFocus) = $0
      else { return false }
      return key == left && workspaceId == borrowed.id && !shouldFocus
    }
    await store.receive {
      guard case .cursorWarpFinished(let workspaceId, let target) = $0 else { return false }
      return workspaceId == borrowed.id && target == left
    }
    await store.finish()

    #expect(order.value == ["layout", "frame", "warp"])
    #expect(applications.value.count == 1)
    #expect(applications.value[0].forceAllFrames)
    #expect(Set(applications.value[0].windowFrames.keys) == [hostWindow, left, right])
  }

  @Test
  func `window server destroy prunes background display without stealing focus`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let focusedA = WindowKey(pid: 1, windowID: 101, bundleId: "app.a")
    let closedB = WindowKey(pid: 2, windowID: 201, bundleId: "app.b")
    let survivorB = WindowKey(pid: 2, windowID: 202, bundleId: "app.b")
    let wsA = Workspace(
      name: "A",
      apps: [AppAssignment(bundleIdentifier: focusedA.bundleId, name: "A")],
    )
    let wsB = Workspace(
      name: "B",
      apps: [AppAssignment(bundleIdentifier: closedB.bundleId, name: "B")],
    )
    let state = Self.makeState(workspaces: [wsA, wsB]) {
      $0.$config.withLock { $0.settings.focus.refocusOnClose = true }
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [displayA: wsA.id, displayB: wsB.id]
      $0.tilingTrees[wsA.id] = .leaf(focusedA)
      $0.tilingTrees[wsB.id] = .branch(
        BSPBranch(
          split: .vertical,
          ratio: 0.5,
          left: .leaf(closedB),
          right: .leaf(survivorB),
        )
      )
      $0.mruWindows[wsB.id] = [closedB, survivorB]
    }
    let applied = LockIsolated<[Set<WindowKey>]>([])
    let focused = LockIsolated<[WindowKey]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.windowSnapshot.onScreenWindowIDs = { [focusedA.windowID, survivorB.windowID] }
      $0.windowSnapshot.focusedWindowKey = { focusedA }
      $0.windowTiler.apply = { request in
        applied.withValue { $0.append(Set(request.windowFrames.keys)) }
      }
      $0.focusManager.focusWindow = { key in focused.withValue { $0.append(key) } }
    }
    store.exhaustivity = .off

    await store.send(.windowServerWindowEvent(.terminated(closedB.windowID)))
    await store.finish()

    #expect(store.state.tilingTrees[wsA.id]?.windows == [focusedA])
    #expect(store.state.tilingTrees[wsB.id]?.windows == [survivorB])
    #expect(applied.value == [[survivorB]])
    #expect(focused.value.isEmpty)
    #expect(store.state.focusedDisplay == displayA)
  }

  @Test
  func `ax close sync routes to background display without stealing focus`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let focusedA = WindowKey(pid: 1, windowID: 101, bundleId: "app.a")
    let closedB = WindowKey(pid: 2, windowID: 201, bundleId: "app.b")
    let survivorB = WindowKey(pid: 2, windowID: 202, bundleId: "app.b")
    let wsA = Workspace(name: "A")
    let wsB = Workspace(
      name: "B",
      apps: [AppAssignment(bundleIdentifier: closedB.bundleId, name: "B")],
    )
    let state = Self.makeState(workspaces: [wsA, wsB]) {
      $0.$config.withLock { $0.settings.focus.refocusOnClose = true }
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [displayA: wsA.id, displayB: wsB.id]
      $0.tilingTrees[wsA.id] = .leaf(focusedA)
      $0.tilingTrees[wsB.id] = .branch(
        BSPBranch(
          split: .vertical,
          ratio: 0.5,
          left: .leaf(closedB),
          right: .leaf(survivorB),
        )
      )
    }
    let focused = LockIsolated<[WindowKey]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.windowSnapshot.discoverKeys = { _, _ in [survivorB] }
      $0.windowSnapshot.focusedWindowKey = { focusedA }
      $0.focusManager.focusWindow = { key in focused.withValue { $0.append(key) } }
    }
    store.exhaustivity = .off

    await store.send(.syncAppWindows(bundleId: closedB.bundleId))
    await store.receive(\.syncAppWindowsResolved)
    await store.finish()

    #expect(store.state.tilingTrees[wsA.id]?.windows == [focusedA])
    #expect(store.state.tilingTrees[wsB.id]?.windows == [survivorB])
    #expect(focused.value.isEmpty)
  }

  @Test
  func `shared app sync reconciles every visible display owner`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let onA = WindowKey(pid: 1, windowID: 101, bundleId: "app.shared")
    let closedB = WindowKey(pid: 1, windowID: 202, bundleId: "app.shared")
    let wsA = Workspace(name: "A")
    let wsB = Workspace(name: "B")
    let state = Self.makeState(workspaces: [wsA, wsB]) {
      $0.$config.withLock {
        $0.sharedApps = [SharedApp(bundleIdentifier: onA.bundleId, name: "Shared")]
      }
      $0.connectedDisplays = [displayA, displayB]
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [displayA: wsA.id, displayB: wsB.id]
      $0.tilingTrees = [wsA.id: .leaf(onA), wsB.id: .leaf(closedB)]
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { display in
        display == displayA
          ? CGRect(x: 0, y: 0, width: 1000, height: 800)
          : CGRect(x: 1000, y: 0, width: 1000, height: 800)
      }
      $0.windowSnapshot.discoverKeys = { _, _ in [onA] }
      $0.windowSnapshot.windowFrame = { key in
        key == onA
          ? CGRect(x: 100, y: 100, width: 400, height: 300)
          : nil
      }
      $0.windowSnapshot.focusedWindowKey = { onA }
    }
    store.exhaustivity = .off

    await store.send(.syncAppWindows(bundleId: onA.bundleId))
    await store.receive(\.syncAppWindowsResolved)
    await store.finish()

    #expect(store.state.tilingTrees[wsA.id]?.windows == [onA])
    #expect(store.state.tilingTrees[wsB.id] == nil)
    #expect(store.state.focusedDisplay == displayA)
  }

  @Test
  func `resolved floating set feeds overlay and markers`() async {
    let key = WindowKey(pid: 1, windowID: 101, bundleId: "app.float")
    let ws = Workspace(
      name: "one",
      apps: [
        AppAssignment(
          bundleIdentifier: key.bundleId,
          name: "Float",
          layout: .floating,
        )
      ],
    )
    let state = Self.makeState(workspaces: [ws]) {
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = ws.id
      $0.$config.withLock { $0.settings.marker.floatingEnabled = true }
    }
    let overlayKeys = LockIsolated<Set<WindowKey>>([])
    let markerKeys = LockIsolated<Set<WindowKey>>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.floatingOverlay.setFloating = { keys in overlayKeys.withValue { $0 = keys } }
      $0.marker.setTargets = { targets, _, _, _ in
        markerKeys.withValue { $0 = Set(targets.keys) }
      }
    }
    store.exhaustivity = .off

    await store.send(.floatingPresentationResolved([key]))
    await store.finish()

    #expect(overlayKeys.value == [key])
    #expect(markerKeys.value == [key])
  }

  @Test
  func `move events do not demote A pending resize`() async {
    let key = WindowKey(pid: 1, windowID: 100, bundleId: "app.one")
    let resizeFrame = CGRect(x: 0, y: 0, width: 500, height: 400)
    let store = TestStore(initialState: Self.makeState(workspaces: [])) {
      WorkspaceActivationFeature()
    } withDependencies: {
      // The drag pipeline drives the preview overlay on every event.
      $0.dragPreview.show = { _, _ in }
      $0.dragPreview.hide = { }
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
    await store.send(
      .windowChanged(
        .windowDragEnded(
          trackedWindowID: key.windowID,
          key: nil,
          frame: nil,
          pointerMoved: true,
        )
      )
    )
    #expect(store.state.drag == .idle)
  }

  @Test
  func `mouse-up geometry recovers a short resize with no AX event`() async {
    let display = Self.display
    let left = WindowKey(pid: 1, windowID: 101, bundleId: "app.left")
    let right = WindowKey(pid: 2, windowID: 202, bundleId: "app.right")
    let workspace = Workspace(name: "Drag")
    let workArea = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let initialTree = BSPNode.branch(
      BSPBranch(
        split: .vertical,
        ratio: 0.5,
        left: .leaf(left),
        right: .leaf(right),
      )
    )
    let state = Self.makeState(workspaces: [workspace]) {
      $0.$config.withLock {
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
      }
      $0.focusedDisplay = display
      $0.activeWorkspacesByDisplay[display] = workspace.id
      $0.tilingTrees[workspace.id] = initialTree
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in workArea }
      $0.dragPreview.hide = { }
      $0.windowTiler.apply = { _ in }
    }
    store.exhaustivity = .off

    await store.send(
      .windowChanged(
        .windowDragEnded(
          trackedWindowID: left.windowID,
          key: left,
          frame: CGRect(x: 0, y: 0, width: 600, height: 800),
          pointerMoved: true,
        )
      )
    )
    await store.finish()

    let expectedTree = BSPNode.branch(
      BSPBranch(
        split: .vertical,
        ratio: 0.6,
        left: .leaf(left),
        right: .leaf(right),
      )
    )
    #expect(store.state.tilingTrees[workspace.id] == expectedTree)
    #expect(store.state.drag == .idle)
  }

  @Test
  func `drop converges every tile after the app restores an old frame`() async throws {
    let left = WindowKey(pid: 1, windowID: 101, bundleId: "org.alacritty")
    let topRight = WindowKey(pid: 2, windowID: 201, bundleId: "com.mitchellh.ghostty")
    let bottomRight = WindowKey(pid: 2, windowID: 202, bundleId: topRight.bundleId)
    let workspace = Workspace(name: "Terminal")
    let workArea = await MainActor.run {
      ScreenGeometry.workArea(for: Self.display)
    }
    let initialTree = BSPNode.branch(
      BSPBranch(
        split: .vertical,
        ratio: 0.5,
        left: .leaf(left),
        right: .branch(
          BSPBranch(
            split: .horizontal,
            ratio: 0.5,
            left: .leaf(topRight),
            right: .leaf(bottomRight),
          )
        ),
      )
    )
    let initialFrames = initialTree.frames(in: workArea, gap: 0)
    let state = Self.makeState(workspaces: [workspace]) {
      $0.$config.withLock {
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
      }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = initialTree
      $0.drag = .dropping(
        .init(dragged: bottomRight, target: topRight, zone: .right)
      )
    }
    let liveFrames = LockIsolated(
      Dictionary(uniqueKeysWithValues: initialFrames.map { ($0.key.windowID, $0.value) })
    )
    let applications = LockIsolated<[FrameApplication]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in workArea }
      $0.dragPreview.hide = { }
      $0.windowSnapshot.onScreenWindowFrames = { liveFrames.value }
      $0.windowTiler.apply = { application in
        applications.withValue { $0.append(application) }
        liveFrames.withValue { frames in
          for (key, frame) in application.windowFrames {
            frames[key.windowID] = frame
          }
        }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .windowChanged(
        .windowDragEnded(
          trackedWindowID: bottomRight.windowID,
          key: nil,
          frame: nil,
          pointerMoved: true,
        )
      )
    )
    await store.finish()

    let firstApplication = try #require(applications.value.first)
    #expect(firstApplication.forceAllFrames)
    #expect(Set(firstApplication.windowFrames.keys) == [left, topRight, bottomRight])
    #expect(
      store.state.presentationConvergenceWindows
        == [left, topRight, bottomRight]
    )
    let targetFrame = try #require(firstApplication.windowFrames[topRight])
    let staleFrame = try #require(initialFrames[topRight])
    #expect(targetFrame.height > staleFrame.height)
    #expect(staleFrame.height == workArea.height / 2)

    liveFrames.withValue { $0[topRight.windowID] = staleFrame }
    await store.send(
      .windowChanged(
        .windowFrameChanged(key: topRight, frame: staleFrame)
      )
    )
    await store.finish()

    #expect(applications.value.count == 2)
    #expect(applications.value.last?.windowFrames[topRight] == targetFrame)
    #expect(liveFrames.value[topRight.windowID] == targetFrame)
  }

  @Test
  func `a drop never warps the cursor while repairing the app's restored frame`() async throws {
    let left = WindowKey(pid: 1, windowID: 101, bundleId: "org.alacritty")
    let topRight = WindowKey(pid: 2, windowID: 201, bundleId: "com.mitchellh.ghostty")
    let bottomRight = WindowKey(pid: 2, windowID: 202, bundleId: topRight.bundleId)
    let workspace = Workspace(name: "Terminal")
    let workArea = await MainActor.run {
      ScreenGeometry.workArea(for: Self.display)
    }
    let initialTree = BSPNode.branch(
      BSPBranch(
        split: .vertical,
        ratio: 0.5,
        left: .leaf(left),
        right: .branch(
          BSPBranch(
            split: .horizontal,
            ratio: 0.5,
            left: .leaf(topRight),
            right: .leaf(bottomRight),
          )
        ),
      )
    )
    let initialFrames = initialTree.frames(in: workArea, gap: 0)
    let state = Self.makeState(workspaces: [workspace]) {
      $0.$config.withLock {
        $0.settings.layout.gapInner = 0
        $0.settings.layout.gapOuter = 0
        $0.settings.focus.mouseFollowsFocus = true
      }
      $0.focusedDisplay = Self.display
      $0.activeWorkspacesByDisplay[Self.display] = workspace.id
      $0.tilingTrees[workspace.id] = initialTree
      $0.lastObservedFocusedWindow = topRight
      $0.drag = .dropping(
        .init(dragged: bottomRight, target: topRight, zone: .right)
      )
    }
    let liveFrames = LockIsolated(
      Dictionary(uniqueKeysWithValues: initialFrames.map { ($0.key.windowID, $0.value) })
    )
    let warps = LockIsolated<[CGPoint]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { _ in workArea }
      $0.dragPreview.hide = { }
      $0.windowSnapshot.onScreenWindowFrames = { liveFrames.value }
      $0.mouse.warp = { point in warps.withValue { $0.append(point) } }
      $0.windowTiler.apply = { application in
        liveFrames.withValue { frames in
          for (key, frame) in application.windowFrames {
            frames[key.windowID] = frame
          }
        }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .windowChanged(
        .windowDragEnded(
          trackedWindowID: bottomRight.windowID,
          key: nil,
          frame: nil,
          pointerMoved: true,
        )
      )
    )
    await store.finish()

    // The pointer caused this layout, so the tiles it touched are exempt from
    // being chased by the cursor.
    #expect(store.state.presentationPreservesPointerWindows.contains(topRight))

    // The app restores its pre-drop frame; the repair writes the target frame
    // back, and the cursor must stay exactly where the user released it.
    let staleFrame = try #require(initialFrames[topRight])
    liveFrames.withValue { $0[topRight.windowID] = staleFrame }
    await store.send(
      .windowChanged(
        .windowFrameChanged(key: topRight, frame: staleFrame)
      )
    )
    await store.finish()

    #expect(warps.value.isEmpty)
  }

  @Test
  func `plain move snaps back on mouse up`() async {
    let key = WindowKey(pid: 1, windowID: 100, bundleId: "app.one")
    let store = TestStore(initialState: Self.makeState(workspaces: [])) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.dragPreview.show = { _, _ in }
      $0.dragPreview.hide = { }
    }
    store.exhaustivity = .off

    // No tree → no drop target → the drag is a bare move.
    await store.send(
      .windowChanged(.windowMoved(key: key, frame: CGRect(x: 5, y: 5, width: 500, height: 400)))
    )
    #expect(store.state.drag == .moving(key))
    await store.send(
      .windowChanged(
        .windowDragEnded(
          trackedWindowID: key.windowID,
          key: nil,
          frame: nil,
          pointerMoved: true,
        )
      )
    )
    #expect(store.state.drag == .idle)
  }

  @Test
  func `background display move snaps its owning tree`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let keyA = WindowKey(pid: 1, windowID: 101, bundleId: "app.a")
    let keyB = WindowKey(pid: 2, windowID: 202, bundleId: "app.b")
    let wsA = Workspace(name: "A")
    let wsB = Workspace(name: "B")
    let state = Self.makeState(workspaces: [wsA, wsB]) {
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [displayA: wsA.id, displayB: wsB.id]
      $0.tilingTrees = [wsA.id: .leaf(keyA), wsB.id: .leaf(keyB)]
      $0.drag = .moving(keyB)
    }
    let applied = LockIsolated<[Set<WindowKey>]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.dragPreview.hide = { }
      $0.windowTiler.apply = { request in
        applied.withValue { $0.append(Set(request.windowFrames.keys)) }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .windowChanged(
        .windowDragEnded(
          trackedWindowID: keyB.windowID,
          key: nil,
          frame: nil,
          pointerMoved: true,
        )
      )
    )
    await store.finish()

    #expect(store.state.drag == .idle)
    #expect(applied.value == [[keyB]])
  }

  @Test
  func `repeated move in the same drop decision does not replay the preview`() async {
    let key = WindowKey(pid: 1, windowID: 100, bundleId: "app.one")
    let hides = LockIsolated(0)
    let store = TestStore(initialState: Self.makeState(workspaces: [])) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.dragPreview.show = { _, _ in }
      $0.dragPreview.hide = { hides.withValue { $0 += 1 } }
    }
    store.exhaustivity = .off

    let moved = WorkspaceActivationFeature.Action.windowChanged(
      .windowMoved(key: key, frame: CGRect(x: 5, y: 5, width: 500, height: 400))
    )
    await store.send(moved)
    await store.send(moved)
    await store.finish()

    #expect(hides.value == 1)
  }

  @Test
  func `toggling membership moves the app to the active workspace`() async {
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
  func `toggling membership never assigns tatami itself`() async {
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
        bundleId: "dev.PangMo5.Tatami.dev",
        name: "Tatami",
        edit: .toggleInActiveWorkspace,
      )
    )
    #expect(store.state.config.activeProfile?.workspaces.first?.apps.isEmpty == true)
  }

  @Test
  func `display geometry change reflows every visible display`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let keyA = WindowKey(pid: 1, windowID: 101, bundleId: "app.a")
    let keyB = WindowKey(pid: 2, windowID: 202, bundleId: "app.b")
    let wsA = Workspace(name: "A")
    let wsB = Workspace(name: "B")
    let state = Self.makeState(workspaces: [wsA, wsB]) {
      $0.connectedDisplays = [displayA, displayB]
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [displayA: wsA.id, displayB: wsB.id]
      $0.tilingTrees = [wsA.id: .leaf(keyA), wsB.id: .leaf(keyB)]
    }
    let applied = LockIsolated<[Set<WindowKey>]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.workArea = { display in
        display == displayA
          ? CGRect(x: 0, y: 0, width: 1000, height: 800)
          : CGRect(x: 1000, y: 0, width: 1200, height: 900)
      }
      $0.windowTiler.apply = { request in
        applied.withValue { $0.append(Set(request.windowFrames.keys)) }
      }
    }
    store.exhaustivity = .off

    // Same identities means DisplayClient detected a geometry-only change.
    await store.send(.displaysReconfigured([displayA, displayB]))
    await store.receive {
      guard case .displayGeometryChanged = $0 else { return false }
      return true
    }
    await store.finish()

    #expect(Set(applied.value) == Set([[keyA], [keyB]]))
    #expect(store.state.activeWorkspacesByDisplay == [displayA: wsA.id, displayB: wsB.id])
  }

  @Test
  func `display UUID promotion preserves and canonicalizes live runtime state`() async {
    let legacyDisplay = DisplayName("Studio")
    let liveDisplay = DisplayName(uuid: "studio-display", name: "Studio")
    let host = Workspace(name: "Host")
    let previous = Workspace(name: "Previous")
    let borrowed = Workspace(name: "Borrowed")
    let composition = Composition(
      host: host.id,
      borrowed: [
        BorrowedSlot(workspace: borrowed.id, edge: .right, fraction: 0.4)
      ],
    )
    let pendingBorrow = WorkspaceActivationFeature.State.PendingBorrowCompletion(
      workspaceId: borrowed.id,
      generation: 7,
    )
    let state = Self.makeState(workspaces: [host, previous, borrowed]) {
      $0.isTilingPaused = true
      $0.connectedDisplays = [legacyDisplay]
      $0.activeWorkspacesByDisplay = [legacyDisplay: host.id]
      $0.previousWorkspacesByDisplay = [legacyDisplay: previous.id]
      $0.displayWorkspaceHistory = [legacyDisplay: [host.id, previous.id]]
      $0.lastActiveDisplay = [host.id: legacyDisplay]
      $0.focusedDisplay = legacyDisplay
      $0.activatingDisplay = legacyDisplay
      $0.compositionsByDisplay = [legacyDisplay: composition]
      $0.borrowGenerationByDisplay = [legacyDisplay: 7]
      $0.pendingBorrowCompletionByDisplay = [legacyDisplay: pendingBorrow]
      $0.pendingCenterWarps[borrowed.id] = WindowKey(
        pid: 1,
        windowID: 101,
        bundleId: "app.borrowed",
      )
      $0.borrowCapture = .init(display: legacyDisplay, workspaceId: borrowed.id)
      $0.pendingDisplayRestores = [
        DisplayAssignment(display: legacyDisplay, workspace: host.id)
      ]
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    }
    store.exhaustivity = .off

    await store.send(.displaysReconfigured([liveDisplay]))
    await store.receive(\.displayGeometryChanged)
    await store.finish()

    #expect(store.state.connectedDisplays == [liveDisplay])
    #expect(store.state.activeWorkspacesByDisplay == [liveDisplay: host.id])
    #expect(store.state.previousWorkspacesByDisplay == [liveDisplay: previous.id])
    #expect(
      store.state.displayWorkspaceHistory
        == [liveDisplay: [host.id, previous.id]]
    )
    #expect(store.state.lastActiveDisplay == [host.id: liveDisplay])
    #expect(store.state.focusedDisplay == liveDisplay)
    #expect(store.state.activatingDisplay == liveDisplay)
    #expect(store.state.compositionsByDisplay == [liveDisplay: composition])
    #expect(store.state.borrowGenerationByDisplay == [liveDisplay: 7])
    #expect(
      store.state.pendingBorrowCompletionByDisplay
        == [liveDisplay: pendingBorrow]
    )
    #expect(store.state.pendingCenterWarps[borrowed.id] != nil)
    #expect(store.state.borrowCapture?.display == liveDisplay)
    #expect(store.state.pendingDisplayRestores.first?.display == liveDisplay)
  }

  @Test
  func `activation clears a legacy keyed composition on the target display`() async {
    let legacyDisplay = DisplayName("Studio")
    let liveDisplay = DisplayName(uuid: "studio-display", name: "Studio")
    let host = Workspace(name: "Host")
    let borrowed = Workspace(name: "Borrowed")
    let target = Workspace(name: "Target")
    let state = Self.makeState(workspaces: [host, borrowed, target]) {
      $0.isTilingPaused = true
      $0.connectedDisplays = [liveDisplay]
      $0.focusedDisplay = legacyDisplay
      $0.activeWorkspacesByDisplay = [legacyDisplay: host.id]
      $0.compositionsByDisplay = [
        legacyDisplay: Composition(
          host: host.id,
          borrowed: [
            BorrowedSlot(workspace: borrowed.id, edge: .right, fraction: 0.4)
          ],
        )
      ]
      $0.borrowGenerationByDisplay = [legacyDisplay: 3]
      $0.pendingBorrowCompletionByDisplay[legacyDisplay] = .init(
        workspaceId: borrowed.id,
        generation: 3,
      )
      $0.pendingCenterWarps[borrowed.id] = WindowKey(
        pid: 1,
        windowID: 101,
        bundleId: "app.borrowed",
      )
    }
    let requests = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.current = { liveDisplay }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        requests.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activate(
      workspaceId: target.id,
      setFocus: true,
      interactionDisplay: liveDisplay,
    ))
    #expect(store.state.compositionsByDisplay.isEmpty)
    #expect(store.state.borrowGenerationByDisplay[legacyDisplay] == 4)
    #expect(store.state.pendingBorrowCompletionByDisplay[legacyDisplay] == nil)
    #expect(store.state.pendingCenterWarps[borrowed.id] == nil)
    await store.receive {
      guard case .activationCompleted(let id, let display, _) = $0 else { return false }
      return id == target.id && display?.matches(liveDisplay) == true
    }
    await store.finish()

    #expect(requests.value.last?.targetDisplay == liveDisplay)
  }

  @Test
  func `floating presentation includes every visible monitor`() {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let wsA = Workspace(
      name: "A",
      apps: [AppAssignment(bundleIdentifier: "float.a", name: "A", layout: .floating)],
    )
    let wsB = Workspace(
      name: "B",
      apps: [AppAssignment(bundleIdentifier: "float.b", name: "B", layout: .floating)],
    )
    let state = Self.makeState(workspaces: [wsA, wsB]) {
      $0.activeWorkspacesByDisplay = [displayA: wsA.id, displayB: wsB.id]
    }

    #expect(Set(WorkspaceActivationFeature.floatingBundleIds(state: state)) == ["float.a", "float.b"])
  }

  @Test
  func `borrow refuses a workspace already visible on another monitor`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let wsA = Workspace(name: "A")
    let wsB = Workspace(name: "B")
    let state = Self.makeState(workspaces: [wsA, wsB]) {
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [displayA: wsA.id, displayB: wsB.id]
    }
    let requests = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.current = { displayA }
      $0.workspaceManager.activate = { request in
        requests.withValue { $0.append(request) }
      }
    }
    store.exhaustivity = .off

    await store.send(.borrow(workspaceId: wsB.id, edge: .right))
    await store.finish()

    #expect(store.state.compositionsByDisplay.isEmpty)
    #expect(requests.value.isEmpty)
  }

  @Test
  func `direct borrow uses the pointer display instead of keyboard focus`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let wsA = Workspace(name: "A")
    let wsB = Workspace(name: "B")
    let target = Workspace(name: "Target")
    let state = Self.makeState(workspaces: [wsA, wsB, target]) {
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [displayA: wsA.id, displayB: wsB.id]
    }
    let requests = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.current = { displayB }
      $0.workspaceManager.activate = { request in
        requests.withValue { $0.append(request) }
      }
    }
    store.exhaustivity = .off

    await store.send(.borrow(workspaceId: target.id, edge: .right))
    await store.finish()

    #expect(store.state.compositionsByDisplay[displayA] == nil)
    #expect(store.state.compositionsByDisplay[displayB]?.host == wsB.id)
    #expect(store.state.compositionsByDisplay[displayB]?.borrowed.first?.workspace == target.id)
    #expect(requests.value.last?.targetDisplay == displayB)
  }

  @Test
  func `borrow direction stays on the pointer display captured at invocation`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let wsA = Workspace(name: "A")
    let wsB = Workspace(name: "B")
    let target = Workspace(name: "Target")
    let state = Self.makeState(workspaces: [wsA, wsB, target]) {
      $0.$config.withLock { $0.settings.switching.borrowDefaultEdge = nil }
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [displayA: wsA.id, displayB: wsB.id]
    }
    let pointerDisplay = LockIsolated(displayB)
    let requests = LockIsolated<[ActivationRequest]>([])
    let clock = TestClock()
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.current = { pointerDisplay.value }
      $0.continuousClock = clock
      $0.borrowChord.setArmed = { _ in }
      $0.workspaceManager.activate = { request in
        requests.withValue { $0.append(request) }
      }
    }
    store.exhaustivity = .off

    await store.send(.beginBorrowDirection(workspaceId: target.id))
    #expect(store.state.borrowCapture?.workspaceId == target.id)
    #expect(store.state.borrowCapture?.display == displayB)

    pointerDisplay.withValue { $0 = displayA }
    await store.send(.borrowChordKey(.edge(.right)))
    await store.finish()

    #expect(store.state.borrowCapture == nil)
    #expect(store.state.compositionsByDisplay[displayA] == nil)
    #expect(store.state.compositionsByDisplay[displayB]?.host == wsB.id)
    #expect(requests.value.last?.targetDisplay == displayB)
  }

  @Test
  func `shared windows are partitioned by physical display`() {
    let onA = WindowKey(pid: 1, windowID: 101, bundleId: "app.shared")
    let onB = WindowKey(pid: 1, windowID: 202, bundleId: "app.shared")
    let protected = WindowKey(pid: 2, windowID: 303, bundleId: "app.unique")
    let areaA = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let frames = [
      onA: CGRect(x: 100, y: 100, width: 400, height: 300),
      onB: CGRect(x: 1200, y: 100, width: 400, height: 300),
      protected: CGRect(x: 100, y: 100, width: 400, height: 300),
    ]

    let result = WorkspaceActivationFeature.scopedWindowKeys(
      [onA, onB, protected],
      sharedTiledBundleIds: ["app.shared"],
      existingTargetKeys: [],
      protectedKeys: [protected],
      partitionSharedWindows: true,
      targetWorkArea: areaA,
      windowFrame: { frames[$0] },
    )

    #expect(result == [onA])
  }

  @Test
  func `displays reconfigured drops state for disconnected displays`() async {
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
    } withDependencies: {
      $0.floatingOverlay.setFloating = { _ in }
    }
    store.exhaustivity = .off

    // Disconnecting `gone` drops its per-display state (no new display → no
    // restore plan).
    await store.send(.displaysReconfigured([Self.display]))
    await store.receive {
      guard case .floatingPresentationResolved(let keys) = $0 else { return false }
      return keys.isEmpty
    }
    await store.finish()
    #expect(store.state.connectedDisplays == [Self.display])
    #expect(store.state.activeWorkspacesByDisplay.isEmpty)
    #expect(store.state.previousWorkspacesByDisplay.isEmpty)
    #expect(store.state.lastActiveDisplay.isEmpty)
    #expect(store.state.focusedDisplay == nil)
  }

  @Test
  func `workspace chain places pinned peers and trigger last in both directions`() {
    let a = DisplayName("A")
    let b = DisplayName("B")
    let code = workspace("Code", hint: a)
    let slack = workspace("Slack", hint: b)
    let chain = WorkspaceChain(
      name: "Coding",
      workspaceIDs: [code.id, slack.id],
    )

    let codePlan = WorkspaceActivationFeature.planWorkspaceChain(
      chain,
      triggeredBy: DisplayAssignment(display: a, workspace: code.id),
      dynamicPreferredDisplay: a,
      connected: [a, b],
      primaryDisplay: a,
      workspaces: [code, slack],
      active: [:],
      history: [:],
    )
    #expect(codePlan.map(\.assignments) == .success([
      DisplayAssignment(display: b, workspace: slack.id),
      DisplayAssignment(display: a, workspace: code.id),
    ]))

    let slackPlan = WorkspaceActivationFeature.planWorkspaceChain(
      chain,
      triggeredBy: DisplayAssignment(display: b, workspace: slack.id),
      dynamicPreferredDisplay: b,
      connected: [a, b],
      primaryDisplay: a,
      workspaces: [code, slack],
      active: [:],
      history: [:],
    )
    #expect(slackPlan.map(\.assignments) == .success([
      DisplayAssignment(display: a, workspace: code.id),
      DisplayAssignment(display: b, workspace: slack.id),
    ]))
  }

  @Test
  func `workspace chain active lookup prefers exact UUID keys over legacy aliases`() {
    let a = DisplayName(uuid: "display-a", name: "Studio Display")
    let b = DisplayName(uuid: "display-b", name: "Studio Display")
    let legacy = DisplayName("Studio Display")
    let code = workspace("Code", hint: a)
    let slack = workspace("Slack", hint: b)
    let stale = workspace("Stale")
    let chain = WorkspaceChain(workspaceIDs: [code.id, slack.id])
    var active = [legacy: stale.id]
    active[a] = code.id
    active[b] = slack.id
    var state = Self.makeState(workspaces: [code, slack, stale])
    state.connectedDisplays = [a, b]
    state.activeWorkspacesByDisplay = active
    state.previousWorkspacesByDisplay = [legacy: stale.id, a: slack.id]

    #expect(state.activeWorkspace(on: a) == code.id)
    #expect(state.activeWorkspace(on: b) == slack.id)
    #expect(state.previousWorkspace(on: a) == slack.id)
    #expect(state.previousWorkspace(on: b) == nil)

    let plan = WorkspaceActivationFeature.planWorkspaceChain(
      chain,
      triggeredBy: DisplayAssignment(display: a, workspace: code.id),
      dynamicPreferredDisplay: a,
      connected: [a, b],
      primaryDisplay: a,
      workspaces: [code, slack, stale],
      active: active,
      history: [:],
    )

    #expect(plan.map(\.assignments) == .success([
      DisplayAssignment(display: a, workspace: code.id)
    ]))
  }

  @Test
  func `workspace chain derives a dynamic peer from remaining connected displays`() {
    let a = DisplayName("A")
    let b = DisplayName("B")
    let c = DisplayName("C")
    let code = workspace("Code", hint: a)
    let slack = workspace("Slack")
    let notes = workspace("Notes", hint: c)
    let chain = WorkspaceChain(workspaceIDs: [code.id, slack.id])

    let plan = WorkspaceActivationFeature.planWorkspaceChain(
      chain,
      triggeredBy: DisplayAssignment(display: a, workspace: code.id),
      dynamicPreferredDisplay: a,
      connected: [a, b, c],
      primaryDisplay: a,
      workspaces: [code, slack, notes],
      active: [:],
      history: [:],
    )

    #expect(plan.map(\.assignments) == .success([
      DisplayAssignment(display: b, workspace: slack.id),
      DisplayAssignment(display: c, workspace: notes.id),
      DisplayAssignment(display: a, workspace: code.id),
    ]))
  }

  @Test
  func `pinned trigger sends its first dynamic companion to the pointer display`() {
    let a = DisplayName("A")
    let b = DisplayName("B")
    let c = DisplayName("C")
    let code = workspace("Code", hint: a)
    let slack = workspace("Slack")
    let notes = workspace("Notes", hint: b)
    let chain = WorkspaceChain(workspaceIDs: [code.id, slack.id])

    let plan = WorkspaceActivationFeature.planWorkspaceChain(
      chain,
      triggeredBy: DisplayAssignment(display: a, workspace: code.id),
      dynamicPreferredDisplay: c,
      connected: [a, b, c],
      primaryDisplay: a,
      workspaces: [code, slack, notes],
      active: [:],
      history: [:],
    )

    #expect(plan.map(\.assignments) == .success([
      DisplayAssignment(display: b, workspace: notes.id),
      DisplayAssignment(display: c, workspace: slack.id),
      // The pinned trigger still runs last even though its companion used the
      // pointer preference.
      DisplayAssignment(display: a, workspace: code.id),
    ]))
  }

  @Test
  func `dynamic workspace-chain trigger prefers the pointer display`() {
    let a = DisplayName("A")
    let b = DisplayName("B")
    let c = DisplayName("C")
    let code = workspace("Code", hint: a)
    let slack = workspace("Slack")
    let notes = workspace("Notes", hint: b)
    let chain = WorkspaceChain(workspaceIDs: [code.id, slack.id])

    let plan = WorkspaceActivationFeature.planWorkspaceChain(
      chain,
      triggeredBy: DisplayAssignment(display: c, workspace: slack.id),
      dynamicPreferredDisplay: c,
      connected: [a, b, c],
      primaryDisplay: a,
      workspaces: [code, slack, notes],
      active: [:],
      history: [:],
    )

    #expect(plan.map(\.assignments) == .success([
      DisplayAssignment(display: a, workspace: code.id),
      DisplayAssignment(display: b, workspace: notes.id),
      DisplayAssignment(display: c, workspace: slack.id),
    ]))
  }

  @Test
  func `dynamic trigger remains mandatory when a pinned peer targets the same display`() {
    let a = DisplayName("A")
    let b = DisplayName("B")
    let code = workspace("Code", hint: a)
    let slack = workspace("Slack")
    let chain = WorkspaceChain(workspaceIDs: [code.id, slack.id])

    let plan = WorkspaceActivationFeature.planWorkspaceChain(
      chain,
      triggeredBy: DisplayAssignment(display: a, workspace: slack.id),
      dynamicPreferredDisplay: a,
      connected: [a, b],
      primaryDisplay: a,
      workspaces: [code, slack],
      active: [:],
      history: [:],
    )

    #expect(plan.map(\.assignments) == .success([
      DisplayAssignment(display: a, workspace: slack.id)
    ]))
  }

  @Test
  func `dynamic workspace-chain members use chain order after trigger reservation`() {
    let a = DisplayName("A")
    let b = DisplayName("B")
    let c = DisplayName("C")
    let first = workspace("First")
    let trigger = workspace("Trigger")
    let third = workspace("Third")
    let chain = WorkspaceChain(workspaceIDs: [first.id, trigger.id, third.id])

    let plan = WorkspaceActivationFeature.planWorkspaceChain(
      chain,
      triggeredBy: DisplayAssignment(display: c, workspace: trigger.id),
      dynamicPreferredDisplay: c,
      connected: [a, b, c],
      primaryDisplay: a,
      workspaces: [first, trigger, third],
      active: [:],
      history: [:],
    )

    #expect(plan.map(\.assignments) == .success([
      DisplayAssignment(display: a, workspace: first.id),
      DisplayAssignment(display: b, workspace: third.id),
      DisplayAssignment(display: c, workspace: trigger.id),
    ]))
  }

  @Test
  func `duplicate pins use stored priority then continue to a later dynamic member`() {
    let a = DisplayName("A")
    let b = DisplayName("B")
    let first = workspace("First", hint: a)
    let second = workspace("Second", hint: a)
    let dynamic = workspace("Dynamic")
    let chain = WorkspaceChain(workspaceIDs: [first.id, second.id, dynamic.id])

    let plan = WorkspaceActivationFeature.planWorkspaceChain(
      chain,
      triggeredBy: DisplayAssignment(display: a, workspace: first.id),
      dynamicPreferredDisplay: a,
      connected: [a, b],
      primaryDisplay: a,
      workspaces: [first, second, dynamic],
      active: [:],
      history: [:],
    )

    #expect(plan.map(\.assignments) == .success([
      DisplayAssignment(display: b, workspace: dynamic.id),
      DisplayAssignment(display: a, workspace: first.id),
    ]))
  }

  @Test
  func `disconnected pinned chain peer is skipped before ordinary fallback`() {
    let a = DisplayName("A")
    let b = DisplayName("B")
    let disconnected = DisplayName("Disconnected")
    let trigger = workspace("Trigger", hint: a)
    let peer = workspace("Peer", hint: disconnected)
    let fallback = workspace("Fallback")
    let chain = WorkspaceChain(workspaceIDs: [trigger.id, peer.id])

    let plan = WorkspaceActivationFeature.planWorkspaceChain(
      chain,
      triggeredBy: DisplayAssignment(display: a, workspace: trigger.id),
      dynamicPreferredDisplay: b,
      connected: [a, b],
      primaryDisplay: a,
      workspaces: [trigger, peer, fallback],
      active: [:],
      history: [b: [fallback.id]],
    )

    #expect(plan.map(\.assignments) == .success([
      DisplayAssignment(display: b, workspace: fallback.id),
      DisplayAssignment(display: a, workspace: trigger.id),
    ]))
    #expect(plan.map(\.selectedWorkspaceIDs) == .success([trigger.id]))
  }

  @Test
  func `disconnected UUID pin cannot alias a connected display with the same name`() {
    let a = DisplayName(uuid: "display-a", name: "Built-in")
    let gone = DisplayName(uuid: "display-gone", name: "Studio Display")
    let live = DisplayName(uuid: "display-live", name: "Studio Display")
    let trigger = workspace("Trigger", hint: a)
    let peer = workspace("Peer", hint: gone)
    let fallback = workspace("Fallback")

    let pinnedPlan = WorkspaceActivationFeature.planWorkspaceChain(
      WorkspaceChain(workspaceIDs: [trigger.id, peer.id]),
      triggeredBy: DisplayAssignment(display: a, workspace: trigger.id),
      dynamicPreferredDisplay: live,
      connected: [a, live],
      primaryDisplay: a,
      workspaces: [trigger, peer, fallback],
      active: [:],
      history: [live: [fallback.id]],
    )
    #expect(pinnedPlan.map(\.assignments) == .success([
      DisplayAssignment(display: live, workspace: fallback.id),
      DisplayAssignment(display: a, workspace: trigger.id),
    ]))
    #expect(pinnedPlan.map(\.selectedWorkspaceIDs) == .success([trigger.id]))

    let dynamicPlan = WorkspaceActivationFeature.planWorkspaceChain(
      WorkspaceChain(
        workspaceIDs: [trigger.id, peer.id],
        dynamicWorkspaceIDs: [peer.id],
      ),
      triggeredBy: DisplayAssignment(display: a, workspace: trigger.id),
      dynamicPreferredDisplay: live,
      connected: [a, live],
      primaryDisplay: a,
      workspaces: [trigger, peer, fallback],
      active: [:],
      history: [live: [fallback.id]],
    )
    #expect(dynamicPlan.map(\.assignments) == .success([
      DisplayAssignment(display: live, workspace: peer.id),
      DisplayAssignment(display: a, workspace: trigger.id),
    ]))
    #expect(dynamicPlan.map(\.selectedWorkspaceIDs) == .success([trigger.id, peer.id]))
  }

  @Test
  func `chain dynamic override fills before ordinary fallback`() {
    let a = DisplayName("A")
    let b = DisplayName("B")
    let disconnected = DisplayName("Disconnected")
    let trigger = workspace("Trigger", hint: a)
    let peer = workspace("Peer", hint: disconnected)
    let fallback = workspace("Fallback")
    let chain = WorkspaceChain(
      workspaceIDs: [trigger.id, peer.id],
      dynamicWorkspaceIDs: [peer.id],
    )

    let plan = WorkspaceActivationFeature.planWorkspaceChain(
      chain,
      triggeredBy: DisplayAssignment(display: a, workspace: trigger.id),
      dynamicPreferredDisplay: b,
      connected: [a, b],
      primaryDisplay: a,
      workspaces: [trigger, peer, fallback],
      active: [:],
      history: [b: [fallback.id]],
    )

    #expect(plan.map(\.assignments) == .success([
      DisplayAssignment(display: b, workspace: peer.id),
      DisplayAssignment(display: a, workspace: trigger.id),
    ]))
    #expect(plan.map(\.selectedWorkspaceIDs) == .success([trigger.id, peer.id]))
  }

  @Test
  func `chain dynamic override does not change the selected trigger target`() {
    let a = DisplayName("A")
    let b = DisplayName("B")
    let peer = workspace("Peer")
    let trigger = workspace("Trigger", hint: a)
    let chain = WorkspaceChain(
      workspaceIDs: [peer.id, trigger.id],
      dynamicWorkspaceIDs: [trigger.id],
    )

    let plan = WorkspaceActivationFeature.planWorkspaceChain(
      chain,
      triggeredBy: DisplayAssignment(display: b, workspace: trigger.id),
      dynamicPreferredDisplay: b,
      connected: [a, b],
      primaryDisplay: a,
      workspaces: [peer, trigger],
      active: [:],
      history: [:],
    )

    #expect(plan.map(\.assignments) == .success([
      DisplayAssignment(display: b, workspace: peer.id),
      DisplayAssignment(display: a, workspace: trigger.id),
    ]))
  }

  @Test
  func `workspace chain applies the highest-priority members that fit`() {
    let a = DisplayName("A")
    let b = DisplayName("B")
    let pinned = workspace("Pinned", hint: a)
    let first = workspace("First")
    let second = workspace("Second")
    let chain = WorkspaceChain(workspaceIDs: [pinned.id, first.id, second.id])

    let plan = WorkspaceActivationFeature.planWorkspaceChain(
      chain,
      triggeredBy: DisplayAssignment(display: b, workspace: first.id),
      dynamicPreferredDisplay: b,
      connected: [a, b],
      primaryDisplay: a,
      workspaces: [pinned, first, second],
      active: [:],
      history: [:],
    )

    #expect(plan.map(\.assignments) == .success([
      DisplayAssignment(display: a, workspace: pinned.id),
      DisplayAssignment(display: b, workspace: first.id),
    ]))
  }

  @Test
  func `lower-priority duplicate pin trigger overrides the earlier peer`() {
    let a = DisplayName("A")
    let b = DisplayName("B")
    let first = workspace("First", hint: a)
    let trigger = workspace("Trigger", hint: a)
    let dynamic = workspace("Dynamic")
    let chain = WorkspaceChain(workspaceIDs: [first.id, trigger.id, dynamic.id])

    let plan = WorkspaceActivationFeature.planWorkspaceChain(
      chain,
      triggeredBy: DisplayAssignment(display: a, workspace: trigger.id),
      dynamicPreferredDisplay: a,
      connected: [a, b],
      primaryDisplay: a,
      workspaces: [first, trigger, dynamic],
      active: [:],
      history: [:],
    )

    #expect(plan.map(\.assignments) == .success([
      DisplayAssignment(display: b, workspace: dynamic.id),
      DisplayAssignment(display: a, workspace: trigger.id),
    ]))
  }

  @Test
  func `skipped chain member is removed and its display uses ordinary fallback`() {
    let a = DisplayName("A")
    let b = DisplayName("B")
    let c = DisplayName("C")
    let first = workspace("First", hint: a)
    let skipped = workspace("Skipped", hint: a)
    let dynamic = workspace("Dynamic")
    let fallback = workspace("Fallback", hint: c)
    let chain = WorkspaceChain(workspaceIDs: [first.id, skipped.id, dynamic.id])

    let plan = WorkspaceActivationFeature.planWorkspaceChain(
      chain,
      triggeredBy: DisplayAssignment(display: a, workspace: first.id),
      dynamicPreferredDisplay: b,
      connected: [a, b, c],
      primaryDisplay: a,
      workspaces: [first, skipped, dynamic, fallback],
      active: [c: skipped.id],
      history: [c: [skipped.id, fallback.id]],
    )

    #expect(plan.map(\.assignments) == .success([
      DisplayAssignment(display: b, workspace: dynamic.id),
      DisplayAssignment(display: c, workspace: fallback.id),
      DisplayAssignment(display: a, workspace: first.id),
    ]))
  }

  @Test
  func `last dynamic trigger reserves its display before stored-order peers`() {
    let a = DisplayName("A")
    let b = DisplayName("B")
    let first = workspace("First")
    let second = workspace("Second")
    let trigger = workspace("Trigger")
    let chain = WorkspaceChain(workspaceIDs: [first.id, second.id, trigger.id])

    let plan = WorkspaceActivationFeature.planWorkspaceChain(
      chain,
      triggeredBy: DisplayAssignment(display: a, workspace: trigger.id),
      dynamicPreferredDisplay: a,
      connected: [a, b],
      primaryDisplay: a,
      workspaces: [first, second, trigger],
      active: [:],
      history: [:],
    )

    #expect(plan.map(\.assignments) == .success([
      DisplayAssignment(display: b, workspace: first.id),
      DisplayAssignment(display: a, workspace: trigger.id),
    ]))
  }

  @Test
  func `workspace chain fills a vacated display without reusing chain members`() {
    let a = DisplayName("A")
    let b = DisplayName("B")
    let c = DisplayName("C")
    let code = workspace("Code", hint: a)
    let slack = workspace("Slack")
    let notes = workspace("Notes", hint: c)
    let old = workspace("Old", hint: b)
    let chain = WorkspaceChain(workspaceIDs: [code.id, slack.id])

    let plan = WorkspaceActivationFeature.planWorkspaceChain(
      chain,
      triggeredBy: DisplayAssignment(display: a, workspace: code.id),
      dynamicPreferredDisplay: a,
      connected: [a, b, c],
      primaryDisplay: a,
      workspaces: [code, slack, notes, old],
      active: [a: code.id, b: old.id, c: slack.id],
      history: [c: [slack.id, notes.id]],
    )

    #expect(plan.map(\.assignments) == .success([
      DisplayAssignment(display: b, workspace: slack.id),
      DisplayAssignment(display: c, workspace: notes.id),
      DisplayAssignment(display: a, workspace: code.id),
    ]))
  }

  @Test
  func `workspace chain skips unchanged peers but retains trigger for focus`() {
    let a = DisplayName("A")
    let b = DisplayName("B")
    let code = workspace("Code", hint: a)
    let slack = workspace("Slack", hint: b)
    let chain = WorkspaceChain(workspaceIDs: [code.id, slack.id])

    let plan = WorkspaceActivationFeature.planWorkspaceChain(
      chain,
      triggeredBy: DisplayAssignment(display: a, workspace: code.id),
      dynamicPreferredDisplay: a,
      connected: [a, b],
      primaryDisplay: a,
      workspaces: [code, slack],
      active: [a: code.id, b: slack.id],
      history: [:],
    )

    #expect(plan.map(\.assignments) == .success([
      DisplayAssignment(display: a, workspace: code.id)
    ]))
  }

  @Test
  func `reconnect restores last shown when pinned or free dynamic`() {
    let b = DisplayName("B")
    let wB = workspace("wB", hint: b)
    #expect(
      WorkspaceActivationFeature.planDisplayRestore(
        connected: [b],
        newlyConnected: [b],
        workspaces: [wB],
        active: [:],
        history: [b: [wB.id]],
      ) == [DisplayAssignment(display: b, workspace: wB.id)]
    )
    // A dynamic last-shown IS restored — as long as it isn't in use elsewhere.
    let dyn = workspace("dyn")
    #expect(
      WorkspaceActivationFeature.planDisplayRestore(
        connected: [b],
        newlyConnected: [b],
        workspaces: [dyn],
        active: [:],
        history: [b: [dyn.id]],
      ) == [DisplayAssignment(display: b, workspace: dyn.id)]
    )
  }

  @Test
  func `reconnect falls back to first pinned then most recent free dynamic`() {
    let b = DisplayName("B")
    let pinned = workspace("pinned", hint: b)
    #expect(
      WorkspaceActivationFeature.planDisplayRestore(
        connected: [b],
        newlyConnected: [b],
        workspaces: [pinned],
        active: [:],
        history: [:],
      ) == [DisplayAssignment(display: b, workspace: pinned.id)]
    )
    // No pinned → rule 3: the most-recently-used free dynamic (MRU order).
    let a = DisplayName("A")
    let used = workspace("used") // dynamic, currently on A
    let recent = workspace("recent") // dynamic, free, more recent than `older`
    let older = workspace("older") // dynamic, free
    let plan = WorkspaceActivationFeature.planDisplayRestore(
      connected: [a, b],
      newlyConnected: [b],
      workspaces: [used, recent, older],
      active: [a: used.id],
      history: [:],
      workspaceMRU: [used.id, recent.id, older.id],
    )
    #expect(plan == [
      DisplayAssignment(display: a, workspace: used.id), // re-assert A
      DisplayAssignment(display: b, workspace: recent.id), // used is elsewhere → recent
    ])
  }

  @Test
  func `restart falls back to a workspace pinned to a missing display`() {
    let connected = DisplayName("Laptop")
    let missing = DisplayName("Studio Display")
    let workspace = workspace("Studio", hint: missing)

    let plan = WorkspaceActivationFeature.planDisplayRestore(
      connected: [connected],
      newlyConnected: [connected],
      workspaces: [workspace],
      active: [:],
      history: [:],
      workspaceMRU: [workspace.id],
    )

    #expect(plan == [
      DisplayAssignment(display: connected, workspace: workspace.id)
    ])
  }

  @Test
  func `reconnect re asserts connected displays and leaves unpinned new ones empty`() {
    // The Figma case: dynamic Figma on A; B reconnects with nothing pinned to
    // it. The plan re-asserts A→figma (overwriting macOS's shuffle) and leaves
    // B empty — Figma stays on A rather than drifting to B.
    let a = DisplayName("A")
    let b = DisplayName("B")
    let figma = workspace("figma") // dynamic
    let plan = WorkspaceActivationFeature.planDisplayRestore(
      connected: [a, b],
      newlyConnected: [b],
      workspaces: [figma],
      active: [a: figma.id],
      history: [b: [figma.id]],
    )
    #expect(plan == [DisplayAssignment(display: a, workspace: figma.id)])
  }

  @Test
  func `reconnect reclaims pinned from another display and refills it`() {
    let a = DisplayName("A")
    let b = DisplayName("B")
    let wB = workspace("wB", hint: b) // pinned to B, currently up on A
    let wAprev = workspace("wAprev", hint: a) // A's previous workspace
    let plan = WorkspaceActivationFeature.planDisplayRestore(
      connected: [a, b],
      newlyConnected: [b],
      workspaces: [wB, wAprev],
      active: [a: wB.id],
      history: [b: [wB.id], a: [wB.id, wAprev.id]],
    )
    #expect(plan == [
      DisplayAssignment(display: a, workspace: wAprev.id),
      DisplayAssignment(display: b, workspace: wB.id),
    ])
  }

  @Test
  func `vacated refill walks history past workspaces in use elsewhere`() {
    let a = DisplayName("A")
    let b = DisplayName("B")
    let c = DisplayName("C")
    let wB = workspace("wB", hint: b) // reclaimed to B
    let wOnC = workspace("wOnC") // dynamic, currently up on C
    let wOlder = workspace("wOlder", hint: a) // A's older workspace
    let plan = WorkspaceActivationFeature.planDisplayRestore(
      connected: [a, b, c],
      newlyConnected: [b],
      workspaces: [wB, wOnC, wOlder],
      active: [a: wB.id, c: wOnC.id],
      history: [b: [wB.id], a: [wB.id, wOnC.id, wOlder.id]],
    )
    // B←wB; A skips wB (now on B) and wOnC (on C) → wOlder; C re-asserts wOnC.
    #expect(plan == [
      DisplayAssignment(display: a, workspace: wOlder.id),
      DisplayAssignment(display: b, workspace: wB.id),
      DisplayAssignment(display: c, workspace: wOnC.id),
    ])
  }

  @Test
  func `a display that blinks out during a lock is restored untouched`() async {
    let builtIn = DisplayName("Built-in")
    let external = DisplayName("External")
    let wsBuiltIn = workspace("Terminal", hint: builtIn)
    let wsExternal = workspace("Slack", hint: external)
    let state = Self.makeState(workspaces: [wsBuiltIn, wsExternal]) {
      $0.isTilingPaused = true
      $0.connectedDisplays = [builtIn, external]
      $0.focusedDisplay = external
      $0.activeWorkspacesByDisplay = [
        builtIn: wsBuiltIn.id,
        external: wsExternal.id,
      ]
    }
    let activations = LockIsolated<[ActivationRequest]>([])
    let live = LockIsolated([builtIn, external])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { live.value }
      $0.displays.current = { external }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        activations.withValue { $0.append(request) }
      }
      $0.windowTiler.apply = { _ in }
      $0.windowSnapshot.onScreenWindowFrames = { [:] }
      $0.sls.isActiveSpaceFullscreen = { false }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.screenWillLock)
    // macOS drops the external display behind the lock shield, then hands it
    // back before the user is even authenticated.
    live.setValue([builtIn])
    await store.send(.displaysReconfigured([builtIn]))
    live.setValue([builtIn, external])
    await store.send(.displaysReconfigured([builtIn, external]))

    // Nothing was torn down or re-activated while the screen was locked.
    #expect(store.state.activeWorkspacesByDisplay[external] == wsExternal.id)
    #expect(store.state.focusedDisplay == external)
    #expect(activations.value.isEmpty)
    #expect(store.state.pendingDisplayTopologyReconcile)

    await store.send(.screenDidUnlock)
    await store.receive {
      guard case .displaysReconfigured(let names) = $0 else { return false }
      return Set(names) == [builtIn, external]
    }
    await store.finish()

    // The replay diffs against the pre-lock topology, which is unchanged, so
    // the desk comes back exactly as the user left it.
    #expect(store.state.activeWorkspacesByDisplay[builtIn] == wsBuiltIn.id)
    #expect(store.state.activeWorkspacesByDisplay[external] == wsExternal.id)
    #expect(store.state.focusedDisplay == external)
    #expect(!store.state.pendingDisplayTopologyReconcile)
  }

  @Test
  func `a display really unplugged during a lock is reconciled once on unlock`() async {
    let builtIn = DisplayName("Built-in")
    let external = DisplayName("External")
    let wsBuiltIn = workspace("Terminal", hint: builtIn)
    let wsExternal = workspace("Slack", hint: external)
    let state = Self.makeState(workspaces: [wsBuiltIn, wsExternal]) {
      $0.isTilingPaused = true
      $0.connectedDisplays = [builtIn, external]
      $0.focusedDisplay = external
      $0.activeWorkspacesByDisplay = [
        builtIn: wsBuiltIn.id,
        external: wsExternal.id,
      ]
    }
    let live = LockIsolated([builtIn, external])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { live.value }
      $0.displays.current = { builtIn }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { _ in }
      $0.windowTiler.apply = { _ in }
      $0.windowSnapshot.onScreenWindowFrames = { [:] }
      $0.sls.isActiveSpaceFullscreen = { false }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.screenWillLock)
    live.setValue([builtIn])
    await store.send(.displaysReconfigured([builtIn]))
    await store.send(.screenDidUnlock)
    await store.receive {
      guard case .displaysReconfigured(let names) = $0 else { return false }
      return names == [builtIn]
    }
    await store.finish()

    // The monitor is genuinely gone, so its assignment is dropped — but only
    // once, on the settled topology, not per intermediate report.
    #expect(store.state.connectedDisplays == [builtIn])
    #expect(store.state.activeWorkspacesByDisplay[external] == nil)
    #expect(store.state.activeWorkspacesByDisplay[builtIn] == wsBuiltIn.id)
  }

  @Test
  func `vacated display leaves itself empty rather than summon a homeless pin`() {
    let a = DisplayName("A")
    let b = DisplayName("B")
    let gone = DisplayName("Disconnected")
    let dynamic = workspace("dynamic") // just left B for A
    let homeless = workspace("homeless", hint: gone)
    let chosen = WorkspaceActivationFeature.chooseWorkspaceForDisplay(
      b,
      reconnect: false,
      byId: [dynamic.id: dynamic, homeless.id: homeless],
      workspaces: [dynamic, homeless],
      assigned: [a: dynamic.id],
      history: [b: [dynamic.id, homeless.id]],
      connected: [a, b],
    )
    // `dynamic` is in use on A. `homeless` is pinned to a disconnected
    // display, and unlike the reconnect branch the vacated branch will not
    // drag it here — an empty display beats opening a workspace's apps on a
    // monitor it was never assigned to.
    #expect(chosen == nil)
  }

  @Test
  func `vacated display walks its history in order past ineligible entries`() {
    let a = DisplayName("A")
    let b = DisplayName("B")
    let gone = DisplayName("Disconnected")
    let dynamic = workspace("dynamic")
    let homeless = workspace("homeless", hint: gone)
    let pinnedHere = workspace("pinnedHere", hint: b)
    let chosen = WorkspaceActivationFeature.chooseWorkspaceForDisplay(
      b,
      reconnect: false,
      byId: [dynamic.id: dynamic, homeless.id: homeless, pinnedHere.id: pinnedHere],
      workspaces: [dynamic, homeless, pinnedHere],
      assigned: [a: dynamic.id],
      history: [b: [homeless.id, dynamic.id, pinnedHere.id]],
      connected: [a, b],
    )
    // Newest first, skipping the homeless pin and the one now on A.
    #expect(chosen == pinnedHere.id)
  }

  @Test
  func `vacated display still rejects a dynamic workspace in use elsewhere`() {
    let a = DisplayName("A")
    let b = DisplayName("B")
    let dynamic = workspace("dynamic")
    let chosen = WorkspaceActivationFeature.chooseWorkspaceForDisplay(
      b,
      reconnect: false,
      byId: [dynamic.id: dynamic],
      workspaces: [dynamic],
      assigned: [a: dynamic.id],
      history: [b: [dynamic.id]],
      connected: [a, b],
    )
    // One workspace lives on exactly one display.
    #expect(chosen == nil)
  }

  @Test
  func `vacated display returns nil when history holds only the departed dynamic`() {
    let a = DisplayName("A")
    let b = DisplayName("B")
    let dynamic = workspace("dynamic")
    let neverHere = workspace("neverHere", hint: a)
    let chosen = WorkspaceActivationFeature.chooseWorkspaceForDisplay(
      b,
      reconnect: false,
      byId: [dynamic.id: dynamic, neverHere.id: neverHere],
      workspaces: [dynamic, neverHere],
      assigned: [a: dynamic.id],
      history: [b: [dynamic.id]],
      connected: [a, b],
    )
    // The vacated branch is per-display MRU only: a workspace that was never
    // on B is not dragged over just to fill it.
    #expect(chosen == nil)
  }

  @Test
  func `profile session decodes the legacy active profile only shape`() throws {
    let profileId = UUID()
    let data = Data(
      """
      {"activeProfileId":"\(profileId.uuidString)"}
      """.utf8
    )

    let session = try JSONDecoder().decode(ProfileSession.self, from: data)

    #expect(session.activeProfileId == profileId)
    #expect(session.displayWorkspaceHistory.isEmpty)
    #expect(session.workspaceMRU.isEmpty)
  }

  @Test
  func `profile session round trips display workspace history`() throws {
    let profileId = UUID()
    let workspaceId = UUID()
    let display = DisplayName(uuid: "display-1", name: "Studio")
    let session = ProfileSession(
      activeProfileId: profileId,
      displayWorkspaceHistory: [
        .init(display: display, workspaceIds: [workspaceId])
      ],
      workspaceMRU: [workspaceId],
    )

    let restored = try JSONDecoder().decode(
      ProfileSession.self,
      from: JSONEncoder().encode(session),
    )

    #expect(restored == session)
    #expect(restored.historyByDisplay == [display: [workspaceId]])
  }

  // MARK: Private

  /// Matches `DisplayClient.testValue.current()`.
  private static let display = DisplayName("Test Display")

  private static func makeState(
    workspaces: [Workspace],
    mutate: (inout WorkspaceActivationFeature.State) -> Void = { _ in },
  ) -> WorkspaceActivationFeature.State {
    var state = WorkspaceActivationFeature.State()
    state.$config.withLock {
      $0.profiles = [Profile(name: "Default", workspaces: IdentifiedArray(uniqueElements: workspaces))]
    }
    mutate(&state)
    return state
  }

  private static func receiveActivationCompletion(
    _ store: TestStoreOf<WorkspaceActivationFeature>,
    workspaceID: Workspace.ID,
    display: DisplayName,
  ) async {
    await store.receive {
      guard case .activationCompleted(let receivedID, let receivedDisplay, _) = $0 else {
        return false
      }
      return receivedID == workspaceID && receivedDisplay?.matches(display) == true
    }
    await store.receive {
      guard case .activationTailFinished = $0 else { return false }
      return true
    }
  }

  private func workspace(_ name: String, hint: DisplayName? = nil) -> Workspace {
    Workspace(name: name, displayHint: hint)
  }

}
