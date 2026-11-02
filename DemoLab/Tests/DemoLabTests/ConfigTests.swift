// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import DemoAppKit
import Foundation
import Testing

@testable import DemoCtlKit

// MARK: - Fixtures

private func labPaths() throws -> LabPaths {
  guard let root = LabPaths.discoverPackageRoot() else {
    Issue.record("could not find the DemoLab package root from the test bundle")
    throw DemoCtlError.packageRootNotFound
  }
  return LabPaths(packageRoot: root)
}

private func renderedConfig() throws -> String {
  try ConfigRenderer(paths: try labPaths()).render(SeedOptions())
}

// MARK: - ConfigTemplateTests

@Suite("Config template")
struct ConfigTemplateTests {

  @Test
  func `renders with every placeholder resolved`() throws {
    let text = try renderedConfig()
    #expect(!text.contains("@PULSE_LAYOUT@"))
    #expect(!text.contains("@HOOK@"))
    #expect(!text.contains("@EVENT_LOG@"))
  }

  @Test
  func `passes the validator with no problems`() throws {
    let report = ConfigValidator.report(try renderedConfig())
    #expect(report.problems.isEmpty, "problems: \(report.problems)")
  }

  /// The single most load-bearing setting in the whole lab: without it a
  /// scripted Borrow arms a keyboard-only picker and then silently cancels.
  @Test
  func `sets a default borrow edge`() throws {
    let root = try TomlLite.parse(try renderedConfig())
    #expect(root["settings"]?["switching"]?["borrowDefaultEdge"]?.stringValue == "right")
  }

  @Test
  func `writes all three workspace modifier arrays explicitly`() throws {
    let shortcuts = try TomlLite.parse(try renderedConfig())["settings"]?["shortcuts"]
    #expect(shortcuts?["keyEquivalentModifiers"]?.stringArray == ["ctrl", "alt", "shift"])
    #expect(shortcuts?["assignModifiers"]?.stringArray == ["alt", "shift", "cmd"])
    #expect(shortcuts?["borrowModifiers"]?.stringArray == ["ctrl", "alt", "cmd"])
  }

  /// A `displayHint` names one machine's monitor. It would silently fall back
  /// to the primary display elsewhere, and a *matching* name would be worse:
  /// Tatami rewrites the config in place to learn that display's UUID.
  @Test
  func `pins no display, so the config is portable to any machine or VM`() throws {
    let profiles = try #require(TomlLite.parse(try renderedConfig())["profiles"]?.tableArray)
    for profile in profiles {
      for workspace in profile["workspaces"]?.tableArray ?? [] {
        #expect(workspace["displayHint"] == nil, "\(workspace["name"]?.stringValue ?? "?") is pinned")
      }
    }
  }

  @Test
  func `auto-activates profiles by display count only`() throws {
    let profiles = try #require(TomlLite.parse(try renderedConfig())["profiles"]?.tableArray)
    let counts = profiles.compactMap { $0["autoActivation"]?["displayCount"]?.stringValue }
    #expect(counts == ["==1", ">=2"])
    for profile in profiles {
      #expect(profile["autoActivation"]?["whenConnected"] == nil)
    }
  }

  @Test
  func `every workspace's focus target is one of its own apps`() throws {
    let profiles = try #require(TomlLite.parse(try renderedConfig())["profiles"]?.tableArray)
    for profile in profiles {
      for workspace in profile["workspaces"]?.tableArray ?? [] {
        guard let focus = workspace["appToFocusBundleId"]?.stringValue else { continue }
        let members = (workspace["apps"]?.tableArray ?? [])
          .compactMap { $0["bundleIdentifier"]?.stringValue }
        #expect(members.contains(focus), "\(focus) is not a member of \(workspace["name"]?.stringValue ?? "?")")
      }
    }
  }

  /// Every scene relies on activation bringing its apps up, and `autoOpen` is
  /// `try?`-decoded: a quoted or missing value would silently mean "do not
  /// open" and the take would be of an empty desktop.
  @Test
  func `every app row carries a bare boolean autoOpen`() throws {
    let root = try TomlLite.parse(try renderedConfig())
    for shared in try #require(root["sharedApps"]?.tableArray) {
      #expect(shared["autoOpen"]?.boolValue == false, "Shared Monitor is launched only for its own demo")
    }
    for profile in try #require(root["profiles"]?.tableArray) {
      for workspace in profile["workspaces"]?.tableArray ?? [] {
        for app in workspace["apps"]?.tableArray ?? [] {
          #expect(app["autoOpen"]?.boolValue == true, "\(app["name"]?.stringValue ?? "?") does not auto-open")
        }
      }
    }
  }

  @Test
  func `only Notes is borrow-only, and it has an edge to dock to`() throws {
    let profiles = try #require(TomlLite.parse(try renderedConfig())["profiles"]?.tableArray)
    var scratchpads = [String]()
    for profile in profiles {
      for workspace in profile["workspaces"]?.tableArray ?? []
        where workspace["kind"]?.stringValue == "scratchpad"
      {
        scratchpads.append(workspace["name"]?.stringValue ?? "?")
        #expect(workspace["borrowEdge"]?.stringValue == "right")
      }
    }
    #expect(scratchpads == ["Notes", "Notes"])
  }

  @Test
  func `chains reference real workspaces and never a scratchpad`() throws {
    let profiles = try #require(TomlLite.parse(try renderedConfig())["profiles"]?.tableArray)
    let desk = try #require(profiles.first { $0["name"]?.stringValue == "Desk" })
    let workspaces = desk["workspaces"]?.tableArray ?? []
    let normalIDs = Set(
      workspaces
        .filter { ($0["kind"]?.stringValue ?? "normal") == "normal" }
        .compactMap { $0["id"]?.stringValue }
    )
    let chains = try #require(desk["workspaceChains"]?.tableArray)
    #expect(chains.count == 3)
    var claimed = Set<String>()
    for chain in chains {
      let members = try #require(chain["workspaceIds"]?.stringArray)
      #expect(members.count >= 2)
      for member in members {
        #expect(normalIDs.contains(member))
        #expect(claimed.insert(member).inserted, "\(member) is in more than one chain")
      }
    }
  }

  @Test
  func `every referenced bundle identifier is a Demo Lab app`() throws {
    let known = Set(DemoCatalog.all.map(\.bundleIdentifier))
    let report = ConfigValidator.report(try renderedConfig())
    #expect(!report.warnings.contains(where: { $0.contains("not a Demo Lab app") }))
    #expect(known.count == DemoAppID.allCases.count)
  }

  @Test
  func `seed options reject values Tatami would silently ignore`() {
    #expect(throws: DemoCtlError.self) {
      try SeedOptions(pulseLayout: "float").validated()
    }
    #expect(throws: DemoCtlError.self) {
      try SeedOptions(borrowEdge: "east").validated()
    }
  }

}

// MARK: - ConfigValidatorTests

@Suite("Config validator")
struct ConfigValidatorTests {

  /// Each of these is a mistake Tatami accepts *silently*. If the validator
  /// stopped catching them, a take would quietly differ from the previous one
  /// with nothing in any log to explain it.
  @Test(
    arguments: [
      ("layout = \"tiled\"", "layout = \"tile\"", "layout"),
      ("autoBalance = \"none\"", "autoBalance = \"nope\"", "autoBalance"),
      ("displayCount = \"==1\"", "displayCount = 1", "displayCount"),
      ("position = \"top\"", "position = \"topmost\"", "position"),
      ("focusFollowsMouseDisableHotkey = \"Alt\"", "focusFollowsMouseDisableHotkey = \"None\"", "DisableHotkey"),
      ("borrowFraction = 0.34", "borrowFraction = 2.5", "borrowFraction"),
      ("focusLeft = \"ctrl + alt - h\"", "focusLeft = \"ctrl + hyper - h\"", "focusLeft"),
    ]
  )
  func `catches silently-defaulted mistakes`(original: String, broken: String, needle: String) throws {
    let text = try renderedConfig()
    #expect(text.contains(original), "fixture drifted: \(original) is no longer in the template")
    let mutated = text.replacing(original, with: broken)
    let report = ConfigValidator.report(mutated)
    #expect(
      report.problems.contains { $0.contains(needle) },
      "expected a problem mentioning \(needle); got \(report.problems)",
    )
  }

  @Test
  func `catches a missing borrow edge`() throws {
    let text = try renderedConfig()
      .replacing("borrowDefaultEdge = \"right\"", with: "")
    let report = ConfigValidator.report(text)
    #expect(report.problems.contains { $0.contains("borrowDefaultEdge") })
  }

  @Test
  func `catches a duplicate workspace id, which rejects the whole file`() throws {
    let text = try renderedConfig().replacing(
      "11111111-0000-4000-8000-000000000002",
      with: "11111111-0000-4000-8000-000000000001",
    )
    let report = ConfigValidator.report(text)
    #expect(report.problems.contains { $0.contains("duplicates a workspace id") })
  }

  @Test
  func `catches a display hint that can never match`() {
    let text = """
      [settings.switching]
      borrowDefaultEdge = "right"

      [[profiles]]
      id = "d0000000-0000-4000-8000-000000000001"
      name = "P"

      [[profiles.workspaces]]
      id = "11111111-0000-4000-8000-000000000001"
      name = "W"
      displayHint = "::Studio Display"
      """
    #expect(ConfigValidator.report(text).problems.contains { $0.contains("::") })
  }

  /// The only check that can catch a misspelled *key*. Tatami never looks at a
  /// key its CodingKeys do not name, so the setting simply never takes effect.
  @Test
  func `catches a key name Tatami's decoder does not know`() throws {
    let text = try renderedConfig()
    #expect(text.contains("borrowFraction = 0.3\n"), "fixture drifted: no workspace borrowFraction")
    let typo = text.replacing("borrowFraction = 0.3\n", with: "borrowFractoin = 0.3\n")
    let problems = ConfigValidator.problems(in: typo)
    #expect(
      problems.contains { $0.contains("borrowFractoin") && $0.contains("did you mean borrowFraction?") },
      "expected an unknown-key problem; got \(problems)",
    )
  }

  @Test
  func `catches a misspelled settings key, which Tatami drops without a word`() throws {
    let text = try renderedConfig()
    #expect(text.contains("gapInner = 10"), "fixture drifted: no gapInner")
    let typo = text.replacing("gapInner = 10", with: "gapInnner = 10")
    let problems = ConfigValidator.problems(in: typo)
    #expect(problems.contains { $0.contains("settings.layout.gapInnner") }, "got \(problems)")
  }

  /// `[[floatingApps]]` is a decode-only migration table and a bare `floating`
  /// bool is the pre-1.4 spelling of `layout`. Both still decode, so calling
  /// them unknown would refuse a config Tatami reads fine.
  @Test
  func `does not call Tatami's legacy keys unknown`() {
    let text = """
      [settings.switching]
      borrowDefaultEdge = "right"

      [[floatingApps]]
      bundleIdentifier = "dev.PangMo5.DemoLab.Pulse"
      name = "Pulse"

      [[profiles]]
      id = "d0000000-0000-4000-8000-000000000001"
      name = "P"

      [[profiles.workspaces]]
      id = "11111111-0000-4000-8000-000000000001"
      name = "W"

      [[profiles.workspaces.apps]]
      bundleIdentifier = "dev.PangMo5.DemoLab.Forge"
      name = "Forge"
      autoOpen = true
      floating = true
      """
    let problems = ConfigValidator.problems(in: text)
    #expect(!problems.contains { $0.contains("not a key Tatami decodes") }, "got \(problems)")
  }

  /// `autoOpen` is the one app-row key with no banner and no rejection behind
  /// it: `AppAssignment` and `SharedApp` both decode it with a bare `try?`.
  @Test
  func `catches an autoOpen Tatami would silently read as false`() throws {
    let text = try renderedConfig()
    #expect(text.contains("autoOpen = true\n"), "fixture drifted: no autoOpen rows")

    let quoted = text.replacing("autoOpen = true", with: "autoOpen = \"true\"")
    #expect(ConfigValidator.problems(in: quoted).contains { $0.contains("autoOpen must be a bare true/false") })

    let removed = text.replacing("autoOpen = true\n", with: "")
    let report = ConfigValidator.report(removed)
    #expect(report.problems.contains { $0.contains("has no autoOpen") })
    #expect(report.warnings.contains { $0.contains("none with autoOpen = true") })
  }

  /// `HotKey.init(parsing:)` takes all three spellings. Rejecting one would
  /// block `democtl seed` on a config Tatami would have accepted, which is
  /// worse than not checking at all.
  @Test(
    arguments: [
      ("cycleNextWindow = \"alt - tab\"", "cycleNextWindow = \"alt-tab\""),
      ("focusLeft = \"ctrl + alt - h\"", "focusLeft = \"ctrl-alt-h\""),
      ("focusDown = \"ctrl + alt - j\"", "focusDown = \"fn + ctrl + alt - j\""),
      ("balance = \"ctrl + alt - e\"", "balance = \"ctrl+alt+e\""),
    ]
  )
  func `accepts every shortcut spelling Tatami's parser accepts`(original: String, rewritten: String) throws {
    let text = try renderedConfig()
    #expect(text.contains(original), "fixture drifted: \(original)")
    let report = ConfigValidator.report(text.replacing(original, with: rewritten))
    #expect(report.problems.isEmpty, "problems: \(report.problems)")
  }

  /// Tatami resolves the pin against workspace ∪ shared ∪ borrowed apps, so
  /// pinning the shared Monitor is legal and refusing it would block the seed.
  @Test
  func `accepts a shared app as a workspace's focus pin`() throws {
    let text = try renderedConfig().replacing(
      "appToFocusBundleId = \"dev.PangMo5.DemoLab.Chat\"",
      with: "appToFocusBundleId = \"dev.PangMo5.DemoLab.Monitor\"",
    )
    let report = ConfigValidator.report(text)
    #expect(report.problems.isEmpty, "problems: \(report.problems)")
    #expect(report.warnings.contains { $0.contains("pins the shared app") })
  }

  @Test
  func `still rejects a focus pin that is neither a member nor shared`() throws {
    let text = try renderedConfig().replacing(
      // Editor is a real Demo Lab app, so this exercises the stray-pin rule on
      // its own rather than also tripping the unknown-bundle warning.
      "appToFocusBundleId = \"dev.PangMo5.DemoLab.Chat\"",
      with: "appToFocusBundleId = \"dev.PangMo5.DemoLab.Editor\"",
    )
    let problems = ConfigValidator.problems(in: text)
    #expect(problems.contains { $0.contains("neither one of its apps nor a shared app") }, "got \(problems)")
  }

  @Test
  func `accepts an empty settings table without inventing problems`() {
    let text = """
      [settings.switching]
      borrowDefaultEdge = "left"

      [[profiles]]
      id = "d0000000-0000-4000-8000-000000000001"
      name = "Only"

      [[profiles.workspaces]]
      id = "11111111-0000-4000-8000-000000000001"
      name = "One"
      """
    #expect(ConfigValidator.report(text).problems.isEmpty)
  }

}

// MARK: - TomlLiteTests

@Suite("TomlLite")
struct TomlLiteTests {

  @Test
  func `attaches a sub-table array to the last parent element`() throws {
    let text = """
      [[profiles]]
      name = "A"

      [[profiles.workspaces]]
      name = "A1"

      [[profiles.workspaces]]
      name = "A2"

      [[profiles]]
      name = "B"

      [[profiles.workspaces]]
      name = "B1"
      """
    let profiles = try #require(TomlLite.parse(text)["profiles"]?.tableArray)
    #expect(profiles.count == 2)
    #expect(profiles[0]["workspaces"]?.tableArray?.count == 2)
    #expect(profiles[1]["workspaces"]?.tableArray?.compactMap { $0["name"]?.stringValue } == ["B1"])
  }

  @Test
  func `reads multi-line arrays, comments, escapes and inline tables`() throws {
    let text = #"""
      # leading comment
      name = "with \"quotes\" and # not a comment"
      literal = 'raw \ text'
      yes = true
      count = 12
      ratio = 0.34
      ids = [
        "one",   # trailing comment
        "two",
      ]
      env = { MODE = "desk", LEVEL = 2 }
      backslash = "\\"
      """#
    let root = try TomlLite.parse(text)
    #expect(root["name"]?.stringValue == "with \"quotes\" and # not a comment")
    #expect(root["literal"]?.stringValue == #"raw \ text"#)
    #expect(root["yes"]?.boolValue == true)
    #expect(root["count"]?.intValue == 12)
    #expect(root["ratio"]?.doubleValue == 0.34)
    #expect(root["ids"]?.stringArray == ["one", "two"])
    #expect(root["env"]?["MODE"]?.stringValue == "desk")
    #expect(root["backslash"]?.stringValue == "\\")
  }

  @Test
  func `rejects malformed input instead of guessing`() {
    #expect(throws: TomlLiteError.self) { try TomlLite.parse("[unterminated") }
    #expect(throws: TomlLiteError.self) { try TomlLite.parse("novalue") }
  }

}

// MARK: - AssignmentPreparationTests

@Suite("Scoped demo assignment preparation")
struct AssignmentPreparationTests {
  @Test
  func `changes only the exact profile/workspace/app and rejects missing targets`() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("config.toml")
    let original = try renderedConfig()
    try original.write(to: file, atomically: true, encoding: .utf8)
    try LiveConfigEditor.updateAssignment(
      file: file,
      bundleIdentifier: "dev.PangMo5.DemoLab.Canvas",
      workspace: "Design",
      profile: "Desk",
      autoOpen: false,
    )
    let changed = try String(contentsOf: file, encoding: .utf8)
    let profiles = try #require(try TomlLite.parse(changed)["profiles"]?.tableArray)
    for profile in profiles {
      for workspace in try #require(profile["workspaces"]?.tableArray) {
        for app in workspace["apps"]?.tableArray ?? []
          where app["bundleIdentifier"]?.stringValue == "dev.PangMo5.DemoLab.Canvas"
        {
          let target = profile["name"]?.stringValue == "Desk" && workspace["name"]?.stringValue == "Design"
          #expect(app["autoOpen"]?.boolValue == !target)
        }
      }
    }
    #expect(throws: (any Error).self) {
      try LiveConfigEditor.updateAssignment(
        file: file,
        bundleIdentifier: "missing",
        workspace: "Design",
        profile: "Desk",
        autoOpen: true,
      )
    }
    #expect(try String(contentsOf: file, encoding: .utf8) == changed)
  }
}
