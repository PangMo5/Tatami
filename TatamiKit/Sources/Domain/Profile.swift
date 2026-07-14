import Foundation
import IdentifiedCollections

/// A named collection of `Workspace`s. The user can switch profiles to
/// completely swap which workspaces, hotkeys, and assignments are active.
public struct Profile: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var name: String
  /// SF Symbol shown for the profile (sidebar, menu bar). Nil = the default
  /// `rectangle.stack`.
  public var symbolIconName: String?
  /// Optional global shortcut that activates this profile.
  public var shortcut: HotKey?
  /// Optional rule that auto-activates this profile when the connected displays
  /// match (nil = manual only). See `ProfileActivation`.
  public var autoActivation: ProfileActivation?
  public var workspaces: IdentifiedArrayOf<Workspace>

  public init(
    id: UUID = UUID(),
    name: String,
    symbolIconName: String? = nil,
    shortcut: HotKey? = nil,
    autoActivation: ProfileActivation? = nil,
    workspaces: IdentifiedArrayOf<Workspace> = []
  ) {
    self.id = id
    self.name = name
    self.symbolIconName = symbolIconName
    self.shortcut = shortcut
    self.autoActivation = autoActivation
    self.workspaces = workspaces
  }
}

extension Profile {
  public static let defaultName = "Default"

  public static func makeDefault() -> Profile {
    Profile(name: defaultName)
  }
}
