// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TatamiKit

struct StackGroupEditingTests {
  @Test
  func `moving apps edits the source and destination in one save`() {
    let writing = StackGroup(name: "Writing", bundleIdentifiers: ["app.pages", "app.notes"])
    let browsing = StackGroup(name: "Browsing", bundleIdentifiers: ["app.safari"])
    let research = StackGroup(name: "Research", bundleIdentifiers: ["app.pages", "app.safari"])
    var groups = [writing, browsing]

    let changed = groups.save(
      research,
      movingFrom: ["app.pages": writing.id, "app.safari": browsing.id],
      availableBundleIds: ["app.pages", "app.notes", "app.safari"],
    )

    #expect(changed == ["app.pages", "app.safari"])
    #expect(groups.count == 2)
    #expect(groups.first { $0.id == writing.id }?.bundleIdentifiers == ["app.notes"])
    #expect(!groups.contains { $0.id == browsing.id })
    #expect(groups.first { $0.id == research.id }?.bundleIdentifiers == research.bundleIdentifiers)
  }

  @Test
  func `an unconfirmed or stale app move preserves the complete configuration`() {
    let source = StackGroup(name: "Source", bundleIdentifiers: ["app.notes"])
    let destination = StackGroup(name: "Destination", bundleIdentifiers: ["app.notes"])
    var groups = [source]

    let withoutConfirmation = groups.save(destination, availableBundleIds: ["app.notes"])
    #expect(withoutConfirmation.isEmpty)
    let fromAnotherGroup = groups.save(
      destination,
      movingFrom: ["app.notes": UUID()],
      availableBundleIds: ["app.notes"],
    )
    #expect(fromAnotherGroup.isEmpty)
    #expect(groups == [source])
  }

  @Test
  func `a duplicate app is rejected within a config scope`() throws {
    let first = StackGroup(name: "First", bundleIdentifiers: ["app.notes"])
    let second = StackGroup(name: "Second", bundleIdentifiers: ["app.notes"])
    let workspace = Workspace(name: "Work", stackGroups: [first, second])
    let workspaceData = try JSONEncoder().encode(workspace)
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(Workspace.self, from: workspaceData)
    }
    let sharedData = try JSONEncoder().encode(AppConfig(sharedStackGroups: [first, second]))
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(AppConfig.self, from: sharedData)
    }

    let separateScopes = AppConfig(
      profiles: [Profile(name: "Test", workspaces: [Workspace(name: "Work", stackGroups: [first])])],
      sharedStackGroups: [second],
    )
    let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(separateScopes))
    #expect(decoded == separateScopes)
  }

  @Test
  func `older groups get distinct colors without depending on their display order`() throws {
    let first = StackGroup(name: "Writing", bundleIdentifiers: ["app.pages"])
    let second = StackGroup(name: "Reading", bundleIdentifiers: ["app.safari"])
    let groups = [first, second]
    let colors = StackGroupColors.colors(for: groups, scope: .workspace)
    #expect(colors == StackGroupColors.colors(for: Array(groups.reversed()), scope: .workspace))
    #expect(Set(colors.values).count == 2)
    #expect(Set(colors.values).isDisjoint(with: StackGroupColors.colors(for: groups, scope: .shared).values))

    var workspace = Workspace(name: "Work", stackGroups: groups)
    workspace = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
    let original = workspace.stackGroups
    let added = StackGroup(name: "Chat", bundleIdentifiers: ["app.chat"])
    _ = workspace.stackGroups.save(added, availableBundleIds: ["app.chat"])
    #expect(Array(workspace.stackGroups.prefix(2)) == original)
    #expect(Set(StackGroupColors.colors(for: workspace.stackGroups, scope: .workspace).values).count == 3)
    _ = workspace.stackGroups.remove(id: first.id)
    #expect(StackGroupColors.colors(for: workspace.stackGroups, scope: .workspace)[second.id] == colors[second.id])
  }

  @Test
  func `generated names stay tied to the app selection and keep a single display line`() {
    let safari = MacApp(bundleIdentifier: "com.apple.Safari", name: "Safari")
    let preview = MacApp(bundleIdentifier: "com.apple.Preview", name: "Preview")
    let request = StackGroupNameSuggestion.Request(apps: [safari, preview], locale: Locale(identifier: "en"))
    let changed = StackGroupNameSuggestion.Request(apps: [safari], locale: request.locale)
    let valid = StackGroupNameSuggestion(request: request, name: "  Reference  ")
    #expect(valid?.name == "Reference")
    #expect(valid?.request != changed)
    #expect(StackGroupNameSuggestion(request: request, name: "Research\nSecond line") == nil)
    #expect(StackGroupNameSuggestion(request: request, name: "SafariPreview") == nil)
    #expect(StackGroupNameSuggestion(request: request, name: String(repeating: "a", count: 49)) == nil)
  }

  @Test(arguments: [
    "Simulator Pulse Itsuka Tart",
    "Tart · Itsuka · Pulse · Simulator",
    "SimulatorPulseItsukaTart",
    "Simulator, Pulse and Tart",
    "Simulator Pulse Itsuka Tart Stack",
    "Pulse",
  ])
  func `stack naming rejects reused app names and lists`(_ reusedName: String) {
    let apps = [
      MacApp(bundleIdentifier: "com.apple.iphonesimulator", name: "Simulator"),
      MacApp(bundleIdentifier: "app.pulse", name: "Pulse"),
      MacApp(bundleIdentifier: "app.itsuka", name: "Itsuka"),
      MacApp(bundleIdentifier: "app.tart", name: "Tart"),
    ]
    let request = StackGroupNameSuggestion.Request(apps: apps, locale: Locale(identifier: "ko_KR"))
    #expect(StackGroupNameSuggestion(request: request, name: reusedName) == nil)
    #expect(StackGroupNameSuggestion(request: request, name: "테스트 환경")?.name == "테스트 환경")
  }
}
