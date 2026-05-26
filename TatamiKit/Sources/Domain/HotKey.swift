import Foundation
import StructuredQueries

/// A keyboard shortcut binding serialized as a human-readable string
/// (e.g. `"cmd+shift+a"`).
///
/// `HotKey` is purely a value carrier — registering it with the system
/// happens in the HotKeys feature (Phase 3).
public struct HotKey:
  RawRepresentable, QueryBindable, Hashable, Sendable, Codable, ExpressibleByStringLiteral
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public init(stringLiteral value: StringLiteralType) {
    rawValue = value
  }

  public init(from decoder: Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

extension HotKey: CustomStringConvertible {
  public var description: String { rawValue }
}
