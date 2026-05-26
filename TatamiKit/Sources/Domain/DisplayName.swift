import Foundation

/// A macOS display's localized name (e.g. "Built-in Retina Display", "LG UltraFine").
///
/// Tatami pins a `Workspace` to a display by name so reconnecting the same monitor
/// continues to honor the user's assignment, even if `CGDirectDisplayID` changes.
public struct DisplayName:
  RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral
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

extension DisplayName: CustomStringConvertible {
  public var description: String { rawValue }
}
