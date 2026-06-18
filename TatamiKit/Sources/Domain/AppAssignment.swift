import Foundation

/// How a workspace lays out an assigned (or shared) app's windows.
///
/// `tiled` and `floating` are the original two modes; `unmanaged` is the
/// "leave it alone" mode — the app stays a full workspace member
/// (auto-open, show/hide, focus, focus-follows-mouse, window cycling) but
/// its windows are neither tiled into the BSP tree nor mirrored onto an
/// always-on-top panel.
public enum LayoutMode: String, Hashable, Sendable, Codable, CaseIterable {
  /// Tiled into the workspace's BSP layout (a frame is written).
  case tiled
  /// Excluded from the tree, kept above the tiles via a ScreenCaptureKit
  /// mirror (requires Screen Recording).
  case floating
  /// Excluded from the tree and *not* mirrored — the real window is left
  /// at its current position/size, no Screen Recording cost. Still a
  /// managed member: counts for membership, focus, focus-follows-mouse,
  /// and window cycling, just not for layout.
  case unmanaged
}

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
  /// How this workspace lays out the app's windows. `.unmanaged` keeps it
  /// a member (auto-open, show/hide, focus, FFM, cycling) but leaves its
  /// windows alone — no tile, no mirror.
  public var layout: LayoutMode

  public var id: String { bundleIdentifier }

  public init(
    bundleIdentifier: String,
    name: String,
    iconPath: String? = nil,
    autoOpen: Bool = false,
    layout: LayoutMode = .tiled
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.name = name
    self.iconPath = iconPath
    self.autoOpen = autoOpen
    self.layout = layout
  }

  public init(_ app: MacApp, autoOpen: Bool = false, layout: LayoutMode = .tiled) {
    self.init(
      bundleIdentifier: app.bundleIdentifier,
      name: app.name,
      iconPath: app.iconPath,
      autoOpen: autoOpen,
      layout: layout
    )
  }

  public var app: MacApp {
    MacApp(bundleIdentifier: bundleIdentifier, name: name, iconPath: iconPath)
  }
}

extension AppAssignment {
  private enum CodingKeys: String, CodingKey {
    case bundleIdentifier, name, iconPath, autoOpen, layout, floating
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    bundleIdentifier = try c.decode(String.self, forKey: .bundleIdentifier)
    name = try c.decode(String.self, forKey: .name)
    iconPath = try c.decodeIfPresent(String.self, forKey: .iconPath)
    autoOpen = (try? c.decode(Bool.self, forKey: .autoOpen)) ?? false
    // Migrate the legacy `floating: Bool`. New configs carry `layout`;
    // older ones only have `floating` (true → .floating, else .tiled).
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
    try c.encode(autoOpen, forKey: .autoOpen)
    try c.encode(layout, forKey: .layout)
  }
}
