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
  /// Apps present in every workspace. Each carries a `floating` flag: tiled
  /// into each workspace's layout when `false`, untiled + on top when `true`.
  public var sharedApps: [SharedApp]
  public var settings: AppSettings

  public init(
    profiles: [Profile] = [Profile.makeDefault()],
    sharedApps: [SharedApp] = [],
    settings: AppSettings = AppSettings()
  ) {
    self.profiles = profiles
    self.sharedApps = sharedApps
    self.settings = settings
  }

  private enum CodingKeys: String, CodingKey {
    case profiles, sharedApps, settings
    // DEPRECATED: legacy key, read once to migrate into `sharedApps`. The
    // first GUI/CLI write re-serializes as `sharedApps`, so it disappears.
    // Remove after a few releases.
    case floatingApps
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    // A *missing* key is the normal partial-config case and gets the
    // default. A key that is PRESENT but corrupt must fail the decode:
    // defaulting here would silently reset (and the next GUI write would
    // persist the reset, wiping the user's workspaces) — the fileStorage
    // containment keeps the previous in-memory config and reports instead.
    self.profiles = c.contains(.profiles)
      ? try c.decode([Profile].self, forKey: .profiles)
      : [Profile.makeDefault()]
    self.settings = c.contains(.settings)
      ? try c.decode(AppSettings.self, forKey: .settings)
      : AppSettings()
    if c.contains(.sharedApps) {
      self.sharedApps = try c.decode([SharedApp].self, forKey: .sharedApps)
    } else if c.contains(.floatingApps) {
      // One-time migration: old floating apps were "untiled + everywhere",
      // which is exactly a shared floating app.
      self.sharedApps = try c.decode([FloatingApp].self, forKey: .floatingApps).map {
        SharedApp(bundleIdentifier: $0.bundleIdentifier, name: $0.name,
                  iconPath: $0.iconPath, layout: .floating)
      }
    } else {
      self.sharedApps = []
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(profiles, forKey: .profiles)
    try c.encode(sharedApps, forKey: .sharedApps)
    try c.encode(settings, forKey: .settings)
    // Legacy `floatingApps` is intentionally never written.
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

  public mutating func mutateWorkspace(
    _ id: Workspace.ID,
    _ body: (inout Workspace) -> Void
  ) {
    mutateActiveProfile { profile in
      guard var workspace = profile.workspaces[id: id] else { return }
      body(&workspace)
      profile.workspaces[id: id] = workspace
    }
  }
}
