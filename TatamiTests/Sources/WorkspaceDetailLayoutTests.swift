// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

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

  // MARK: Internal

  @Test(arguments: [false, true])
  func `cold unclassified window bounds saved preview without adding dialog tiles`(classified: Bool) async throws {
    let ws = Workspace(name: "Browser", apps: [AppAssignment(bundleIdentifier: "a", name: "Browser")])
    let key = WindowKey(pid: 1, windowID: 10, bundleId: "a")
    let dialog = WindowKey(pid: 1, windowID: 11, bundleId: "a")
    var state = makeState(ws)
    let snapshot = LayoutSnapshot(
      tree: .branch(BSPBranch(split: .vertical, ratio: 0.3, left: .leaf(slot("a", 0)), right: .leaf(slot("a", 1)))),
      fullscreenZoomedSlots: [slot("a", 0)],
    )
    state.layoutSnapshot = snapshot
    let store = TestStore(initialState: state) { WorkspaceLayoutFeature() } withDependencies: {
      $0.windowSnapshot.discoverCapabilitiesAsync = { _ in
        .value(WindowCapabilitySnapshot(
          movableKeys: classified ? [key] : [],
          resizableKeys: classified ? [key] : [],
          unclassifiedKeys: classified ? [dialog] : [key],
        ))
      }
    }
    store.exhaustivity = .off
    await store.send(.loadWindowTitles(bundleIds: ["a"]))
    await store.receive(\.windowInfoLoaded)
    await store.finish()
    #expect(store.state.windowKeys == [key])
    let projected = try #require(store.state.resolved)
    #expect(projected.fullscreenItems().map(\.slot) == [slot("a", 0)])
    #expect(projected.renderRegions(in: unit, hidden: []).tiles.isEmpty)
    #expect(store.state.layoutSnapshot == snapshot)
  }

  @Test(arguments: [false, true])
  func `inactive preview projects current windows without erasing saved restoration slots`(hasTitles: Bool) async throws {
    let ws = Workspace(name: "Browser", apps: [AppAssignment(bundleIdentifier: "a", name: "Browser")])
    let first = WindowKey(pid: 1, windowID: 10, bundleId: "a")
    let second = WindowKey(pid: 1, windowID: 11, bundleId: "a")
    let tree = BSPNode.branch(BSPBranch(
      split: .vertical,
      ratio: 0.4,
      left: .leaf(slot("a", 0)),
      right: .branch(BSPBranch(
        split: .horizontal,
        ratio: 0.3,
        left: .leaf(slot("a", 1)),
        right: .leaf(slot("removed-app")),
      )),
    ))
    let snapshot = LayoutSnapshot(tree: tree, fullscreenZoomedSlots: [slot("a", 0)])
    var state = makeState(ws)
    state.layoutSnapshot = snapshot
    state.windowInfoRequestGeneration = 1
    let store = TestStore(initialState: state) { WorkspaceLayoutFeature() } withDependencies: {
      $0.windowSnapshot.discoverKeys = { _, _ in [first, second] }
      $0.windowSnapshot.windowTitles = { _ in hasTitles ? [first: "First", second: "Second"] : [:] }
    }
    store.exhaustivity = .off
    await store.send(.windowInfoLoaded(
      workspaceId: ws.id,
      generation: 1,
      titles: hasTitles ? [first: "First"] : [:],
      present: ["a"],
      keys: [first],
    ))
    let projected = try #require(store.state.resolved)
    #expect(projected.fullscreenItems().map(\.slot) == [slot("a", 0)])
    #expect(projected.renderRegions(in: unit, hidden: []).tiles.isEmpty)
    #expect(store.state.layoutSnapshot == snapshot)

    // Reopening the second window restores its preview slot. Missing titles
    // are not missing windows, and previewing never rewrites the saved layout.
    await store.send(.loadWindowTitles(bundleIds: ["a"]))
    await store.receive(\.windowInfoLoaded)
    await store.finish()
    let restored = try #require(store.state.resolved)
    #expect(restored.renderRegions(in: unit, hidden: []).tiles.map(\.slot) == [slot("a", 1)])
    #expect(store.state.layoutSnapshot == snapshot)
  }

  @Test
  func `inactive preview retains the surviving second windows identity and zoom`() throws {
    let ws = Workspace(name: "Browser", apps: [AppAssignment(bundleIdentifier: "a", name: "Browser")])
    let first = WindowKey(pid: 1, windowID: 10, bundleId: "a")
    let second = WindowKey(pid: 1, windowID: 11, bundleId: "a")
    var state = makeState(ws)
    state.layoutSnapshot = LayoutSnapshot(
      tree: .branch(BSPBranch(split: .vertical, ratio: 0.3, left: .leaf(slot("a", 0)), right: .leaf(slot("a", 1)))),
      fullscreenZoomedSlots: [slot("a", 0)],
    )
    state.liveTree = .branch(BSPBranch(split: .vertical, ratio: 0.3, left: .leaf(first), right: .leaf(second)))
    state.windowKeys = [second]
    state.windowTitles = [second: "Survivor"]
    let resolved = try #require(state.resolved)
    #expect(state.previewWindowBindings == [slot("a", 1): second])
    #expect(resolved.fullscreenItems().isEmpty)
    #expect(resolved.renderRegions(in: unit, hidden: []).tiles.map(\.slot) == [slot("a", 1)])
  }

  @Test(arguments: AutoBalanceMode.allCases)
  func `inactive preview preserves restored proportions like activation`(balance: AutoBalanceMode) throws {
    let ws = Workspace(name: "Work", apps: [
      AppAssignment(bundleIdentifier: "a", name: "A"),
      AppAssignment(bundleIdentifier: "b", name: "B"),
    ])
    var state = makeState(ws)
    let tree = BSPNode.branch(BSPBranch(split: .vertical, ratio: 0.7, left: .leaf(slot("a")), right: .leaf(slot("b"))))
    state.layoutSnapshot = LayoutSnapshot(tree: tree)
    state.$config.withLock { $0.settings.layout.autoBalance = balance }
    guard case .template(let actual, _) = try #require(state.resolved) else {
      Issue.record("Expected an inactive template")
      return
    }
    #expect(actual == tree)
  }

  @Test
  func `inactive edits use the same projected tree as the preview`() async {
    let ws = Workspace(name: "Work", apps: [
      AppAssignment(bundleIdentifier: "a", name: "A"),
      AppAssignment(bundleIdentifier: "b", name: "B"),
    ])
    var state = makeState(ws)
    state.layoutSnapshot = LayoutSnapshot(tree: .branch(BSPBranch(
      split: .vertical,
      ratio: 0.4,
      left: .leaf(slot("a", 0)),
      right: .branch(BSPBranch(split: .horizontal, ratio: 0.3, left: .leaf(slot("a", 1)), right: .leaf(slot("b")))),
    )))
    state.windowKeys = [WindowKey(pid: 1, windowID: 10, bundleId: "a"), WindowKey(pid: 2, windowID: 20, bundleId: "b")]
    let saved = LockIsolated<[LayoutSnapshot]>([])
    let store = TestStore(initialState: state) { WorkspaceLayoutFeature() } withDependencies: {
      $0.layoutStore.save = { _, snapshot in saved.withValue { $0.append(snapshot) } }
    }
    store.exhaustivity = .off
    await store.send(.dividerResized(trimmedBranchPath: [], ratio: 0.7))
    await store.finish()
    let expected = BSPNode.branch(BSPBranch(split: .vertical, ratio: 0.7, left: .leaf(slot("a")), right: .leaf(slot("b"))))
    #expect(saved.value.last?.tree == expected)
  }

  @Test
  func `inactive divider resize saves synthesized snapshot`() async {
    let ws = Workspace(
      name: "W",
      apps: [
        AppAssignment(bundleIdentifier: "a", name: "A"),
        AppAssignment(bundleIdentifier: "b", name: "B"),
      ],
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
    #expect(Set((saved.value[ws.id]?.tree.windows ?? []).map(\.bundleId)) == ["a", "b"])
    #expect(store.state.layoutSnapshot != nil)
  }

  @Test
  func `inactive move edits the loaded snapshot`() async throws {
    let ws = Workspace(
      name: "W",
      apps: [
        AppAssignment(bundleIdentifier: "a", name: "A"),
        AppAssignment(bundleIdentifier: "b", name: "B"),
      ],
    )
    let base = LayoutSnapshot(tree: try #require(BSPNode.build([slot("a"), slot("b")], in: unit)))
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

    #expect(Set((saved.value[ws.id]?.tree.windows ?? []).map(\.bundleId)) == ["a", "b"])
    #expect(saved.value[ws.id]?.tree != base.tree)
  }

  @Test
  func `inactive fullscreen toggle persists slot`() async {
    let ws = Workspace(name: "W", apps: [AppAssignment(bundleIdentifier: "a", name: "A")])
    let saved = LockIsolated<[UUID: LayoutSnapshot]>([:])
    let store = TestStore(initialState: makeState(ws)) {
      WorkspaceLayoutFeature()
    } withDependencies: {
      $0.layoutStore.save = { id, snapshot in saved.withValue { $0[id] = snapshot } }
    }
    store.exhaustivity = .off

    await store.send(.toggleFullscreen(bundleId: "a", liveKey: nil, occurrence: 0, zoomIn: true))
    await store.finish()
    #expect(saved.value[ws.id]?.fullscreenZoomedSlots == [slot("a", 0)])
  }

  @Test
  func `active edit delegates and does not save`() async throws {
    let ws = Workspace(
      name: "W",
      apps: [
        AppAssignment(bundleIdentifier: "a", name: "A"),
        AppAssignment(bundleIdentifier: "b", name: "B"),
      ],
    )
    let liveTree = try #require(BSPNode.build(
      [
        WindowKey(pid: 1, windowID: 10, bundleId: "a"),
        WindowKey(pid: 1, windowID: 11, bundleId: "b"),
      ],
      in: unit,
    ))
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
  func `template path mapping keeps same app leaves distinct`() throws {
    // Two "a" slots + one "b". Each rendered tile must map to a *distinct*
    // full-tree path — SlotID identity keeps same-app leaves apart, so a
    // same-app relocate targets the right (not its own) leaf.
    let tree = try #require(BSPNode.build([slot("a", 0), slot("a", 1), slot("b")], in: unit))
    let resolved = ResolvedLayout.template(tree, zoomedSlots: [])
    let (tiles, _) = resolved.renderRegions(in: unit, hidden: [])
    let fullPaths = tiles.map { resolved.fullLeafPath(trimmedLeafPath: $0.path, hidden: []) }
    #expect(fullPaths.allSatisfy { $0 != nil })
    #expect(Set(fullPaths.compactMap { $0 }).count == tiles.count)
  }

  @Test
  func `migrates legacy bundle id snapshot to occurrence slots`() throws {
    // v1 on disk: two "a" leaves + one "b", with one "a" fullscreen-zoomed.
    let legacy = try #require(BSPNode.build(["a", "a", "b"], in: unit))
    let migrated = LayoutSnapshot.migratedFromV1(tree: legacy, zoomedBundleIds: ["a"])
    let windows = migrated.tree.windows
    #expect(Set(windows.map(\.bundleId)) == ["a", "b"])
    // The two "a" leaves get distinct occurrences (0, 1) so they stay arrangeable.
    #expect(windows.filter { $0.bundleId == "a" }.map(\.occurrence).sorted() == [0, 1])
    #expect(migrated.fullscreenZoomedSlots == [slot("a", 0)])
    #expect(migrated.version == 2)
  }

  @Test
  func `reveal app bubbles delegate`() async {
    let ws = Workspace(name: "W", apps: [AppAssignment(bundleIdentifier: "a", name: "A")])
    let store = TestStore(initialState: makeState(ws)) {
      WorkspaceLayoutFeature()
    }
    store.exhaustivity = .off

    await store.send(.revealApp(bundleId: "a", isShared: true))
    await store.receive(\.delegate)
  }

  @Test
  func `on appear loads snapshot`() async {
    let ws = Workspace(name: "W", apps: [AppAssignment(bundleIdentifier: "a", name: "A")])
    let snapshot = LayoutSnapshot(tree: .leaf(BSPLeaf(windowList: [slot("a")])))
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

  @Test
  func `stale window info result cannot overwrite the latest request`() async {
    let ws = Workspace(name: "W", apps: [AppAssignment(bundleIdentifier: "a", name: "A")])
    var state = makeState(ws)
    state.windowInfoRequestGeneration = 2
    let current = WindowKey(pid: 2, windowID: 202, bundleId: "a")
    state.windowTitles = [current: "Current"]
    state.presentBundleIds = ["a"]
    let stale = WindowKey(pid: 1, windowID: 101, bundleId: "a")
    let store = TestStore(initialState: state) {
      WorkspaceLayoutFeature()
    }

    await store.send(.windowInfoLoaded(
      workspaceId: ws.id,
      generation: 1,
      titles: [stale: "Stale"],
      present: ["stale"],
    ))

    #expect(store.state.windowTitles == [current: "Current"])
    #expect(store.state.presentBundleIds == ["a"])
  }

  // MARK: Private

  private let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

  private func slot(_ bundle: String, _ occurrence: Int = 0) -> SlotID {
    SlotID(bundleId: bundle, occurrence: occurrence)
  }

  private func makeState(_ ws: Workspace) -> WorkspaceLayoutFeature.State {
    let state = WorkspaceLayoutFeature.State(workspaceId: ws.id)
    state.$config.withLock {
      $0.profiles = [Profile(name: "Default", workspaces: IdentifiedArray(uniqueElements: [ws]))]
    }
    return state
  }

}
