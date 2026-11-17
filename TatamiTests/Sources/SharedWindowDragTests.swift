// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import CoreGraphics
import Foundation
import Testing
@testable import TatamiKit

@MainActor
struct SharedWindowDragTests {

  // MARK: Internal

  nonisolated static let a = DisplayName(uuid: "a", name: "A")
  nonisolated static let b = DisplayName(uuid: "b", name: "B")
  nonisolated static let moved = WindowKey(pid: 1, windowID: 10, bundleId: "app.shared")
  nonisolated static let target = WindowKey(pid: 2, windowID: 20, bundleId: "app.target")
  nonisolated static let bounds = [
    a: CGRect(x: 0, y: 0, width: 1000, height: 800),
    b: CGRect(x: 1000, y: 0, width: 1000, height: 800),
  ]

  @Test(arguments: [CGPoint(x: 1100, y: 400), CGPoint(x: 1900, y: 400), CGPoint(x: 1500, y: 100), CGPoint(x: 1500, y: 700)])
  func `shared cross display drops insert on an edge without swapping`(point: CGPoint) throws {
    var (state, source, destination) = Self.state()
    let decision = try #require(Self.decision(state, point: point))
    #expect(decision.drop.zone != .swap)
    #expect(decision.drop.destination == destination.id)
    Self.commit(decision.drop, state: &state)
    #expect(state.tilingTrees[source.id] == nil)
    #expect(Set(state.tilingTrees[destination.id]?.windows ?? []) == [Self.moved, Self.target])
    #expect(state.sharedWindowDisplayOwners[Self.moved] == Self.b)
    let frames = try #require(state.tilingTrees[destination.id]).frames(in: try #require(Self.bounds[Self.b]), gap: 0)
    let moved = try #require(frames[Self.moved])
    let target = try #require(frames[Self.target])
    switch decision.drop.zone {
    case .left: #expect(moved.maxX <= target.minX)
    case .right: #expect(target.maxX <= moved.minX)
    case .top: #expect(moved.maxY <= target.minY)
    case .bottom: #expect(target.maxY <= moved.minY)
    default: Issue.record("Cross-display drop must have an insertion edge")
    }
  }

  @Test
  func `an empty host accepts its first shared tile`() throws {
    var (state, source, destination) = Self.state()
    state.tilingTrees[destination.id] = nil
    let decision = try #require(Self.decision(state, point: CGPoint(x: 1500, y: 400)))
    #expect(decision.drop.target == nil)
    #expect(decision.drop.zone == nil)
    Self.commit(decision.drop, state: &state)
    #expect(state.tilingTrees[source.id] == nil)
    #expect(state.tilingTrees[destination.id] == .leaf(Self.moved))
  }

  @Test
  func `nonshared windows cannot transfer and local center drops still swap`() {
    var (state, _, _) = Self.state()
    state.$config.withLock { $0.sharedApps = [] }
    #expect(Self.decision(state, point: CGPoint(x: 1500, y: 400)) == nil)
    #expect(DropZone.quadrant(point: CGPoint(x: 50, y: 50), in: CGRect(x: 0, y: 0, width: 100, height: 100)) == .swap)
    #expect(DropZone
      .quadrant(point: CGPoint(x: 50, y: 50), in: CGRect(x: 0, y: 0, width: 100, height: 100), allowsSwap: false) != .swap)
  }

  @Test
  func `changed destination rejects a frozen transfer`() throws {
    var (state, source, destination) = Self.state()
    let decision = try #require(Self.decision(state, point: CGPoint(x: 1500, y: 400)))
    state.activeWorkspacesByDisplay[Self.b] = source.id
    Self.commit(decision.drop, state: &state)
    #expect(state.tilingTrees[source.id] == .leaf(Self.moved))
    #expect(state.tilingTrees[destination.id] == .leaf(Self.target))
  }

  @Test
  func `native away destinations are not drag targets`() throws {
    var (state, _, _) = Self.state()
    var away = try #require(state.desktops.snapshot)
    away.displays[1].currentSpace = 3
    state.desktops.observe(away, displays: state.connectedDisplays)
    #expect(Self.decision(state, point: CGPoint(x: 1500, y: 400)) == nil)
  }

  @Test
  func `old app restored geometry cannot reverse an explicit transfer`() {
    let accepted = Self.bounds.keys.filter { display in
      !WorkspaceActivationFeature.scopedWindowKeys(
        [Self.moved],
        sharedTiledBundleIds: [Self.moved.bundleId],
        existingTargetKeys: [],
        protectedKeys: [],
        partitionSharedWindows: true,
        targetDisplay: display,
        displayBounds: Self.bounds,
        explicitOwners: [Self.moved: Self.b],
        onScreenWindowIDs: [Self.moved.windowID],
        windowFrame: { _ in CGRect(x: 10, y: 10, width: 400, height: 500) },
      ).isEmpty
    }
    #expect(accepted == [Self.b])
  }

  @Test
  func `a pointer down protects shared membership before AX movement arrives`() async {
    let (state, source, destination) = Self.state()
    let store = TestStore(initialState: state) { WorkspaceActivationFeature() }
    store.exhaustivity = .off
    await store.send(.windowChanged(.windowPointerDown(windowID: Self.moved.windowID)))
    await store.send(.syncAppWindowsResolved(
      bundleId: Self.moved.bundleId,
      resizableKeys: [],
      onScreenFrames: [:],
      placementFrames: [:],
    ))
    await store.finish()
    #expect(store.state.tilingTrees[source.id] == .leaf(Self.moved))
    #expect(store.state.tilingTrees[destination.id] == .leaf(Self.target))
    #expect(store.state.pendingWindowSyncBundleIds.contains(Self.moved.bundleId))
  }

  @Test
  func `disconnected display releases explicit ownership`() {
    var (state, _, _) = Self.state()
    state.sharedWindowDisplayOwners[Self.moved] = Self.b
    _ = state.reconcileDisplayTopology(liveDisplays: [Self.a])
    #expect(state.sharedWindowDisplayOwners.isEmpty)
  }

  @Test
  func `borrowed blocks are excluded while their host remains a destination`() throws {
    var (state, _, destination) = Self.state()
    let borrowed = Workspace(name: "Borrowed")
    let borrowedKey = WindowKey(pid: 3, windowID: 30, bundleId: "app.borrowed")
    state.$config.withLock { $0.profiles[0].workspaces.append(borrowed) }
    state.compositionsByDisplay[Self.b] = Composition(
      host: destination.id,
      borrowed: [BorrowedSlot(workspace: borrowed.id, edge: .right, fraction: 0.4)],
    )
    state.tilingTrees[borrowed.id] = .leaf(borrowedKey)
    #expect(Self.decision(state, point: CGPoint(x: 1800, y: 400)) == nil)
    let decision = try #require(Self.decision(state, point: CGPoint(x: 1200, y: 400)))
    Self.commit(decision.drop, state: &state)
    #expect(state.tilingTrees[borrowed.id] == .leaf(borrowedKey))
    #expect(state.tilingTrees[destination.id]?.windows.contains(Self.moved) == true)
  }

  @Test
  func `negative portrait coordinates are valid cross display destinations`() throws {
    let (state, _, _) = Self.state()
    let bounds = [
      Self.a: CGRect(x: 0, y: 0, width: 1920, height: 1200),
      Self.b: CGRect(x: -1440, y: 0, width: 1440, height: 2560),
    ]
    let decision = withDependencies {
      $0.mouse.axLocation = { CGPoint(x: -800, y: 600) }
      $0.displays.bounds = { bounds[$0 ?? Self.a] ?? .zero }
      $0.displays.workArea = { bounds[$0 ?? Self.a] ?? .zero }
    } operation: { WorkspaceActivationFeature().sharedWindowDropDecision(dragged: Self.moved, state: state) }
    #expect(try #require(decision).drop.display == Self.b)
  }

  @Test
  func `explicit placement does not admit hidden windows on another native Desktop`() {
    let accepted = WorkspaceActivationFeature.scopedWindowKeys(
      [Self.moved],
      sharedTiledBundleIds: [Self.moved.bundleId],
      existingTargetKeys: [],
      protectedKeys: [],
      partitionSharedWindows: true,
      targetDisplay: Self.b,
      displayBounds: Self.bounds,
      explicitOwners: [Self.moved: Self.b],
      onScreenWindowIDs: [],
      windowFrame: { _ in CGRect(x: 1100, y: 10, width: 400, height: 500) },
    )
    #expect(accepted.isEmpty)
  }

  @Test
  func `a click without movement releases deferred shared discovery`() async {
    let (state, source, destination) = Self.state()
    let spaces = state.desktops.snapshot
    let reads = LockIsolated(0)
    let store = TestStore(initialState: state) { WorkspaceActivationFeature() } withDependencies: {
      $0.dragPreview.hide = { }
      $0.sls.desktopSpaces = { spaces }
      $0.displays.all = { [Self.a, Self.b] }
      $0.displays.workArea = { Self.bounds[$0 ?? Self.a] ?? .zero }
      $0.displays.bounds = { Self.bounds[$0 ?? Self.a] ?? .zero }
      $0.windowSnapshot.discoverKeys = { _, _ in reads.withValue { $0 += 1 }
        return [Self.moved]
      }
      $0.windowSnapshot.onScreenWindowFrames = { [
        Self.moved.windowID: Self.bounds[Self.a]!,
        Self.target.windowID: Self.bounds[Self.b]!,
      ] }
    }
    store.exhaustivity = .off
    await store.send(.windowChanged(.windowPointerDown(windowID: Self.moved.windowID)))
    await store.send(.syncAppWindowsResolved(bundleId: Self.moved.bundleId, resizableKeys: [], onScreenFrames: [:]))
    #expect(store.state.pendingWindowSyncBundleIds.contains(Self.moved.bundleId))
    await store.send(.windowChanged(.windowDragEnded(
      trackedWindowID: Self.moved.windowID,
      key: nil,
      frame: nil,
      pointerMoved: false,
    )))
    await store.finish()
    #expect(reads.value > 0)
    #expect(!store.state.pendingWindowSyncBundleIds.contains(Self.moved.bundleId))
    #expect(store.state.tilingTrees[source.id] == .leaf(Self.moved))
    #expect(store.state.tilingTrees[destination.id] == .leaf(Self.target))
  }

  @Test
  func `captured release coordinates survive a later cursor move`() throws {
    let (state, _, destination) = Self.state()
    let decision = withDependencies {
      $0.mouse.axLocation = { CGPoint(x: 500, y: 400) }
      $0.displays.bounds = { Self.bounds[$0 ?? Self.a] ?? .zero }
      $0.displays.workArea = { Self.bounds[$0 ?? Self.a] ?? .zero }
    } operation: {
      WorkspaceActivationFeature().sharedWindowDropDecision(
        dragged: Self.moved,
        state: state,
        pointer: CGPoint(x: 1500, y: 400),
      )
    }
    #expect(try #require(decision).drop.destination == destination.id)
  }

  @Test
  func `moving one shared window leaves its same app sibling on the source display`() throws {
    var (state, source, destination) = Self.state()
    let sibling = WindowKey(pid: Self.moved.pid, windowID: 11, bundleId: Self.moved.bundleId)
    state.tilingTrees[source.id] = .branch(BSPBranch(
      split: .horizontal,
      ratio: 0.4,
      left: .leaf(Self.moved),
      right: .leaf(sibling),
    ))
    let decision = try #require(Self.decision(state, point: CGPoint(x: 1500, y: 400)))
    Self.commit(decision.drop, state: &state)
    #expect(state.tilingTrees[source.id] == .leaf(sibling))
    #expect(state.tilingTrees[destination.id]?.windows.contains(Self.moved) == true)
    #expect(state.sharedWindowDisplayOwners[sibling] == nil)
  }

  @Test(arguments: [true, false])
  func `release point commits or cancels a preview even without a final frame`(moves: Bool) throws {
    var (state, source, destination) = Self.state()
    let oldPreview = try #require(Self.decision(state, point: CGPoint(x: 1500, y: 400)))
    state.drag = .transferring(oldPreview.drop)
    let released = moves ? CGPoint(x: 1500, y: 400) : CGPoint(x: 500, y: 400)
    withDependencies {
      $0.mouse.axLocation = { moves ? CGPoint(x: 500, y: 400) : CGPoint(x: 1500, y: 400) }
      $0.displays.bounds = { Self.bounds[$0 ?? Self.a] ?? .zero }
      $0.displays.workArea = { Self.bounds[$0 ?? Self.a] ?? .zero }
    } operation: {
      var reducer = WorkspaceActivationFeature().body
      _ = reducer.reduce(into: &state, action: .windowChanged(.windowDragEnded(
        trackedWindowID: Self.moved.windowID,
        key: nil,
        frame: nil,
        pointerMoved: true,
        pointerLocation: released,
      )))
    }
    #expect(state.tilingTrees[source.id]?.windows.contains(Self.moved) == (moves ? nil : true))
    #expect(state.tilingTrees[destination.id]?.windows.contains(Self.moved) == moves)
  }

  @Test
  func `new shared windows are discovered on hosts with no existing sibling`() async throws {
    var (state, source, destination) = Self.state()
    state.tilingTrees[source.id] = nil
    state.tilingTrees[destination.id] = .leaf(Self.moved)
    state.sharedWindowDisplayOwners[Self.moved] = Self.b
    let fresh = WindowKey(pid: Self.moved.pid, windowID: 12, bundleId: Self.moved.bundleId)
    let frames = [Self.moved.windowID: try #require(Self.bounds[Self.b]), fresh.windowID: try #require(Self.bounds[Self.a])]
    #expect(Set(state.workspacesForSync(bundleId: Self.moved.bundleId)) == [source.id, destination.id])
    let store = TestStore(initialState: state) { WorkspaceActivationFeature() } withDependencies: {
      $0.displays.all = { [Self.a, Self.b] }
      $0.displays.bounds = { Self.bounds[$0 ?? Self.a] ?? .zero }
      $0.displays.workArea = { Self.bounds[$0 ?? Self.a] ?? .zero }
      $0.windowSnapshot.onScreenWindowFrames = { frames }
      $0.windowTiler.apply = { _ in }
    }
    store.exhaustivity = .off
    await store.send(.syncAppWindowsResolved(
      bundleId: Self.moved.bundleId,
      resizableKeys: [Self.moved, fresh],
      onScreenFrames: frames,
      placementFrames: [Self.moved: try #require(Self.bounds[Self.b]), fresh: try #require(Self.bounds[Self.a])],
    ))
    await store.finish()
    #expect(store.state.tilingTrees[source.id] == .leaf(fresh))
    #expect(store.state.tilingTrees[destination.id] == .leaf(Self.moved))
  }

  // MARK: Private

  private static func decision(_ state: WorkspaceActivationFeature.State, point: CGPoint)
    -> (drop: WorkspaceActivationFeature.State.SharedWindowDrop, rect: CGRect)?
  {
    withDependencies {
      $0.mouse.axLocation = { point }
      $0.displays.bounds = { Self.bounds[$0 ?? Self.a] ?? .zero }
      $0.displays.workArea = { Self.bounds[$0 ?? Self.a] ?? .zero }
    } operation: {
      WorkspaceActivationFeature().sharedWindowDropDecision(dragged: Self.moved, state: state)
    }
  }

  private static func commit(
    _ drop: WorkspaceActivationFeature.State.SharedWindowDrop,
    state: inout WorkspaceActivationFeature.State,
  ) {
    withDependencies {
      $0.displays.workArea = { Self.bounds[$0 ?? Self.a] ?? .zero }
    } operation: { _ = WorkspaceActivationFeature().applySharedWindowDrop(drop, state: &state) }
  }

  private static func state() -> (WorkspaceActivationFeature.State, Workspace, Workspace) {
    var state = WorkspaceActivationFeature.State()
    let source = Workspace(name: "Source")
    let destination = Workspace(name: "Destination")
    state.$config.withLock {
      $0.profiles = [Profile(name: "Default", workspaces: [source, destination])]
      $0.sharedApps = [SharedApp(bundleIdentifier: Self.moved.bundleId, name: "Shared")]
      $0.settings.layout.gapInner = 0
      $0.settings.layout.gapOuter = 0
    }
    state.connectedDisplays = [Self.a, Self.b]
    state.activeWorkspacesByDisplay = [Self.a: source.id, Self.b: destination.id]
    state.tilingTrees = [source.id: .leaf(Self.moved), destination.id: .leaf(Self.target)]
    state.desktops.observe(DesktopSpaces(displays: [
      .init(uuid: "a", currentSpace: 1, isUserDesktop: true, userDesktops: [1]),
      .init(uuid: "b", currentSpace: 2, isUserDesktop: true, userDesktops: [2, 3]),
    ]), displays: state.connectedDisplays)
    return (state, source, destination)
  }

}
