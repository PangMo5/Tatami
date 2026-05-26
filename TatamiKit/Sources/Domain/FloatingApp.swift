import Foundation
import SQLiteData

/// Apps that should remain visible across all workspaces, independent of
/// which workspace is currently active.
///
/// Identified by `bundleIdentifier` directly — there is at most one floating
/// entry per app.
@Table("floating_apps")
public struct FloatingApp: Identifiable, Hashable, Sendable {
  /// The bundle identifier doubles as the primary key.
  public var id: String { bundleIdentifier }
  public var bundleIdentifier: String
  public var name: String
  public var iconPath: String?

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
