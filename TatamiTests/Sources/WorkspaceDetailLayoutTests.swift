import ComposableArchitecture
import CoreGraphics
import Foundation
import IdentifiedCollections
import Testing
@testable import TatamiKit

/// `WorkspaceLayoutFeature`: intents map trimmed→full and route to an inactive
/// snapshot edit (persisted) or, for the active workspace, a `delegate` the
/// parent forwards to activation.
@MainActor
struct WorkspaceLayoutFeatureTests {
  private let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

  private func makeState(_ ws: Workspace) -> WorkspaceLayoutFeature.State {
    let state = WorkspaceLayoutFeature.State(workspaceId: ws.id)
    state.$config.withLock {
      $0.profiles = [Profile(name: "Default", workspaces: IdentifiedArray(uniqueElements: [ws]))]
    }
    return state
  }

  @Test
  func inactiveDividerResizeSavesSynthesizedSnapshot() async {
    let ws = Workspace(
      name: "W",
      apps: [
        AppAssignment(bundleIdentifier: "a", name: "A"),
        AppAssignment(bundleIdentifier: "b", name: "B"),
      ]
    )
    let saved = LockIsolated<[UUID: LayoutSnapshot]>([:])
    let store = TestStore(initialState: makeState(ws)) {
      WorkspaceLayoutFeature()
    } withDependencies: {
      $0.layoutStore.save = { id, snapshot in saved.withValue { $0[id] = snapshot } }
    }
    store.exhaustivity = .off

    // Root branch: trimmed [] ⇒ full []. Inactive ⇒ persists a template
    // synthesized from the two tiled apps.
    await store.send(.dividerResized(trimmedBranchPath: [], ratio: 0.7))
    await store.finish()

    #expect(saved.value[ws.id] != nil)
    #expect(Set(saved.value[ws.id]?.tree.windows ?? []) == ["a", "b"])
    #expect(store.state.layoutSnapshot != nil)
  }

  @Test
  func inactiveMoveEditsTheLoadedSnapshot() async {
    let ws = Workspace(
      name: "W",
      apps: [
        AppAssignment(bundleIdentifier: "a", name: "A"),
        AppAssignment(bundleIdentifier: "b", name: "B"),
      ]
    )
    let base = LayoutSnapshot(tree: BSPNode.build(["a", "b"], in: unit)!)
    let saved = LockIsolated<[UUID: LayoutSnapshot]>([:])
    var state = makeState(ws)
    state.layoutSnapshot = base
    let store = TestStore(initialState: state) {
      WorkspaceLayoutFeature()
    } withDependencies: {
      $0.layoutStore.save = { id, snapshot in saved.withValue { $0[id] = snapshot } }
    }
    store.exhaustivity = .off

    await store.send(.tileMoved(sourceTrimmedPath: [.left], targetTrimmedPath: [.right], zone: .swap))
    await store.finish()

    #expect(Set(saved.value[ws.id]?.tree.windows ?? []) == ["a", "b"])
    #expect(saved.value[ws.id]?.tree != base.tree)
  }

  @Test
  func inactiveFullscreenTogglePersistsBundleId() async {
    let ws = Workspace(name: "W", apps: [AppAssignment(bundleIdentifier: "a", name: "A")])
    let saved = LockIsolated<[UUID: LayoutSnapshot]>([:])
    let store = TestStore(initialState: makeState(ws)) {
      WorkspaceLayoutFeature()
    } withDependencies: {
      $0.layoutStore.save = { id, snapshot in saved.withValue { $0[id] = snapshot } }
    }
    store.exhaustivity = .off

    await store.send(.toggleFullscreen(bundleId: "a", liveKey: nil, zoomIn: true))
    await store.finish()
    #expect(saved.value[ws.id]?.fullscreenZoomedBundleIds == ["a"])
  }

  @Test
  func activeEditDelegatesAndDoesNotSave() async {
    let ws = Workspace(
      name: "W",
      apps: [
        AppAssignment(bundleIdentifier: "a", name: "A"),
        AppAssignment(bundleIdentifier: "b", name: "B"),
      ]
    )
    let liveTree = BSPNode.build(
      [WindowKey(pid: 1, windowID: 10, bundleId: "a"),
       WindowKey(pid: 1, windowID: 11, bundleId: "b")],
      in: unit
    )!
    let saved = LockIsolated<[UUID: LayoutSnapshot]>([:])
    var state = makeState(ws)
    state.isActive = true
    state.liveTree = liveTree
    let store = TestStore(initialState: state) {
      WorkspaceLayoutFeature()
    } withDependencies: {
      $0.layoutStore.save = { id, snapshot in saved.withValue { $0[id] = snapshot } }
    }
    store.exhaustivity = .off

    // Active workspace: the edit is delegated to activation, never persisted here.
    await store.send(.dividerResized(trimmedBranchPath: [], ratio: 0.7))
    await store.receive(\.delegate)
    await store.finish()
    #expect(saved.value.isEmpty)
  }

  @Test
  func onAppearLoadsSnapshot() async {
    let ws = Workspace(name: "W", apps: [AppAssignment(bundleIdentifier: "a", name: "A")])
    let snapshot = LayoutSnapshot(tree: .leaf(BSPLeaf(windowList: ["a"])))
    let store = TestStore(initialState: makeState(ws)) {
      WorkspaceLayoutFeature()
    } withDependencies: {
      $0.layoutStore.load = { _ in snapshot }
    }
    store.exhaustivity = .off

    await store.send(.onAppear)
    await store.receive(\.layoutSnapshotLoaded) {
      $0.layoutSnapshot = snapshot
      $0.snapshotLoadedFor = ws.id
    }
  }
}
