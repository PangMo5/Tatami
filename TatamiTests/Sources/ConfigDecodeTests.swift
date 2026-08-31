// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Dependencies
import Foundation
import TOML
import Testing
@testable import TatamiKit

/// Decode policy: missing keys default quietly; present-but-corrupt
/// values are surfaced — a typo'd settings field reports and defaults,
/// while corrupt top-level sections fail the decode so the fileStorage
/// containment keeps the previous config instead of silently resetting.
struct ConfigDecodeTests {
  @Test
  func typoedSettingsFieldReportsAndUsesDefault() throws {
    let toml = """
    [settings.general]
    launchAtLogin = "yes"
    """
    let reported = LockIsolated<[String]>([])
    let config = try withDependencies {
      $0.errorReporter.report = { domain, message, _ in
        reported.withValue { $0.append("\(domain): \(message)") }
      }
    } operation: {
      try TOMLDecoder().decode(AppConfig.self, from: toml)
    }
    // The typo'd field falls back to its default…
    #expect(config.settings.general.launchAtLogin == false)
    // …and the user is told, instead of a silent reset.
    #expect(
      reported.value.contains { $0.hasPrefix("Settings:") && $0.contains("launchAtLogin") }
    )
  }

  @Test
  func missingKeysDefaultWithoutReporting() throws {
    let reported = LockIsolated(0)
    let config = try withDependencies {
      $0.errorReporter.report = { _, _, _ in reported.withValue { $0 += 1 } }
    } operation: {
      try TOMLDecoder().decode(AppConfig.self, from: "")
    }
    #expect(config.settings.general.launchAtLogin == false)
    #expect(config.settings.switching.recentAcrossDisplays)
    #expect(config.settings.switching.toggleBorrowOnRepeat)
    #expect(config.settings.hud.windowCycle)
    #expect(config.hooks.isEmpty)
    #expect(reported.value == 0)
  }

  @Test
  func hooksDecodeWithDefaultsAndRoundTrip() throws {
    let toml = """
    [[hooks]]
    id = "notify"
    event = "workspaceActivated"
    command = ["/usr/bin/true"]

    [[hooks]]
    id = "profile-log"
    event = "profileChanged"
    enabled = false
    command = ["/bin/zsh", "-c", "print changed"]
    timeoutMs = 1234
    workingDirectory = "~/Documents"
    environment = { MODE = "test" }
    """

    let decoded = try TOMLDecoder().decode(AppConfig.self, from: toml)

    #expect(decoded.hooks.count == 2)
    #expect(decoded.hooks[0].enabled)
    #expect(decoded.hooks[0].timeoutMs == 5_000)
    #expect(decoded.hooks[1].environment == ["MODE": "test"])

    let encoder = TOMLEncoder()
    let encoded = try encoder.encode(decoded)
    #expect(try TOMLDecoder().decode(AppConfig.self, from: encoded).hooks == decoded.hooks)
  }

  @Test
  func unknownHookEventFailsTheWholeConfigDecode() {
    let toml = """
    [[hooks]]
    id = "unknown"
    event = "windowFocused"
    command = ["/usr/bin/true"]
    """

    #expect(throws: (any Error).self) {
      try TOMLDecoder().decode(AppConfig.self, from: toml)
    }
  }

  @Test
  func legacyGestureFingerCountMigratesToDirectionalBindings() throws {
    let toml = """
    [settings.gestures]
    enabled = true
    fingerCount = 4
    threshold = 0.42
    """
    let config = try TOMLDecoder().decode(AppConfig.self, from: toml)
    let gestures = config.settings.gestures

    #expect(gestures.enabled)
    #expect(gestures.threshold == 0.42)
    #expect(gestures.threeFinger == AppSettings.GestureBindings())
    #expect(gestures.fourFinger.left == .nextWorkspace)
    #expect(gestures.fourFinger.right == .previousWorkspace)
    #expect(gestures.fourFinger.up == .none)
    #expect(gestures.fourFinger.down == .none)
  }

  @Test
  func directionalGestureBindingsDecodeWithoutLegacyDefaults() throws {
    let toml = """
    [settings.gestures]
    enabled = true

    [settings.gestures.threeFinger]
    up = "toggleFullscreen"

    [settings.gestures.fourFinger]
    down = "dismissBorrow"
    """
    let config = try TOMLDecoder().decode(AppConfig.self, from: toml)
    let gestures = config.settings.gestures

    #expect(gestures.threeFinger.up == .toggleFullscreen)
    #expect(gestures.threeFinger.left == .none)
    #expect(gestures.fourFinger.down == .dismissBorrow)
  }

  @Test
  func workspaceSpecificGestureBindingUsesStableIDCoding() throws {
    let id = try #require(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF"))
    let toml = """
    [settings.gestures.threeFinger]
    up = "activateWorkspace:\(id.uuidString)"

    [settings.gestures.fourFinger]
    down = "borrowWorkspace:\(id.uuidString)"
    """
    let gestures = try TOMLDecoder().decode(AppConfig.self, from: toml).settings.gestures

    #expect(gestures.threeFinger.up == .activateWorkspace(id))
    #expect(gestures.fourFinger.down == .borrowWorkspace(id))
  }

  @Test
  func corruptProfilesSectionFailsTheDecode() {
    // `profiles` present but not an array of tables: defaulting here
    // would wipe the user's workspaces on the next write.
    #expect(throws: (any Error).self) {
      _ = try TOMLDecoder().decode(AppConfig.self, from: "profiles = 3")
    }
  }
}

/// The recommended starter shortcuts seed a fresh install (`TatamiConfigKey`).
/// They're built from skhd strings via `HotKey(parsing:)`, which fails soft to
/// nil — so a typo'd string would silently ship an unbound action. Guard both
/// the parse and the resulting bindings being conflict-free.
struct RecommendedShortcutsTests {
  @Test
  func everyIntendedBindingParses() {
    let s = AppSettings.Shortcuts.recommended
    let bound: [HotKey?] = [
      s.focusLeft, s.focusRight, s.focusUp, s.focusDown,
      s.moveToNextWorkspace, s.moveToPreviousWorkspace,
      s.focusNextDisplay, s.focusPreviousDisplay,
      s.cycleNextWindow, s.cyclePreviousWindow,
      s.resizeGrow, s.resizeShrink,
      s.swapLeft, s.swapRight, s.swapUp, s.swapDown,
      s.toggleOrientation, s.toggleFullscreen, s.balance,
      s.toggleFloating, s.toggleSharedFloating, s.toggleSpaceActivated,
      s.toggleFocusedAppInActiveWorkspace, s.toggleAppInSharedApps,
      s.dismissBorrow,
    ]
    #expect(bound.allSatisfy { $0 != nil })
  }

  @Test
  func seededConfigHasNoConflictingBindings() {
    // The exact fresh-install seed used by `@Shared(.tatamiConfig)`.
    let config = AppConfig(settings: AppSettings(shortcuts: .recommended))
    let bindings = config.hotKeyBindings
    #expect(!bindings.isEmpty)
    // No two distinct actions may resolve to the same key combo.
    let clashes = Dictionary(grouping: bindings, by: \.hotKey)
      .filter { Set($0.value.map(\.action)).count > 1 }
    #expect(
      clashes.isEmpty,
      "conflicting recommended shortcuts: \(clashes.keys.map(\.displayString))"
    )
  }
}
