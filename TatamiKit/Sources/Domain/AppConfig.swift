import Foundation

/// Root of the on-disk Tatami configuration.
///
/// Serialized to `$XDG_CONFIG_HOME/tatami/config.toml` (defaulting to
/// `~/.config/tatami/config.toml`) and observed in-memory via
/// `@Shared(.tatamiConfig)`.
///
/// Edits made by the user in the GUI are written back to disk; edits made
/// outside the GUI (vim, dotfiles, etc.) are picked up via Sharing's file
/// watcher.
public struct AppConfig: Hashable, Sendable, Codable {
  public var profiles: [Profile]
  public var floatingApps: [FloatingApp]
  public var settings: AppSettings

  public init(
    profiles: [Profile] = [Profile.makeDefault()],
    floatingApps: [FloatingApp] = [],
    settings: AppSettings = AppSettings()
  ) {
    self.profiles = profiles
    self.floatingApps = floatingApps
    self.settings = settings
  }
}

extension AppConfig {
  /// First profile by encounter order. Tatami treats this as "the active
  /// profile" until profile switching is implemented (Phase 3).
  public var activeProfile: Profile? {
    profiles.first
  }

  public mutating func mutateActiveProfile(_ body: (inout Profile) -> Void) {
    guard !profiles.isEmpty else { return }
    body(&profiles[0])
  }
}
