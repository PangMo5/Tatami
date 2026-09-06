// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import DemoAppKit
import Foundation

// MARK: - ConfigReport

public struct ConfigReport: Sendable {

  // MARK: Lifecycle

  public init(problems: [String], warnings: [String]) {
    self.problems = problems
    self.warnings = warnings
  }

  // MARK: Public

  /// Things that would make Tatami reject the file, or silently ignore a value
  /// the demo depends on.
  public let problems: [String]
  /// Things that are legal but probably not what the author meant.
  public let warnings: [String]

  public var isClean: Bool { problems.isEmpty }

}

// MARK: - TableSchema

/// The key names one TOML table accepts, plus the shape of the tables nested
/// inside it. `tables` are `[a.b]` sub-tables, `tableArrays` are `[[a.b]]`.
private struct TableSchema {

  // MARK: Lifecycle

  init(
    keys: Set<String> = [],
    tables: [String: TableSchema] = [:],
    tableArrays: [String: TableSchema] = [:]
  ) {
    self.keys = keys
    self.tables = tables
    self.tableArrays = tableArrays
  }

  // MARK: Internal

  let keys: Set<String>
  let tables: [String: TableSchema]
  let tableArrays: [String: TableSchema]

}

// MARK: - ConfigValidator

/// Checks a rendered `config.toml` against what Tatami's decoder actually does.
///
/// This exists because of one asymmetry in Tatami: some mistakes reject the
/// whole file loudly, while others — a misspelled key name, a misspelled
/// `layout`, an unknown `autoBalance`, a missing `borrowDefaultEdge`, a bad
/// `displayCount`, a quoted `autoOpen` — are **silently defaulted with no
/// banner, no log line, and no CLI signal**. In a recording lab that is the
/// worst possible failure: the demo runs, looks almost right, and differs from
/// the previous take for no visible reason.
///
/// The rules encoded here were read out of Tatami's decoder and domain types,
/// not inferred from the documentation. A rule that is too strict is just as
/// bad as a missing one: `ConfigRenderer.write` throws on any problem, so a
/// false rejection blocks `democtl seed` on config Tatami would have accepted.
public enum ConfigValidator {

  // MARK: Public

  public static let workspaceKinds: Set<String> = ["normal", "scratchpad"]
  public static let layoutModes: Set<String> = ["tiled", "floating", "unmanaged"]
  public static let borrowEdges: Set<String> = ["top", "bottom", "left", "right"]
  public static let autoBalanceModes: Set<String> = ["none", "horizontal", "vertical", "both"]
  public static let splitTypes: Set<String> = ["auto", "horizontal", "vertical"]
  public static let windowPlacements: Set<String> = ["first", "second"]
  public static let hudPositions: Set<String> = [
    "topLeading", "top", "topTrailing", "leading", "center", "trailing",
    "bottomLeading", "bottom", "bottomTrailing",
  ]
  public static let hudSizes: Set<String> = ["small", "default", "large"]
  public static let markerCorners: Set<String> = [
    "topLeading", "topTrailing", "bottomLeading", "bottomTrailing",
  ]
  public static let checkIntervals: Set<String> = ["hourly", "daily", "weekly"]
  /// Only `none` is lowercase. `None` fails and falls back with a banner.
  public static let ffmDisableHotkeys: Set<String> = ["none", "Alt", "Cmd", "Ctrl", "Shift"]
  public static let hookEvents: Set<String> = [
    "tatamiLaunched", "profileChanged", "workspaceActivated", "hud",
  ]
  public static let modifierTokens: Set<String> = ["ctrl", "alt", "shift", "cmd"]

  /// Exactly the key names Tatami's shortcut parser accepts. Anything else
  /// leaves the action unbound (with a Problem banner, which nobody is watching
  /// during a take).
  public static let keyNames: Set<String> = {
    var names = Set<String>()
    for scalar in UnicodeScalar("a").value...UnicodeScalar("z").value {
      names.insert(String(UnicodeScalar(scalar)!))
    }
    for digit in 0...9 { names.insert(String(digit)) }
    names.formUnion(["`", "-", "=", "[", "]", "\\", ";", "'", ",", ".", "/"])
    names.formUnion([
      "return", "enter", "tab", "space", "delete", "escape", "help", "home", "end",
      "pageup", "pagedown", "forwarddelete", "left", "right", "up", "down",
    ])
    for index in 1...13 { names.insert("f\(index)") }
    names.formUnion(["esc", "backspace", "del", "spacebar", "pgup", "pgdn"])
    return names
  }()

  public static func problems(in text: String) -> [String] {
    report(text).problems
  }

  public static func report(_ text: String) -> ConfigReport {
    var problems = [String]()
    var warnings = [String]()

    let root: [String: TomlValue]
    do {
      root = try TomlLite.parse(text)
    } catch {
      return ConfigReport(problems: ["config is not parseable TOML: \(error)"], warnings: [])
    }

    checkUnknownKeys(root, against: configSchema, path: "", into: &problems)
    checkSettings(root["settings"], problems: &problems, warnings: &warnings)
    checkSharedApps(root["sharedApps"], problems: &problems, warnings: &warnings)
    checkHooks(root["hooks"], problems: &problems)

    let globalBorrowEdge = root["settings"]?["switching"]?["borrowDefaultEdge"]?.stringValue
    // Tatami resolves a workspace's focus pin against its own apps *and* the
    // shared apps, so the shared set has to reach the workspace check.
    let sharedBundleIdentifiers = Set(
      (root["sharedApps"]?.tableArray ?? []).compactMap { $0["bundleIdentifier"]?.stringValue }
    )
    checkProfiles(
      root["profiles"],
      globalBorrowEdge: globalBorrowEdge,
      sharedBundleIdentifiers: sharedBundleIdentifiers,
      problems: &problems,
      warnings: &warnings
    )

    return ConfigReport(problems: problems, warnings: warnings)
  }

  // MARK: Private

  private static let knownBundleIdentifiers = Set(DemoCatalog.all.map(\.bundleIdentifier))

  /// Every coding key of `AppSettings.Shortcuts`, including the six explicit
  /// assign/borrow overrides the template does not use.
  private static let shortcutKeys: Set<String> = [
    "focusLeft", "focusRight", "focusUp", "focusDown",
    "switchToNextWorkspace", "switchToPreviousWorkspace", "switchToRecentWorkspace",
    "moveToNextWorkspace", "moveToPreviousWorkspace",
    "focusNextDisplay", "focusPreviousDisplay",
    "cycleNextWindow", "cyclePreviousWindow",
    "resizeGrow", "resizeShrink",
    "swapLeft", "swapRight", "swapUp", "swapDown",
    "toggleOrientation", "toggleFullscreen", "balance",
    "toggleFloating", "toggleSharedFloating", "toggleSpaceActivated",
    "toggleFocusedAppInActiveWorkspace", "toggleAppInSharedApps",
    "keyEquivalentModifiers", "assignModifiers", "borrowModifiers",
    "recentWorkspaceKey", "nextWorkspaceKey", "previousWorkspaceKey",
    "assignRecentWorkspace", "assignNextWorkspace", "assignPreviousWorkspace",
    "borrowRecentWorkspace", "borrowNextWorkspace", "borrowPreviousWorkspace",
    "dismissBorrow",
  ]

  private static let gestureBindingsSchema = TableSchema(keys: ["left", "right", "up", "down"])

  /// `AppAssignment` and `SharedApp` share a key set. `floating` is the pre-1.4
  /// Bool that `layout` replaced and still decodes, so it is not a typo.
  private static let appSchema = TableSchema(
    keys: ["bundleIdentifier", "name", "iconPath", "autoOpen", "layout", "floating"]
  )

  private static let settingsSchema = TableSchema(
    tables: [
      "general": TableSchema(keys: [
        "launchAtLogin", "checkForUpdatesAutomatically", "checkInterval", "debugLogging",
      ]),
      "visibility": TableSchema(keys: ["overlayAwareApps"]),
      "menuBar": TableSchema(keys: [
        "showWorkspaceIcon", "showWorkspaceName", "showProfileIcon", "showProfileName",
      ]),
      "hud": TableSchema(keys: [
        "enabled", "workspaceSwitch", "windowCycle", "profileSwitch", "floating", "appMembership",
        "tilingPaused", "fullscreen", "layout", "borrow", "position", "size", "durationMs",
      ]),
      "marker": TableSchema(keys: [
        "floatingEnabled", "floatingColorHex", "fullscreenEnabled", "fullscreenColorHex",
        "borrowEnabled", "borrowColorHex", "size", "corner", "hideOnHover",
      ]),
      "layout": TableSchema(keys: [
        "gapInner", "gapOuter", "autoBalance", "splitType", "windowPlacement",
      ]),
      "focus": TableSchema(keys: [
        "mouseFollowsFocus", "mouseHidesOnFocus", "focusFollowsMouse",
        "focusFollowsMouseDisableHotkey", "focusFollowsMouseIgnoreFullscreen", "refocusOnClose",
      ]),
      "switching": TableSchema(keys: [
        "loop", "skipEmpty", "followAppFocus", "cycleAcrossDisplays", "recentAcrossDisplays",
        "switchToRecentWhenEmpty", "cycleSameAppWindows", "includeSharedAppsInWindowSwitcher",
        "toggleBorrowOnRepeat", "borrowDefaultEdge", "borrowFraction",
      ]),
      "gestures": TableSchema(
        // `fingerCount` and `sensitivity` are decode-only survivors of older builds.
        keys: ["enabled", "threshold", "fingerCount", "sensitivity"],
        tables: ["threeFinger": gestureBindingsSchema, "fourFinger": gestureBindingsSchema]
      ),
      "shortcuts": TableSchema(keys: shortcutKeys),
    ]
  )

  private static let workspaceSchema = TableSchema(
    keys: [
      "id", "name", "displayHint", "activateShortcut", "assignAppShortcut", "symbolIconName",
      "appToFocusBundleId", "kind", "keyEquivalent", "borrowShortcut", "borrowEdge", "borrowFraction",
    ],
    tableArrays: ["apps": appSchema]
  )

  private static let profileSchema = TableSchema(
    keys: ["id", "name", "symbolIconName", "shortcut"],
    tables: [
      "autoActivation": TableSchema(keys: [
        "whenConnectedMatch", "whenConnected", "whenDisconnected", "displayCount",
      ]),
    ],
    tableArrays: [
      "workspaces": workspaceSchema,
      "workspaceChains": TableSchema(keys: ["id", "name", "workspaceIds", "dynamicWorkspaceIds"]),
    ]
  )

  /// Exactly the keys Tatami's decoders read, table by table.
  ///
  /// Copied from the `CodingKeys` of `AppConfig`, `AppSettings`, `Profile`,
  /// `Workspace`, `AppAssignment`, `SharedApp`, `HookDefinition`,
  /// `WorkspaceChain` and `ProfileActivation` — decode-only legacy keys
  /// included, so an older hand-written config is not called broken.
  ///
  /// `activeProfileId` is deliberately absent: Tatami never decodes it from
  /// config.toml (it lives in ProfileSessionStore), so writing it here would
  /// do nothing.
  private static let configSchema = TableSchema(
    tables: ["settings": settingsSchema],
    tableArrays: [
      "profiles": profileSchema,
      "sharedApps": appSchema,
      "hooks": TableSchema(keys: [
        "id", "event", "enabled", "command", "timeoutMs", "workingDirectory", "environment",
      ]),
      // Pre-1.4 shape, decoded once and migrated into `sharedApps`.
      "floatingApps": TableSchema(keys: ["bundleIdentifier", "name", "iconPath"]),
    ]
  )

  /// Reports a key name Tatami's decoders do not contain.
  ///
  /// Every other rule in this file inspects a *value*; this is the only one
  /// that can catch a misspelled *key*. Tatami decodes into typed models and
  /// never looks at a key it does not name, so `borrowFractoin` costs the whole
  /// setting with no banner, no log line and no CLI signal.
  private static func checkUnknownKeys(
    _ table: [String: TomlValue],
    against schema: TableSchema,
    path: String,
    into problems: inout [String]
  ) {
    for key in table.keys.sorted() {
      let keyPath = path.isEmpty ? key : "\(path).\(key)"
      if let nested = schema.tables[key] {
        if let child = table[key]?.tableValue {
          checkUnknownKeys(child, against: nested, path: keyPath, into: &problems)
        }
        continue
      }
      if let element = schema.tableArrays[key] {
        for (index, row) in (table[key]?.tableArray ?? []).enumerated() {
          checkUnknownKeys(row, against: element, path: "\(keyPath)[\(index)]", into: &problems)
        }
        continue
      }
      guard !schema.keys.contains(key) else { continue }
      let known = schema.keys.union(schema.tables.keys).union(schema.tableArrays.keys)
      let hint = nearestKey(to: key, in: known).map { " (did you mean \($0)?)" } ?? ""
      problems.append(
        "\(keyPath) is not a key Tatami decodes\(hint); it is dropped in silence, so whatever it was "
          + "meant to configure keeps its default"
      )
    }
  }

  /// A deliberately cheap "did you mean": the same letters in a different order
  /// or a different case. Those are the two typos that actually get made, and a
  /// wrong guess here would be worse than none.
  private static func nearestKey(to key: String, in known: Set<String>) -> String? {
    let fingerprint = key.lowercased().sorted()
    return known.sorted().first { $0.lowercased().sorted() == fingerprint }
  }

  private static func checkEnum(
    _ value: TomlValue?,
    _ allowed: Set<String>,
    _ path: String,
    into problems: inout [String]
  ) {
    guard let value else { return }
    guard let raw = value.stringValue else {
      problems.append("\(path) must be a string")
      return
    }
    guard allowed.contains(raw) else {
      problems.append("\(path) = \"\(raw)\" is not one of \(allowed.sorted().joined(separator: ", "))")
      return
    }
  }

  /// `autoOpen` is the one app-row key that neither reports nor rejects a bad
  /// value: both `AppAssignment` and `SharedApp` decode it with a bare `try?`,
  /// so `autoOpen = "true"` and a missing key both mean "do not open" with no
  /// banner anywhere. Every scene relies on activation bringing its apps up, so
  /// the take would be of an empty desktop while every step reports success.
  private static func checkAutoOpen(
    _ row: [String: TomlValue],
    _ path: String,
    requirePresence: Bool = true,
    into problems: inout [String]
  ) {
    guard let value = row["autoOpen"] else {
      if requirePresence {
        problems.append(
          "\(path) has no autoOpen, so it decodes to false and activating its workspace opens nothing"
        )
      }
      return
    }
    if value.boolValue == nil {
      problems.append(
        "\(path).autoOpen must be a bare true/false; a quoted or numeric value is silently decoded as false"
      )
    }
  }

  private static func checkSettings(
    _ settings: TomlValue?,
    problems: inout [String],
    warnings: inout [String]
  ) {
    guard let settings else {
      warnings.append("no [settings] table; every setting falls back to its default")
      return
    }

    checkEnum(settings["general"]?["checkInterval"], checkIntervals, "settings.general.checkInterval", into: &problems)

    let layout = settings["layout"]
    checkEnum(layout?["autoBalance"], autoBalanceModes, "settings.layout.autoBalance", into: &problems)
    checkEnum(layout?["splitType"], splitTypes, "settings.layout.splitType", into: &problems)
    checkEnum(layout?["windowPlacement"], windowPlacements, "settings.layout.windowPlacement", into: &problems)
    for key in ["gapInner", "gapOuter"] {
      if let gap = layout?[key]?.intValue, !(0...100).contains(gap) {
        warnings.append("settings.layout.\(key) = \(gap) is outside the range the app's UI offers (0...100)")
      }
    }

    let hud = settings["hud"]
    checkEnum(hud?["position"], hudPositions, "settings.hud.position", into: &problems)
    checkEnum(hud?["size"], hudSizes, "settings.hud.size", into: &problems)
    if let duration = hud?["durationMs"]?.intValue, !(300...3000).contains(duration) {
      // Not range-checked at decode time, so an absurd value is accepted and
      // then leaves feedback on screen for the whole take.
      warnings.append("settings.hud.durationMs = \(duration) is outside the app's 300...3000 range")
    }

    checkEnum(
      settings["focus"]?["focusFollowsMouseDisableHotkey"],
      ffmDisableHotkeys,
      "settings.focus.focusFollowsMouseDisableHotkey",
      into: &problems
    )

    checkEnum(settings["marker"]?["corner"], markerCorners, "settings.marker.corner", into: &problems)

    let switching = settings["switching"]
    if let edge = switching?["borrowDefaultEdge"] {
      checkEnum(edge, borrowEdges, "settings.switching.borrowDefaultEdge", into: &problems)
    } else {
      problems.append(
        """
        settings.switching.borrowDefaultEdge is missing. Without it (and without a per-workspace \
        borrowEdge) a CLI borrow arms a keyboard-only direction picker that silently cancels itself \
        after 5 seconds, so every scripted Borrow would appear to do nothing.
        """
      )
    }
    if let fraction = switching?["borrowFraction"]?.doubleValue, !(0.1...0.9).contains(fraction) {
      problems.append("settings.switching.borrowFraction = \(fraction) is outside 0.1...0.9 and is never clamped")
    }

    checkShortcuts(settings["shortcuts"], problems: &problems)
  }

  private static func checkShortcuts(_ shortcuts: TomlValue?, problems: inout [String]) {
    guard let shortcuts, let table = shortcuts.tableValue else { return }

    for key in ["keyEquivalentModifiers", "assignModifiers", "borrowModifiers"] {
      guard let value = table[key] else {
        problems.append(
          "settings.shortcuts.\(key) is missing; a hand-authored config falls back to the decode "
            + "default, not the recommended set a fresh install gets"
        )
        continue
      }
      guard let tokens = value.stringArray else {
        problems.append("settings.shortcuts.\(key) must be an array of strings")
        continue
      }
      let unknown = tokens.filter { !modifierTokens.contains($0) }
      if !unknown.isEmpty {
        problems.append("settings.shortcuts.\(key) has unknown modifiers: \(unknown.joined(separator: ", "))")
      }
      if tokens.isEmpty {
        problems.append("settings.shortcuts.\(key) is empty, which disables that whole action")
      }
    }

    for key in ["recentWorkspaceKey", "nextWorkspaceKey", "previousWorkspaceKey"] {
      guard let name = table[key]?.stringValue else { continue }
      if !keyNames.contains(name.lowercased()) {
        problems.append("settings.shortcuts.\(key) = \"\(name)\" is not a key name Tatami knows")
      }
    }

    let modifierArrays = ["keyEquivalentModifiers", "assignModifiers", "borrowModifiers"]
    let navigationKeys = ["recentWorkspaceKey", "nextWorkspaceKey", "previousWorkspaceKey"]
    for (key, value) in table {
      guard !modifierArrays.contains(key), !navigationKeys.contains(key) else { continue }
      guard let raw = value.stringValue else {
        problems.append("settings.shortcuts.\(key) must be a shortcut string")
        continue
      }
      if let issue = shortcutProblem(raw) {
        problems.append("settings.shortcuts.\(key) = \"\(raw)\": \(issue)")
      }
    }
  }

  /// Mirrors all three separator forms of `HotKey.init(parsing:)`: the padded
  /// ` - `, the unpadded trailing dash, and the `+`-only form.
  ///
  /// Both directions of a mismatch are expensive. A missed typo leaves an
  /// action unbound mid-take; a spelling this rejects but Tatami accepts blocks
  /// `democtl seed` entirely, because any problem throws before the config is
  /// written.
  private static func shortcutProblem(_ raw: String) -> String? {
    let text = raw.lowercased().trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return "empty" }

    var modifiers = [String]()
    var keyName = text

    if let separator = text.range(of: " - ", options: .backwards) {
      modifiers = splitModifiers(String(text[text.startIndex..<separator.lowerBound]))
      keyName = String(text[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
    } else if
      let separator = text.range(of: "-", options: .backwards),
      separator.lowerBound != text.startIndex,
      separator.upperBound != text.endIndex
    {
      // Tatami's looser unpadded form ("alt-tab", "ctrl-alt-h"), guarded exactly
      // as HotKey guards it so a literal `-` key still parses. The order of the
      // three branches matters: it is what makes "ctrl-alt+h" fail here for the
      // same reason it fails there.
      modifiers = splitModifiers(String(text[text.startIndex..<separator.lowerBound]))
      keyName = String(text[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
    } else if text.contains("+") {
      var parts = text.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
      // `"+"` alone splits to nothing; `removeLast()` on that would trap.
      guard !parts.isEmpty else { return "empty" }
      keyName = parts.removeLast()
      modifiers = splitModifiers(parts.joined(separator: "+"))
    }

    let aliases: [String: String] = [
      "command": "cmd", "opt": "alt", "option": "alt", "control": "ctrl",
      "⌘": "cmd", "⇧": "shift", "⌥": "alt", "⌃": "ctrl",
    ]
    let unknownModifiers = modifiers
      .map { aliases[$0] ?? $0 }
      .filter { !modifierTokens.contains($0) && !$0.isEmpty && $0 != "fn" }
    if !unknownModifiers.isEmpty {
      return "unknown modifier(s) \(unknownModifiers.joined(separator: ", ")) — Tatami drops these silently"
    }

    guard keyNames.contains(keyName) else { return "unknown key \"\(keyName)\"" }
    return nil
  }

  /// Tatami splits the modifier part on both `+` and `-`, so "ctrl-alt - h" and
  /// "ctrl+alt+h" name the same combo.
  private static func splitModifiers(_ part: String) -> [String] {
    part
      .split(whereSeparator: { $0 == "+" || $0 == "-" })
      .map { $0.trimmingCharacters(in: .whitespaces) }
  }

  private static func checkSharedApps(
    _ shared: TomlValue?,
    problems: inout [String],
    warnings: inout [String]
  ) {
    guard let rows = shared?.tableArray else { return }
    for (index, row) in rows.enumerated() {
      let label = "sharedApps[\(index)]"
      guard let bundleIdentifier = row["bundleIdentifier"]?.stringValue, !bundleIdentifier.isEmpty else {
        problems.append("\(label) has no bundleIdentifier")
        continue
      }
      if row["name"]?.stringValue == nil { problems.append("\(label) has no name") }
      checkAutoOpen(row, label, into: &problems)
      checkEnum(row["layout"], layoutModes, "\(label).layout", into: &problems)
      if !knownBundleIdentifiers.contains(bundleIdentifier) {
        warnings.append("\(label) references \(bundleIdentifier), which is not a Demo Lab app")
      }
    }
  }

  private static func checkHooks(_ hooks: TomlValue?, problems: inout [String]) {
    guard let rows = hooks?.tableArray else { return }
    var seen = Set<String>()
    for (index, row) in rows.enumerated() {
      let label = "hooks[\(index)]"
      guard let identifier = row["id"]?.stringValue, !identifier.isEmpty else {
        problems.append("\(label) has no id")
        continue
      }
      if !seen.insert(identifier).inserted { problems.append("\(label) reuses hook id \(identifier)") }
      if identifier.count > 64 { problems.append("\(label) id is longer than 64 characters") }
      let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
      if identifier.unicodeScalars.contains(where: { !allowed.contains($0) }) {
        problems.append("\(label) id may only use ASCII letters, digits, '.', '_' and '-'")
      }
      checkEnum(row["event"], hookEvents, "\(label).event", into: &problems)
      guard let command = row["command"]?.stringArray, let executable = command.first,
            !executable.isEmpty
      else {
        problems.append("\(label).command must be a non-empty array of strings")
        continue
      }
      if !FileManager.default.isExecutableFile(atPath: executable) {
        problems.append("\(label).command[0] is not an executable file: \(executable)")
      }
      if let timeout = row["timeoutMs"]?.intValue, !(100...300_000).contains(timeout) {
        problems.append("\(label).timeoutMs = \(timeout) is outside 100...300000")
      }
    }
  }

  private static func checkProfiles(
    _ profiles: TomlValue?,
    globalBorrowEdge: String?,
    sharedBundleIdentifiers: Set<String>,
    problems: inout [String],
    warnings: inout [String]
  ) {
    guard let rows = profiles?.tableArray, !rows.isEmpty else {
      problems.append("[[profiles]] is missing or empty")
      return
    }

    var allWorkspaceIDs = Set<String>()
    var profileIDs = Set<String>()

    for (index, profile) in rows.enumerated() {
      let name = profile["name"]?.stringValue ?? "profiles[\(index)]"
      let label = "profile \"\(name)\""

      guard let identifier = profile["id"]?.stringValue, UUID(uuidString: identifier) != nil else {
        problems.append("\(label) has a missing or malformed id (a bad id rejects the whole file)")
        continue
      }
      if !profileIDs.insert(identifier).inserted { problems.append("\(label) reuses profile id \(identifier)") }
      if profile["name"]?.stringValue == nil { problems.append("profiles[\(index)] has no name") }

      if let shortcut = profile["shortcut"]?.stringValue, let issue = shortcutProblem(shortcut) {
        // A profile shortcut is decoded with a hard `try`: a bad one rejects
        // the entire config rather than degrading.
        problems.append("\(label).shortcut = \"\(shortcut)\": \(issue) — this rejects the whole file")
      }

      checkAutoActivation(profile["autoActivation"], label: label, problems: &problems, warnings: &warnings)

      guard let workspaces = profile["workspaces"]?.tableArray else {
        problems.append("\(label) has no [[profiles.workspaces]] (a profile without workspaces rejects the file)")
        continue
      }

      var workspaceIDsInProfile = Set<String>()
      var scratchpadIDs = Set<String>()
      var keyEquivalents = [String: String]()

      for (position, workspace) in workspaces.enumerated() {
        let workspaceName = workspace["name"]?.stringValue ?? "workspaces[\(position)]"
        let workspaceLabel = "\(label) / workspace \"\(workspaceName)\""

        guard let workspaceID = workspace["id"]?.stringValue, UUID(uuidString: workspaceID) != nil else {
          problems.append("\(workspaceLabel) has a missing or malformed id")
          continue
        }
        if !workspaceIDsInProfile.insert(workspaceID).inserted {
          problems.append("\(workspaceLabel) duplicates a workspace id inside its profile — this rejects the whole file")
        }
        if !allWorkspaceIDs.insert(workspaceID).inserted {
          problems.append("\(workspaceLabel) reuses a workspace id from another profile; ids must be globally unique")
        }
        if workspace["name"]?.stringValue == nil { problems.append("\(workspaceLabel) has no name") }

        checkEnum(workspace["kind"], workspaceKinds, "\(workspaceLabel).kind", into: &problems)
        let kind = workspace["kind"]?.stringValue ?? "normal"
        if kind == "scratchpad" { scratchpadIDs.insert(workspaceID) }

        if let edge = workspace["borrowEdge"] {
          checkEnum(edge, borrowEdges, "\(workspaceLabel).borrowEdge", into: &problems)
        }
        if let fraction = workspace["borrowFraction"]?.doubleValue, !(0.1...0.9).contains(fraction) {
          problems.append("\(workspaceLabel).borrowFraction = \(fraction) is outside 0.1...0.9 and is never clamped")
        }
        if kind == "scratchpad", workspace["borrowEdge"]?.stringValue == nil, globalBorrowEdge == nil {
          problems.append(
            "\(workspaceLabel) is a scratchpad with no borrowEdge and no settings.switching.borrowDefaultEdge, "
              + "so summoning it would wait for a keystroke and then cancel"
          )
        }

        for key in ["activateShortcut", "assignAppShortcut", "borrowShortcut"] {
          guard let shortcut = workspace[key]?.stringValue else { continue }
          if let issue = shortcutProblem(shortcut) {
            problems.append("\(workspaceLabel).\(key) = \"\(shortcut)\": \(issue) — this rejects the whole file")
          }
        }

        if let equivalent = workspace["keyEquivalent"]?.stringValue {
          if !keyNames.contains(equivalent.lowercased()) {
            problems.append("\(workspaceLabel).keyEquivalent = \"\(equivalent)\" is not a key name Tatami knows")
          }
          if let previous = keyEquivalents.updateValue(workspaceName, forKey: equivalent.lowercased()) {
            problems.append("\(label) uses key equivalent \"\(equivalent)\" for both \(previous) and \(workspaceName)")
          }
        }

        if let hint = workspace["displayHint"]?.stringValue {
          if hint.hasPrefix("::") {
            problems.append("\(workspaceLabel).displayHint starts with '::', which yields an empty UUID that can never match")
          } else if hint.contains("::") {
            warnings.append("\(workspaceLabel).displayHint pins to a specific machine's display and will not resolve elsewhere")
          }
        }

        let apps = workspace["apps"]?.tableArray ?? []
        var bundleIdentifiers = Set<String>()
        var opensAnApp = false
        for (appIndex, app) in apps.enumerated() {
          let appLabel = "\(workspaceLabel) / apps[\(appIndex)]"
          guard let bundleIdentifier = app["bundleIdentifier"]?.stringValue, !bundleIdentifier.isEmpty else {
            problems.append("\(appLabel) has no bundleIdentifier")
            continue
          }
          bundleIdentifiers.insert(bundleIdentifier)
          if app["name"]?.stringValue == nil { problems.append("\(appLabel) has no name") }
          // A borrow forces autoOpen on a scratchpad's apps, so only the type
          // matters there.
          checkAutoOpen(app, appLabel, requirePresence: kind != "scratchpad", into: &problems)
          if app["autoOpen"]?.boolValue == true { opensAnApp = true }
          checkEnum(app["layout"], layoutModes, "\(appLabel).layout", into: &problems)
          if !knownBundleIdentifiers.contains(bundleIdentifier) {
            warnings.append("\(appLabel) references \(bundleIdentifier), which is not a Demo Lab app")
          }
        }

        if !apps.isEmpty, !opensAnApp, kind != "scratchpad" {
          warnings.append(
            "\(workspaceLabel) has apps but none with autoOpen = true, so activating it opens nothing"
          )
        }

        // Tatami resolves the pin against workspace ∪ shared ∪ borrowed apps
        // (WorkspaceManagerClient's `keepVisible`), so a shared app such as
        // Pulse is a legitimate focus target. Only an id in neither set
        // silently falls back to most-recently-used, which is exactly the kind
        // of drift between takes this lab exists to prevent.
        if
          let focus = workspace["appToFocusBundleId"]?.stringValue,
          !bundleIdentifiers.contains(focus),
          !sharedBundleIdentifiers.contains(focus)
        {
          problems.append(
            "\(workspaceLabel).appToFocusBundleId = \(focus) is neither one of its apps nor a shared app, "
              + "so it has no effect"
          )
        } else if
          let focus = workspace["appToFocusBundleId"]?.stringValue,
          !bundleIdentifiers.contains(focus)
        {
          warnings.append(
            "\(workspaceLabel).appToFocusBundleId pins the shared app \(focus); Tatami honours it at "
              + "activation, but its Focus app picker only lists the workspace's own apps and "
              + "duplicating the workspace clears the pin"
          )
        }
      }

      checkChains(
        profile["workspaceChains"],
        label: label,
        workspaceIDs: workspaceIDsInProfile,
        scratchpadIDs: scratchpadIDs,
        problems: &problems
      )
    }
  }

  private static func checkAutoActivation(
    _ activation: TomlValue?,
    label: String,
    problems: inout [String],
    warnings: inout [String]
  ) {
    guard let activation, let table = activation.tableValue else { return }

    if let count = table["displayCount"] {
      guard let raw = count.stringValue else {
        // Decoded with `try?` against a String: an integer is dropped without a
        // trace and the rule quietly becomes "no display-count condition".
        problems.append("\(label).autoActivation.displayCount must be a STRING like \"==1\" or \">=2\"")
        return
      }
      let pattern = try? NSRegularExpression(pattern: "^\\s*(==|>=|<=)?\\s*\\d+\\s*$")
      let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
      if pattern?.firstMatch(in: raw, range: range) == nil {
        problems.append("\(label).autoActivation.displayCount = \"\(raw)\" is not \"==N\", \">=N\", \"<=N\" or \"N\"")
      }
    }

    if let match = table["whenConnectedMatch"]?.stringValue, match != "exactly", match != "contains" {
      // Only the literal "exactly" is special; anything else means "contains",
      // including a typo of "exactly".
      problems.append("\(label).autoActivation.whenConnectedMatch = \"\(match)\" silently means \"contains\"")
    }

    if table["whenConnected"] != nil || table["whenDisconnected"] != nil {
      warnings.append("\(label).autoActivation names specific displays and will not match on another machine or in a VM")
    }
  }

  private static func checkChains(
    _ chains: TomlValue?,
    label: String,
    workspaceIDs: Set<String>,
    scratchpadIDs: Set<String>,
    problems: inout [String]
  ) {
    guard let rows = chains?.tableArray else { return }
    var chainIDs = Set<String>()
    var claimed = [String: String]()

    for (index, chain) in rows.enumerated() {
      let name = chain["name"]?.stringValue ?? "workspaceChains[\(index)]"
      let chainLabel = "\(label) / chain \"\(name)\""

      guard let identifier = chain["id"]?.stringValue, UUID(uuidString: identifier) != nil else {
        problems.append("\(chainLabel) has a missing or malformed id")
        continue
      }
      if !chainIDs.insert(identifier).inserted { problems.append("\(chainLabel) reuses a chain id") }

      guard let members = chain["workspaceIds"]?.stringArray else {
        problems.append("\(chainLabel).workspaceIds must be an array of workspace ids")
        continue
      }
      // Any of these makes Tatami skip the entire chain at run time — silently,
      // as far as a script can tell.
      if members.count < 2 { problems.append("\(chainLabel) needs at least two members") }
      if Set(members).count != members.count { problems.append("\(chainLabel) lists a workspace twice") }

      for member in members {
        if !workspaceIDs.contains(member) {
          problems.append("\(chainLabel) references \(member), which is not a workspace in this profile")
        }
        if scratchpadIDs.contains(member) {
          problems.append("\(chainLabel) includes a scratchpad, which chains do not accept")
        }
        if let other = claimed.updateValue(name, forKey: member), other != name {
          problems.append("\(label): workspace \(member) is in both \"\(other)\" and \"\(name)\"; one chain each")
        }
      }

      if let dynamic = chain["dynamicWorkspaceIds"]?.stringArray {
        if Set(dynamic).count != dynamic.count { problems.append("\(chainLabel).dynamicWorkspaceIds has duplicates") }
        for entry in dynamic where !members.contains(entry) {
          problems.append("\(chainLabel).dynamicWorkspaceIds contains \(entry), which is not one of its members")
        }
      }
    }
  }

}
