// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CustomDump
import Foundation
import Testing
@testable import TatamiKit

@Suite("HotKey skhd encoding")
struct HotKeyTests {
  @Test
  func encodesAsSkhdString() throws {
    // keyCode 4 = h, modifiers 6144 = control(4096) + option(2048)
    let key = HotKey(carbonKeyCode: 4, carbonModifiers: 6144)
    #expect(key.displayString == "ctrl + alt - h")

    let data = try JSONEncoder().encode(key)
    #expect(String(data: data, encoding: .utf8) == "\"ctrl + alt - h\"")
  }

  @Test
  func roundTripsThroughString() throws {
    let key = HotKey(carbonKeyCode: 45, carbonModifiers: 256 + 512) // cmd+shift - n
    let data = try JSONEncoder().encode(key)
    let decoded = try JSONDecoder().decode(HotKey.self, from: data)
    #expect(decoded == key)
    #expect(key.displayString == "shift + cmd - n")
  }

  @Test
  func parsesLooseForm() {
    #expect(HotKey(parsing: "ctrl+alt+h") == HotKey(carbonKeyCode: 4, carbonModifiers: 6144))
    #expect(HotKey(parsing: "cmd - return") == HotKey(carbonKeyCode: 36, carbonModifiers: 256))
    #expect(HotKey(parsing: "left") == HotKey(carbonKeyCode: 123, carbonModifiers: 0))
  }

  @Test
  func decodesLegacyCarbonTable() throws {
    let json = #"{"carbonKeyCode":4,"carbonModifiers":6144}"#
    let decoded = try JSONDecoder().decode(HotKey.self, from: Data(json.utf8))
    #expect(decoded == HotKey(carbonKeyCode: 4, carbonModifiers: 6144))
  }

  @Test
  func rejectsUnknownKey() {
    #expect(HotKey(parsing: "cmd - boguskey") == nil)
  }

  @Test
  func reverseCycleBindingKeepsOnlyThePrimaryModifier() throws {
    let reverse = try #require(HotKey(parsing: "alt + shift - tab"))
    let shiftOnly = try #require(HotKey(parsing: "shift - tab"))

    #expect(reverse.holdModifiers == .option)
    #expect(shiftOnly.holdModifiers == .shift)
  }
}

@Suite("Profile-scoped hot keys")
struct ProfileScopedHotKeyTests {
  @Test
  func runtimeProjectionRegistersOnlyTheSelectedProfilesWorkspaceBinding() throws {
    let key = try #require(HotKey(parsing: "ctrl + alt - a"))
    let defaultWorkspaceId = try #require(
      UUID(uuidString: "00000000-0000-0000-0000-000000000011")
    )
    let dualWorkspaceId = try #require(
      UUID(uuidString: "00000000-0000-0000-0000-000000000012")
    )
    let defaultProfileId = try #require(
      UUID(uuidString: "00000000-0000-0000-0000-000000000001")
    )
    let dualProfileId = try #require(
      UUID(uuidString: "00000000-0000-0000-0000-000000000002")
    )
    let defaultWorkspace = Workspace(
      id: defaultWorkspaceId,
      name: "Default A",
      activateShortcut: key
    )
    let dualWorkspace = Workspace(
      id: dualWorkspaceId,
      name: "Dual A",
      activateShortcut: key
    )
    let defaultProfile = Profile(
      id: defaultProfileId,
      name: "Default",
      workspaces: [defaultWorkspace]
    )
    let dualProfile = Profile(
      id: dualProfileId,
      name: "Dual",
      workspaces: [dualWorkspace]
    )
    var config = AppConfig(
      profiles: [defaultProfile, dualProfile],
      activeProfileId: defaultProfile.id
    )

    expectNoDifference(
      config.hotKeyBindings.filter { $0.hotKey == key }.map(\.action),
      [.activateWorkspace(defaultWorkspace.id)]
    )

    config.activeProfileId = dualProfile.id
    expectNoDifference(
      config.hotKeyBindings.filter { $0.hotKey == key }.map(\.action),
      [.activateWorkspace(dualWorkspace.id)]
    )
  }

  @Test
  func inactiveProfileCanReuseAWorkspaceKeyFromTheActiveProfile() throws {
    let key = try #require(HotKey(parsing: "ctrl + alt - a"))
    let defaultWorkspace = Workspace(name: "Default A", keyEquivalent: "a")
    let dualWorkspace = Workspace(name: "Dual A", keyEquivalent: "a")
    let defaultProfile = Profile(name: "Default", workspaces: [defaultWorkspace])
    let dualProfile = Profile(name: "Dual", workspaces: [dualWorkspace])
    let config = AppConfig(
      profiles: [defaultProfile, dualProfile],
      activeProfileId: defaultProfile.id
    )

    #expect(
      config.shortcutConflict(
        for: key,
        excluding: .activateWorkspace(dualWorkspace.id),
        in: dualProfile.id
      ) == nil
    )
  }

  @Test
  func inactiveProfileStillRejectsAKeyUsedByItsSiblingWorkspace() throws {
    let key = try #require(HotKey(parsing: "ctrl + alt - a"))
    let defaultWorkspace = Workspace(name: "Default A", keyEquivalent: "a")
    let dualWorkspace = Workspace(name: "Dual A")
    let dualSibling = Workspace(name: "Dual sibling", keyEquivalent: "a")
    let defaultProfile = Profile(name: "Default", workspaces: [defaultWorkspace])
    let dualProfile = Profile(name: "Dual", workspaces: [dualWorkspace, dualSibling])
    let config = AppConfig(
      profiles: [defaultProfile, dualProfile],
      activeProfileId: defaultProfile.id
    )
    let expectedTitle = String(localized: "Activate \(dualSibling.name)")

    #expect(
      config.shortcutConflict(
        for: key,
        excluding: .activateWorkspace(dualWorkspace.id),
        in: dualProfile.id
      ) == expectedTitle
    )
  }

  @Test
  func globalShortcutRejectsAKeyUsedByAnInactiveProfilesWorkspace() throws {
    let key = try #require(HotKey(parsing: "ctrl + alt - a"))
    let defaultProfile = Profile(name: "Default")
    let dualWorkspace = Workspace(name: "Dual A", activateShortcut: key)
    let dualProfile = Profile(name: "Dual", workspaces: [dualWorkspace])
    let config = AppConfig(
      profiles: [defaultProfile, dualProfile],
      activeProfileId: defaultProfile.id
    )
    let expectedTitle = String(localized: "Activate \(dualWorkspace.name)")

    #expect(
      config.shortcutConflict(
        for: key,
        excluding: .focusLeft
      ) == expectedTitle
    )
  }

  @Test
  func workspaceKeyEquivalentIgnoresActionsWithExplicitOverrides() throws {
    let derivedKey = try #require(HotKey(parsing: "ctrl - a"))
    let explicitKey = try #require(HotKey(parsing: "cmd - x"))
    let workspace = Workspace(name: "Coding", activateShortcut: explicitKey)
    var settings = AppSettings()
    settings.shortcuts.keyEquivalentModifiers = ["ctrl"]
    settings.shortcuts.assignModifiers = []
    settings.shortcuts.borrowModifiers = []
    settings.shortcuts.focusLeft = derivedKey
    var config = AppConfig(
      profiles: [Profile(name: "Default", workspaces: [workspace])],
      settings: settings
    )

    #expect(
      config.workspaceKeyEquivalentConflict(
        for: "a",
        workspaceId: workspace.id
      ) == nil
    )

    config.profiles[0].workspaces[0].activateShortcut = nil
    #expect(
      config.workspaceKeyEquivalentConflict(
        for: "a",
        workspaceId: workspace.id
      ) == String(localized: "Focus left")
    )
  }

  @Test
  func navigationKeyEquivalentIgnoresActionsWithExplicitOverrides() throws {
    let derivedKey = try #require(HotKey(parsing: "ctrl - a"))
    let explicitKey = try #require(HotKey(parsing: "cmd - x"))
    var settings = AppSettings()
    settings.shortcuts.keyEquivalentModifiers = ["ctrl"]
    settings.shortcuts.assignModifiers = []
    settings.shortcuts.borrowModifiers = []
    settings.shortcuts.focusLeft = derivedKey
    let config = AppConfig(settings: settings)

    #expect(
      config.navigationKeyEquivalentConflict(
        for: "a",
        switchAction: .switchToRecentWorkspace,
        switchOverride: explicitKey,
        assignAction: .assignFocusedAppToRecentWorkspace,
        assignOverride: nil,
        borrowAction: .borrowRecentWorkspace,
        borrowOverride: nil
      ) == nil
    )

    #expect(
      config.navigationKeyEquivalentConflict(
        for: "a",
        switchAction: .switchToRecentWorkspace,
        switchOverride: nil,
        assignAction: .assignFocusedAppToRecentWorkspace,
        assignOverride: nil,
        borrowAction: .borrowRecentWorkspace,
        borrowOverride: nil
      ) == String(localized: "Focus left")
    )
  }
}
