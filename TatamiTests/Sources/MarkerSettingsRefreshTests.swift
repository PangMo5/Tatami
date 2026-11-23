// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import Testing
@testable import TatamiKit

@MainActor
struct MarkerSettingsRefreshTests {
  @Test
  func `shared marker settings immediately replace an existing floating marker target`() async throws {
    let key = WindowKey(pid: 1, windowID: 10, bundleId: "app.shared")
    let workspace = Workspace(name: "Work")
    var state = AppFeature.State()
    state.$config.withLock {
      $0.profiles = [Profile(name: "Default", workspaces: [workspace])]
      $0.sharedApps = [SharedApp(bundleIdentifier: key.bundleId, name: "Shared", layout: .floating)]
    }
    state.activation.activeWorkspacesByDisplay = [DesktopSpacesTests.left: workspace.id]
    let targets = LockIsolated<[[WindowKey: MarkerTarget]]>([])
    let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
      $0.focusFollowsMouse.configure = { _ in }
      $0.gestures.start = { _ in }
      $0.gestures.stop = { }
      $0.windowSnapshot.cachedKeys = { _, _ in [key] }
      $0.marker.setTargets = { value, _, _, _ in targets.withValue { $0.append(value) } }
    }
    store.exhaustivity = .off
    await store.send(.settingsChanged(store.state.config.settings))
    await store.finish()
    #expect(targets.value.last?[key]?.badges.first(where: { $0.kind == .shared })?.colorHex == MarkerPalette.shared)
    store.state.$config.withLock { $0.settings.marker.sharedEnabled = false }
    await store.send(.settingsChanged(store.state.config.settings))
    await store.finish()
    let disabled = try #require(targets.value.last?[key])
    #expect(disabled.badges == [WindowMarker(kind: .floating, colorHex: MarkerPalette.floating)])
    store.state.$config.withLock {
      $0.settings.marker.sharedEnabled = true
      $0.settings.marker.sharedColorHex = "#ABCDEF"
    }
    await store.send(.settingsChanged(store.state.config.settings))
    await store.finish()
    #expect(targets.value.last?[key]?.badges.first(where: { $0.kind == .shared })?.colorHex == "#ABCDEF")
  }

  @Test
  func `discovering a shared unmanaged window updates markers without changing the tree`() async throws {
    let key = WindowKey(pid: 1, windowID: 10, bundleId: "app.shared")
    let workspace = Workspace(name: "Work")
    var state = WorkspaceActivationFeature.State()
    state.$config.withLock {
      $0.profiles = [Profile(name: "Default", workspaces: [workspace])]
      $0.sharedApps = [SharedApp(bundleIdentifier: key.bundleId, name: "Shared", layout: .unmanaged)]
    }
    state.activeWorkspacesByDisplay = [DesktopSpacesTests.left: workspace.id]
    let targets = LockIsolated<[[WindowKey: MarkerTarget]]>([])
    let store = TestStore(initialState: state) { WorkspaceActivationFeature() } withDependencies: {
      $0.windowSnapshot.cachedKeys = { _, _ in [key] }
      $0.marker.setTargets = { value, _, _, _ in targets.withValue { $0.append(value) } }
    }
    store.exhaustivity = .off
    await store.send(.syncAppWindowsResolved(bundleId: key.bundleId, resizableKeys: nil, onScreenFrames: [:]))
    await store.finish()
    let target = try #require(targets.value.last?[key])
    #expect(target.badges == [WindowMarker(kind: .shared, colorHex: MarkerPalette.shared, symbol: "person.2.fill")])
    #expect(store.state.tilingTrees[workspace.id] == nil)
  }

  @Test
  func `a shared floating badge does not depend on the floating status dot setting`() async throws {
    let key = WindowKey(pid: 1, windowID: 10, bundleId: "app.shared")
    let state = WorkspaceActivationFeature.State()
    state.$config.withLock {
      $0.settings.marker.floatingEnabled = false
      $0.sharedApps = [SharedApp(bundleIdentifier: key.bundleId, name: "Shared", layout: .floating)]
    }
    let targets = LockIsolated<[[WindowKey: MarkerTarget]]>([])
    let store = TestStore(initialState: state) { WorkspaceActivationFeature() } withDependencies: {
      $0.windowSnapshot.cachedKeys = { _, _ in [key] }
      $0.marker.setTargets = { value, _, _, _ in targets.withValue { $0.append(value) } }
    }
    store.exhaustivity = .off
    await store.send(.refreshWindowMarkers)
    await store.finish()
    let target = try #require(targets.value.last?[key])
    #expect(target.badges == [WindowMarker(kind: .shared, colorHex: MarkerPalette.shared, symbol: "person.2.fill")])
  }
}
