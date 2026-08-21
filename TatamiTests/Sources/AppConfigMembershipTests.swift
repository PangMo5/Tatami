// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import IdentifiedCollections
import Testing
@testable import TatamiKit

/// Pure value-type tests for the membership rules — no TestStore needed
/// now that the mutations live on `AppConfig` instead of inside the
/// activation reducer.
struct AppConfigMembershipTests {
  private func makeConfig(workspaces: [Workspace]) -> AppConfig {
    AppConfig(profiles: [
      Profile(name: "Default", workspaces: IdentifiedArray(uniqueElements: workspaces))
    ])
  }

  private func apps(_ config: AppConfig, _ id: Workspace.ID) -> [String] {
    config.activeProfile?.workspaces[id: id]?.apps.map(\.bundleIdentifier) ?? []
  }

  @Test
  func toggleMembershipEnforcesSingleMembership() {
    let ws1 = Workspace(name: "one", apps: [AppAssignment(bundleIdentifier: "a", name: "A")])
    let ws2 = Workspace(name: "two")
    var config = makeConfig(workspaces: [ws1, ws2])

    let didAdd = config.toggleMembership(bundleId: "a", name: "A", in: ws2.id)
    #expect(didAdd)
    #expect(apps(config, ws1.id).isEmpty)
    #expect(apps(config, ws2.id) == ["a"])

    let didAddAgain = config.toggleMembership(bundleId: "a", name: "A", in: ws2.id)
    #expect(!didAddAgain)
    #expect(apps(config, ws2.id).isEmpty)
  }

  @Test
  func toggleFloatingAddsUnassignedAppAsFloatingMember() {
    let ws = Workspace(name: "one")
    var config = makeConfig(workspaces: [ws])

    let nowFloating = config.toggleFloating(bundleId: "a", name: "A", in: ws.id)
    #expect(nowFloating)
    #expect(config.activeProfile?.workspaces[id: ws.id]?.apps.first?.layout == .floating)

    // Un-floating keeps the membership.
    let unfloated = config.toggleFloating(bundleId: "a", name: "A", in: ws.id)
    #expect(!unfloated)
    #expect(apps(config, ws.id) == ["a"])
    #expect(config.activeProfile?.workspaces[id: ws.id]?.apps.first?.layout == .tiled)
  }

  @Test
  func toggleSharedFloatingJoinsSharedAppsButNeverRemoves() {
    var config = makeConfig(workspaces: [])

    let nowShared = config.toggleSharedFloating(bundleId: "a", name: "A")
    #expect(nowShared)
    #expect(config.sharedApps.map(\.bundleIdentifier) == ["a"])

    // Flipping the float attribute keeps the app shared.
    let flipped = config.toggleSharedFloating(bundleId: "a", name: "A")
    #expect(!flipped)
    #expect(config.sharedApps.map(\.bundleIdentifier) == ["a"])
    #expect(config.sharedApps.first?.layout == .tiled)
  }

  @Test
  func toggleSharedMembershipAddsTiledAndRemovesEntirely() {
    var config = makeConfig(workspaces: [])

    let added = config.toggleSharedMembership(bundleId: "a", name: "A")
    #expect(added)
    #expect(config.sharedApps.first?.layout == .tiled)

    let removed = config.toggleSharedMembership(bundleId: "a", name: "A")
    #expect(!removed)
    #expect(config.sharedApps.isEmpty)
  }

  @Test
  func moveAppCarriesExistingAssignmentMetadata() {
    let assignment = AppAssignment(
      bundleIdentifier: "a", name: "Custom Name", autoOpen: true, layout: .floating
    )
    let ws1 = Workspace(name: "one", apps: [assignment])
    let ws2 = Workspace(name: "two")
    var config = makeConfig(workspaces: [ws1, ws2])

    config.moveApp(bundleId: "a", name: "Live Name", to: ws2.id)
    #expect(apps(config, ws1.id).isEmpty)
    let moved = config.activeProfile?.workspaces[id: ws2.id]?.apps.first
    #expect(moved?.name == "Custom Name")
    #expect(moved?.autoOpen == true)
    #expect(moved?.layout == .floating)
  }

  @Test
  func assignAppKeepsExistingMembershipsAndDeduplicates() {
    let ws1 = Workspace(name: "one", apps: [AppAssignment(bundleIdentifier: "a", name: "A")])
    let ws2 = Workspace(name: "two")
    var config = makeConfig(workspaces: [ws1, ws2])

    config.assignApp(bundleId: "a", name: "A", to: ws2.id)
    #expect(apps(config, ws1.id) == ["a"])
    #expect(apps(config, ws2.id) == ["a"])

    // Idempotent: assigning again doesn't duplicate.
    config.assignApp(bundleId: "a", name: "A", to: ws2.id)
    #expect(apps(config, ws2.id) == ["a"])
  }
}
