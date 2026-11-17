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
      $0.windowSnapshot.onScreenWindowIDs = { [key.windowID] }
      $0.marker.setTargets = { value, _, _, _ in targets.withValue { $0.append(value) } }
    }
    store.exhaustivity = .off
    await store.send(.settingsChanged(store.state.config.settings))
    await store.finish()
    #expect(targets.value.last?[key]?.sharedColorHex == MarkerPalette.shared)
    store.state.$config.withLock { $0.settings.marker.sharedEnabled = false }
    await store.send(.settingsChanged(store.state.config.settings))
    await store.finish()
    let disabled = try #require(targets.value.last?[key])
    #expect(disabled.sharedColorHex == nil)
    #expect(disabled.colorHex == MarkerPalette.floating)
    store.state.$config.withLock {
      $0.settings.marker.sharedEnabled = true
      $0.settings.marker.sharedColorHex = "#ABCDEF"
    }
    await store.send(.settingsChanged(store.state.config.settings))
    await store.finish()
    #expect(targets.value.last?[key]?.sharedColorHex == "#ABCDEF")
  }
}
