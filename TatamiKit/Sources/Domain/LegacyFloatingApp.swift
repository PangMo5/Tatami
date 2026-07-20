import Foundation

/// Decode-only shape for the old `floatingApps` config key. It deliberately
/// has no domain behavior or public API; the value exists only long enough for
/// `AppConfig` to map it into `SharedApp` during migration.
struct LegacyFloatingApp: Decodable {
  var bundleIdentifier: String
  var name: String
  var iconPath: String?
}
