// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - TomlValue

public indirect enum TomlValue: Equatable, Sendable {
  case string(String)
  case integer(Int)
  case double(Double)
  case bool(Bool)
  case array([TomlValue])
  case table([String: TomlValue])

  // MARK: Public

  public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
  public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
  public var intValue: Int? { if case .integer(let value) = self { value } else { nil } }

  public var doubleValue: Double? {
    switch self {
    case .double(let value): value
    case .integer(let value): Double(value)
    default: nil
    }
  }

  public var arrayValue: [TomlValue]? { if case .array(let value) = self { value } else { nil } }
  public var tableValue: [String: TomlValue]? { if case .table(let value) = self { value } else { nil } }

  public var stringArray: [String]? {
    guard let array = arrayValue else { return nil }
    let strings = array.compactMap(\.stringValue)
    return strings.count == array.count ? strings : nil
  }

  public var tableArray: [[String: TomlValue]]? {
    guard let array = arrayValue else { return nil }
    let tables = array.compactMap(\.tableValue)
    return tables.count == array.count ? tables : nil
  }

  public subscript(key: String) -> TomlValue? { tableValue?[key] }

}

// MARK: - TomlLiteError

public struct TomlLiteError: Error, CustomStringConvertible {

  // MARK: Lifecycle

  public init(line: Int, message: String) {
    self.line = line
    self.message = message
  }

  // MARK: Public

  public let line: Int
  public let message: String

  public var description: String { "line \(line): \(message)" }

}

// MARK: - TomlLite

/// A deliberately small TOML reader covering exactly the subset the Demo Lab
/// writes: comments, `[table]`, `[[array of tables]]`, basic and literal
/// strings, integers, floats, booleans, arrays (including multi-line), and
/// single-line inline tables.
///
/// Its purpose is validation, not general parsing. Tatami accepts a config file
/// where a misspelled key, a wrong enum spelling, or an out-of-range value is
/// **silently defaulted** with no warning anywhere — so the failure mode this
/// guards against is a recording that quietly uses different settings than the
/// one before it. Parsing the file the lab just wrote and asserting on it is
/// the only way to catch that before the camera rolls.
public enum TomlLite {

  // MARK: Public

  public static func parse(_ text: String) throws -> [String: TomlValue] {
    let root = Node()
    var current = root
    let lines = text.components(separatedBy: .newlines)
    var index = 0

    while index < lines.count {
      let number = index + 1
      var line = strippingComment(lines[index]).trimmingCharacters(in: .whitespaces)
      index += 1
      if line.isEmpty { continue }

      if line.hasPrefix("[[") {
        guard line.hasSuffix("]]") else { throw TomlLiteError(line: number, message: "unterminated [[") }
        let path = try keyPath(String(line.dropFirst(2).dropLast(2)), line: number)
        current = root.appendTableArray(at: path)
        continue
      }

      if line.hasPrefix("[") {
        guard line.hasSuffix("]") else { throw TomlLiteError(line: number, message: "unterminated [") }
        let path = try keyPath(String(line.dropFirst().dropLast()), line: number)
        current = root.table(at: path)
        continue
      }

      guard let separator = line.firstIndex(of: "=") else {
        throw TomlLiteError(line: number, message: "expected key = value")
      }
      let key = unquote(String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces))
      var raw = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)

      // Multi-line arrays: keep pulling lines until the brackets balance.
      if raw.hasPrefix("[") {
        while unbalanced(raw), index < lines.count {
          line = strippingComment(lines[index]).trimmingCharacters(in: .whitespaces)
          index += 1
          raw += " " + line
        }
        if unbalanced(raw) { throw TomlLiteError(line: number, message: "unterminated array") }
      }

      guard !key.isEmpty else { throw TomlLiteError(line: number, message: "empty key") }
      current.values[key] = try value(raw, line: number)
    }

    return root.materialize()
  }

  // MARK: Private

  private final class Node {

    // MARK: Internal

    var values = [String: TomlValue]()
    var children = [String: Node]()
    var childArrays = [String: [Node]]()
    /// Preserves declaration order so diagnostics read like the file.
    var order = [String]()

    func table(at path: [String]) -> Node {
      var node = self
      for part in path { node = node.descend(part) }
      return node
    }

    func appendTableArray(at path: [String]) -> Node {
      guard let last = path.last else { return self }
      var node = self
      for part in path.dropLast() { node = node.descend(part) }
      let fresh = Node()
      node.childArrays[last, default: []].append(fresh)
      if !node.order.contains(last) { node.order.append(last) }
      return fresh
    }

    func materialize() -> [String: TomlValue] {
      var result = values
      for (key, child) in children { result[key] = .table(child.materialize()) }
      for (key, array) in childArrays {
        result[key] = .array(array.map { .table($0.materialize()) })
      }
      return result
    }

    // MARK: Private

    /// Walks into an existing sub-table, or the *last* element of an existing
    /// array of tables — that is the TOML rule that makes
    /// `[[profiles.workspaces]]` attach to the profile declared above it.
    private func descend(_ part: String) -> Node {
      if let existing = childArrays[part]?.last { return existing }
      if let existing = children[part] { return existing }
      let fresh = Node()
      children[part] = fresh
      order.append(part)
      return fresh
    }

  }

  private static func strippingComment(_ line: String) -> String {
    var inBasic = false
    var inLiteral = false
    var escaped = false
    for (offset, character) in line.enumerated() {
      if escaped { escaped = false; continue }
      switch character {
      case "\\" where inBasic: escaped = true
      case "\"" where !inLiteral: inBasic.toggle()
      case "'" where !inBasic: inLiteral.toggle()
      case "#" where !inBasic && !inLiteral:
        return String(line.prefix(offset))
      default: break
      }
    }
    return line
  }

  private static func unbalanced(_ text: String) -> Bool {
    var depth = 0
    var inBasic = false
    var inLiteral = false
    var escaped = false
    for character in text {
      if escaped { escaped = false; continue }
      switch character {
      case "\\" where inBasic: escaped = true
      case "\"" where !inLiteral: inBasic.toggle()
      case "'" where !inBasic: inLiteral.toggle()
      case "[" where !inBasic && !inLiteral: depth += 1
      case "]" where !inBasic && !inLiteral: depth -= 1
      default: break
      }
    }
    return depth != 0
  }

  private static func keyPath(_ text: String, line: Int) throws -> [String] {
    let parts = text.split(separator: ".").map {
      unquote($0.trimmingCharacters(in: .whitespaces))
    }
    guard !parts.isEmpty, !parts.contains(where: \.isEmpty) else {
      throw TomlLiteError(line: line, message: "empty table path")
    }
    return parts
  }

  private static func unquote(_ text: String) -> String {
    if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
      return unescape(String(text.dropFirst().dropLast()))
    }
    if text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") {
      return String(text.dropFirst().dropLast())
    }
    return text
  }

  private static func unescape(_ text: String) -> String {
    var result = ""
    var iterator = text.makeIterator()
    while let character = iterator.next() {
      guard character == "\\" else { result.append(character); continue }
      switch iterator.next() {
      case "n": result.append("\n")
      case "t": result.append("\t")
      case "r": result.append("\r")
      case "\"": result.append("\"")
      case "\\": result.append("\\")
      case let other?: result.append(other)
      case nil: result.append("\\")
      }
    }
    return result
  }

  private static func value(_ raw: String, line: Int) throws -> TomlValue {
    let text = raw.trimmingCharacters(in: .whitespaces)
    if text.isEmpty { throw TomlLiteError(line: line, message: "missing value") }

    if text.hasPrefix("\"") || text.hasPrefix("'") { return .string(unquote(text)) }
    if text == "true" { return .bool(true) }
    if text == "false" { return .bool(false) }

    if text.hasPrefix("[") {
      guard text.hasSuffix("]") else { throw TomlLiteError(line: line, message: "unterminated array") }
      let inner = String(text.dropFirst().dropLast())
      return .array(try splitTopLevel(inner, line: line).map { try value($0, line: line) })
    }

    if text.hasPrefix("{") {
      guard text.hasSuffix("}") else { throw TomlLiteError(line: line, message: "unterminated table") }
      let inner = String(text.dropFirst().dropLast())
      var table = [String: TomlValue]()
      for entry in try splitTopLevel(inner, line: line) {
        guard let separator = entry.firstIndex(of: "=") else {
          throw TomlLiteError(line: line, message: "expected key = value in inline table")
        }
        let key = unquote(String(entry[entry.startIndex..<separator]).trimmingCharacters(in: .whitespaces))
        table[key] = try value(String(entry[entry.index(after: separator)...]), line: line)
      }
      return .table(table)
    }

    let normalized = text.replacingOccurrences(of: "_", with: "")
    if let integer = Int(normalized) { return .integer(integer) }
    if let double = Double(normalized) { return .double(double) }

    throw TomlLiteError(line: line, message: "unsupported value: \(text)")
  }

  private static func splitTopLevel(_ text: String, line: Int) throws -> [String] {
    var parts = [String]()
    var current = ""
    var depth = 0
    var inBasic = false
    var inLiteral = false
    var escaped = false

    for character in text {
      if escaped { current.append(character); escaped = false; continue }
      switch character {
      case "\\" where inBasic: current.append(character); escaped = true
      case "\"" where !inLiteral: inBasic.toggle(); current.append(character)
      case "'" where !inBasic: inLiteral.toggle(); current.append(character)
      // Each pattern needs its own `where`: in Swift a where clause binds to the
      // preceding pattern only, so `case "[", "{" where …` would leave "[" unguarded.
      case "[" where !inBasic && !inLiteral, "{" where !inBasic && !inLiteral:
        depth += 1
        current.append(character)

      case "]" where !inBasic && !inLiteral, "}" where !inBasic && !inLiteral:
        depth -= 1
        current.append(character)

      case "," where depth == 0 && !inBasic && !inLiteral:
        parts.append(current)
        current = ""
      default: current.append(character)
      }
    }
    parts.append(current)

    return parts
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

}
