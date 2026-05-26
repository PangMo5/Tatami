import Foundation

/// A named collection of `Workspace`s. The user can switch profiles to
/// completely swap which workspaces, hotkeys, and assignments are active.
public struct Profile: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var name: String
  /// Optional global shortcut that activates this profile.
  public var shortcut: HotKey?
  public var workspaces: [Workspace]

  public init(
    id: UUID = UUID(),
    name: String,
    shortcut: HotKey? = nil,
    workspaces: [Workspace] = []
  ) {
    self.id = id
    self.name = name
    self.shortcut = shortcut
    self.workspaces = workspaces
  }
}

extension Profile {
  public static let defaultName = "Default"

  public static func makeDefault() -> Profile {
    Profile(name: defaultName)
  }
}
