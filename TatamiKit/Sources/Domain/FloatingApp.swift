import Foundation

/// Apps that should remain visible across all workspaces, independent of
/// which workspace is currently active.
public struct FloatingApp: Identifiable, Hashable, Sendable, Codable {
  public var bundleIdentifier: String
  public var name: String
  public var iconPath: String?

  public var id: String { bundleIdentifier }

  public init(bundleIdentifier: String, name: String, iconPath: String? = nil) {
    self.bundleIdentifier = bundleIdentifier
    self.name = name
    self.iconPath = iconPath
  }

  public init(_ app: MacApp) {
    self.init(
      bundleIdentifier: app.bundleIdentifier,
      name: app.name,
      iconPath: app.iconPath
    )
  }

  public var app: MacApp {
    MacApp(bundleIdentifier: bundleIdentifier, name: name, iconPath: iconPath)
  }
}
