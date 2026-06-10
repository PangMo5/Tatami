import Foundation

/// Lightweight reference to a macOS application identified by its bundle ID.
///
/// `MacApp` is intentionally a value type with no persistence semantics; it
/// is embedded as columns inside `AppAssignment` and `FloatingApp` rows.
public struct MacApp: Hashable, Sendable, Codable {
  /// Reverse-DNS bundle identifier, e.g. `com.apple.Safari`.
  public var bundleIdentifier: String
  /// Localized application name as last seen.
  public var name: String
  /// Filesystem path to the cached icon, if any.
  public var iconPath: String?

  public init(bundleIdentifier: String, name: String, iconPath: String? = nil) {
    self.bundleIdentifier = bundleIdentifier
    self.name = name
    self.iconPath = iconPath
  }
}

extension MacApp {
  public static let finderBundleId = "com.apple.finder"

  public var isFinder: Bool {
    bundleIdentifier == Self.finderBundleId
  }

  /// Whether `bundleId` is Tatami itself (any build flavor). Used to keep
  /// Tatami out of its own workspace membership / sync paths — checking
  /// the two literals at every call site meant a new flavor (e.g. a beta
  /// suffix) would need every site touched.
  public static func isTatami(_ bundleId: String) -> Bool {
    bundleId == "dev.PangMo5.Tatami" || bundleId.hasPrefix("dev.PangMo5.Tatami.")
  }
}
