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

// MARK: - Template

@Suite("Config template")
struct ConfigTemplateTests {

  @Test("renders with every placeholder resolved")
  func rendersCleanly() throws {
    let text = try renderedConfig()
    #expect(!text.contains("@PULSE_LAYOUT@"))
    #expect(!text.contains("@HOOK@"))
    #expect(!text.contains("@EVENT_LOG@"))
  }

  @Test("passes the validator with no problems")
  func validatorIsClean() throws {
    let report = ConfigValidator.report(try renderedConfig())
    #expect(report.problems.isEmpty, "problems: \(report.problems)")
  }

  /// The single most load-bearing setting in the whole lab: without it a
  /// scripted Borrow arms a keyboard-only picker and then silently cancels.
  @Test("sets a default borrow edge")
  func borrowEdgeIsSet() throws {
    let root = try TomlLite.parse(try renderedConfig())
    #expect(root["settings"]?["switching"]?["borrowDefaultEdge"]?.stringValue == "right")
  }

  @Test("writes all three workspace modifier arrays explicitly")
  func modifierArraysArePresent() throws {
    let shortcuts = try TomlLite.parse(try renderedConfig())["settings"]?["shortcuts"]
    #expect(shortcuts?["keyEquivalentModifiers"]?.stringArray == ["ctrl", "alt", "shift"])
    #expect(shortcuts?["assignModifiers"]?.stringArray == ["alt", "shift", "cmd"])
    #expect(shortcuts?["borrowModifiers"]?.stringArray == ["ctrl", "alt", "cmd"])
  }

  /// A `displayHint` names one machine's monitor. It would silently fall back
  /// to the primary display elsewhere, and a *matching* name would be worse:
  /// Tatami rewrites the config in place to learn that display's UUID.
  @Test("pins no display, so the config is portable to any machine or VM")
  func noDisplayHints() throws {
    let profiles = try #require(TomlLite.parse(try renderedConfig())["profiles"]?.tableArray)
    for profile in profiles {
      for workspace in profile["workspaces"]?.tableArray ?? [] {
        #expect(workspace["displayHint"] == nil, "\(workspace["name"]?.stringValue ?? "?") is pinned")
      }
    }
  }

  @Test("auto-activates profiles by display count only")
  func autoActivationUsesCountOnly() throws {
    let profiles = try #require(TomlLite.parse(try renderedConfig())["profiles"]?.tableArray)
    let counts = profiles.compactMap { $0["autoActivation"]?["displayCount"]?.stringValue }
    #expect(counts == ["==1", ">=2"])
    for profile in profiles {
      #expect(profile["autoActivation"]?["whenConnected"] == nil)
    }
  }

  @Test("every workspace's focus target is one of its own apps")
  func focusTargetsAreMembers() throws {
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
  @Test("every app row carries a bare boolean autoOpen")
  func autoOpenIsAlwaysABareBool() throws {
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

  @Test("only Notes is borrow-only, and it has an edge to dock to")
  func scratchpadIsConfigured() throws {
    let profiles = try #require(TomlLite.parse(try renderedConfig())["profiles"]?.tableArray)
    var scratchpads = [String]()
    for profile in profiles {
      for workspace in profile["workspaces"]?.tableArray ?? []
        where workspace["kind"]?.stringValue == "scratchpad" {
        scratchpads.append(workspace["name"]?.stringValue ?? "?")
        #expect(workspace["borrowEdge"]?.stringValue == "right")
      }
    }
    #expect(scratchpads == ["Notes", "Notes"])
  }

  @Test("chains reference real workspaces and never a scratchpad")
  func chainsAreValid() throws {
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

  @Test("every referenced bundle identifier is a Demo Lab app")
  func bundleIdentifiersMatchTheCatalog() throws {
    let known = Set(DemoCatalog.all.map(\.bundleIdentifier))
    let report = ConfigValidator.report(try renderedConfig())
    #expect(report.warnings.filter { $0.contains("not a Demo Lab app") }.isEmpty)
    #expect(known.count == DemoAppID.allCases.count)
  }

  @Test("seed options reject values Tatami would silently ignore")
  func seedOptionsAreValidated() {
    #expect(throws: DemoCtlError.self) {
      try SeedOptions(pulseLayout: "float").validated()
    }
    #expect(throws: DemoCtlError.self) {
      try SeedOptions(borrowEdge: "east").validated()
    }
  }

}

// MARK: - Validator

@Suite("Config validator")
struct ConfigValidatorTests {

  /// Each of these is a mistake Tatami accepts *silently*. If the validator
  /// stopped catching them, a take would quietly differ from the previous one
  /// with nothing in any log to explain it.
  @Test(
    "catches silently-defaulted mistakes",
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
  func catchesSilentDefaults(original: String, broken: String, needle: String) throws {
    let text = try renderedConfig()
    #expect(text.contains(original), "fixture drifted: \(original) is no longer in the template")
    let mutated = text.replacingOccurrences(of: original, with: broken)
    let report = ConfigValidator.report(mutated)
    #expect(
      report.problems.contains { $0.contains(needle) },
      "expected a problem mentioning \(needle); got \(report.problems)"
    )
  }

  @Test("catches a missing borrow edge")
  func catchesMissingBorrowEdge() throws {
    let text = try renderedConfig()
      .replacingOccurrences(of: "borrowDefaultEdge = \"right\"", with: "")
    let report = ConfigValidator.report(text)
    #expect(report.problems.contains { $0.contains("borrowDefaultEdge") })
  }

  @Test("catches a duplicate workspace id, which rejects the whole file")
  func catchesDuplicateWorkspaceID() throws {
    let text = try renderedConfig().replacingOccurrences(
      of: "11111111-0000-4000-8000-000000000002",
      with: "11111111-0000-4000-8000-000000000001"
    )
    let report = ConfigValidator.report(text)
    #expect(report.problems.contains { $0.contains("duplicates a workspace id") })
  }

  @Test("catches a display hint that can never match")
  func catchesEmptyUUIDHint() {
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
  @Test("catches a key name Tatami's decoder does not know")
  func catchesUnknownKey() throws {
    let text = try renderedConfig()
    #expect(text.contains("borrowFraction = 0.3\n"), "fixture drifted: no workspace borrowFraction")
    let typo = text.replacingOccurrences(of: "borrowFraction = 0.3\n", with: "borrowFractoin = 0.3\n")
    let problems = ConfigValidator.problems(in: typo)
    #expect(
      problems.contains { $0.contains("borrowFractoin") && $0.contains("did you mean borrowFraction?") },
      "expected an unknown-key problem; got \(problems)"
    )
  }

  @Test("catches a misspelled settings key, which Tatami drops without a word")
  func catchesUnknownSettingsKey() throws {
    let text = try renderedConfig()
    #expect(text.contains("gapInner = 10"), "fixture drifted: no gapInner")
    let typo = text.replacingOccurrences(of: "gapInner = 10", with: "gapInnner = 10")
    let problems = ConfigValidator.problems(in: typo)
    #expect(problems.contains { $0.contains("settings.layout.gapInnner") }, "got \(problems)")
  }

  /// `[[floatingApps]]` is a decode-only migration table and a bare `floating`
  /// bool is the pre-1.4 spelling of `layout`. Both still decode, so calling
  /// them unknown would refuse a config Tatami reads fine.
  @Test("does not call Tatami's legacy keys unknown")
  func toleratesLegacyKeys() {
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
  @Test("catches an autoOpen Tatami would silently read as false")
  func catchesUnusableAutoOpen() throws {
    let text = try renderedConfig()
    #expect(text.contains("autoOpen = true\n"), "fixture drifted: no autoOpen rows")

    let quoted = text.replacingOccurrences(of: "autoOpen = true", with: "autoOpen = \"true\"")
    #expect(ConfigValidator.problems(in: quoted).contains { $0.contains("autoOpen must be a bare true/false") })

    let removed = text.replacingOccurrences(of: "autoOpen = true\n", with: "")
    let report = ConfigValidator.report(removed)
    #expect(report.problems.contains { $0.contains("has no autoOpen") })
    #expect(report.warnings.contains { $0.contains("none with autoOpen = true") })
  }

  /// `HotKey.init(parsing:)` takes all three spellings. Rejecting one would
  /// block `democtl seed` on a config Tatami would have accepted, which is
  /// worse than not checking at all.
  @Test(
    "accepts every shortcut spelling Tatami's parser accepts",
    arguments: [
      ("cycleNextWindow = \"alt - tab\"", "cycleNextWindow = \"alt-tab\""),
      ("focusLeft = \"ctrl + alt - h\"", "focusLeft = \"ctrl-alt-h\""),
      ("focusDown = \"ctrl + alt - j\"", "focusDown = \"fn + ctrl + alt - j\""),
      ("balance = \"ctrl + alt - e\"", "balance = \"ctrl+alt+e\""),
    ]
  )
  func acceptsLooserShortcutSpellings(original: String, rewritten: String) throws {
    let text = try renderedConfig()
    #expect(text.contains(original), "fixture drifted: \(original)")
    let report = ConfigValidator.report(text.replacingOccurrences(of: original, with: rewritten))
    #expect(report.problems.isEmpty, "problems: \(report.problems)")
  }

  /// Tatami resolves the pin against workspace ∪ shared ∪ borrowed apps, so
  /// pinning the shared Monitor is legal and refusing it would block the seed.
  @Test("accepts a shared app as a workspace's focus pin")
  func acceptsSharedAppFocusPin() throws {
    let text = try renderedConfig().replacingOccurrences(
      of: "appToFocusBundleId = \"dev.PangMo5.DemoLab.Chat\"",
      with: "appToFocusBundleId = \"dev.PangMo5.DemoLab.Monitor\""
    )
    let report = ConfigValidator.report(text)
    #expect(report.problems.isEmpty, "problems: \(report.problems)")
    #expect(report.warnings.contains { $0.contains("pins the shared app") })
  }

  @Test("still rejects a focus pin that is neither a member nor shared")
  func rejectsStrayFocusPin() throws {
    let text = try renderedConfig().replacingOccurrences(
      // Editor is a real Demo Lab app, so this exercises the stray-pin rule on
      // its own rather than also tripping the unknown-bundle warning.
      of: "appToFocusBundleId = \"dev.PangMo5.DemoLab.Chat\"",
      with: "appToFocusBundleId = \"dev.PangMo5.DemoLab.Editor\""
    )
    let problems = ConfigValidator.problems(in: text)
    #expect(problems.contains { $0.contains("neither one of its apps nor a shared app") }, "got \(problems)")
  }

  @Test("accepts an empty settings table without inventing problems")
  func toleratesMinimalConfig() {
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

// MARK: - TomlLite

@Suite("TomlLite")
struct TomlLiteTests {

  @Test("attaches a sub-table array to the last parent element")
  func nestedTableArrays() throws {
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

  @Test("reads multi-line arrays, comments, escapes and inline tables")
  func scalarsAndArrays() throws {
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

  @Test("rejects malformed input instead of guessing")
  func rejectsGarbage() {
    #expect(throws: TomlLiteError.self) { try TomlLite.parse("[unterminated") }
    #expect(throws: TomlLiteError.self) { try TomlLite.parse("novalue") }
  }

}
