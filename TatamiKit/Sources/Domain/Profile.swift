import Foundation
import SQLiteData

/// A named collection of `Workspace`s. The user can switch profiles to
/// completely swap which workspaces, hotkeys, and assignments are active.
@Table("profiles")
public struct Profile: Identifiable, Hashable, Sendable {
  public let id: UUID
  public var name: String
  /// Optional global shortcut that activates this profile.
  public var shortcut: HotKey?
  /// Display order in the profile list.
  public var sortOrder: Int

  public init(
    id: UUID = UUID(),
    name: String,
    shortcut: HotKey? = nil,
    sortOrder: Int = 0
  ) {
    self.id = id
    self.name = name
    self.shortcut = shortcut
    self.sortOrder = sortOrder
  }
}

extension Profile {
  public static let defaultName = "Default"
}
