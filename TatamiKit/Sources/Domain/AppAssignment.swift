import Foundation
import SQLiteData

/// Many-to-many membership row between a `Workspace` and a `MacApp`.
///
/// `MacApp`'s columns are embedded directly rather than referenced via a
/// foreign key — `(workspaceId, bundleIdentifier)` is the natural key and
/// the same app can legitimately belong to multiple workspaces with
/// different per-workspace metadata (e.g. autoOpen).
@Table("app_assignments")
public struct AppAssignment: Identifiable, Hashable, Sendable {
  public let id: UUID
  public var workspaceId: Workspace.ID
  public var bundleIdentifier: String
  public var name: String
  public var iconPath: String?
  /// Launch the app automatically when its workspace activates.
  public var autoOpen: Bool
  public var sortOrder: Int

  public init(
    id: UUID = UUID(),
    workspaceId: Workspace.ID,
    bundleIdentifier: String,
    name: String,
    iconPath: String? = nil,
    autoOpen: Bool = false,
    sortOrder: Int = 0
  ) {
    self.id = id
    self.workspaceId = workspaceId
    self.bundleIdentifier = bundleIdentifier
    self.name = name
    self.iconPath = iconPath
    self.autoOpen = autoOpen
    self.sortOrder = sortOrder
  }
}

extension AppAssignment {
  public init(workspaceId: Workspace.ID, app: MacApp, sortOrder: Int = 0) {
    self.init(
      workspaceId: workspaceId,
      bundleIdentifier: app.bundleIdentifier,
      name: app.name,
      iconPath: app.iconPath,
      autoOpen: false,
      sortOrder: sortOrder
    )
  }

  public var app: MacApp {
    MacApp(bundleIdentifier: bundleIdentifier, name: name, iconPath: iconPath)
  }
}
