import Foundation

/// An app present in *every* workspace (shared), independent of which
/// workspace is active.
///
/// `layout` is the per-workspace layout axis: `.tiled` joins each
/// workspace's BSP layout, `.floating` is kept above the tiles via a
/// mirror, and `.unmanaged` leaves the real window alone (still a member,
/// just not laid out).
public struct SharedApp: Identifiable, Hashable, Sendable, Codable {
  public var bundleIdentifier: String
  public var name: String
  public var iconPath: String?
  /// How this app's windows are laid out across workspaces.
  public var layout: LayoutMode

  public var id: String { bundleIdentifier }

  public init(
    bundleIdentifier: String,
    name: String,
    iconPath: String? = nil,
    layout: LayoutMode = .tiled
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.name = name
    self.iconPath = iconPath
    self.layout = layout
  }

  public init(_ app: MacApp, layout: LayoutMode = .tiled) {
    self.init(
      bundleIdentifier: app.bundleIdentifier,
      name: app.name,
      iconPath: app.iconPath,
      layout: layout
    )
  }

  public var app: MacApp {
    MacApp(bundleIdentifier: bundleIdentifier, name: name, iconPath: iconPath)
  }

  private enum CodingKeys: String, CodingKey {
    case bundleIdentifier, name, iconPath, layout, floating
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    bundleIdentifier = try c.decode(String.self, forKey: .bundleIdentifier)
    name = try c.decode(String.self, forKey: .name)
    iconPath = try c.decodeIfPresent(String.self, forKey: .iconPath)
    // Migrate the legacy `floating: Bool`. New configs carry `layout`.
    if let mode = try? c.decode(LayoutMode.self, forKey: .layout) {
      layout = mode
    } else {
      layout = ((try? c.decode(Bool.self, forKey: .floating)) == true) ? .floating : .tiled
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(bundleIdentifier, forKey: .bundleIdentifier)
    try c.encode(name, forKey: .name)
    try c.encodeIfPresent(iconPath, forKey: .iconPath)
    try c.encode(layout, forKey: .layout)
  }
}
