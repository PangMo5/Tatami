import Foundation

/// Application-wide settings. Currently a placeholder — feature-specific
/// settings (General, MenuBar, Workspaces, Focus, Gestures, Integrations…)
/// will be folded in as those features land in Phase 3.
public struct AppSettings: Hashable, Sendable, Codable {
  public var checkForUpdatesAutomatically: Bool

  public init(checkForUpdatesAutomatically: Bool = true) {
    self.checkForUpdatesAutomatically = checkForUpdatesAutomatically
  }
}
