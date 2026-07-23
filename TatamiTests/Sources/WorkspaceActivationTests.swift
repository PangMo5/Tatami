import ComposableArchitecture
import CoreGraphics
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

    await store.send(.activateNext)
    await store.receive {
      guard case .activate(let id, let setFocus) = $0 else { return false }
      return id == ws1.id && setFocus
    }
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
    await store.send(.activateNext)
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
    await store.send(.activateNext)
    await store.receive {
      guard case .activate(let id, _) = $0 else { return false }
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

  @Test
  func `window cycle HUD follows app level cycle order`() async {
    let appA1 = WindowKey(pid: 1, windowID: 101, bundleId: "app.a")
    let appA2 = WindowKey(pid: 1, windowID: 102, bundleId: "app.a")
    let appB = WindowKey(pid: 2, windowID: 201, bundleId: "app.b")
    let workspace = Workspace(name: "Work")
    let state = Self.makeState(workspaces: [workspace]) {
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
    }
    let focused = LockIsolated<WindowKey?>(nil)
    let hudWindows = LockIsolated<[WindowKey]>([])
    let hudSelected = LockIsolated<WindowKey?>(nil)
    let hudByWindow = LockIsolated<Bool?>(nil)
    let hudDisplay = LockIsolated<DisplayName?>(nil)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.focusManager.focusWindow = { key in focused.withValue { $0 = key } }
      $0.workspaceHUD.showWindowSwitcher = { windows, selected, byWindow, _, display in
        hudWindows.withValue { $0 = windows }
        hudSelected.withValue { $0 = selected }
        hudByWindow.withValue { $0 = byWindow }
        hudDisplay.withValue { $0 = display }
      }
    }

    await store.send(.cycleWindowResolved(windowKey: appA1, direction: .next))
    await store.finish()

    #expect(focused.value == appB)
    #expect(hudWindows.value == [appA1, appB])
    #expect(hudSelected.value == appB)
    #expect(hudByWindow.value == false)
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
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.focusManager.focusWindow = { key in focused.withValue { $0 = key } }
      $0.workspaceHUD.showWindowSwitcher = { windows, _, byWindow, _, _ in
        hudWindows.withValue { $0 = windows }
        hudByWindow.withValue { $0 = byWindow }
      }
    }

    await store.send(.cycleWindowResolved(windowKey: appA1, direction: .next))
    await store.finish()

    #expect(focused.value == appA2)
    #expect(hudWindows.value == [appA1, appA2])
    #expect(hudByWindow.value == true)
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
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.windowSnapshot.cachedKeys = { bundleIds, requireResizable in
        #expect(bundleIds == [floating.bundleId])
        #expect(requireResizable == false)
        return [floating]
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
    }
    store.exhaustivity = .off

    await store.send(.cycleWindowResolved(windowKey: tiled, direction: .next))
    await store.finish()

    #expect(order.value == ["focus", "frame", "warp"])
    #expect(warped.value == [CGPoint(x: floatingFrame.midX, y: floatingFrame.midY)])
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
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.focusManager.focusWindow = { key in focused.withValue { $0 = key } }
      $0.workspaceHUD.showWindowSwitcher = { windows, _, _, _, _ in
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
      $0.workspaceHUD.showWindowSwitcher = { windows, _, _, _, _ in
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
      $0.workspaceHUD.showWindowSwitcher = { _, _, _, _, _ in
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
      $0.workspaceHUD.showWindowSwitcher = { _, _, _, autoDismiss, _ in
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
      $0.workspaceHUD.showWindowSwitcher = { _, selected, _, _, _ in
        hudSelected.withValue { $0 = selected }
      }
    }
    store.exhaustivity = .off

    await store.send(.windowCycleHUDInteraction(.move(.next)))
    await store.finish()

    #expect(store.state.windowCycleSession?.selected == appC)
    #expect(hudSelected.value == appC)
    #expect(focused.value == nil)
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
  func `assigning to another profile requests one profile switch transaction`() async {
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
    ))
    await store.receive {
      guard case .delegate(.profileSwitchRequested(let id, let focus)) = $0 else {
        return false
      }
      return id == targetProfile.id && focus == targetWorkspace.id
    }

    #expect(
      store.state.config.profiles
        .first(where: { $0.id == targetProfile.id })?
        .workspaces[id: targetWorkspace.id]?
        .apps.contains(where: { $0.bundleIdentifier == "app.example" }) == true
    )
  }

  @Test
  func `focus adjacent display keeps dynamic workspace on that display`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let wsA = Workspace(name: "A")
    let wsB = Workspace(name: "B")
    let state = Self.makeState(workspaces: [wsA, wsB]) {
      $0.isTilingPaused = true
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [displayA: wsA.id, displayB: wsB.id]
    }
    let requests = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.all = { [displayA, displayB] }
      $0.displays.current = { displayA }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        requests.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.focusAdjacentDisplay(direction: 1))
    await store.receive {
      guard case .activationCompleted(let workspaceId, let display) = $0 else { return false }
      return workspaceId == wsB.id && display == displayB
    }
    await store.finish()

    #expect(requests.value.count == 1)
    #expect(requests.value.first?.workspace.id == wsB.id)
    #expect(requests.value.first?.targetDisplay == displayB)
    #expect(store.state.activeWorkspacesByDisplay[displayB] == wsB.id)
    #expect(store.state.activeWorkspacesByDisplay[displayA] == wsA.id)
  }

  @Test
  func `global recent focuses the workspace on its existing display`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let wsA = Workspace(name: "A")
    let wsB = Workspace(name: "B")
    let state = Self.makeState(workspaces: [wsA, wsB]) {
      $0.$config.withLock { $0.settings.switching.recentAcrossDisplays = true }
      $0.isTilingPaused = true
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [displayA: wsA.id, displayB: wsB.id]
      $0.workspaceMRU = [wsA.id, UUID(), wsB.id]
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

    await store.send(.activateRecent)
    await store.receive {
      guard case .activationCompleted(let workspaceId, let display) = $0 else { return false }
      return workspaceId == wsB.id && display == displayB
    }
    await store.finish()

    #expect(requests.value.last?.workspace.id == wsB.id)
    #expect(requests.value.last?.targetDisplay == displayB)
    #expect(store.state.focusedDisplay == displayB)
    #expect(store.state.activeWorkspacesByDisplay[displayA] == wsA.id)
    #expect(store.state.activeWorkspacesByDisplay[displayB] == wsB.id)
  }

  @Test
  func `recent remains scoped to the focused display by default`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let current = Workspace(name: "Current")
    let localRecent = Workspace(name: "Local Recent")
    let otherDisplayRecent = Workspace(name: "Other Display Recent")
    let state = Self.makeState(workspaces: [current, localRecent, otherDisplayRecent]) {
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

    await store.send(.activateRecent)
    await store.receive {
      guard case .activationCompleted(let workspaceId, let display) = $0 else { return false }
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
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [displayA: wsA.id, displayB: wsB.id]
      $0.previousWorkspacesByDisplay[displayB] = wsA.id
      $0.workspaceMRU = [wsA.id, wsB.id]
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    }

    await store.send(.activateRecent)
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

  @Test
  func `activation completed records display and recent workspace`() async {
    let ws1 = Workspace(name: "one")
    let ws2 = Workspace(name: "two")
    let state = Self.makeState(workspaces: [ws1, ws2]) {
      $0.activeWorkspacesByDisplay[Self.display] = ws1.id
      $0.isActivating = true
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
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
  func `activation watchdog releases the gate`() async {
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
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    await store.send(
      .windowChanged(.windowFocused(bundleId: shared.bundleId, key: shared))
    )

    #expect(store.state.mruWindows[ws.id] == [own])
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
      $0.insertionPoint[activeWorkspace.id] = key
      $0.tilingTrees[activeWorkspace.id] = .leaf(key)
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

  @Test(arguments: [true, false])
  func `window server close settlement reflows either borrowed sibling to the full block`(
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
    }
    let clock = TestClock()
    let snapshotCount = LockIsolated(0)
    let frameReadCount = LockIsolated(0)
    let applied = LockIsolated<[FrameApplication]>([])
    let warped = LockIsolated<[CGPoint]>([])
    let staleHalfFrame = CGRect(x: 600, y: 0, width: 400, height: 400)
    let settledFullFrame = CGRect(x: 600, y: 0, width: 400, height: 800)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.displays.workArea = { _ in workArea }
      $0.windowSnapshot.onScreenWindowIDs = {
        snapshotCount.withValue { count in
          defer { count += 1 }
          return count == 0
            ? [hostWindow.windowID, closed.windowID, survivor.windowID]
            : [hostWindow.windowID, survivor.windowID]
        }
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

    await store.send(.windowServerWindowDestroyed(closed.windowID))
    #expect(Set(store.state.tilingTrees[borrowed.id]?.windows ?? []) == [closed, survivor])
    #expect(applied.value.isEmpty)

    await clock.advance(by: .milliseconds(24))
    await store.receive {
      guard case .windowServerCloseSettled(let workspaceIds) = $0 else { return false }
      return workspaceIds == [borrowed.id]
    }
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
      $0.windowSnapshot.focusedWindowKey = { liveFocus.value }
      $0.workspaceManager.activate = { request in
        requests.withValue { $0.append(request) }
      }
    }
    store.exhaustivity = .off

    await store.send(.activate(workspaceId: other.id, setFocus: true))
    await store.receive {
      guard case .activationCompleted(let workspaceId, _) = $0 else { return false }
      return workspaceId == other.id
    }
    #expect(store.state.mruWindows[browser.id] == [work, personal])

    liveFocus.withValue { $0 = nil }
    await store.send(.activate(workspaceId: browser.id, setFocus: true))
    await store.receive {
      guard case .activationCompleted(let workspaceId, _) = $0 else { return false }
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
      guard case .activationCompleted(let workspaceId, _) = $0 else { return false }
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
      guard case .activationCompleted(let workspaceId, let display) = $0 else { return false }
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
      guard case .activationCompleted(let workspaceId, let display) = $0 else { return false }
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
      guard case .activationCompleted(let workspaceId, let display) = $0 else { return false }
      return workspaceId == host.id && display == displayB
    }
    await store.finish()

    #expect(store.state.compositionsByDisplay[displayB] == nil)
    #expect(requests.value.last?.targetDisplay == displayB)
    #expect(store.state.activeWorkspacesByDisplay[displayB] == host.id)
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
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.displays.current = { display }
      $0.continuousClock = TestClock()
      $0.workspaceManager.activate = { request in
        requests.withValue { $0.append(request) }
      }
      $0.floatingOverlay.retainOnly = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.beginBorrowDirection(workspaceId: borrowed.id))
    await store.receive {
      guard case .activationCompleted(let workspaceId, let owner) = $0 else { return false }
      return workspaceId == host.id && owner == display
    }
    await store.finish()

    #expect(store.state.compositionsByDisplay[display] == nil)
    #expect(requests.value.last?.workspace.id == host.id)
    #expect(requests.value.last?.targetDisplay == display)
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
    let clock = TestClock()
    let borrowedFrame = CGRect(x: 600, y: 0, width: 400, height: 800)
    let restoredFrame = CGRect(x: 600, y: 0, width: 400, height: 400)
    let order = LockIsolated<[String]>([])
    let frameReads = LockIsolated(0)
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.displays.current = { display }
      $0.displays.workArea = { _ in CGRect(x: 0, y: 0, width: 1000, height: 800) }
      $0.workspaceManager.activate = { _ in }
      $0.windowSnapshot.cachedKeys = { bundleIDs, _ in
        bundleIDs.contains(borrowedWindow.bundleId) ? [borrowedWindow] : []
      }
      $0.windowSnapshot.focusedWindowKey = { borrowedWindow }
      $0.windowSnapshot.windowFrame = { key in
        #expect(key == borrowedWindow)
        order.withValue { $0.append("frame") }
        return frameReads.withValue { reads in
          defer { reads += 1 }
          return reads == 1 ? restoredFrame : borrowedFrame
        }
      }
      $0.windowTiler.apply = { _ in
        order.withValue { $0.append("layout") }
      }
      $0.focusManager.focusWindow = { key in
        #expect(key == borrowedWindow)
        order.withValue { $0.append("focus") }
      }
      $0.mouse.warp = { point in
        #expect(point == CGPoint(x: borrowedFrame.midX, y: borrowedFrame.midY))
        order.withValue { $0.append("warp") }
      }
    }
    store.exhaustivity = .off

    await store.send(.borrow(workspaceId: borrowed.id, edge: .right))
    await store.receive {
      guard case .cursorWarpFinished(let workspaceId, let target) = $0 else { return false }
      return workspaceId == borrowed.id && target == borrowedWindow
    }

    // KakaoTalk-like behavior: after the initial Borrow layout/focus, the app
    // restores a stale half-height frame. The bounded activation settlement
    // pass repairs the composition, then re-centers MFF on the live full frame.
    await clock.advance(by: .milliseconds(250))
    await store.receive {
      guard case .borrowActivationSettled(let owner, let workspaceId) = $0 else {
        return false
      }
      return owner == display && workspaceId == borrowed.id
    }
    await store.receive {
      guard case .settleFocusAfterLayout(let key, let workspaceId, let shouldFocus) = $0
      else { return false }
      return key == borrowedWindow && workspaceId == borrowed.id && !shouldFocus
    }
    await store.receive {
      guard case .cursorWarpFinished(let workspaceId, let target) = $0 else { return false }
      return workspaceId == borrowed.id && target == borrowedWindow
    }
    await store.finish()

    #expect(
      order.value
        == ["layout", "focus", "frame", "warp", "frame", "layout", "frame", "warp"]
    )
    #expect(store.state.compositionsByDisplay[display]?.host == host.id)
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
    let clock = TestClock()
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.windowSnapshot.onScreenWindowIDs = { [focusedA.windowID, survivorB.windowID] }
      $0.windowSnapshot.focusedWindowKey = { focusedA }
      $0.windowTiler.apply = { request in
        applied.withValue { $0.append(Set(request.windowFrames.keys)) }
      }
      $0.focusManager.focusWindow = { key in focused.withValue { $0.append(key) } }
    }
    store.exhaustivity = .off

    await store.send(.windowServerWindowDestroyed(closedB.windowID))
    await clock.advance(by: .milliseconds(24))
    await store.receive {
      guard case .windowServerCloseSettled(let workspaceIds) = $0 else { return false }
      return workspaceIds == [wsB.id]
    }
    await store.finish()

    #expect(store.state.tilingTrees[wsA.id]?.windows == [focusedA])
    #expect(store.state.tilingTrees[wsB.id]?.windows == [survivorB])
    #expect(applied.value == [[survivorB], [survivorB]])
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
    await store.send(.windowChanged(.windowDragEnded))
    #expect(store.state.drag == .idle)
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
    await store.send(.windowChanged(.windowDragEnded))
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

    await store.send(.windowChanged(.windowDragEnded))
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

  private func workspace(_ name: String, hint: DisplayName? = nil) -> Workspace {
    Workspace(name: name, displayHint: hint)
  }

}
