// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import Testing
@testable import TatamiKit

@MainActor
struct PlacementDesktopIntegrationTests {
  @Test
  func `unavailable placement preserves tiles while applying a fresh Desktop observation`() async {
    let leftKey = WindowKey(pid: 1, windowID: 101, bundleId: "app.shared")
    let rightKey = WindowKey(pid: 2, windowID: 201, bundleId: "app.shared")
    let left = Workspace(name: "Left")
    let right = Workspace(name: "Right")
    var state = WorkspaceActivationFeature.State()
    state.$config.withLock {
      $0.profiles = [Profile(name: "Default", workspaces: [left, right])]
      $0.sharedApps = [SharedApp(bundleIdentifier: leftKey.bundleId, name: "Shared")]
    }
    state.connectedDisplays = [DesktopSpacesTests.left, DesktopSpacesTests.right]
    state.activeWorkspacesByDisplay = [DesktopSpacesTests.left: left.id, DesktopSpacesTests.right: right.id]
    state.tilingTrees = [left.id: .leaf(leftKey), right.id: .leaf(rightKey)]
    state.desktops.observe(DesktopSpacesTests.spaces(), displays: state.connectedDisplays)
    let store = TestStore(initialState: state) { WorkspaceActivationFeature() }
    store.exhaustivity = .off
    await store.send(.syncAppWindowsResolved(
      bundleId: leftKey.bundleId,
      resizableKeys: [],
      onScreenFrames: [:],
      placementFrames: nil,
      geometryAvailable: false,
      desktopObservation: DesktopObservation(spaces: DesktopSpacesTests.spaces(left: 3), revision: state.desktops.revision),
    ))
    await store.finish()
    #expect(!store.state.desktops.isAvailable(on: DesktopSpacesTests.left))
    #expect(store.state.desktops.isAvailable(on: DesktopSpacesTests.right))
    #expect(store.state.tilingTrees[left.id] == .leaf(leftKey))
    #expect(store.state.tilingTrees[right.id] == .leaf(rightKey))
  }
}
