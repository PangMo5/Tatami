import Foundation

/// How a workspace remembers its BSP layout across re-activations.
public enum TilingMemory: String, Hashable, Sendable, Codable, CaseIterable {
  /// Remember for the lifetime of the app process. Switching away and
  /// back preserves split axes + user-tuned ratios, but a restart
  /// starts clean. (Default — matches prior behavior.)
  case session
  /// Remember across restarts. The tree shape (split axes + ratios) is
  /// snapshotted to disk keyed by bundle id, and restored when the same
  /// apps are present again.
  case persistent
}

/// One unit of "what's visible right now": a named set of app assignments,
/// pinned to a display (or floating across displays in `dynamic` mode).
public struct Workspace: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var name: String
  /// Static-mode display assignment. `nil` means dynamic (follow apps).
  public var displayHint: DisplayName?
  /// Hotkey that activates this workspace.
  public var activateShortcut: HotKey?
  /// Hotkey that assigns the focused app to this workspace (duplicate
  /// assignment — keeps existing memberships) and switches to it.
  public var assignAppShortcut: HotKey?
  /// SF Symbol name for menu/space-control rendering.
  public var symbolIconName: String?
  /// Bundle identifier of the app to focus when this workspace activates.
  /// Nil = focus the most recently active assigned app.
  public var appToFocusBundleId: String?
  /// How this workspace remembers its BSP layout across activations.
  /// `nil` inherits the global `AppSettings.defaultTilingMemory`.
  public var tilingMemory: TilingMemory?
  public var apps: [AppAssignment]

  public init(
    id: UUID = UUID(),
    name: String,
    displayHint: DisplayName? = nil,
    activateShortcut: HotKey? = nil,
    assignAppShortcut: HotKey? = nil,
    symbolIconName: String? = nil,
    appToFocusBundleId: String? = nil,
    tilingMemory: TilingMemory? = nil,
    apps: [AppAssignment] = []
  ) {
    self.id = id
    self.name = name
    self.displayHint = displayHint
    self.activateShortcut = activateShortcut
    self.assignAppShortcut = assignAppShortcut
    self.symbolIconName = symbolIconName
    self.appToFocusBundleId = appToFocusBundleId
    self.tilingMemory = tilingMemory
    self.apps = apps
  }
}

extension Workspace {
  private enum CodingKeys: String, CodingKey {
    case id, name, displayHint, activateShortcut, assignAppShortcut
    case symbolIconName, appToFocusBundleId
    case tilingMemory
    case apps
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    displayHint = try container.decodeIfPresent(DisplayName.self, forKey: .displayHint)
    activateShortcut = try container.decodeIfPresent(HotKey.self, forKey: .activateShortcut)
    assignAppShortcut = try container.decodeIfPresent(HotKey.self, forKey: .assignAppShortcut)
    symbolIconName = try container.decodeIfPresent(String.self, forKey: .symbolIconName)
    appToFocusBundleId = try container.decodeIfPresent(String.self, forKey: .appToFocusBundleId)
    tilingMemory = try container.decodeIfPresent(TilingMemory.self, forKey: .tilingMemory)
    apps = try container.decodeIfPresent([AppAssignment].self, forKey: .apps) ?? []
  }
}

extension Workspace {
  public var isDynamic: Bool { displayHint == nil }
}
