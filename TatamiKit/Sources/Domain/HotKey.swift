import Foundation
import KeyboardShortcuts

/// A persisted keyboard shortcut.
///
/// Stored as the raw Carbon key code + modifier bitfield so it round-trips
/// losslessly through TOML/JSON without needing a brittle string parser.
/// Convert to/from the live `KeyboardShortcuts.Shortcut` at registration
/// time.
public struct HotKey: Codable, Hashable, Sendable {
  public var carbonKeyCode: Int
  public var carbonModifiers: Int

  public init(carbonKeyCode: Int, carbonModifiers: Int) {
    self.carbonKeyCode = carbonKeyCode
    self.carbonModifiers = carbonModifiers
  }
}

extension HotKey {
  public init(_ shortcut: KeyboardShortcuts.Shortcut) {
    self.init(
      carbonKeyCode: shortcut.carbonKeyCode,
      carbonModifiers: shortcut.carbonModifiers
    )
  }

  public var shortcut: KeyboardShortcuts.Shortcut {
    KeyboardShortcuts.Shortcut(
      carbonKeyCode: carbonKeyCode,
      carbonModifiers: carbonModifiers
    )
  }
}
