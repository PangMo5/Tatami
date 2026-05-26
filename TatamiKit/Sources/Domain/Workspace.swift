import Foundation

/// One unit of "what's visible right now": a named set of app assignments,
/// pinned to a display (or floating across displays in `dynamic` mode).
public struct Workspace: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
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
  public var apps: [AppAssignment]

  public init(
    id: UUID = UUID(),
    name: String,
    displayHint: DisplayName? = nil,
    activateShortcut: HotKey? = nil,
    assignAppShortcut: HotKey? = nil,
    symbolIconName: String? = nil,
    openAppsOnActivation: Bool = false,
    appToFocusBundleId: String? = nil,
    apps: [AppAssignment] = []
  ) {
    self.id = id
    self.name = name
    self.displayHint = displayHint
    self.activateShortcut = activateShortcut
    self.assignAppShortcut = assignAppShortcut
    self.symbolIconName = symbolIconName
    self.openAppsOnActivation = openAppsOnActivation
    self.appToFocusBundleId = appToFocusBundleId
    self.apps = apps
  }
}

extension Workspace {
  public var isDynamic: Bool { displayHint == nil }
}
