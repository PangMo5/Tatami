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
    let windowA = WindowKey(pid: 1, windowID: 101, bundleId: "app.a")
    let windowB = WindowKey(pid: 2, windowID: 201, bundleId: "app.b")
    let state = Self.makeState(workspaces: [wsA, wsB]) {
      $0.focusedDisplay = displayA
      $0.activeWorkspacesByDisplay = [displayA: wsA.id, displayB: wsB.id]
      $0.tilingTrees = [wsA.id: .leaf(windowA), wsB.id: .leaf(windowB)]
    }
    let requests = LockIsolated<[ActivationRequest]>([])
    let focused = LockIsolated<[WindowKey]>([])
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
    }
    store.exhaustivity = .off

    await store.send(.focusAdjacentDisplay(direction: 1))
    await store.finish()

    #expect(requests.value.isEmpty)
    #expect(focused.value == [windowB])
    #expect(store.state.focusedDisplay == displayB)
    #expect(store.state.activeWorkspacesByDisplay[displayB] == wsB.id)
    #expect(store.state.activeWorkspacesByDisplay[displayA] == wsA.id)
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
        BorrowedSlot(workspace: figma.id, edge: .right, fraction: 0.4),
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
      $0.displays.all = { [displayA, displayB] }
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
    let browser = Workspace(name: "Browser")
    let terminal = Workspace(name: "Terminal")
    let figma = Workspace(name: "Figma")
    let browserWindow = WindowKey(pid: 1, windowID: 101, bundleId: "app.browser")
    let terminalWindow = WindowKey(pid: 2, windowID: 201, bundleId: "app.terminal")
    let figmaWindow = WindowKey(pid: 3, windowID: 301, bundleId: "app.figma")
    let composition = Composition(
      host: browser.id,
      borrowed: [
        BorrowedSlot(workspace: figma.id, edge: .right, fraction: 0.4),
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

    await store.send(.activateRecent)
    await store.finish()

    #expect(requests.value.isEmpty)
    #expect(focused.value == [windowB])
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

  @Test(arguments: AutoBalanceMode.allCases)
  func `fresh activation initializes a missing layout from auto balance`(
    mode: AutoBalanceMode
  ) async {
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
    let initial = WorkspaceActivationFeature.mergeTree(
      existing: nil,
      target: keys,
      focused: { nil },
      insertionPoint: nil,
      workArea: workArea,
      settings: AppSettings(),
    )!
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
      guard case .activationCompleted(let workspaceId, _) = $0 else { return false }
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

    await store.send(.activationCompleted(workspaceId: ws2.id, display: Self.display)) {
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
  func `restored workspace history keeps only valid normal workspaces`() async {
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
    let activeProfileId = store.state.config.activeProfile!.id

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
      guard case .restoreDisplay(let workspaceId, let display) = $0 else { return false }
      return workspaceId == workspaceA.id && display == displayA
    }
    await store.receive {
      guard case .activationCompleted(let workspaceId, let display) = $0 else { return false }
      return workspaceId == workspaceA.id && display == displayA
    }
    await store.receive(\.processDisplayRestores)
    await store.receive {
      guard case .restoreDisplay(let workspaceId, let display) = $0 else { return false }
      return workspaceId == workspaceB.id && display == displayB
    }
    await store.receive {
      guard case .activationCompleted(let workspaceId, let display) = $0 else { return false }
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
      guard case .restoreDisplay(let workspaceId, let owner) = $0 else { return false }
      return workspaceId == frontmost.id && owner == display
    }
    await store.receive {
      guard case .activationCompleted(let workspaceId, let owner) = $0 else { return false }
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
  func `outgoing focus snapshot repairs MRU without restoring the old display`() async {
    let displayA = DisplayName("A")
    let displayB = DisplayName("B")
    let outgoing = WindowKey(pid: 1, windowID: 101, bundleId: "app.outgoing")
    let oldWorkspace = Workspace(
      name: "Old",
      apps: [AppAssignment(bundleIdentifier: outgoing.bundleId, name: "Outgoing")],
    )
    let targetWorkspace = Workspace(name: "Target")
    let state = Self.makeState(workspaces: [oldWorkspace, targetWorkspace]) {
      $0.focusedDisplay = displayB
      $0.activeWorkspacesByDisplay = [
        displayA: oldWorkspace.id,
        displayB: targetWorkspace.id,
      ]
      $0.tilingTrees[oldWorkspace.id] = .leaf(outgoing)
    }
    let store = TestStore(initialState: state) {
      WorkspaceActivationFeature()
    }

    await store.send(.activationFocusSnapshotResolved(outgoing)) {
      $0.insertionPoint[oldWorkspace.id] = outgoing
      $0.mruWindows[oldWorkspace.id] = [outgoing]
    }

    #expect(store.state.focusedDisplay == displayB)
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
          .windowFocused(bundleId: let bundleId, key: let key)
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
      $0.isSystemSuspended = true
      $0.suspendedLayoutWindows[workspace.id] = [first, second]
    }
    await store.send(.windowServerWindowEvent(.terminated(first.windowID)))
    await store.send(.windowServerWindowEvent(.becameInvisible(second.windowID)))
    await store.finish()

    #expect(store.state.tilingTrees[workspace.id] == tree)
    #expect(invalidated.value == [first.windowID])
    #expect(saved.value.isEmpty)
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
      guard case .activationCompleted(let workspaceId, _) = $0 else { return false }
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

  private func workspace(_ name: String, hint: DisplayName? = nil) -> Workspace {
    Workspace(name: name, displayHint: hint)
  }

}
