import Foundation
import SQLiteData

/// One unit of "what's visible right now": a named set of app assignments,
/// pinned to a display (or floating across displays in `dynamic` mode).
@Table("workspaces")
public struct Workspace: Identifiable, Hashable, Sendable {
  public let id: UUID
  public var profileId: Profile.ID
  public var name: String
  /// Static-mode display assignment. `nil` means dynamic (follow apps).
  public var displayHint: DisplayName?
  /// Hotkey that activates this workspace.
  public var activateShortcut: HotKey?
  /// Hotkey that assigns the focused app to this workspace.
  public var assignAppShortcut: HotKey?
  /// SF Symbol name for menu/space-control rendering.
  public var symbolIconName: String?
  /// Whether non-running assigned apps should auto-launch when activated.
  public var openAppsOnActivation: Bool
  /// Bundle identifier of the app to focus when this workspace activates.
  /// Nil = focus the most recently active assigned app.
  public var appToFocusBundleId: String?
  /// Display order within a profile.
  public var sortOrder: Int

  public init(
    id: UUID = UUID(),
    profileId: Profile.ID,
    name: String,
    displayHint: DisplayName? = nil,
    activateShortcut: HotKey? = nil,
    assignAppShortcut: HotKey? = nil,
    symbolIconName: String? = nil,
    openAppsOnActivation: Bool = false,
    appToFocusBundleId: String? = nil,
    sortOrder: Int = 0
  ) {
    self.id = id
    self.profileId = profileId
    self.name = name
    self.displayHint = displayHint
    self.activateShortcut = activateShortcut
    self.assignAppShortcut = assignAppShortcut
    self.symbolIconName = symbolIconName
    self.openAppsOnActivation = openAppsOnActivation
    self.appToFocusBundleId = appToFocusBundleId
    self.sortOrder = sortOrder
  }
}

extension Workspace {
  public var isDynamic: Bool { displayHint == nil }
}
