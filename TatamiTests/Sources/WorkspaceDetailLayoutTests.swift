import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Testing
@testable import TatamiKit

/// The inactive-workspace layout-edit path: a preview edit builds/updates the
/// on-disk template, persists it, and opts the workspace into `.persistent`
/// memory so the edit is honored on the next activation.
@MainActor
struct WorkspaceDetailLayoutTests {
  private func makeState(_ ws: Workspace) -> WorkspaceDetailFeature.State {
    let state = WorkspaceDetailFeature.State(workspaceId: ws.id)
    state.$config.withLock {
      $0.profiles = [Profile(name: "Default", workspaces: IdentifiedArray(uniqueElements: [ws]))]
    }
    return state
  }

  @Test
  func editingInactiveLayoutSavesSnapshotAndSwitchesToPersistent() async {
    let ws = Workspace(
      name: "W",
      apps: [
        AppAssignment(bundleIdentifier: "a", name: "A"),
        AppAssignment(bundleIdentifier: "b", name: "B"),
      ]
    )
    let saved = LockIsolated<[UUID: LayoutSnapshot]>([:])
    let store = TestStore(initialState: makeState(ws)) {
      WorkspaceDetailFeature()
    } withDependencies: {
      $0.layoutStore.load = { _ in nil }
      $0.layoutStore.save = { id, snapshot in saved.withValue { $0[id] = snapshot } }
    }
    store.exhaustivity = .off

    await store.send(.layoutEdited(.setRatio(path: [], ratio: 0.7)))
    await store.finish()

    // Persisted a template synthesized from the two tiled apps (layouts always
    // persist now, so no per-workspace memory flag is involved).
    #expect(saved.value[ws.id] != nil)
    #expect(Set(saved.value[ws.id]?.tree.windows ?? []) == ["a", "b"])
    #expect(store.state.layoutSnapshot != nil)
  }

  @Test
  func togglingFullscreenPersistsBundleId() async {
    let ws = Workspace(name: "W", apps: [AppAssignment(bundleIdentifier: "a", name: "A")])
    let saved = LockIsolated<[UUID: LayoutSnapshot]>([:])
    let store = TestStore(initialState: makeState(ws)) {
      WorkspaceDetailFeature()
    } withDependencies: {
      $0.layoutStore.save = { id, snapshot in saved.withValue { $0[id] = snapshot } }
    }
    store.exhaustivity = .off

    await store.send(.layoutFullscreenToggled(bundleId: "a", zoomIn: true))
    await store.finish()
    #expect(saved.value[ws.id]?.fullscreenZoomedBundleIds == ["a"])
  }

  @Test
  func editingUsesLoadedSnapshotAsBase() async {
    let ws = Workspace(
      name: "W",
      apps: [
        AppAssignment(bundleIdentifier: "a", name: "A"),
        AppAssignment(bundleIdentifier: "b", name: "B"),
      ]
    )
    // A pre-existing saved template shaped a→left, b→right.
    let base = LayoutSnapshot(tree: BSPNode.build(["a", "b"], in: CGRect(x: 0, y: 0, width: 1, height: 1))!)
    let saved = LockIsolated<[UUID: LayoutSnapshot]>([:])
    var state = makeState(ws)
    state.layoutSnapshot = base
    let store = TestStore(initialState: state) {
      WorkspaceDetailFeature()
    } withDependencies: {
      $0.layoutStore.save = { id, snapshot in saved.withValue { $0[id] = snapshot } }
    }
    store.exhaustivity = .off

    // Swap the two leaves — the persisted template's window set is unchanged
    // but the shape differs from base.
    await store.send(.layoutEdited(.swap(a: [.left], b: [.right])))
    await store.finish()

    #expect(Set(saved.value[ws.id]?.tree.windows ?? []) == ["a", "b"])
    #expect(saved.value[ws.id]?.tree != base.tree)
  }

  @Test
  func onAppearLoadsSnapshot() async {
    let ws = Workspace(name: "W", apps: [AppAssignment(bundleIdentifier: "a", name: "A")])
    let snapshot = LayoutSnapshot(tree: .leaf(BSPLeaf(windowList: ["a"])))
    let store = TestStore(initialState: makeState(ws)) {
      WorkspaceDetailFeature()
    } withDependencies: {
      $0.layoutStore.load = { _ in snapshot }
    }
    store.exhaustivity = .off

    await store.send(.onAppear)
    await store.receive(\.layoutSnapshotLoaded) {
      $0.layoutSnapshot = snapshot
    }
  }
}
