// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Testing
@testable import TatamiKit

@MainActor
struct OverlayAwareAppsFeatureTests {
  @Test
  func `workspace style picker filters adds and removes apps`() async {
    let notion = MacApp(bundleIdentifier: "notion.id", name: "Notion")
    let dia = MacApp(bundleIdentifier: "company.thebrowser.dia", name: "Dia")
    let tatami = MacApp(bundleIdentifier: "dev.PangMo5.Tatami.debug", name: "Tatami Dev")
    let state = OverlayAwareAppsFeature.State()
    state.$config.withLock {
      $0.settings.visibility = .init(overlayAwareApps: [notion.bundleIdentifier])
    }
    let store = TestStore(initialState: state) {
      OverlayAwareAppsFeature()
    } withDependencies: {
      $0.runningApps.current = { [notion, dia, tatami] }
    }
    store.exhaustivity = .off

    await store.send(.onAppear)
    #expect(store.state.apps == [notion])

    await store.send(.addAppButtonTapped)
    #expect(store.state.isAppPickerPresented)
    #expect(store.state.availableRunningApps == [dia])

    await store.send(.appPickerAppSelected(dia))
    #expect(!store.state.isAppPickerPresented)
    #expect(store.state.apps == [notion, dia])

    await store.send(
      .appRemoveRequested(bundleIdentifier: notion.bundleIdentifier)
    )
    #expect(store.state.apps == [dia])
  }

  @Test
  func `registered app metadata resolves after relaunch while app is not running`() async {
    let notion = MacApp(
      bundleIdentifier: "notion.id",
      name: "Notion",
      iconPath: "/Applications/Notion.app",
    )
    let state = OverlayAwareAppsFeature.State()
    state.$config.withLock {
      $0.settings.visibility = .init(overlayAwareApps: [notion.bundleIdentifier])
    }
    let store = TestStore(initialState: state) {
      OverlayAwareAppsFeature()
    } withDependencies: {
      $0.runningApps.current = { [] }
      $0.runningApps.resolveInstalled = { _ in [notion] }
    }

    await store.send(.onAppear) {
      $0.knownApps[notion.bundleIdentifier] = notion
    }

    #expect(store.state.apps == [notion])
  }
}
