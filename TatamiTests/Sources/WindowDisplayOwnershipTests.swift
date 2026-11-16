// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import CoreGraphics
import Foundation
import Testing
@testable import TatamiKit

// MARK: - WindowDisplayOwnershipTests

struct WindowDisplayOwnershipTests {
  static let portrait = DisplayName(uuid: "portrait", name: "Portrait")
  static let laptop = DisplayName(uuid: "laptop", name: "Laptop")
  static let landscape = DisplayName(uuid: "landscape", name: "Landscape")
  static let bounds: [DisplayName: CGRect] = [
    portrait: CGRect(x: -1687, y: 0, width: 1440, height: 2560),
    laptop: CGRect(x: 0, y: 1920, width: 1728, height: 1050),
    landscape: CGRect(x: 0, y: 0, width: 3360, height: 1890),
  ]
  static let stranded = CGRect(x: -1679, y: 1368, width: 1424, height: 2514)

  @Test
  func `a portrait window whose center is outside every screen still has a physical owner`() {
    let center = CGPoint(x: Self.stranded.midX, y: Self.stranded.midY)
    #expect(Self.bounds.values.allSatisfy { !$0.contains(center) })
    #expect(WindowDisplayOwnership.owner(of: Self.stranded, displays: Self.bounds) == Self.portrait)
  }

  @Test
  func `offscreen windows return to the nearest connected display`() {
    let frame = CGRect(x: -1600, y: 3000, width: 600, height: 400)
    #expect(Self.bounds.values.allSatisfy { $0.intersection(frame).isNull })
    #expect(WindowDisplayOwnership.owner(of: frame, displays: Self.bounds) == Self.portrait)
  }

  @Test
  func `largest intersection wins and equal intersections retain one existing owner`() {
    let a = DisplayName(uuid: "a", name: "Same Model")
    let b = DisplayName(uuid: "b", name: "Same Model")
    let screens = [a: CGRect(x: 0, y: 0, width: 1000, height: 800), b: CGRect(x: 1000, y: 0, width: 1000, height: 800)]
    #expect(WindowDisplayOwnership.owner(of: CGRect(x: 800, y: 100, width: 800, height: 500), displays: screens) == b)
    let tie = CGRect(x: 800, y: 100, width: 400, height: 500)
    #expect(WindowDisplayOwnership.owner(of: tie, displays: screens, preferred: b) == b)
    #expect(WindowDisplayOwnership.owner(of: tie, displays: screens) == a)
    #expect(WindowDisplayOwnership.owner(of: tie, displays: screens, preferred: DisplayName("Same Model")) == a)
  }

  @Test
  func `ownership includes the full screen instead of excluding Dock and menu bar regions`() {
    let a: DisplayName = "A"
    let b: DisplayName = "B"
    let screens = [a: CGRect(x: 0, y: 0, width: 1000, height: 800), b: CGRect(x: 1000, y: 0, width: 1000, height: 800)]
    let smallWindow = CGRect(x: 10, y: 760, width: 50, height: 30)
    #expect(!CGRect(x: 0, y: 24, width: 1000, height: 700).contains(CGPoint(x: smallWindow.midX, y: smallWindow.midY)))
    #expect(WindowDisplayOwnership.owner(of: smallWindow, displays: screens) == a)
  }

  @Test
  func `top origin conversion retains portrait negative coordinates and vertical stacking`() {
    #expect(ScreenGeometry.topOrigin(CGRect(x: -1687, y: -640, width: 1440, height: 2560), primaryHeight: 1920)
      == CGRect(x: -1687, y: 0, width: 1440, height: 2560))
    #expect(ScreenGeometry.topOrigin(CGRect(x: 0, y: -1050, width: 1728, height: 1050), primaryHeight: 1920)
      == CGRect(x: 0, y: 1920, width: 1728, height: 1050))
  }

  @Test
  func `a placement census retains offscreen frames without claiming they are visible or accepting recycled identities`() {
    let key = WindowKey(pid: 7, windowID: 70, bundleId: "app.shared")
    let recycled = WindowKey(pid: 8, windowID: 70, bundleId: "app.other")
    let window = WindowServerWindow(
      id: 70,
      surface: WindowServerSurface(ownerPID: 7, layer: 0, frame: Self.stranded),
      title: nil,
      isOnScreen: false,
    )
    let snapshot = WindowPlacementSnapshot(windows: [window], keys: [key, recycled])
    #expect(snapshot.frames[key] == Self.stranded)
    #expect(snapshot.frames[recycled] == nil)
    #expect(snapshot.onScreenFrames.isEmpty)
  }

  @Test
  func `each shared window is admitted to exactly one display even when its center misses every work area`() {
    let key = WindowKey(pid: 7, windowID: 70, bundleId: "app.shared")
    let owners = Self.bounds.keys.filter { display in
      !WorkspaceActivationFeature.scopedWindowKeys(
        [key],
        sharedTiledBundleIds: [key.bundleId],
        existingTargetKeys: [],
        protectedKeys: [],
        partitionSharedWindows: true,
        targetDisplay: display,
        displayBounds: Self.bounds,
        windowFrame: { _ in Self.stranded },
      ).isEmpty
    }
    #expect(owners == [Self.portrait])
  }
}

// MARK: - PortraitWorkspaceRoutingTests

@MainActor
struct PortraitWorkspaceRoutingTests {

  // MARK: Internal

  nonisolated static let shared = WindowKey(pid: 7, windowID: 70, bundleId: "app.shared")

  @Test
  func `a known MRU cannot bypass recovery of an empty shared tiled workspace on a portrait monitor`() async throws {
    let laptop = Workspace(name: "Laptop")
    var target = Workspace(name: "Communication", apps: [AppAssignment(bundleIdentifier: Self.shared.bundleId, name: "Shared")])
    target.displayHint = WindowDisplayOwnershipTests.portrait
    var state = Self.state([laptop, target])
    state.activeWorkspacesByDisplay = [
      WindowDisplayOwnershipTests.laptop: laptop.id,
      WindowDisplayOwnershipTests.portrait: target.id,
    ]
    state.mruWindows[target.id] = [Self.shared]
    let activations = LockIsolated<[ActivationRequest]>([])
    let applications = LockIsolated<[FrameApplication]>([])
    let portrait = WindowDisplayOwnershipTests.portrait
    let area = try #require(WindowDisplayOwnershipTests.bounds[portrait])
    let store = TestStore(initialState: state) { WorkspaceActivationFeature() } withDependencies: {
      $0.continuousClock = TestClock()
      $0.displays.all = { Array(WindowDisplayOwnershipTests.bounds.keys) }
      $0.displays.current = { portrait }
      $0.displays.workArea = { name in name.flatMap { WindowDisplayOwnershipTests.bounds[$0] } ?? .zero }
      $0.displays.bounds = { name in name.flatMap { WindowDisplayOwnershipTests.bounds[$0] } ?? .zero }
      $0.windowSnapshot.cachedKeysOnlyAsync = { bundles, _ in .hit(bundles.contains(Self.shared.bundleId) ? [Self.shared] : []) }
      $0.windowSnapshot.discoverKeys = { bundles, _ in bundles.contains(Self.shared.bundleId) ? [Self.shared] : [] }
      $0.windowSnapshot.placementSnapshotAsync = { _ in .value(WindowPlacementSnapshot(
        frames: [Self.shared: WindowDisplayOwnershipTests.stranded],
        onScreenFrames: [:],
      )) }
      $0.workspaceManager.activate = { request in activations.withValue { $0.append(request) } }
      $0.windowTiler.apply = { app in applications.withValue { $0.append(app) } }
      $0.floatingOverlay.retainOnly = { _ in }
      $0.floatingOverlay.setFloating = { _ in }
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
    #expect(activations.value.count == 1)
    #expect(store.state.tilingTrees[target.id]?.windows == [Self.shared])
    let written = applications.value.compactMap { $0.windowFrames[Self.shared] }
    #expect(written.contains(area))
  }

  @Test
  func `shared tiled membership survives an unavailable placement census`() async {
    let target = Workspace(name: "Communication", apps: [AppAssignment(bundleIdentifier: Self.shared.bundleId, name: "Shared")])
    var state = Self.state([target])
    state.activeWorkspacesByDisplay[WindowDisplayOwnershipTests.portrait] = target.id
    state.tilingTrees[target.id] = .leaf(Self.shared)
    let store = TestStore(initialState: state) { WorkspaceActivationFeature() } withDependencies: {
      $0.windowSnapshot.discoverKeys = { _, _ in [Self.shared] }
      $0.windowSnapshot.placementSnapshotAsync = { _ in .value(nil) }
    }
    store.exhaustivity = .off
    await store.send(.syncAppWindows(bundleId: Self.shared.bundleId))
    await store.receive {
      if case .syncAppWindowsResolved = $0 {
        true
      } else {
        false
      }
    }
    await store.finish()
    #expect(store.state.tilingTrees[target.id] == .leaf(Self.shared))
  }

  @Test
  func `sync admits a shared portrait window even when it is not in the onscreen census`() async {
    let target = Workspace(name: "Communication", apps: [AppAssignment(bundleIdentifier: Self.shared.bundleId, name: "Shared")])
    var state = Self.state([target])
    state.activeWorkspacesByDisplay[WindowDisplayOwnershipTests.portrait] = target.id
    let applications = LockIsolated<[FrameApplication]>([])
    let store = TestStore(initialState: state) { WorkspaceActivationFeature() } withDependencies: {
      $0.displays.all = { Array(WindowDisplayOwnershipTests.bounds.keys) }
      $0.displays.bounds = { name in name.flatMap { WindowDisplayOwnershipTests.bounds[$0] } ?? .zero }
      $0.displays.workArea = { name in name.flatMap { WindowDisplayOwnershipTests.bounds[$0] } ?? .zero }
      $0.windowTiler.apply = { app in applications.withValue { $0.append(app) } }
    }
    store.exhaustivity = .off
    await store.send(.syncAppWindowsResolved(
      bundleId: Self.shared.bundleId,
      resizableKeys: [Self.shared],
      onScreenFrames: [:],
      placementFrames: [Self.shared: WindowDisplayOwnershipTests.stranded],
    ))
    await store.receive {
      if case .layoutWriteFinished = $0 {
        true
      } else {
        false
      }
    }
    await store.finish()
    #expect(store.state.tilingTrees[target.id] == .leaf(Self.shared))
    let written = applications.value.compactMap { $0.windowFrames[Self.shared] }
    #expect(written.contains { $0 == WindowDisplayOwnershipTests.bounds[WindowDisplayOwnershipTests.portrait] })
  }

  @Test
  func `dragging a managed shared portrait tile toward another monitor snaps to its owning display`() async {
    let target = Workspace(name: "Communication", apps: [AppAssignment(bundleIdentifier: Self.shared.bundleId, name: "Shared")])
    var state = Self.state([target])
    state.activeWorkspacesByDisplay[WindowDisplayOwnershipTests.portrait] = target.id
    state.tilingTrees[target.id] = .leaf(Self.shared)
    state.drag = .moving(Self.shared)
    let applications = LockIsolated<[FrameApplication]>([])
    let store = TestStore(initialState: state) { WorkspaceActivationFeature() } withDependencies: {
      $0.displays.current = { WindowDisplayOwnershipTests.landscape }
      $0.displays.workArea = { name in name.flatMap { WindowDisplayOwnershipTests.bounds[$0] } ?? .zero }
      $0.dragPreview.hide = { }
      $0.windowTiler.apply = { app in applications.withValue { $0.append(app) } }
    }
    store.exhaustivity = .off
    await store.send(.windowChanged(.windowDragEnded(
      trackedWindowID: Self.shared.windowID,
      key: Self.shared,
      frame: CGRect(x: 2000, y: 100, width: 1440, height: 2560),
      pointerMoved: true,
    )))
    await store.receive {
      if case .layoutWriteFinished = $0 {
        true
      } else {
        false
      }
    }
    await store.finish()
    #expect(store.state.tilingTrees[target.id] == .leaf(Self.shared))
    let written = applications.value.compactMap { $0.windowFrames[Self.shared] }
    #expect(written.contains { $0 == WindowDisplayOwnershipTests.bounds[WindowDisplayOwnershipTests.portrait] })
  }

  @Test
  func `focus only transfer keeps untiled MRU but rejects tiled windows without layout membership`() {
    let floating = WindowKey(pid: 8, windowID: 80, bundleId: "app.floating")
    let target = Workspace(name: "Communication", apps: [
      AppAssignment(bundleIdentifier: Self.shared.bundleId, name: "Shared"),
      AppAssignment(bundleIdentifier: floating.bundleId, name: "Floating", layout: .floating),
    ])
    var state = Self.state([target])
    state.mruWindows[target.id] = [Self.shared]
    #expect(WorkspaceActivationFeature().visibleFocusTarget(target.id, state: state) == nil)
    state.mruWindows[target.id] = [Self.shared, floating]
    #expect(WorkspaceActivationFeature().visibleFocusTarget(target.id, state: state) == floating)
  }

  // MARK: Private

  private static func state(_ workspaces: [Workspace]) -> WorkspaceActivationFeature.State {
    var state = WorkspaceActivationFeature.State()
    state.$config.withLock {
      $0.profiles = [Profile(name: "Test", workspaces: IdentifiedArray(uniqueElements: workspaces))]
      $0.sharedApps = [SharedApp(bundleIdentifier: Self.shared.bundleId, name: "Shared")]
      $0.settings.layout.gapOuter = 0
      $0.settings.layout.gapInner = 0
    }
    state.connectedDisplays = Set(WindowDisplayOwnershipTests.bounds.keys)
    state.focusedDisplay = WindowDisplayOwnershipTests.laptop
    return state
  }

}
