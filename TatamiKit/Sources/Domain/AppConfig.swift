import Foundation
import IdentifiedCollections

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
  /// The active profile. `nil` → the first profile (back-compat with
  /// single-profile configs). Changed by a profile-switch hotkey or a
  /// display-activation rule.
  public var activeProfileId: Profile.ID?

  public init(
    profiles: [Profile] = [Profile.makeDefault()],
    sharedApps: [SharedApp] = [],
    settings: AppSettings = AppSettings(),
    activeProfileId: Profile.ID? = nil
  ) {
    self.profiles = profiles
    self.sharedApps = sharedApps
    self.settings = settings
    self.activeProfileId = activeProfileId
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
    // Which profile is active is session state, not a setting — it's persisted
    // separately (ProfileSessionStore, like layouts.json) and injected at
    // startup, so it never clutters config.toml or overwrites hand-edits.
    self.activeProfileId = nil
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(profiles, forKey: .profiles)
    try c.encode(sharedApps, forKey: .sharedApps)
    try c.encode(settings, forKey: .settings)
    // `activeProfileId` is intentionally not written — session state lives in
    // ProfileSessionStore (see the decode note above).
    // Legacy `floatingApps` is intentionally never written.
  }
}

extension AppConfig {
  /// The active profile: the one `activeProfileId` points at, falling back to
  /// the first by encounter order (back-compat with single-profile configs).
  public var activeProfile: Profile? {
    if let id = activeProfileId, let p = profiles.first(where: { $0.id == id }) {
      return p
    }
    return profiles.first
  }

  /// Index of the active profile in `profiles`, or nil when there are none.
  private var activeProfileIndex: Int? {
    if let id = activeProfileId, let idx = profiles.firstIndex(where: { $0.id == id }) {
      return idx
    }
    return profiles.isEmpty ? nil : 0
  }

  public mutating func mutateActiveProfile(_ body: (inout Profile) -> Void) {
    guard let idx = activeProfileIndex else { return }
    body(&profiles[idx])
  }

  /// Deep-copy `id` into a new profile placed right after it, returning the
  /// old→new workspace-id remap so the caller can copy each workspace's saved
  /// layout (layouts are keyed by workspace id, which must be fresh here so
  /// the clone's tiling is independent). The clone drops its switch shortcut
  /// and (future) auto-activation rule so it can't collide with the source.
  /// Returns an empty map when `id` is unknown.
  @discardableResult
  public mutating func duplicateProfile(_ id: Profile.ID) -> [Workspace.ID: Workspace.ID] {
    guard let srcIdx = profiles.firstIndex(where: { $0.id == id }) else { return [:] }
    let src = profiles[srcIdx]
    var remap: [Workspace.ID: Workspace.ID] = [:]
    var clonedWorkspaces: [Workspace] = []
    for var ws in src.workspaces {
      let newId = UUID()
      remap[ws.id] = newId
      ws.id = newId
      clonedWorkspaces.append(ws)
    }
    var clone = src
    clone.id = UUID()
    clone.name = "\(src.name) copy"
    clone.shortcut = nil
    clone.workspaces = IdentifiedArray(uniqueElements: clonedWorkspaces)
    profiles.insert(clone, at: srcIdx + 1)
    return remap
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

  /// Place `draggedId` — the effect of a sidebar drag-and-drop that both
  /// reorders within a section and moves between the "Workspaces" and
  /// "Scratchpads" sections. `kind` is the destination section; the workspace
  /// lands just before or after `targetId` (per `after`), matching the drop
  /// line the view drew above/below that row. `targetId == nil` appends to
  /// `kind`'s subset. Retypes the workspace when it crosses sections.
  public mutating func placeWorkspace(
    _ draggedId: Workspace.ID,
    kind: WorkspaceKind,
    relativeTo targetId: Workspace.ID?,
    after: Bool
  ) {
    guard draggedId != targetId else { return }
    mutateActiveProfile { profile in
      guard var moved = profile.workspaces[id: draggedId] else { return }
      moved.kind = kind
      var rest = Array(profile.workspaces)
      rest.removeAll { $0.id == draggedId }

      let insertionIndex: Int
      if let targetId, let targetIdx = rest.firstIndex(where: { $0.id == targetId }) {
        insertionIndex = after ? targetIdx + 1 : targetIdx
      } else {
        let slots = rest.indices.filter { rest[$0].kind == kind }
        insertionIndex = slots.last.map { $0 + 1 } ?? rest.count
      }
      rest.insert(moved, at: insertionIndex)
      profile.workspaces = IdentifiedArray(uniqueElements: rest)
    }
  }
}
