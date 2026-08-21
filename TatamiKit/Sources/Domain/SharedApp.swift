// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

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
  /// Launch/reopen this app on workspace activation when it has no on-screen
  /// window — same meaning as `AppAssignment.autoOpen`, and the sole intended
  /// path that restores a minimized shared app (focus never de-minimizes).
  public var autoOpen: Bool

  public var id: String { bundleIdentifier }

  public init(
    bundleIdentifier: String,
    name: String,
    iconPath: String? = nil,
    layout: LayoutMode = .tiled,
    autoOpen: Bool = false
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.name = name
    self.iconPath = iconPath
    self.layout = layout
    self.autoOpen = autoOpen
  }

  public init(_ app: MacApp, layout: LayoutMode = .tiled, autoOpen: Bool = false) {
    self.init(
      bundleIdentifier: app.bundleIdentifier,
      name: app.name,
      iconPath: app.iconPath,
      layout: layout,
      autoOpen: autoOpen
    )
  }

  public var app: MacApp {
    MacApp(bundleIdentifier: bundleIdentifier, name: name, iconPath: iconPath)
  }

  private enum CodingKeys: String, CodingKey {
    case bundleIdentifier, name, iconPath, layout, floating, autoOpen
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
    autoOpen = (try? c.decode(Bool.self, forKey: .autoOpen)) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(bundleIdentifier, forKey: .bundleIdentifier)
    try c.encode(name, forKey: .name)
    try c.encodeIfPresent(iconPath, forKey: .iconPath)
    try c.encode(layout, forKey: .layout)
    try c.encode(autoOpen, forKey: .autoOpen)
  }
}
