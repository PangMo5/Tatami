// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

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
      self.sharedApps = try c.decode([LegacyFloatingApp].self, forKey: .floatingApps).map {
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

  /// The profile whose auto-activation rule best matches `connected`, or nil
  /// when none match. Most-specific wins (see `ProfileActivation.specificity`);
  /// ties break toward the earlier profile in order.
  public func autoActiveProfile(connected: Set<DisplayName>) -> Profile.ID? {
    var best: (id: Profile.ID, score: Int)?
    for profile in profiles {
      guard let rule = profile.autoActivation, rule.matches(connected: connected) else { continue }
      let score = rule.specificity
      if best == nil || score > best!.score { best = (profile.id, score) }
    }
    return best?.id
  }

  /// The profile to restore on launch. A last-used manual profile has no
  /// display constraints, so it remains eligible. A conditioned profile is
  /// restored only while its rule still matches; otherwise the normal
  /// auto-activation resolver (then the first profile) provides the fallback.
  public func startupActiveProfile(
    lastUsedProfileId: Profile.ID?,
    connected: Set<DisplayName>,
  ) -> Profile.ID? {
    if
      let lastUsedProfileId,
      let profile = profiles.first(where: { $0.id == lastUsedProfileId }),
      profile.autoActivation?.matches(connected: connected) ?? true
    {
      return profile.id
    }
    return autoActiveProfile(connected: connected) ?? profiles.first?.id
  }

  /// How one profile's auto-activation rule relates to the others': which
  /// profiles fire on the same configuration, and whether the tie is decided
  /// by order (equal specificity — a genuine conflict) or by precedence
  /// (different specificity — intended shadowing, shown as info).
  public func autoActivationDiagnostic(for profileId: Profile.ID) -> ProfileActivationDiagnostic {
    guard let rule = profiles.first(where: { $0.id == profileId })?.autoActivation
    else { return ProfileActivationDiagnostic() }

    var diagnostic = ProfileActivationDiagnostic()
    let mySpecificity = rule.specificity
    for other in profiles where other.id != profileId {
      guard let otherRule = other.autoActivation, rule.overlaps(with: otherRule)
      else { continue }
      let otherSpecificity = otherRule.specificity
      if otherSpecificity == mySpecificity {
        diagnostic.ambiguousWith.append(other.name)
      } else if otherSpecificity > mySpecificity {
        diagnostic.shadowedBy.append(other.name)
      } else {
        diagnostic.shadows.append(other.name)
      }
    }
    return diagnostic
  }

  /// The workspace with `id` in whichever profile owns it (workspace ids are
  /// globally unique across profiles), or nil. Lets the detail/layout editors
  /// resolve a workspace without knowing — or caring — which profile is active.
  public func workspace(id: Workspace.ID) -> Workspace? {
    for profile in profiles {
      if let workspace = profile.workspaces[id: id] { return workspace }
    }
    return nil
  }

  /// The id of the profile that owns `workspaceId`, or nil.
  public func profileId(owning workspaceId: Workspace.ID) -> Profile.ID? {
    profiles.first { $0.workspaces[id: workspaceId] != nil }?.id
  }

  /// Mutate a specific profile by id (the 3-column sidebar edits the *selected*
  /// profile, which need not be the active one).
  public mutating func mutateProfile(_ id: Profile.ID, _ body: (inout Profile) -> Void) {
    guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
    body(&profiles[idx])
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
    // Don't inherit the source's switch shortcut or auto-activation rule — two
    // profiles firing on the same hotkey / display set would collide.
    clone.autoActivation = nil
    clone.workspaces = IdentifiedArray(uniqueElements: clonedWorkspaces)
    profiles.insert(clone, at: srcIdx + 1)
    return remap
  }

  /// Names of workspaces in `targetId` that differ from the same-named
  /// workspace in `sourceId` — by apps or by any field (display pin included).
  /// Drift indicator for the profile-sync tool.
  public func workspacesDiffering(
    in targetId: Profile.ID, comparedTo sourceId: Profile.ID
  ) -> [String] {
    guard targetId != sourceId,
          let target = profiles.first(where: { $0.id == targetId }),
          let source = profiles.first(where: { $0.id == sourceId })
    else { return [] }
    var diverged: [String] = []
    for ws in target.workspaces {
      guard let match = source.workspaces.first(where: { $0.name == ws.name }) else { continue }
      let apps = WorkspaceSync.appChanges(from: match.apps, to: ws.apps)
      let fields = WorkspaceSync.fieldChanges(from: match, to: ws)
      if !apps.isEmpty || !fields.isEmpty { diverged.append(ws.name) }
    }
    return diverged
  }

  /// Copy a source profile's workspaces onto the target's, matched by name —
  /// applying only the per-workspace app / field changes the user kept
  /// (`excluded*ByWorkspace` map a workspace id to the app bundle ids / field
  /// ids to skip). Nothing is hard-excluded, including the display pin: the
  /// preview shows every difference and the user unchecks what to leave alone.
  /// Profiles stay independent.
  public mutating func applyProfileSync(
    into targetId: Profile.ID,
    from sourceId: Profile.ID,
    excludedAppsByWorkspace: [Workspace.ID: Set<String>] = [:],
    excludedFieldsByWorkspace: [Workspace.ID: Set<String>] = [:]
  ) {
    guard targetId != sourceId,
          let sourceIdx = profiles.firstIndex(where: { $0.id == sourceId }),
          let targetIdx = profiles.firstIndex(where: { $0.id == targetId })
    else { return }
    let source = profiles[sourceIdx]
    for ws in profiles[targetIdx].workspaces {
      guard let match = source.workspaces.first(where: { $0.name == ws.name }) else { continue }
      let appChanges = WorkspaceSync.appChanges(from: match.apps, to: ws.apps)
      let fieldChanges = WorkspaceSync.fieldChanges(from: match, to: ws)
      guard !appChanges.isEmpty || !fieldChanges.isEmpty,
            var updated = profiles[targetIdx].workspaces[id: ws.id]
      else { continue }
      updated.apps = WorkspaceSync.apply(
        appChanges, to: updated.apps, excluding: excludedAppsByWorkspace[ws.id] ?? []
      )
      WorkspaceSync.apply(
        fieldChanges, to: &updated, excluding: excludedFieldsByWorkspace[ws.id] ?? []
      )
      profiles[targetIdx].workspaces[id: ws.id] = updated
    }
  }

  /// Copy a source profile's workspace onto the target workspace: apply the app
  /// changes (by bundle id) and setting changes (by field id) the user kept,
  /// never touching the target's display pin. `targetWsId` is resolved in
  /// whichever profile owns it (workspace ids are unique).
  public mutating func importWorkspace(
    into targetWsId: Workspace.ID,
    from sourceProfileId: Profile.ID,
    sourceWorkspace sourceWsId: Workspace.ID,
    excludingApps: Set<String> = [],
    excludingFields: Set<String> = []
  ) {
    guard let sourceWs = profiles.first(where: { $0.id == sourceProfileId })?
      .workspaces[id: sourceWsId]
    else { return }
    mutateWorkspace(targetWsId) { ws in
      let appChanges = WorkspaceSync.appChanges(from: sourceWs.apps, to: ws.apps)
      ws.apps = WorkspaceSync.apply(appChanges, to: ws.apps, excluding: excludingApps)
      let fieldChanges = WorkspaceSync.fieldChanges(from: sourceWs, to: ws)
      WorkspaceSync.apply(fieldChanges, to: &ws, excluding: excludingFields)
    }
  }

  /// Mutate the workspace with `id` in whichever profile owns it — not just the
  /// active one — so editing a non-active profile's workspace works. Ids are
  /// globally unique, so this resolves to exactly one workspace.
  public mutating func mutateWorkspace(
    _ id: Workspace.ID,
    _ body: (inout Workspace) -> Void
  ) {
    guard let pIdx = profiles.firstIndex(where: { $0.workspaces[id: id] != nil }),
          var workspace = profiles[pIdx].workspaces[id: id]
    else { return }
    body(&workspace)
    profiles[pIdx].workspaces[id: id] = workspace
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
    after: Bool,
    in profileId: Profile.ID? = nil
  ) {
    guard draggedId != targetId else { return }
    let target = profileId ?? activeProfileId ?? profiles.first?.id
    guard let target else { return }
    mutateProfile(target) { profile in
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
