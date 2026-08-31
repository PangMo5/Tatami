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

  @Test
  func effectiveSelectionDropsStaleAndDisabledChildIDs() {
    let selected: Set<String> = ["parent", "child", "stale"]
    let valid: Set<String> = ["parent", "child"]
    #expect(WorkspaceSync.effectiveSelection(
      selected: selected,
      validIDs: valid,
      parentByItemID: ["child": "parent"]
    ) == ["parent", "child"])
    #expect(WorkspaceSync.effectiveSelection(
      selected: ["child", "stale"],
      validIDs: valid,
      parentByItemID: ["child": "parent"]
    ).isEmpty)
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

  // MARK: - Shortcut-safe projections

  @Test
  func workspaceImportUsesProjectedExplicitOverridePrecedence() throws {
    let explicit = try #require(HotKey(parsing: "cmd - x"))
    let derived = try #require(HotKey(parsing: "ctrl + alt - a"))
    let sourceWorkspace = Workspace(
      name: "Source",
      activateShortcut: explicit,
      keyEquivalent: "a"
    )
    let targetWorkspace = Workspace(name: "Target", keyEquivalent: "b")
    let source = Profile(name: "Source", workspaces: [sourceWorkspace])
    let target = Profile(name: "Target", workspaces: [targetWorkspace])
    var settings = AppSettings()
    settings.shortcuts.assignModifiers = []
    settings.shortcuts.borrowModifiers = []
    settings.shortcuts.focusLeft = derived
    let config = AppConfig(profiles: [target, source], settings: settings)

    let allSelected = try #require(config.workspaceImportProjection(
      into: targetWorkspace.id,
      from: source.id,
      sourceWorkspace: sourceWorkspace.id
    ))
    #expect(allSelected.conflicts.isEmpty)
    #expect(allSelected.config.workspace(id: targetWorkspace.id)?.keyEquivalent == "a")
    #expect(allSelected.config.workspace(id: targetWorkspace.id)?.activateShortcut == explicit)

    let withoutOverride = try #require(config.workspaceImportProjection(
      into: targetWorkspace.id,
      from: source.id,
      sourceWorkspace: sourceWorkspace.id,
      excludingFields: [WorkspaceShortcutField.activateShortcut.rawValue]
    ))
    #expect(withoutOverride.conflicts.map(\.selection.field) == [.keyEquivalent])
    #expect(withoutOverride.conflicts.map(\.hotKey) == [derived])
  }

  @Test
  func profileSyncDetectsConflictsBetweenSelectedWorkspaceKeys() throws {
    let firstOverride = try #require(HotKey(parsing: "cmd - x"))
    let secondOverride = try #require(HotKey(parsing: "cmd - y"))
    let sourceFirst = Workspace(
      name: "First",
      activateShortcut: firstOverride,
      keyEquivalent: "a"
    )
    let sourceSecond = Workspace(
      name: "Second",
      activateShortcut: secondOverride,
      keyEquivalent: "a"
    )
    let targetFirst = Workspace(name: "First", keyEquivalent: "b")
    let targetSecond = Workspace(name: "Second", keyEquivalent: "c")
    let source = Profile(name: "Source", workspaces: [sourceFirst, sourceSecond])
    let target = Profile(name: "Target", workspaces: [targetFirst, targetSecond])
    var settings = AppSettings()
    settings.shortcuts.assignModifiers = []
    settings.shortcuts.borrowModifiers = []
    let config = AppConfig(profiles: [target, source], settings: settings)

    let projection = try #require(config.profileSyncProjection(
      into: target.id,
      from: source.id,
      excludedFieldsByWorkspace: [
        targetFirst.id: [WorkspaceShortcutField.activateShortcut.rawValue],
        targetSecond.id: [WorkspaceShortcutField.activateShortcut.rawValue],
      ]
    ))

    #expect(Set(projection.conflicts.map(\.selection)) == [
      .init(workspaceId: targetFirst.id, field: .keyEquivalent),
      .init(workspaceId: targetSecond.id, field: .keyEquivalent),
    ])
    #expect(Set(projection.conflicts.map(\.hotKey)).count == 1)
  }

  @Test
  func workspaceKeysMayBeReusedAcrossProfiles() throws {
    let sourceWorkspace = Workspace(name: "Browser", keyEquivalent: "a")
    let targetWorkspace = Workspace(name: "Browser", keyEquivalent: "b")
    let source = Profile(name: "Default", workspaces: [sourceWorkspace])
    let target = Profile(name: "Dual", workspaces: [targetWorkspace])
    var settings = AppSettings()
    settings.shortcuts.assignModifiers = []
    settings.shortcuts.borrowModifiers = []
    let config = AppConfig(profiles: [source, target], settings: settings)

    let projection = try #require(config.profileSyncProjection(
      into: target.id,
      from: source.id
    ))

    #expect(projection.conflicts.isEmpty)
    #expect(projection.config.workspace(id: targetWorkspace.id)?.keyEquivalent == "a")
  }

  @Test
  func unrelatedLegacyConflictDoesNotBlockNonShortcutCopy() throws {
    let legacyConflict = try #require(HotKey(parsing: "cmd - h"))
    let sourceWorkspace = Workspace(name: "Source", symbolIconName: "star")
    let targetWorkspace = Workspace(name: "Target", symbolIconName: "bolt")
    let source = Profile(name: "Source", workspaces: [sourceWorkspace])
    let target = Profile(name: "Target", workspaces: [targetWorkspace])
    var settings = AppSettings()
    settings.shortcuts.focusLeft = legacyConflict
    settings.shortcuts.focusRight = legacyConflict
    var config = AppConfig(profiles: [target, source], settings: settings)

    let conflicts = config.importWorkspace(
      into: targetWorkspace.id,
      from: source.id,
      sourceWorkspace: sourceWorkspace.id
    )

    #expect(conflicts.isEmpty)
    #expect(config.workspace(id: targetWorkspace.id)?.symbolIconName == "star")
  }

  @Test
  func representationOnlyExplicitOverrideDoesNotIntroduceLegacyConflict() throws {
    let effectiveKey = try #require(HotKey(parsing: "ctrl + alt - a"))
    let sourceWorkspace = Workspace(
      name: "Source",
      activateShortcut: effectiveKey,
      keyEquivalent: "a"
    )
    let targetWorkspace = Workspace(name: "Target", keyEquivalent: "a")
    let source = Profile(name: "Source", workspaces: [sourceWorkspace])
    let target = Profile(name: "Target", workspaces: [targetWorkspace])
    var settings = AppSettings()
    settings.shortcuts.assignModifiers = []
    settings.shortcuts.borrowModifiers = []
    settings.shortcuts.focusLeft = effectiveKey
    var config = AppConfig(profiles: [target, source], settings: settings)

    let projection = try #require(config.workspaceImportProjection(
      into: targetWorkspace.id,
      from: source.id,
      sourceWorkspace: sourceWorkspace.id
    ))
    #expect(projection.conflicts.isEmpty)

    let conflicts = config.importWorkspace(
      into: targetWorkspace.id,
      from: source.id,
      sourceWorkspace: sourceWorkspace.id
    )
    #expect(conflicts.isEmpty)
    #expect(config.workspace(id: targetWorkspace.id)?.activateShortcut == effectiveKey)
  }

  @Test
  func counterfactualAttributesCombinedCollisionOnlyToCausalField() throws {
    let effectiveKey = try #require(HotKey(parsing: "ctrl + alt - a"))
    let sourceWorkspace = Workspace(
      name: "Source",
      activateShortcut: effectiveKey,
      assignAppShortcut: effectiveKey,
      keyEquivalent: "a"
    )
    let targetWorkspace = Workspace(name: "Target", keyEquivalent: "a")
    let source = Profile(name: "Source", workspaces: [sourceWorkspace])
    let target = Profile(name: "Target", workspaces: [targetWorkspace])
    var settings = AppSettings()
    settings.shortcuts.assignModifiers = []
    settings.shortcuts.borrowModifiers = []
    let config = AppConfig(profiles: [target, source], settings: settings)

    let projection = try #require(config.workspaceImportProjection(
      into: targetWorkspace.id,
      from: source.id,
      sourceWorkspace: sourceWorkspace.id
    ))

    #expect(projection.conflicts.map(\.selection.field) == [.assignAppShortcut])
    #expect(projection.conflicts.map(\.hotKey) == [effectiveKey])
  }

  @Test
  func jointKeyAndExplicitFieldsCannotHideIntroducedCollision() throws {
    let conflictingKey = try #require(HotKey(parsing: "ctrl + alt - a"))
    let sourceWorkspace = Workspace(
      name: "Source",
      activateShortcut: conflictingKey,
      keyEquivalent: "a"
    )
    let targetWorkspace = Workspace(name: "Target", keyEquivalent: "b")
    let source = Profile(name: "Source", workspaces: [sourceWorkspace])
    let target = Profile(name: "Target", workspaces: [targetWorkspace])
    var settings = AppSettings()
    settings.shortcuts.assignModifiers = []
    settings.shortcuts.borrowModifiers = []
    settings.shortcuts.focusLeft = conflictingKey
    var config = AppConfig(profiles: [target, source], settings: settings)

    let projection = try #require(config.workspaceImportProjection(
      into: targetWorkspace.id,
      from: source.id,
      sourceWorkspace: sourceWorkspace.id
    ))

    #expect(Set(projection.conflicts.map(\.selection.field)) == [
      .keyEquivalent,
      .activateShortcut,
    ])
    let conflicts = config.importWorkspace(
      into: targetWorkspace.id,
      from: source.id,
      sourceWorkspace: sourceWorkspace.id
    )
    #expect(!conflicts.isEmpty)
    #expect(config.workspace(id: targetWorkspace.id)?.keyEquivalent == "b")
    #expect(config.workspace(id: targetWorkspace.id)?.activateShortcut == nil)
  }

  @Test
  func applyRevalidatesCurrentConfigAndRejectsWholeCopy() throws {
    let derived = try #require(HotKey(parsing: "ctrl + alt - a"))
    let copiedApp = app("copied")
    let sourceWorkspace = Workspace(
      name: "Source",
      keyEquivalent: "a",
      apps: [copiedApp]
    )
    let targetWorkspace = Workspace(name: "Target", keyEquivalent: "b")
    let source = Profile(name: "Source", workspaces: [sourceWorkspace])
    let target = Profile(name: "Target", workspaces: [targetWorkspace])
    var config = AppConfig(profiles: [target, source])

    let chooserProjection = try #require(config.workspaceImportProjection(
      into: targetWorkspace.id,
      from: source.id,
      sourceWorkspace: sourceWorkspace.id
    ))
    #expect(chooserProjection.conflicts.isEmpty)

    // Simulate a shortcut edit landing after the sheet rendered but before
    // Apply. The mutation must be validated against this current config.
    config.settings.shortcuts.focusLeft = derived
    let conflicts = config.importWorkspace(
      into: targetWorkspace.id,
      from: source.id,
      sourceWorkspace: sourceWorkspace.id
    )

    #expect(!conflicts.isEmpty)
    #expect(config.workspace(id: targetWorkspace.id)?.keyEquivalent == "b")
    #expect(config.workspace(id: targetWorkspace.id)?.apps.isEmpty == true)
  }
}
