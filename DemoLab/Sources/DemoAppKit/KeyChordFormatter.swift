// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - KeyChordFormatter

/// Turns a Tatami shortcut string into the keycaps a viewer recognises.
///
/// Scene files carry shortcuts in Tatami's own skhd spelling, the same text that
/// is in `config.toml`, so a scene never keeps a prettified copy in sync with
/// the binding it is demonstrating. Two very different renderers then have to
/// agree on what that text looks like: the live overlay draws each cap as a
/// rounded key, and the ASS sidecar writes them as one run of glyphs. They share
/// this so a burned take and a live take show the same thing. When they did not,
/// the sidecar printed a literal `ctrl + alt - l` under the overlay's `⌃⌥L`.
public enum KeyChordFormatter {

  // MARK: Public

  /// One string per cap, in canonical macOS modifier order.
  public static func caps(from chord: String) -> [String] {
    let text = chord.lowercased().trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return [] }

    var modifiers = [String]()
    var key = text
    // The separator is searched from the END, exactly as Tatami's parser does,
    // so a literal `-` key ("ctrl + alt - -") still resolves.
    if let separator = text.range(of: " - ", options: .backwards) {
      modifiers = text[text.startIndex..<separator.lowerBound]
        .split(separator: "+")
        .map { $0.trimmingCharacters(in: .whitespaces) }
      key = String(text[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
    } else if text.contains("+") {
      var parts = text.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
      key = parts.removeLast()
      modifiers = parts
    }

    let present = Set(modifiers.map(canonical))
    var caps = order.filter { present.contains($0) }.compactMap { modifierSymbols[$0] }
    caps.append(keySymbols[key] ?? key.uppercased())
    return caps
  }

  /// The same caps as one string, for a renderer that cannot draw separate keys.
  public static func display(from chord: String, separator: String = " ") -> String {
    caps(from: chord).joined(separator: separator)
  }

  // MARK: Private

  /// Canonical macOS order, so the caps read the way the keyboard is laid out
  /// rather than the order the config happened to list them in.
  private static let order = ["ctrl", "alt", "shift", "cmd"]

  private static let modifierSymbols: [String: String] = [
    "ctrl": "⌃", "alt": "⌥", "shift": "⇧", "cmd": "⌘",
  ]

  private static let keySymbols: [String: String] = [
    "return": "↩", "enter": "↩", "tab": "⇥", "space": "space", "delete": "⌫",
    "forwarddelete": "⌦", "escape": "⎋", "esc": "⎋",
    "left": "←", "right": "→", "up": "↑", "down": "↓",
    "pageup": "⇞", "pagedown": "⇟", "home": "↖", "end": "↘",
  ]

  private static func canonical(_ token: String) -> String {
    switch token {
    case "control": "ctrl"
    case "opt", "option": "alt"
    case "command": "cmd"
    case "⌃": "ctrl"
    case "⌥": "alt"
    case "⇧": "shift"
    case "⌘": "cmd"
    default: token
    }
  }

}
