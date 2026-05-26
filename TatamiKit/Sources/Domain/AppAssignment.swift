import Foundation

/// Inline membership entry: a workspace's reference to a specific app.
///
/// `AppAssignment` is identified by its bundle identifier within a
/// workspace; the same app may legitimately appear in multiple workspaces
/// with different per-workspace metadata (e.g. autoOpen).
public struct AppAssignment: Identifiable, Hashable, Sendable, Codable {
  public var bundleIdentifier: String
  public var name: String
  public var iconPath: String?
  /// Launch the app automatically when its workspace activates.
  public var autoOpen: Bool

  public var id: String { bundleIdentifier }

  public init(
    bundleIdentifier: String,
    name: String,
    iconPath: String? = nil,
    autoOpen: Bool = false
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.name = name
    self.iconPath = iconPath
    self.autoOpen = autoOpen
  }

  public init(_ app: MacApp, autoOpen: Bool = false) {
    self.init(
      bundleIdentifier: app.bundleIdentifier,
      name: app.name,
      iconPath: app.iconPath,
      autoOpen: autoOpen
    )
  }

  public var app: MacApp {
    MacApp(bundleIdentifier: bundleIdentifier, name: name, iconPath: iconPath)
  }
}

extension AppAssignment {
  private enum CodingKeys: String, CodingKey {
    case bundleIdentifier, name, iconPath, autoOpen
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    bundleIdentifier = try c.decode(String.self, forKey: .bundleIdentifier)
    name = try c.decode(String.self, forKey: .name)
    iconPath = try c.decodeIfPresent(String.self, forKey: .iconPath)
    autoOpen = (try? c.decode(Bool.self, forKey: .autoOpen)) ?? false
  }
}
