import Foundation

/// App-membership mutations, lifted out of the activation reducer so the
/// single-membership / float-attribute rules are plain value-type logic —
/// unit-testable without a `TestStore`, and shared by every entry point
/// (hotkeys today, CLI verbs tomorrow).
extension AppConfig {
  /// Single-membership toggle in `workspaceId`: a member is removed; a
  /// non-member is added after being taken away from every other
  /// workspace (an app never lives in two registered sets). Returns
  /// whether the app was added (`false` = removed).
  public mutating func toggleMembership(
    bundleId: String, name: String, in workspaceId: Workspace.ID
  ) -> Bool {
    var didAdd = false
    mutateActiveProfile { profile in
      guard let workspace = profile.workspaces[id: workspaceId] else { return }
      if workspace.apps.contains(where: { $0.bundleIdentifier == bundleId }) {
        profile.workspaces[id: workspaceId]?.apps
          .removeAll { $0.bundleIdentifier == bundleId }
      } else {
        for id in profile.workspaces.ids {
          profile.workspaces[id: id]?.apps.removeAll { $0.bundleIdentifier == bundleId }
        }
        profile.workspaces[id: workspaceId]?.apps.append(
          AppAssignment(bundleIdentifier: bundleId, name: name.isEmpty ? bundleId : name)
        )
        didAdd = true
      }
    }
    return didAdd
  }

  /// Per-workspace float toggle. Floating a window that isn't assigned
  /// to the workspace yet adds it as a floating member. Returns the
  /// app's new floating state.
  public mutating func toggleFloating(
    bundleId: String, name: String, in workspaceId: Workspace.ID
  ) -> Bool {
    var nowFloating = false
    mutateWorkspace(workspaceId) { workspace in
      if let idx = workspace.apps.firstIndex(where: { $0.bundleIdentifier == bundleId }) {
        workspace.apps[idx].layout = workspace.apps[idx].layout == .floating ? .tiled : .floating
        nowFloating = workspace.apps[idx].layout == .floating
      } else {
        workspace.apps.append(
          AppAssignment(
            bundleIdentifier: bundleId, name: name.isEmpty ? bundleId : name, layout: .floating
          )
        )
        nowFloating = true
      }
    }
    return nowFloating
  }

  /// Float is an *attribute* here, same as the per-workspace toggle: not
  /// shared yet → join Shared Apps as floating; already shared → flip
  /// only the float state (membership stays — removing from Shared Apps
  /// is `toggleSharedMembership`'s / the GUI's axis). Returns the app's
  /// new floating state.
  public mutating func toggleSharedFloating(bundleId: String, name: String) -> Bool {
    if let idx = sharedApps.firstIndex(where: { $0.bundleIdentifier == bundleId }) {
      sharedApps[idx].layout = sharedApps[idx].layout == .floating ? .tiled : .floating
      return sharedApps[idx].layout == .floating
    }
    sharedApps.append(
      SharedApp(bundleIdentifier: bundleId, name: name.isEmpty ? bundleId : name, layout: .floating)
    )
    return true
  }

  /// Shared Apps membership toggle (added tiled; removing drops the
  /// entry entirely). Returns whether the app was added.
  public mutating func toggleSharedMembership(bundleId: String, name: String) -> Bool {
    if sharedApps.contains(where: { $0.bundleIdentifier == bundleId }) {
      sharedApps.removeAll { $0.bundleIdentifier == bundleId }
      return false
    }
    sharedApps.append(
      SharedApp(bundleIdentifier: bundleId, name: name.isEmpty ? bundleId : name)
    )
    return true
  }

  /// Relocate the app to a single workspace (single-membership),
  /// carrying an existing assignment's metadata (display name, icon,
  /// auto-open) across the move.
  public mutating func moveApp(
    bundleId: String, name: String, to workspaceId: Workspace.ID
  ) {
    mutateActiveProfile { profile in
      let existing = profile.workspaces
        .flatMap(\.apps)
        .first { $0.bundleIdentifier == bundleId }
      for id in profile.workspaces.ids {
        profile.workspaces[id: id]?.apps.removeAll { $0.bundleIdentifier == bundleId }
      }
      profile.workspaces[id: workspaceId]?.apps.append(
        existing
          ?? AppAssignment(bundleIdentifier: bundleId, name: name.isEmpty ? bundleId : name)
      )
    }
  }

  /// Duplicate-assign: add to the target *without* removing the app from
  /// any workspace it already belongs to (unlike `moveApp`).
  public mutating func assignApp(
    bundleId: String, name: String, to workspaceId: Workspace.ID
  ) {
    mutateActiveProfile { profile in
      guard let workspace = profile.workspaces[id: workspaceId],
            !workspace.apps.contains(where: { $0.bundleIdentifier == bundleId })
      else { return }
      profile.workspaces[id: workspaceId]?.apps.append(
        AppAssignment(bundleIdentifier: bundleId, name: name.isEmpty ? bundleId : name)
      )
    }
  }
}
