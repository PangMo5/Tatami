// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import IdentifiedCollections
import Testing
@testable import TatamiKit

@Suite("Workspace / profile sync")
struct ProfileSyncTests {
  private func app(_ bundleId: String, layout: LayoutMode = .tiled, autoOpen: Bool = false) -> AppAssignment {
    AppAssignment(bundleIdentifier: bundleId, name: bundleId, autoOpen: autoOpen, layout: layout)
  }

  // MARK: - App diff

  @Test
  func appChangesClassifyAddRemoveModify() {
    let source = [app("keep"), app("changed", layout: .floating), app("added")]
    let target = [app("keep"), app("changed", layout: .tiled), app("gone")]
    let changes = WorkspaceSync.appChanges(from: source, to: target)
    // "keep" unchanged → no entry.
    #expect(!changes.contains { $0.bundleId == "keep" })
    #expect(changes.contains { if case .add(let a) = $0.kind { return a.bundleIdentifier == "added" }; return false })
    #expect(changes.contains { if case .remove(let a) = $0.kind { return a.bundleIdentifier == "gone" }; return false })
    #expect(changes.contains { if case .modify = $0.kind { return $0.bundleId == "changed" }; return false })
  }

  @Test
  func applyAppChangesHonorsExclusions() {
    let source = [app("a"), app("b")]
    let target = [app("c")]
    let changes = WorkspaceSync.appChanges(from: source, to: target)
    // Exclude the "add b" and the "remove c"; keep "add a".
    let result = WorkspaceSync.apply(changes, to: target, excluding: ["b", "c"])
    #expect(result.map(\.bundleIdentifier).sorted() == ["a", "c"])
    // Nothing excluded → target becomes source.
    let full = WorkspaceSync.apply(changes, to: target, excluding: [])
    #expect(full.map(\.bundleIdentifier).sorted() == ["a", "b"])
  }

  // MARK: - Field diff (display pin included)

  @Test
  func fieldChangesIncludeDisplayAndSettings() {
    let source = Workspace(name: "W", displayHint: "External", symbolIconName: "star", keyEquivalent: "x")
    let target = Workspace(name: "W", displayHint: "Built-in", symbolIconName: "bolt", keyEquivalent: "x")
    let changes = WorkspaceSync.fieldChanges(from: source, to: target)
    let ids = Set(changes.map(\.id))
    #expect(ids.contains("icon"))
    #expect(ids.contains("displayHint"))
    #expect(!ids.contains("keyEquivalent")) // same key → no change
  }

  @Test
  func applyFieldChangesHonorsExclusions() {
    let source = Workspace(name: "W", displayHint: "External", symbolIconName: "star")
    var target = Workspace(name: "W", displayHint: "Built-in", symbolIconName: "bolt")
    let changes = WorkspaceSync.fieldChanges(from: source, to: target)
    // Keep the icon change, exclude the display change.
    WorkspaceSync.apply(changes, to: &target, excluding: ["displayHint"])
    #expect(target.symbolIconName == "star")
    #expect(target.displayHint == "Built-in") // display left alone
  }

  // MARK: - Profile sync

  private func twoProfiles() -> AppConfig {
    let base = Profile(name: "Default", workspaces: [
      Workspace(name: "Browser", displayHint: "Built-in", apps: [app("zen"), app("comet")]),
    ])
    let dual = Profile(name: "Dual", workspaces: [
      Workspace(name: "Browser", displayHint: "External", apps: [app("zen")]),
    ])
    return AppConfig(profiles: [base, dual])
  }

  @Test
  func differingCountsAppsAndFields() {
    let config = twoProfiles()
    let diverged = config.workspacesDiffering(in: config.profiles[1].id, comparedTo: config.profiles[0].id)
    #expect(diverged == ["Browser"]) // apps differ (comet) and display differs
  }

  @Test
  func profileSyncAppliesAppsAndFieldsExceptExcluded() {
    var config = twoProfiles()
    let base = config.profiles[0].id
    let dual = config.profiles[1]
    let ws = dual.workspaces.first!.id
    // Sync everything EXCEPT the display change → apps match, display preserved.
    config.applyProfileSync(
      into: dual.id, from: base,
      excludedFieldsByWorkspace: [ws: ["displayHint"]]
    )
    let browser = config.profiles[1].workspaces[id: ws]!
    #expect(browser.apps.map(\.bundleIdentifier) == ["zen", "comet"])
    #expect(browser.displayHint == "External") // excluded, so kept
  }

  // MARK: - Workspace import

  @Test
  func importWorkspacePullsAppsAndFields() {
    let source = Profile(name: "Src", workspaces: [
      Workspace(name: "Src WS", displayHint: "External", symbolIconName: "star", apps: [app("x"), app("y")]),
    ])
    let target = Profile(name: "Tgt", workspaces: [
      Workspace(name: "Tgt WS", displayHint: "Built-in", symbolIconName: "bolt", apps: [app("x")]),
    ])
    var config = AppConfig(profiles: [target, source], activeProfileId: target.id)
    let targetWsId = target.workspaces.first!.id
    let sourceWsId = source.workspaces.first!.id
    config.importWorkspace(
      into: targetWsId, from: source.id, sourceWorkspace: sourceWsId,
      excludingFields: ["displayHint"] // keep target's display
    )
    let ws = config.profiles[0].workspaces[id: targetWsId]!
    #expect(ws.apps.map(\.bundleIdentifier) == ["x", "y"])
    #expect(ws.symbolIconName == "star") // pulled
    #expect(ws.displayHint == "Built-in") // excluded, kept
  }
}
