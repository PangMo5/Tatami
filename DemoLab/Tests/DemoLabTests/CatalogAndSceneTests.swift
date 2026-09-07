// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import DemoAppKit
import Foundation
import Testing

@testable import DemoCtlKit

// MARK: - Catalog

@Suite("Demo app catalog")
struct DemoCatalogTests {

  @Test("has one spec per app id")
  func coversEveryID() {
    #expect(DemoCatalog.all.count == DemoAppID.allCases.count)
    for id in DemoAppID.allCases {
      #expect(DemoCatalog.spec(id).id == id)
    }
  }

  @Test("bundle identifiers are unique")
  func identifiersAreUnique() {
    let identifiers = DemoCatalog.all.map(\.bundleIdentifier)
    #expect(Set(identifiers).count == identifiers.count)
  }

  /// Tatami treats `dev.PangMo5.Tatami` and anything under
  /// `dev.PangMo5.Tatami.` as *itself* and excludes it from management. A demo
  /// app caught by that test would never be tiled, and the failure would look
  /// like a tiling bug rather than a naming mistake.
  @Test("no demo app can be mistaken for Tatami")
  func identifiersAreNotTatami() {
    for spec in DemoCatalog.all {
      #expect(!TatamiInstall.isTatami(spec.bundleIdentifier), "\(spec.bundleIdentifier) reads as Tatami")
    }
  }

  @Test("window titles are fixed, distinct and non-empty")
  func windowTitlesAreDeterministic() {
    for spec in DemoCatalog.all {
      #expect(!spec.windowTitles.isEmpty, "\(spec.name) has no window titles")
      #expect(Set(spec.windowTitles.map { String(localized: $0) }).count == spec.windowTitles.count, "\(spec.name) repeats a title")
      for title in spec.windowTitles { #expect(!String(localized: title).isEmpty) }
      // Same ordinal, same title — twice, in the same process and across runs.
      #expect(spec.windowTitle(at: 0) == spec.windowTitle(at: 0))
      #expect(spec.windowTitle(at: 0) != spec.windowTitle(at: 99))
      #expect(spec.defaultWindowCount >= 1)
    }
  }

  @Test("launch options parse the flags scenes use, and reject anything else")
  func launchOptionsParse() throws {
    let options = try DemoLaunchOptions.parse(["--windows", "2", "--variant", "1"])
    #expect(options.windowCount == 2)
    #expect(options.variant == 1)
    // LaunchServices appends this when an app is opened with `open`.
    #expect(try DemoLaunchOptions.parse(["-psn_0_12345"]).windowCount == nil)
    #expect(throws: DemoLaunchError.self) { try DemoLaunchOptions.parse(["--window", "2"]) }
    #expect(throws: DemoLaunchError.self) { try DemoLaunchOptions.parse(["--windows", "nope"]) }
    #expect(throws: DemoLaunchError.self) { try DemoLaunchOptions.parse(["--windows"]) }
  }

}

// MARK: - Scenes

@Suite("Scenes")
struct SceneTests {

  // MARK: Internal

  @Test("every shipped scene decodes")
  func scenesDecode() throws {
    let paths = try paths()
    let names = SceneLoader.available(in: paths)
    #expect(names.contains("tour"), "the long integrated take must exist")
    for name in names {
      let scene = try SceneLoader.load(name, paths: paths)
      #expect(scene.name == name, "\(name).json declares name \"\(scene.name)\"")
      #expect(!scene.steps.isEmpty)
    }
  }

  @Test("scenes only reference apps and workspaces that exist")
  func scenesReferenceRealThings() throws {
    let paths = try paths()
    let config = try TomlLite.parse(try ConfigRenderer(paths: paths).render(SeedOptions()))
    let profiles = try #require(config["profiles"]?.tableArray)

    var workspaceNames = Set<String>()
    var profileNames = Set<String>()
    for profile in profiles {
      if let name = profile["name"]?.stringValue { profileNames.insert(name) }
      for workspace in profile["workspaces"]?.tableArray ?? [] {
        if let name = workspace["name"]?.stringValue { workspaceNames.insert(name) }
      }
    }

    for name in SceneLoader.available(in: paths) {
      let scene = try SceneLoader.load(name, paths: paths)
      for step in (scene.setup ?? []) + scene.steps {
        switch step {
        case .activateWorkspace(let workspace, let profile):
          #expect(workspaceNames.contains(workspace), "\(name): unknown workspace \(workspace)")
          if let profile { #expect(profileNames.contains(profile), "\(name): unknown profile \(profile)") }

        case .activateProfile(let profile), .waitProfile(let profile, _):
          #expect(profileNames.contains(profile), "\(name): unknown profile \(profile)")

        case .waitWorkspace(let workspace, _):
          #expect(workspaceNames.contains(workspace), "\(name): unknown workspace \(workspace)")

        case .borrow(let workspace, let apps, _):
          #expect(workspaceNames.contains(workspace), "\(name): unknown workspace \(workspace)")
          for app in apps { #expect(DemoCatalog.spec(named: app) != nil, "\(name): unknown app \(app)") }

        case .launch(let apps, let windows):
          for app in apps { #expect(DemoCatalog.spec(named: app) != nil, "\(name): unknown app \(app)") }
          for app in windows.keys { #expect(DemoCatalog.spec(named: app) != nil, "\(name): unknown app \(app)") }

        case .quitApps(let apps):
          for app in apps ?? [] { #expect(DemoCatalog.spec(named: app) != nil, "\(name): unknown app \(app)") }

        default:
          break
        }
      }
    }
  }

  /// Every keystroke a scene types must actually be bound.
  ///
  /// This is the exact silent failure the lab exists to stop. An unbound chord
  /// posts real key events, Tatami ignores them, `democtl` reports the step as
  /// successful, and the recording is of nothing happening. Checking it here
  /// means a mistyped shortcut fails `swift test` instead of a take.
  @Test("every chord a scene types is bound in the seeded config")
  func sceneChordsAreBound() throws {
    let paths = try paths()
    let bound = try boundChords(in: try ConfigRenderer(paths: paths).render(SeedOptions()))

    for name in SceneLoader.available(in: paths) {
      let scene = try SceneLoader.load(name, paths: paths)
      for step in (scene.setup ?? []) + scene.steps {
        switch step {
        case .key(let chord, _, _):
          #expect(
            bound.contains(Self.canonical(chord)),
            "\(name): \"\(chord)\" is not bound in the config and would do nothing"
          )

        case .hold(let modifiers, let keys, _, _):
          for key in keys {
            let chord = key.contains("-") || key.contains("+") ? key : "\(modifiers) - \(key)"
            #expect(
              bound.contains(Self.canonical(chord)),
              "\(name): \"\(chord)\" is not bound in the config and would do nothing"
            )
          }

        default:
          break
        }
      }
    }
  }

  /// Shortcuts that belong to macOS or to the app being driven rather than to
  /// Tatami, so they are correct without appearing in `config.toml`.
  private static let systemChords: Set<String> = [
    "cmd-tab", "cmd-ctrl-f", "ctrl-cmd-f", "left", "right", "up", "down", "esc", "cmd-a", "return", "cmd-,", "cmd-w", "cmd-n", "cmd-s", "cmd-m", "cmd-f", "cmd-q", "cmd-shift-w",
  ]

  /// Canonical form: modifiers in a fixed order, then the key, all lowercased.
  /// Mirrors how Tatami normalizes a binding, so `"alt + ctrl - h"` and
  /// `"ctrl + alt - h"` compare equal.
  private static func canonical(_ chord: String) -> String {
    let text = chord.lowercased().trimmingCharacters(in: .whitespaces)
    var modifiers = [String]()
    var key = text
    if let separator = text.range(of: " - ", options: .backwards) {
      modifiers = text[text.startIndex..<separator.lowerBound]
        .split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
      key = String(text[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
    } else if text.contains("+") {
      var parts = text.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
      key = parts.removeLast()
      modifiers = parts
    }
    let aliases = ["control": "ctrl", "opt": "alt", "option": "alt", "command": "cmd"]
    let normalized = Set(modifiers.map { aliases[$0] ?? $0 })
    let ordered = ["ctrl", "alt", "shift", "cmd"].filter { normalized.contains($0) }
    return (ordered + [key]).joined(separator: "-")
  }

  /// Every chord the seeded config binds: the explicit `[settings.shortcuts]`
  /// entries, each profile's switch shortcut, and the combos derived from the
  /// three modifier arrays with every workspace key equivalent and the three
  /// navigation keys.
  private func boundChords(in config: String) throws -> Set<String> {
    let root = try TomlLite.parse(config)
    var bound = Self.systemChords

    let shortcuts = root["settings"]?["shortcuts"]?.tableValue ?? [:]
    let modifierArrays = ["keyEquivalentModifiers", "assignModifiers", "borrowModifiers"]
    let navigationKeys = ["recentWorkspaceKey", "nextWorkspaceKey", "previousWorkspaceKey"]

    for (key, value) in shortcuts {
      guard !modifierArrays.contains(key), !navigationKeys.contains(key) else { continue }
      if let chord = value.stringValue { bound.insert(Self.canonical(chord)) }
    }

    let sets = modifierArrays.compactMap { shortcuts[$0]?.stringArray }
    var keys = navigationKeys.compactMap { shortcuts[$0]?.stringValue }
    for profile in root["profiles"]?.tableArray ?? [] {
      if let shortcut = profile["shortcut"]?.stringValue { bound.insert(Self.canonical(shortcut)) }
      for workspace in profile["workspaces"]?.tableArray ?? [] {
        if let equivalent = workspace["keyEquivalent"]?.stringValue { keys.append(equivalent) }
        for explicit in ["activateShortcut", "assignAppShortcut", "borrowShortcut"] {
          if let chord = workspace[explicit]?.stringValue { bound.insert(Self.canonical(chord)) }
        }
      }
    }

    for modifiers in sets {
      for key in keys {
        bound.insert(Self.canonical("\(modifiers.joined(separator: " + ")) - \(key)"))
      }
    }
    return bound
  }

  // MARK: Private

  private func paths() throws -> LabPaths {
    guard let root = LabPaths.discoverPackageRoot() else { throw DemoCtlError.packageRootNotFound }
    return LabPaths(packageRoot: root)
  }

}
