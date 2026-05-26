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
  /// Hotkey that moves the focused window into this workspace.
  public var moveWindowShortcut: HotKey?
  /// SF Symbol name for menu/space-control rendering.
  public var symbolIconName: String?
  /// Whether non-running assigned apps should auto-launch when activated.
  public var openAppsOnActivation: Bool
  /// Bundle identifier of the app to focus when this workspace activates.
  /// Nil = focus the most recently active assigned app.
  public var appToFocusBundleId: String?
  /// How Tatami should arrange this workspace's windows on activation.
  public var tilingMode: TilingMode
  public var apps: [AppAssignment]

  public init(
    id: UUID = UUID(),
    name: String,
    displayHint: DisplayName? = nil,
    activateShortcut: HotKey? = nil,
    assignAppShortcut: HotKey? = nil,
    moveWindowShortcut: HotKey? = nil,
    symbolIconName: String? = nil,
    openAppsOnActivation: Bool = false,
    appToFocusBundleId: String? = nil,
    tilingMode: TilingMode = .floating,
    apps: [AppAssignment] = []
  ) {
    self.id = id
    self.name = name
    self.displayHint = displayHint
    self.activateShortcut = activateShortcut
    self.assignAppShortcut = assignAppShortcut
    self.moveWindowShortcut = moveWindowShortcut
    self.symbolIconName = symbolIconName
    self.openAppsOnActivation = openAppsOnActivation
    self.appToFocusBundleId = appToFocusBundleId
    self.tilingMode = tilingMode
    self.apps = apps
  }
}

extension Workspace {
  private enum CodingKeys: String, CodingKey {
    case id, name, displayHint, activateShortcut, assignAppShortcut, moveWindowShortcut
    case symbolIconName, openAppsOnActivation, appToFocusBundleId
    case tilingMode, apps
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    displayHint = try container.decodeIfPresent(DisplayName.self, forKey: .displayHint)
    activateShortcut = try container.decodeIfPresent(HotKey.self, forKey: .activateShortcut)
    assignAppShortcut = try container.decodeIfPresent(HotKey.self, forKey: .assignAppShortcut)
    moveWindowShortcut = try container.decodeIfPresent(HotKey.self, forKey: .moveWindowShortcut)
    symbolIconName = try container.decodeIfPresent(String.self, forKey: .symbolIconName)
    openAppsOnActivation = try container.decodeIfPresent(Bool.self, forKey: .openAppsOnActivation)
      ?? false
    appToFocusBundleId = try container.decodeIfPresent(String.self, forKey: .appToFocusBundleId)
    tilingMode = try container.decodeIfPresent(TilingMode.self, forKey: .tilingMode) ?? .floating
    apps = try container.decodeIfPresent([AppAssignment].self, forKey: .apps) ?? []
  }
}

extension Workspace {
  public var isDynamic: Bool { displayHint == nil }
}
