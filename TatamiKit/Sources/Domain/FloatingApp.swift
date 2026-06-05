import Foundation

/// DEPRECATED: replaced by `SharedApp` (whose `floating` flag distinguishes
/// tiled vs floating shared apps). Kept only so `AppConfig` can read a legacy
/// `floatingApps` config and migrate it to `sharedApps` once. Remove in a few
/// releases, once stored configs have been rewritten.
@available(*, deprecated, message: "Use SharedApp; legacy config migration only.")
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
