import Foundation

/// An app present in *every* workspace (shared), independent of which
/// workspace is active.
///
/// `floating` is the layout axis: when `false` the app is tiled into each
/// workspace's BSP layout; when `true` it's left untiled and kept above the
/// tiles (a "shared floating" window that drifts across all screens).
public struct SharedApp: Identifiable, Hashable, Sendable, Codable {
  public var bundleIdentifier: String
  public var name: String
  public var iconPath: String?
  /// `true` → not tiled, kept on top, drifts across all workspaces.
  /// `false` → tiled into each workspace's layout.
  public var floating: Bool

  public var id: String { bundleIdentifier }

  public init(
    bundleIdentifier: String,
    name: String,
    iconPath: String? = nil,
    floating: Bool = false
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.name = name
    self.iconPath = iconPath
    self.floating = floating
  }

  public init(_ app: MacApp, floating: Bool = false) {
    self.init(
      bundleIdentifier: app.bundleIdentifier,
      name: app.name,
      iconPath: app.iconPath,
      floating: floating
    )
  }

  public var app: MacApp {
    MacApp(bundleIdentifier: bundleIdentifier, name: name, iconPath: iconPath)
  }

  private enum CodingKeys: String, CodingKey {
    case bundleIdentifier, name, iconPath, floating
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    bundleIdentifier = try c.decode(String.self, forKey: .bundleIdentifier)
    name = try c.decode(String.self, forKey: .name)
    iconPath = try c.decodeIfPresent(String.self, forKey: .iconPath)
    floating = (try? c.decode(Bool.self, forKey: .floating)) ?? false
  }
}
