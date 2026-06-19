import Dependencies
import Foundation
import Magnet

/// A persisted keyboard shortcut.
///
/// Serialized as a human-readable skhd-style string (e.g. `"ctrl + alt
/// - h"`, `"cmd - return"`) so the config stays legible. Decoding also
/// accepts the legacy `{ carbonKeyCode, carbonModifiers }` table form,
/// so older configs migrate automatically on the next save.
public struct HotKey: Hashable, Sendable {
  public var carbonKeyCode: Int
  public var carbonModifiers: Int

  public init(carbonKeyCode: Int, carbonModifiers: Int) {
    self.carbonKeyCode = carbonKeyCode
    self.carbonModifiers = carbonModifiers
  }
}

extension HotKey {
  public init(_ keyCombo: KeyCombo) {
    self.init(
      carbonKeyCode: keyCombo.QWERTYKeyCode,
      carbonModifiers: keyCombo.modifiers
    )
  }

  /// A Magnet `KeyCombo` for registering the global hotkey. Nil when the
  /// stored codes don't form a valid combo (Magnet validates the pair).
  public var keyCombo: KeyCombo? {
    KeyCombo(QWERTYKeyCode: carbonKeyCode, carbonModifiers: carbonModifiers)
  }
}

// MARK: - skhd-style string

extension HotKey {
  // Carbon modifier bit masks.
  static let cmd = 256
  static let shift = 512
  static let option = 2048
  static let control = 4096

  /// Carbon modifier mask from skhd-style tokens (`"ctrl"`, `"alt"`,
  /// `"shift"`, `"cmd"` and their aliases) — for settings that store a
  /// modifier combo without a key, like the workspace key-equivalent modifier.
  public static func carbonModifiers(from tokens: [String]) -> Int {
    var mods = 0
    for token in tokens {
      switch token.lowercased().trimmingCharacters(in: .whitespaces) {
      case "cmd", "command", "⌘": mods |= cmd
      case "shift", "⇧": mods |= shift
      case "alt", "opt", "option", "⌥": mods |= option
      case "ctrl", "control", "⌃": mods |= control
      default: break
      }
    }
    return mods
  }

  /// macOS glyphs (`⌃⌥⇧⌘`, in canonical order) for skhd modifier tokens —
  /// for showing the effective key-equivalent combo in settings.
  public static func modifierSymbols(from tokens: [String]) -> String {
    let mods = carbonModifiers(from: tokens)
    var out = ""
    if mods & control != 0 { out += "⌃" }
    if mods & option != 0 { out += "⌥" }
    if mods & shift != 0 { out += "⇧" }
    if mods & cmd != 0 { out += "⌘" }
    return out
  }

  /// skhd-style description: `"<mods joined by ' + '> - <key>"`.
  public var displayString: String {
    var mods: [String] = []
    if carbonModifiers & Self.control != 0 { mods.append("ctrl") }
    if carbonModifiers & Self.option != 0 { mods.append("alt") }
    if carbonModifiers & Self.shift != 0 { mods.append("shift") }
    if carbonModifiers & Self.cmd != 0 { mods.append("cmd") }
    let key = Self.keyCodeToName[carbonKeyCode]
      ?? "0x" + String(carbonKeyCode, radix: 16)
    return mods.isEmpty ? key : mods.joined(separator: " + ") + " - " + key
  }

  /// Parse a skhd-style string. Accepts `"ctrl + alt - h"` and the
  /// looser `"ctrl+alt+h"`. Returns nil on an unknown key/modifier.
  public init?(parsing raw: String) {
    let s = raw.lowercased().trimmingCharacters(in: .whitespaces)
    guard !s.isEmpty else { return nil }

    let modPart: String?
    let keyPart: String
    if let range = s.range(of: " - ", options: .backwards) {
      // Canonical `mods - key` (with spaces around the dash). The
      // padded match is unambiguous when the key is itself "-", e.g.
      // `"ctrl + alt - -"`, where a single-dash search would chop the
      // string after the trailing dash and leave keyPart empty.
      modPart = String(s[..<range.lowerBound])
      keyPart = String(s[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    } else if let range = s.range(of: "-", options: .backwards),
              s.distance(from: s.startIndex, to: range.lowerBound) > 0,
              range.upperBound != s.endIndex {
      // Looser unpadded form like `"cmd-h"` — but only when something
      // follows the dash (otherwise the dash IS the key) and isn't at
      // the very start (a leading dash would also be the key).
      modPart = String(s[..<range.lowerBound])
      keyPart = String(s[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    } else if s.contains("+") {
      // `ctrl+alt+h` / `ctrl+alt+-`: last token is the key, rest are
      // modifiers. `+` is never a key name so it's safe to split on.
      var tokens = s.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
      keyPart = tokens.removeLast()
      modPart = tokens.joined(separator: "+")
    } else {
      modPart = nil
      keyPart = s
    }

    var mods = 0
    if let modPart {
      for token in modPart.split(whereSeparator: { $0 == "+" || $0 == "-" }) {
        switch token.trimmingCharacters(in: .whitespaces) {
        case "cmd", "command", "⌘": mods |= Self.cmd
        case "shift", "⇧": mods |= Self.shift
        case "alt", "opt", "option", "⌥": mods |= Self.option
        case "ctrl", "control", "⌃": mods |= Self.control
        case "", "fn": break
        default: return nil
        }
      }
    }

    guard let code = Self.nameToKeyCode[keyPart.trimmingCharacters(in: .whitespaces)]
    else { return nil }
    self.init(carbonKeyCode: code, carbonModifiers: mods)
  }
}

// MARK: - Symbol display

extension HotKey {
  /// macOS-style glyphs built from the stable English/QWERTY key (e.g.
  /// `⌘S`, `⌃⌥←`), independent of the active keyboard layout — for the
  /// shortcut recorder field.
  public var symbols: String {
    var out = ""
    if carbonModifiers & Self.control != 0 { out += "⌃" }
    if carbonModifiers & Self.option != 0 { out += "⌥" }
    if carbonModifiers & Self.shift != 0 { out += "⇧" }
    if carbonModifiers & Self.cmd != 0 { out += "⌘" }
    return out + keySymbol
  }

  private var keySymbol: String {
    switch carbonKeyCode {
    case 36, 76: "↩"
    case 48: "⇥"
    case 49: "Space"
    case 51: "⌫"
    case 53: "⎋"
    case 117: "⌦"
    case 123: "←"
    case 124: "→"
    case 125: "↓"
    case 126: "↑"
    default: (Self.keyCodeToName[carbonKeyCode] ?? "0x" + String(carbonKeyCode, radix: 16)).uppercased()
    }
  }
}

// MARK: - Codable

extension HotKey: Codable {
  private enum CodingKeys: String, CodingKey {
    case carbonKeyCode, carbonModifiers
  }

  public init(from decoder: Decoder) throws {
    // Preferred: skhd-style string.
    if let container = try? decoder.singleValueContainer(),
       let string = try? container.decode(String.self) {
      if let parsed = HotKey(parsing: string) {
        self = parsed
        return
      }
      // A string that doesn't parse is a hand-edit typo — surface it
      // instead of silently leaving the shortcut unbound. The throw below
      // makes the owning `try?` field fall back to "no shortcut".
      @Dependency(\.errorReporter) var reporter
      reporter.report(
        "Shortcuts",
        "Invalid shortcut \"\(string)\" in config.toml — not registered",
        "expected skhd-style syntax, e.g. \"ctrl + alt - h\""
      )
      throw DecodingError.dataCorrupted(.init(
        codingPath: decoder.codingPath,
        debugDescription: "unparseable shortcut string: \(string)"
      ))
    }
    // Legacy: { carbonKeyCode, carbonModifiers } table.
    let keyed = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      carbonKeyCode: try keyed.decode(Int.self, forKey: .carbonKeyCode),
      carbonModifiers: try keyed.decode(Int.self, forKey: .carbonModifiers)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(displayString)
  }
}

// MARK: - US ANSI virtual key codes

extension HotKey {
  fileprivate static let keyCodeToName: [Int: String] = [
    0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
    11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
    18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
    26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "o", 32: "u", 33: "[",
    34: "i", 35: "p", 36: "return", 37: "l", 38: "j", 39: "'", 40: "k",
    41: ";", 42: "\\", 43: ",", 44: "/", 45: "n", 46: "m", 47: ".",
    48: "tab", 49: "space", 50: "`", 51: "delete", 53: "escape",
    76: "enter", 96: "f5", 97: "f6", 98: "f7", 99: "f3", 100: "f8",
    101: "f9", 103: "f11", 105: "f13", 109: "f10", 111: "f12",
    114: "help", 115: "home", 116: "pageup", 117: "forwarddelete",
    118: "f4", 119: "end", 120: "f2", 121: "pagedown", 122: "f1",
    123: "left", 124: "right", 125: "down", 126: "up",
  ]

  /// QWERTY-position name for a virtual key code (layout-independent) — used
  /// by transient key capture (borrow chord) to decode keystrokes the same
  /// way shortcuts are stored. Nil for unmapped codes.
  public static func keyName(for keyCode: Int) -> String? { keyCodeToName[keyCode] }

  /// QWERTY virtual key code for a single-character key name (e.g. a
  /// workspace's `keyEquivalent`), so a stored char + modifier mask forms a
  /// registerable `HotKey`. Nil for unmapped names.
  public static func keyCode(forName name: String) -> Int? {
    nameToKeyCode[name.lowercased()]
  }

  /// Display glyph for a stored key name — macOS symbols for special keys
  /// (`⌫`, `⏎`, `←`…), uppercased letters/punctuation otherwise. For showing a
  /// key equivalent in the UI.
  public static func keySymbol(forName name: String) -> String {
    switch name.lowercased() {
    case "delete": "⌫"
    case "forwarddelete": "⌦"
    case "return", "enter": "⏎"
    case "tab": "⇥"
    case "space": "Space"
    case "escape": "⎋"
    case "left": "←"
    case "right": "→"
    case "up": "↑"
    case "down": "↓"
    default: name.uppercased()
    }
  }

  fileprivate static let nameToKeyCode: [String: Int] = {
    var map: [String: Int] = [:]
    for (code, name) in keyCodeToName { map[name] = code }
    // Friendly aliases.
    map["esc"] = 53
    map["backspace"] = 51
    map["del"] = 51
    map["spacebar"] = 49
    map["pgup"] = 116
    map["pgdn"] = 121
    return map
  }()
}
