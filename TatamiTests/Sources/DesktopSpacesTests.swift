// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import CoreGraphics
import Foundation
import Testing
@testable import TatamiKit

// MARK: - DesktopSpacesTests

struct DesktopSpacesTests {
  static let left = DisplayName(uuid: "left", name: "External")
  static let right = DisplayName(uuid: "right", name: "External")

  static func spaces(left: UInt64 = 1, fullscreen: Bool = false) -> DesktopSpaces {
    DesktopSpaces(displays: [
      .init(uuid: "left", currentSpace: left, isUserDesktop: !fullscreen, userDesktops: [1, 3]),
      .init(uuid: "right", currentSpace: 2, isUserDesktop: true, userDesktops: [2, 4]),
    ], focusedDisplayUUID: "left")
  }

  @Test(arguments: [false, true])
  func `visiting a Desktop or fullscreen only gates its own monitor`(fullscreen: Bool) {
    var desktops = ManagedDesktops()
    desktops.observe(Self.spaces(), displays: [Self.left, Self.right])
    desktops.observe(Self.spaces(left: 3, fullscreen: fullscreen), displays: [Self.left, Self.right])
    #expect(!desktops.isAvailable(on: Self.left))
    #expect(desktops.isAvailable(on: Self.right))
    #expect(desktops.home(on: Self.left) == 1)
    desktops.observe(Self.spaces(), displays: [Self.left, Self.right])
    #expect(desktops.isAvailable(on: Self.left))
  }

  @Test
  func `unknown Space observations cannot release or reassign a Desktop`() {
    var desktops = ManagedDesktops()
    desktops.observe(Self.spaces(), displays: [Self.left, Self.right])
    desktops.observe(Self.spaces(left: 3), displays: [Self.left, Self.right])
    desktops.observe(nil, displays: [Self.left, Self.right])
    desktops.adopt(Self.left)
    #expect(!desktops.isAvailable(on: Self.left))
    #expect(desktops.home(on: Self.left) == 1)
    desktops.observe(Self.spaces(left: 3), displays: [Self.left, Self.right])
    #expect(!desktops.isAvailable(on: Self.left))
    #expect(desktops.isAvailable(on: Self.right))
  }

  @Test
  func `deleting the managed Desktop adopts an authoritative surviving Desktop`() {
    var desktops = ManagedDesktops()
    desktops.observe(Self.spaces(), displays: [Self.left, Self.right])
    var replacement = Self.spaces(left: 3)
    replacement.displays[0].userDesktops = [3]
    desktops.observe(replacement, displays: [Self.left, Self.right])
    #expect(desktops.home(on: Self.left) == 3)
    #expect(desktops.isAvailable(on: Self.left))
    #expect(desktops.home(on: Self.right) == 2)
  }

  @Test
  func `launching in fullscreen waits for the first ordinary Desktop`() {
    var desktops = ManagedDesktops()
    desktops.observe(Self.spaces(left: 9, fullscreen: true), displays: [Self.left, Self.right])
    #expect(desktops.home(on: Self.left) == nil)
    #expect(!desktops.isAvailable(on: Self.left))
    desktops.observe(Self.spaces(), displays: [Self.left, Self.right])
    #expect(desktops.home(on: Self.left) == 1)
    #expect(desktops.isAvailable(on: Self.left))
  }

  @Test
  func `displays with the same name retain independent Desktop identities`() {
    var desktops = ManagedDesktops()
    desktops.observe(Self.spaces(), displays: [Self.left, Self.right])
    #expect(desktops.homes.count == 2)
    #expect(desktops.home(on: DisplayName(uuid: "left", name: "Renamed")) == 1)
    #expect(desktops.home(on: Self.right) == 2)
  }

  @Test
  func `shared macOS Spaces are resolved only through the Main graph`() {
    let shared = DesktopSpaces(displays: [.init(uuid: "Main", currentSpace: 7, isUserDesktop: true, userDesktops: [7])])
    var desktops = ManagedDesktops()
    desktops.observe(shared, displays: [Self.left, Self.right])
    #expect(desktops.home(on: Self.left) == 7)
    #expect(desktops.home(on: Self.right) == 7)
    #expect(Self.spaces().space(on: DisplayName(uuid: "unknown", name: "External")) == nil)
    let next = DesktopSpaces(displays: [.init(uuid: "Main", currentSpace: 8, isUserDesktop: true, userDesktops: [7, 8])])
    desktops.observe(next, displays: [Self.left, Self.right])
    #expect(!desktops.isAvailable(on: Self.right))
    desktops.adopt(Self.left)
    #expect(desktops.isAvailable(on: Self.left))
    #expect(desktops.isAvailable(on: Self.right))
  }

  @Test
  func `SkyLight decoding rejects incomplete observations`() throws {
    let current: [String: Any] = ["id64": 1, "type": 0]
    let row: [String: Any] = ["Display Identifier": "left", "Current Space": current, "Spaces": [current]]
    let decoded = try #require(DesktopSpaces.decode([row], focusedDisplayUUID: "left"))
    #expect(decoded.displays.first?.currentSpace == 1)
    #expect(decoded.focusedDisplayUUID == "left")
    #expect(DesktopSpaces.decode([], focusedDisplayUUID: nil) == nil)
    #expect(DesktopSpaces.decode([row, row], focusedDisplayUUID: nil) == nil)
    var malformed = row
    malformed["Current Space"] = ["id64": 0, "type": 0]
    #expect(DesktopSpaces.decode([malformed], focusedDisplayUUID: nil) == nil)
    malformed["Current Space"] = ["id64": 1]
    #expect(DesktopSpaces.decode([malformed], focusedDisplayUUID: nil) == nil)
  }
}

// MARK: - DesktopWorkspaceTests

@MainActor
struct DesktopWorkspaceTests {

  // MARK: Internal

  @Test(arguments: [false, true])
  func `Desktop round trips preserve nested topology and zoom while another monitor reconciles`(fullscreen: Bool) async {
    let a = WindowKey(pid: 1, windowID: 101, bundleId: "app.editor")
    let b = WindowKey(pid: 1, windowID: 102, bundleId: a.bundleId)
    let c = WindowKey(pid: 1, windowID: 103, bundleId: a.bundleId)
    let d = WindowKey(pid: 2, windowID: 201, bundleId: "app.terminal")
    let workspace = Workspace(name: "Left", apps: [AppAssignment(bundleIdentifier: a.bundleId, name: "Editor")])
    let other = Workspace(name: "Right", apps: [AppAssignment(bundleIdentifier: d.bundleId, name: "Terminal")])
    let tree = BSPNode.branch(BSPBranch(
      split: .vertical,
      ratio: 0.3,
      left: .leaf(a),
      right:
      .branch(BSPBranch(split: .horizontal, ratio: 0.7, left: .leaf(b), right: .leaf(c))),
    ))
    var state = Self.state([workspace, other])
    state.activeWorkspacesByDisplay = [DesktopSpacesTests.left: workspace.id, DesktopSpacesTests.right: other.id]
    state.tilingTrees = [workspace.id: tree, other.id: .leaf(d)]
    state.fullscreenZoomed[workspace.id] = [b]
    state.desktops.observe(DesktopSpacesTests.spaces(), displays: state.connectedDisplays)
    let active = LockIsolated(DesktopSpacesTests.spaces(left: fullscreen ? 9 : 3, fullscreen: fullscreen))
    let store = TestStore(initialState: state) { WorkspaceActivationFeature() } withDependencies: {
      $0.sls.desktopSpaces = { active.value }
      $0.windowSnapshot.discoverKeys = { bundles, _ in bundles.contains(a.bundleId) ? [a, b, c] : [] }
      $0.windowSnapshot.onScreenWindowFrames = { [a.windowID: CGRect(x: 0, y: 0, width: 100, height: 100)] }
      $0.windowSnapshot.cachedKeys = { bundles, _ in bundles.contains(a.bundleId) ? [a, b, c] : [] }
      $0.windowSnapshot.onScreenWindowIDs = { [a.windowID, b.windowID, c.windowID] }
    }
    store.exhaustivity = .off
    await store.send(.activeSpaceChanged)
    await store.receive {
      if case .desktopSpacesResolved = $0 {
        true
      } else {
        false
      }
    }
    await store.send(.windowServerWindowEvent(.becameInvisible(a.windowID)))
    await store.send(.syncAppWindowsResolved(bundleId: a.bundleId, resizableKeys: [], onScreenFrames: [:]))
    await store.send(.windowServerWindowEvent(.terminated(d.windowID)))
    await store.finish()
    #expect(store.state.tilingTrees[workspace.id] == tree)
    #expect(store.state.fullscreenZoomed[workspace.id] == [b])
    #expect(store.state.tilingTrees[other.id] == nil)
    #expect(store.state.layoutSuspensionReasons.isEmpty)

    active.setValue(DesktopSpacesTests.spaces())
    await store.send(.activeSpaceChanged)
    await store.receive {
      if case .desktopSpacesResolved = $0 {
        true
      } else {
        false
      }
    }
    await store.receive {
      if case .syncAppWindowsResolved = $0 {
        true
      } else {
        false
      }
    }
    await store.finish()
    #expect(store.state.tilingTrees[workspace.id] == tree)
    #expect(store.state.fullscreenZoomed[workspace.id] == [b])
    #expect(store.state.desktops.isAvailable(on: DesktopSpacesTests.left))
  }

  @Test
  func `automatic app focus and queued follow actions cannot adopt a visited Desktop`() async {
    let current = Workspace(name: "Current")
    let target = Workspace(name: "Target", apps: [AppAssignment(bundleIdentifier: "app.target", name: "Target")])
    var state = Self.state([current, target])
    state.activeWorkspacesByDisplay[DesktopSpacesTests.left] = current.id
    state.$config.withLock { $0.settings.switching.followAppFocus = true }
    state.desktops.observe(DesktopSpacesTests.spaces(), displays: state.connectedDisplays)
    state.desktops.observe(DesktopSpacesTests.spaces(left: 3), displays: state.connectedDisplays)
    let requests = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) { WorkspaceActivationFeature() } withDependencies: {
      $0.sls.desktopSpaces = { DesktopSpacesTests.spaces(left: 3) }
      $0.displays.current = { DesktopSpacesTests.left }
      $0.workspaceManager.activate = { request in requests.withValue { $0.append(request) } }
      $0.windowSnapshot.frontmostApp = { FrontmostApp(pid: 3, bundleId: "app.target", name: "Target") }
    }
    store.exhaustivity = .off
    await store.send(.appActivated(bundleId: "app.target", pid: 3))
    await store.receive {
      if case .appFocusDesktopResolved = $0 {
        true
      } else {
        false
      }
    }
    await store.send(.activateFollowingAppFocus(workspaceId: target.id, interactionDisplay: DesktopSpacesTests.left))
    await store.receive {
      if case .appFocusDesktopResolved = $0 {
        true
      } else {
        false
      }
    }
    await store.finish()
    #expect(requests.value.isEmpty)
    #expect(store.state.activeWorkspace(on: DesktopSpacesTests.left) == current.id)
    #expect(store.state.desktops.home(on: DesktopSpacesTests.left) == 1)
  }

  @Test
  func `a stale Space read cannot release a newer transition`() async {
    let workspace = Workspace(name: "Code")
    var state = Self.state([workspace])
    state.activeWorkspacesByDisplay[DesktopSpacesTests.left] = workspace.id
    state.desktops.observe(DesktopSpacesTests.spaces(), displays: state.connectedDisplays)
    state.desktops.revision = 4
    state.desktops.isRefreshing = true
    let store = TestStore(initialState: state) { WorkspaceActivationFeature() }
    store.exhaustivity = .off
    await store.send(.desktopSpacesResolved(DesktopSpacesTests.spaces(), revision: 3))
    #expect(store.state.desktops.isRefreshing)
    await store.send(.desktopSpacesResolved(nil, revision: 4))
    await store.finish()
    #expect(!store.state.desktops.isAvailable(on: DesktopSpacesTests.left))
    #expect(store.state.desktops.home(on: DesktopSpacesTests.left) == 1)
  }

  @Test
  func `explicit activation adopts its completed Desktop and rejects obsolete completion`() async {
    let workspace = Workspace(name: "Code")
    var state = Self.state([workspace])
    state.activeWorkspacesByDisplay[DesktopSpacesTests.left] = workspace.id
    state.desktops.observe(DesktopSpacesTests.spaces(), displays: state.connectedDisplays)
    state.desktopAdoptionWorkspaceID = workspace.id
    state.activeActivationGeneration = 7
    state.activationGeneration = 7
    let store = TestStore(initialState: state) { WorkspaceActivationFeature() }
    store.exhaustivity = .off
    await store.send(.activationCompleted(
      workspaceId: workspace.id,
      display: DesktopSpacesTests.left,
      generation: 6,
      desktopObservation: .init(spaces: DesktopSpacesTests.spaces(left: 3), revision: 0),
    ))
    #expect(store.state.desktops.home(on: DesktopSpacesTests.left) == 1)
    await store.send(.activationCompleted(
      workspaceId: workspace.id,
      display: DesktopSpacesTests.left,
      generation: 7,
      desktopObservation: .init(spaces: DesktopSpacesTests.spaces(left: 3), revision: 0),
    ))
    await store.finish()
    #expect(store.state.desktops.home(on: DesktopSpacesTests.left) == 3)
    #expect(store.state.desktops.home(on: DesktopSpacesTests.right) == 2)
    #expect(store.state.desktopAdoptionWorkspaceID == nil)
  }

  @Test
  func `WindowServer visibility reads Desktop identity before treating a surface as closed`() async {
    let key = WindowKey(pid: 1, windowID: 101, bundleId: "app.editor")
    let workspace = Workspace(name: "Code")
    var state = Self.state([workspace])
    state.activeWorkspacesByDisplay[DesktopSpacesTests.left] = workspace.id
    state.tilingTrees[workspace.id] = .leaf(key)
    state.desktops.observe(DesktopSpacesTests.spaces(), displays: state.connectedDisplays)
    let store = TestStore(initialState: state) { WorkspaceActivationFeature() } withDependencies: {
      $0.sls.desktopSpaces = { DesktopSpacesTests.spaces(left: 3) }
      $0.windowSnapshot.onScreenWindowSurfaces = { [:] }
    }
    store.exhaustivity = .off
    await store.send(.windowServerSnapshotRequested(.becameInvisible(key.windowID)))
    await store.receive {
      if case .desktopSpacesObserved = $0 {
        true
      } else {
        false
      }
    }
    await store.receive {
      if case .windowServerWindowEvent = $0 {
        true
      } else {
        false
      }
    }
    await store.finish()
    #expect(store.state.tilingTrees[workspace.id] == .leaf(key))
    #expect(!store.state.windowServerHiddenWindows.contains(key))
    #expect(!store.state.desktops.isAvailable(on: DesktopSpacesTests.left))
  }

  @Test
  func `a pre-transition AX result cannot change the preserved tree`() async {
    let key = WindowKey(pid: 1, windowID: 101, bundleId: "app.editor")
    let workspace = Workspace(name: "Code")
    var state = Self.state([workspace])
    state.activeWorkspacesByDisplay[DesktopSpacesTests.left] = workspace.id
    state.tilingTrees[workspace.id] = .leaf(key)
    state.desktops.observe(DesktopSpacesTests.spaces(), displays: state.connectedDisplays)
    state.desktops.revision = 4
    state.desktops.isRefreshing = true
    let store = TestStore(initialState: state) { WorkspaceActivationFeature() }
    store.exhaustivity = .off
    await store.send(.syncAppWindowsResolved(
      bundleId: key.bundleId,
      resizableKeys: [],
      onScreenFrames: [:],
      desktopObservation: .init(spaces: DesktopSpacesTests.spaces(), revision: 3),
    ))
    await store.finish()
    #expect(store.state.tilingTrees[workspace.id] == .leaf(key))
    #expect(store.state.desktops.isRefreshing)
  }

  @Test
  func `lock recovery does not reassign a Desktop from a shield snapshot`() async {
    let workspace = Workspace(name: "Code")
    var state = Self.state([workspace])
    state.activeWorkspacesByDisplay[DesktopSpacesTests.left] = workspace.id
    state.desktops.observe(DesktopSpacesTests.spaces(), displays: state.connectedDisplays)
    var shield = DesktopSpacesTests.spaces(left: 3)
    shield.displays[0].userDesktops = [3]
    let store = TestStore(initialState: state) { WorkspaceActivationFeature() } withDependencies: {
      $0.sls.desktopSpaces = { DesktopSpacesTests.spaces(left: 3) }
    }
    store.exhaustivity = .off
    await store.send(.screenWillLock)
    await store.send(.desktopSpacesObserved(shield, revision: 0))
    #expect(store.state.desktops.home(on: DesktopSpacesTests.left) == 1)
    await store.send(.screenDidUnlock)
    await store.receive {
      if case .activeSpaceChanged = $0 {
        true
      } else {
        false
      }
    }
    await store.receive {
      if case .desktopSpacesResolved = $0 {
        true
      } else {
        false
      }
    }
    await store.finish()
    #expect(store.state.desktops.home(on: DesktopSpacesTests.left) == 1)
    #expect(!store.state.desktops.isAvailable(on: DesktopSpacesTests.left))
    #expect(store.state.desktops.isAvailable(on: DesktopSpacesTests.right))
  }

  @Test
  func `following app focus on a healthy monitor cannot adopt an away target monitor`() async {
    let workspace = Workspace(name: "Current")
    var target = Workspace(name: "Target")
    target.displayHint = DesktopSpacesTests.left
    var state = Self.state([workspace, target])
    state.activeWorkspacesByDisplay[DesktopSpacesTests.right] = workspace.id
    state.focusedDisplay = DesktopSpacesTests.right
    state.desktops.observe(DesktopSpacesTests.spaces(), displays: state.connectedDisplays)
    var snapshot = DesktopSpacesTests.spaces(left: 3)
    snapshot.focusedDisplayUUID = "right"
    state.desktops.observe(snapshot, displays: state.connectedDisplays)
    let requests = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) { WorkspaceActivationFeature() } withDependencies: {
      $0.sls.desktopSpaces = {
        var spaces = DesktopSpacesTests.spaces(left: 3)
        spaces.focusedDisplayUUID = "right"
        return spaces
      }
      $0.displays.current = { DesktopSpacesTests.right }
      $0.workspaceManager.activate = { request in requests.withValue { $0.append(request) } }
    }
    store.exhaustivity = .off
    await store.send(.activateFollowingAppFocus(workspaceId: target.id, interactionDisplay: DesktopSpacesTests.right))
    await store.receive {
      if case .appFocusDesktopResolved = $0 {
        true
      } else {
        false
      }
    }
    await store.finish()
    #expect(requests.value.isEmpty)
    #expect(store.state.desktops.home(on: DesktopSpacesTests.left) == 1)
  }

  @Test
  func `a deliberate workspace command can adopt the Desktop where activation finishes`() async {
    let current = Workspace(name: "Current")
    let target = Workspace(name: "Target")
    var state = Self.state([current, target])
    state.activeWorkspacesByDisplay[DesktopSpacesTests.left] = current.id
    state.desktops.observe(DesktopSpacesTests.spaces(), displays: state.connectedDisplays)
    state.desktops.observe(DesktopSpacesTests.spaces(left: 3), displays: state.connectedDisplays)
    let requests = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) { WorkspaceActivationFeature() } withDependencies: {
      $0.continuousClock = TestClock()
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
      $0.displays.current = { DesktopSpacesTests.left }
      $0.sls.desktopSpaces = { DesktopSpacesTests.spaces(left: 3) }
      $0.workspaceManager.activate = { request in requests.withValue { $0.append(request) } }
    }
    store.exhaustivity = .off
    await store.send(.activate(workspaceId: target.id, setFocus: true))
    await store.receive {
      if case .activationCompleted = $0 {
        true
      } else {
        false
      }
    }
    await store.receive {
      if case .activationTailFinished = $0 {
        true
      } else {
        false
      }
    }
    await store.finish()
    #expect(requests.value.count == 1)
    #expect(store.state.activeWorkspace(on: DesktopSpacesTests.left) == target.id)
    #expect(store.state.desktops.home(on: DesktopSpacesTests.left) == 3)
    #expect(store.state.desktops.home(on: DesktopSpacesTests.right) == 2)
  }

  @Test
  func `automatic display restoration waits for that monitors Desktop to return`() async {
    let current = Workspace(name: "Current")
    let restored = Workspace(name: "Restored")
    var state = Self.state([current, restored])
    state.activeWorkspacesByDisplay[DesktopSpacesTests.left] = current.id
    state.desktops.observe(DesktopSpacesTests.spaces(), displays: state.connectedDisplays)
    state.desktops.observe(DesktopSpacesTests.spaces(left: 3), displays: state.connectedDisplays)
    let requests = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) { WorkspaceActivationFeature() } withDependencies: {
      $0.continuousClock = TestClock()
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
      $0.sls.desktopSpaces = { DesktopSpacesTests.spaces() }
      $0.workspaceManager.activate = { request in requests.withValue { $0.append(request) } }
    }
    store.exhaustivity = .off
    await store.send(.restoreDisplay(.init(display: DesktopSpacesTests.left, workspace: restored.id)))
    #expect(requests.value.isEmpty)
    #expect(store.state.deferredDesktopRestores[DesktopSpacesTests.left]?.workspace == restored.id)
    await store.send(.desktopSpacesResolved(DesktopSpacesTests.spaces(), revision: 0))
    await store.receive {
      if case .activationCompleted = $0 {
        true
      } else {
        false
      }
    }
    await store.receive {
      if case .activationTailFinished = $0 {
        true
      } else {
        false
      }
    }
    await store.finish()
    #expect(requests.value.count == 1)
    #expect(store.state.activeWorkspace(on: DesktopSpacesTests.left) == restored.id)
    #expect(store.state.deferredDesktopRestores.isEmpty)
  }

  @Test
  func `Desktop changes remove only offscreen floating mirrors and reject stale presentation`() async {
    let leftKey = WindowKey(pid: 1, windowID: 101, bundleId: "app.left")
    let rightKey = WindowKey(pid: 2, windowID: 201, bundleId: "app.right")
    let left = Workspace(name: "Left", apps: [AppAssignment(bundleIdentifier: leftKey.bundleId, name: "Left", layout: .floating)])
    let right = Workspace(
      name: "Right",
      apps: [AppAssignment(bundleIdentifier: rightKey.bundleId, name: "Right", layout: .floating)],
    )
    var state = Self.state([left, right])
    state.activeWorkspacesByDisplay = [DesktopSpacesTests.left: left.id, DesktopSpacesTests.right: right.id]
    state.desktops.observe(DesktopSpacesTests.spaces(), displays: state.connectedDisplays)
    state.desktops.revision = 2
    let presented = LockIsolated<[Set<WindowKey>]>([])
    let store = TestStore(initialState: state) { WorkspaceActivationFeature() } withDependencies: {
      $0.sls.desktopSpaces = { DesktopSpacesTests.spaces(left: 3) }
      $0.windowSnapshot.discoverKeys = { bundles, _ in
        [leftKey, rightKey].filter { bundles.contains($0.bundleId) }
      }
      $0.windowSnapshot.onScreenWindowIDs = { [rightKey.windowID] }
      $0.floatingOverlay.setFloating = { keys in presented.withValue { $0.append(keys) } }
    }
    store.exhaustivity = .off
    await store.send(.floatingPresentationResolved([leftKey], desktopRevision: 1))
    #expect(presented.value.isEmpty)
    await store.send(.desktopSpacesResolved(DesktopSpacesTests.spaces(left: 3), revision: 2))
    await store.receive {
      if case .floatingPresentationResolved = $0 {
        true
      } else {
        false
      }
    }
    await store.finish()
    #expect(presented.value.last == [rightKey])
    #expect(store.state.desktops.home(on: DesktopSpacesTests.left) == 1)
  }

  @Test
  func `AX discovery spanning a Desktop change cannot prune the preserved layout`() async {
    let key = WindowKey(pid: 1, windowID: 101, bundleId: "app.editor")
    let workspace = Workspace(name: "Code", apps: [AppAssignment(bundleIdentifier: key.bundleId, name: "Editor")])
    var state = Self.state([workspace])
    state.activeWorkspacesByDisplay[DesktopSpacesTests.left] = workspace.id
    state.tilingTrees[workspace.id] = .leaf(key)
    state.desktops.observe(DesktopSpacesTests.spaces(), displays: state.connectedDisplays)
    let reads = LockIsolated(0)
    let store = TestStore(initialState: state) { WorkspaceActivationFeature() } withDependencies: {
      $0.sls.desktopSpaces = {
        let count = reads.withValue { value in value += 1
          return value
        }
        return DesktopSpacesTests.spaces(left: count == 1 ? 1 : 3)
      }
      $0.windowSnapshot.discoverKeys = { _, _ in [] }
    }
    store.exhaustivity = .off
    await store.send(.syncAppWindows(bundleId: key.bundleId))
    await store.receive {
      if case .syncAppWindowsResolved = $0 {
        true
      } else {
        false
      }
    }
    await store.finish()
    #expect(reads.value == 2)
    #expect(store.state.tilingTrees[workspace.id] == .leaf(key))
    #expect(!store.state.desktops.isAvailable(on: DesktopSpacesTests.left))
  }

  @Test(arguments: [false, true])
  func `app focus on the ordinary monitor uses fresh native focus while the pointer remains over fullscreen`(pinned: Bool) async {
    var (state, target, _) = Self.followState()
    if !pinned {
      target.displayHint = nil
      state.$config.withLock { config in
        config.profiles[0].workspaces[id: target.id]?.displayHint = nil
      }
    }
    let originalA = state.activeWorkspacesByDisplay[DesktopSpacesTests.left]
    var fresh = DesktopSpacesTests.spaces(left: 18, fullscreen: true)
    fresh.focusedDisplayUUID = "right"
    let freshSpaces = fresh
    let activations = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) { WorkspaceActivationFeature() } withDependencies: {
      $0.continuousClock = TestClock()
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
      $0.displays.current = { DesktopSpacesTests.left }
      $0.sls.desktopSpaces = { freshSpaces }
      $0.windowSnapshot.frontmostApp = { FrontmostApp(pid: 99, bundleId: "app.follow", name: "Follow") }
      $0.workspaceManager.activate = { request in activations.withValue { $0.append(request) } }
    }
    store.exhaustivity = .off
    await store.send(.appActivated(bundleId: "app.follow", pid: 99))
    await store.receive {
      if case .activationCompleted = $0 {
        true
      } else {
        false
      }
    }
    await store.receive {
      if case .activationTailFinished = $0 {
        true
      } else {
        false
      }
    }
    await store.finish()
    #expect(activations.value.map(\.targetDisplay) == [DesktopSpacesTests.right])
    #expect(store.state.activeWorkspace(on: DesktopSpacesTests.right) == target.id)
    #expect(store.state.activeWorkspace(on: DesktopSpacesTests.left) == originalA)
    #expect(store.state.desktops.home(on: DesktopSpacesTests.left) == 1)
    #expect(store.state.desktops.home(on: DesktopSpacesTests.right) == 2)
  }

  @Test(arguments: [String?.some("left"), nil])
  func `cached ordinary focus cannot authorize fullscreen or unknown native origin`(origin: String?) async {
    let (state, target, current) = Self.followState(cachedFocus: "right")
    var fresh = DesktopSpacesTests.spaces(left: 18, fullscreen: true)
    fresh.focusedDisplayUUID = origin
    let freshSpaces = fresh
    let activations = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) { WorkspaceActivationFeature() } withDependencies: {
      $0.displays.current = { DesktopSpacesTests.right }
      $0.sls.desktopSpaces = { freshSpaces }
      $0.windowSnapshot.frontmostApp = { FrontmostApp(pid: 99, bundleId: "app.follow", name: "Follow") }
      $0.workspaceManager.activate = { request in activations.withValue { $0.append(request) } }
    }
    store.exhaustivity = .off
    await store.send(.activateFollowingAppFocus(workspaceId: target.id))
    await store.receive {
      if case .appFocusDesktopResolved = $0 {
        true
      } else {
        false
      }
    }
    await store.finish()
    #expect(activations.value.isEmpty)
    #expect(store.state.activeWorkspace(on: DesktopSpacesTests.right) == current.id)
    #expect(store.state.pendingAppFocusDesktopRequest == nil)
  }

  @Test
  func `native Space refresh preserves the pending app focus until fresh keyboard focus is available`() async {
    var (state, target, _) = Self.followState()
    state.desktops.isRefreshing = true
    state.desktops.revision = 4
    var fresh = DesktopSpacesTests.spaces(left: 18, fullscreen: true)
    fresh.focusedDisplayUUID = "right"
    let freshSpaces = fresh
    let reads = LockIsolated(0)
    let activations = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) { WorkspaceActivationFeature() } withDependencies: {
      $0.continuousClock = TestClock()
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
      $0.displays.current = { DesktopSpacesTests.left }
      $0.sls.desktopSpaces = { reads.withValue { $0 += 1 }
        return freshSpaces
      }
      $0.windowSnapshot.frontmostApp = { FrontmostApp(pid: 99, bundleId: "app.follow", name: "Follow") }
      $0.workspaceManager.activate = { request in activations.withValue { $0.append(request) } }
    }
    store.exhaustivity = .off
    await store.send(.activateFollowingAppFocus(workspaceId: target.id))
    #expect(reads.value == 0)
    #expect(store.state.pendingAppFocusDesktopRequest?.workspaceID == target.id)
    await store.send(.desktopSpacesResolved(DesktopSpacesTests.spaces(left: 18, fullscreen: true), revision: 4))
    await store.receive {
      if case .activationCompleted = $0 {
        true
      } else {
        false
      }
    }
    await store.receive {
      if case .activationTailFinished = $0 {
        true
      } else {
        false
      }
    }
    await store.finish()
    #expect(activations.value.count == 1)
    #expect(store.state.activeWorkspace(on: DesktopSpacesTests.right) == target.id)
    #expect(store.state.pendingAppFocusDesktopRequest == nil)
  }

  @Test
  func `a different frontmost process supersedes a pending native focus read`() async {
    let (state, target, current) = Self.followState()
    let (stream, continuation) = AsyncStream<DesktopSpaces>.makeStream()
    let frontmost = LockIsolated(FrontmostApp(pid: 99, bundleId: "app.follow", name: "Follow"))
    let activations = LockIsolated<[ActivationRequest]>([])
    let store = TestStore(initialState: state) { WorkspaceActivationFeature() } withDependencies: {
      $0.displays.current = { DesktopSpacesTests.right }
      $0.sls.desktopSpaces = { var iterator = stream.makeAsyncIterator()
        return await iterator.next()
      }
      $0.windowSnapshot.frontmostApp = { frontmost.value }
      $0.workspaceManager.activate = { request in activations.withValue { $0.append(request) } }
    }
    store.exhaustivity = .off
    await store.send(.activateFollowingAppFocus(workspaceId: target.id))
    frontmost.setValue(FrontmostApp(pid: 100, bundleId: "app.other", name: "Other"))
    continuation.yield(DesktopSpacesTests.spaces())
    continuation.finish()
    await store.receive {
      if case .appFocusDesktopResolved = $0 {
        true
      } else {
        false
      }
    }
    await store.finish()
    #expect(activations.value.isEmpty)
    #expect(store.state.activeWorkspace(on: DesktopSpacesTests.right) == current.id)
    #expect(store.state.pendingAppFocusDesktopRequest == nil)
  }

  // MARK: Private

  private static func state(_ workspaces: [Workspace]) -> WorkspaceActivationFeature.State {
    var state = WorkspaceActivationFeature.State()
    state.$config.withLock {
      $0.profiles = [Profile(name: "Default", workspaces: IdentifiedArray(uniqueElements: workspaces))]
    }
    state.connectedDisplays = [DesktopSpacesTests.left, DesktopSpacesTests.right]
    state.focusedDisplay = DesktopSpacesTests.left
    return state
  }

  private static func followState(cachedFocus: String = "left") -> (
    WorkspaceActivationFeature.State,
    Workspace,
    Workspace,
  ) {
    let a = Workspace(name: "A")
    let b = Workspace(name: "B")
    var target = Workspace(name: "Follow B", apps: [AppAssignment(bundleIdentifier: "app.follow", name: "Follow")])
    target.displayHint = DesktopSpacesTests.right
    var state = Self.state([a, b, target])
    state.activeWorkspacesByDisplay = [DesktopSpacesTests.left: a.id, DesktopSpacesTests.right: b.id]
    state.$config.withLock { $0.settings.switching.followAppFocus = true }
    state.desktops.observe(DesktopSpacesTests.spaces(), displays: state.connectedDisplays)
    var cached = DesktopSpacesTests.spaces(left: 18, fullscreen: true)
    cached.focusedDisplayUUID = cachedFocus
    state.desktops.observe(cached, displays: state.connectedDisplays)
    return (state, target, b)
  }

}
