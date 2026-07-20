import Foundation

// MARK: - GestureDirection

/// One direction reported by a trackpad swipe. The recognizer emits the
/// physical finger direction; settings decide which Tatami command it runs.
public enum GestureDirection: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
  case left
  case right
  case up
  case down

  // MARK: Public

  public var id: String {
    rawValue
  }

  public var title: LocalizedStringResource {
    switch self {
    case .left: "Swipe left"
    case .right: "Swipe right"
    case .up: "Swipe up"
    case .down: "Swipe down"
    }
  }

  public var symbolName: String {
    switch self {
    case .left: "arrow.left"
    case .right: "arrow.right"
    case .up: "arrow.up"
    case .down: "arrow.down"
    }
  }
}

// MARK: - TrackpadGesture

/// A recognized three- or four-finger swipe.
public struct TrackpadGesture: Hashable, Sendable {
  public init(fingerCount: Int, direction: GestureDirection) {
    self.fingerCount = fingerCount
    self.direction = direction
  }

  public var fingerCount: Int
  public var direction: GestureDirection
}

// MARK: - GestureAction

/// Config-persisted commands available to gesture bindings. Associated ids let
/// the picker expose the same workspace/profile-specific operations as Tatami's
/// hotkeys; custom single-string coding keeps the TOML stable and readable.
public enum GestureAction: Codable, Hashable, Sendable, Identifiable {
  case none

  case nextWorkspace
  case previousWorkspace
  case recentWorkspace
  case moveAppToNextWorkspace
  case moveAppToPreviousWorkspace
  case assignAppToRecentWorkspace
  case assignAppToNextWorkspace
  case assignAppToPreviousWorkspace

  case focusNextDisplay
  case focusPreviousDisplay
  case focusLeft
  case focusRight
  case focusUp
  case focusDown

  case cycleNextWindow
  case cyclePreviousWindow

  case growWindow
  case shrinkWindow
  case swapLeft
  case swapRight
  case swapUp
  case swapDown
  case toggleOrientation
  case toggleFullscreen
  case balanceLayout

  case toggleFloating
  case toggleSharedFloating
  case toggleTiling
  case toggleAppInWorkspace
  case toggleAppInSharedApps

  case borrowRecentWorkspace
  case borrowNextWorkspace
  case borrowPreviousWorkspace
  case dismissBorrow

  case activateWorkspace(Workspace.ID)
  case assignAppToWorkspace(Workspace.ID)
  case borrowWorkspace(Workspace.ID)
  case activateProfile(Profile.ID)

  // MARK: Public

  public enum Category: String, CaseIterable, Identifiable, Sendable {
    case none
    case workspace
    case profile
    case focus
    case window
    case layout
    case app
    case borrow

    // MARK: Public

    public var id: String {
      rawValue
    }

    public var title: LocalizedStringResource {
      switch self {
      case .none: "Binding"
      case .workspace: "Workspaces"
      case .profile: "Profiles"
      case .focus: "Focus & Displays"
      case .window: "Window Cycling"
      case .layout: "Layout"
      case .app: "Apps & Tiling"
      case .borrow: "Borrow"
      }
    }

    /// Pre-grouped picker contents. Keeping this domain-owned avoids filtering
    /// every action during each SwiftUI body evaluation.
    public var actions: [GestureAction] {
      switch self {
      case .none:
        [.none]

      case .workspace:
        [
          .nextWorkspace,
          .previousWorkspace,
          .recentWorkspace,
          .moveAppToNextWorkspace,
          .moveAppToPreviousWorkspace,
          .assignAppToRecentWorkspace,
          .assignAppToNextWorkspace,
          .assignAppToPreviousWorkspace,
        ]

      case .profile:
        []

      case .focus:
        [.focusNextDisplay, .focusPreviousDisplay, .focusLeft, .focusRight, .focusUp, .focusDown]

      case .window:
        [.cycleNextWindow, .cyclePreviousWindow]

      case .layout:
        [
          .growWindow,
          .shrinkWindow,
          .swapLeft,
          .swapRight,
          .swapUp,
          .swapDown,
          .toggleOrientation,
          .toggleFullscreen,
          .balanceLayout,
        ]

      case .app:
        [
          .toggleFloating,
          .toggleSharedFloating,
          .toggleTiling,
          .toggleAppInWorkspace,
          .toggleAppInSharedApps,
        ]

      case .borrow:
        [.borrowRecentWorkspace, .borrowNextWorkspace, .borrowPreviousWorkspace, .dismissBorrow]
      }
    }
  }

  public var id: String {
    storageValue
  }

  /// Fixed commands grouped by `Category`. Workspace/profile-specific actions
  /// are generated from the live config by the Settings picker.
  public static let fixedActions = Category.allCases.flatMap(\.actions)

  public func title(in config: AppConfig) -> LocalizedStringResource {
    switch self {
    case .none: "None"
    case .nextWorkspace: "Next workspace"
    case .previousWorkspace: "Previous workspace"
    case .recentWorkspace: "Recent workspace"
    case .moveAppToNextWorkspace: "Move app to next workspace"
    case .moveAppToPreviousWorkspace: "Move app to previous workspace"
    case .assignAppToRecentWorkspace: "Assign app to recent workspace"
    case .assignAppToNextWorkspace: "Assign app to next workspace"
    case .assignAppToPreviousWorkspace: "Assign app to previous workspace"
    case .focusNextDisplay: "Focus next display"
    case .focusPreviousDisplay: "Focus previous display"
    case .focusLeft: "Focus left"
    case .focusRight: "Focus right"
    case .focusUp: "Focus up"
    case .focusDown: "Focus down"
    case .cycleNextWindow: "Cycle next window"
    case .cyclePreviousWindow: "Cycle previous window"
    case .growWindow: "Grow window"
    case .shrinkWindow: "Shrink window"
    case .swapLeft: "Swap left"
    case .swapRight: "Swap right"
    case .swapUp: "Swap up"
    case .swapDown: "Swap down"
    case .toggleOrientation: "Toggle orientation"
    case .toggleFullscreen: "Toggle fullscreen"
    case .balanceLayout: "Balance layout"
    case .toggleFloating: "Toggle floating"
    case .toggleSharedFloating: "Toggle shared floating"
    case .toggleTiling: "Pause or resume tiling"
    case .toggleAppInWorkspace: "Toggle app in workspace"
    case .toggleAppInSharedApps: "Toggle app in Shared Apps"
    case .borrowRecentWorkspace: "Borrow recent workspace"
    case .borrowNextWorkspace: "Borrow next workspace"
    case .borrowPreviousWorkspace: "Borrow previous workspace"
    case .dismissBorrow: "Dismiss borrow"
    case .activateWorkspace(let id):
      "Switch to \(workspaceName(id, in: config))"
    case .assignAppToWorkspace(let id):
      "Assign app to \(workspaceName(id, in: config))"
    case .borrowWorkspace(let id):
      "Borrow \(workspaceName(id, in: config))"
    case .activateProfile(let id):
      "Switch to \(profileName(id, in: config))"
    }
  }

  public var category: Category {
    switch self {
    case .none: .none
    case .nextWorkspace,
         .previousWorkspace,
         .recentWorkspace,
         .moveAppToNextWorkspace,
         .moveAppToPreviousWorkspace,
         .assignAppToRecentWorkspace,
         .assignAppToNextWorkspace,
         .assignAppToPreviousWorkspace:
      .workspace
    case .focusNextDisplay,
         .focusPreviousDisplay,
         .focusLeft,
         .focusRight,
         .focusUp,
         .focusDown:
      .focus
    case .cycleNextWindow,
         .cyclePreviousWindow:
      .window
    case .growWindow,
         .shrinkWindow,
         .swapLeft,
         .swapRight,
         .swapUp,
         .swapDown,
         .toggleOrientation,
         .toggleFullscreen,
         .balanceLayout:
      .layout
    case .toggleFloating,
         .toggleSharedFloating,
         .toggleTiling,
         .toggleAppInWorkspace,
         .toggleAppInSharedApps:
      .app
    case .borrowRecentWorkspace,
         .borrowNextWorkspace,
         .borrowPreviousWorkspace,
         .dismissBorrow,
         .borrowWorkspace:
      .borrow
    case .activateWorkspace:
      .workspace
    case .assignAppToWorkspace:
      .app
    case .activateProfile:
      .profile
    }
  }

  public func isAvailable(in config: AppConfig) -> Bool {
    switch self {
    case .activateWorkspace(let id),
         .assignAppToWorkspace(let id):
      return config.profiles.contains { $0.workspaces[id: id] != nil }
    case .borrowWorkspace(let id):
      return config.activeProfile?.workspaces[id: id] != nil
    case .activateProfile(let id):
      return config.profiles.contains(where: { $0.id == id })
    default:
      return true
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let action = Self(storageValue: value) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unknown gesture action: \(value)"
      )
    }
    self = action
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(storageValue)
  }

  // MARK: Private

  private static let activateWorkspacePrefix = "activateWorkspace:"
  private static let assignAppToWorkspacePrefix = "assignAppToWorkspace:"
  private static let borrowWorkspacePrefix = "borrowWorkspace:"
  private static let activateProfilePrefix = "activateProfile:"

  private init?(storageValue: String) {
    if let id = Self.id(after: Self.activateWorkspacePrefix, in: storageValue) {
      self = .activateWorkspace(id)
      return
    }
    if let id = Self.id(after: Self.assignAppToWorkspacePrefix, in: storageValue) {
      self = .assignAppToWorkspace(id)
      return
    }
    if let id = Self.id(after: Self.borrowWorkspacePrefix, in: storageValue) {
      self = .borrowWorkspace(id)
      return
    }
    if let id = Self.id(after: Self.activateProfilePrefix, in: storageValue) {
      self = .activateProfile(id)
      return
    }
    guard let action = Self.fixedActionByStorageValue[storageValue] else { return nil }
    self = action
  }

  private var storageValue: String {
    switch self {
    case .none: "none"
    case .nextWorkspace: "nextWorkspace"
    case .previousWorkspace: "previousWorkspace"
    case .recentWorkspace: "recentWorkspace"
    case .moveAppToNextWorkspace: "moveAppToNextWorkspace"
    case .moveAppToPreviousWorkspace: "moveAppToPreviousWorkspace"
    case .assignAppToRecentWorkspace: "assignAppToRecentWorkspace"
    case .assignAppToNextWorkspace: "assignAppToNextWorkspace"
    case .assignAppToPreviousWorkspace: "assignAppToPreviousWorkspace"
    case .focusNextDisplay: "focusNextDisplay"
    case .focusPreviousDisplay: "focusPreviousDisplay"
    case .focusLeft: "focusLeft"
    case .focusRight: "focusRight"
    case .focusUp: "focusUp"
    case .focusDown: "focusDown"
    case .cycleNextWindow: "cycleNextWindow"
    case .cyclePreviousWindow: "cyclePreviousWindow"
    case .growWindow: "growWindow"
    case .shrinkWindow: "shrinkWindow"
    case .swapLeft: "swapLeft"
    case .swapRight: "swapRight"
    case .swapUp: "swapUp"
    case .swapDown: "swapDown"
    case .toggleOrientation: "toggleOrientation"
    case .toggleFullscreen: "toggleFullscreen"
    case .balanceLayout: "balanceLayout"
    case .toggleFloating: "toggleFloating"
    case .toggleSharedFloating: "toggleSharedFloating"
    case .toggleTiling: "toggleTiling"
    case .toggleAppInWorkspace: "toggleAppInWorkspace"
    case .toggleAppInSharedApps: "toggleAppInSharedApps"
    case .borrowRecentWorkspace: "borrowRecentWorkspace"
    case .borrowNextWorkspace: "borrowNextWorkspace"
    case .borrowPreviousWorkspace: "borrowPreviousWorkspace"
    case .dismissBorrow: "dismissBorrow"
    case .activateWorkspace(let id): Self.activateWorkspacePrefix + id.uuidString
    case .assignAppToWorkspace(let id): Self.assignAppToWorkspacePrefix + id.uuidString
    case .borrowWorkspace(let id): Self.borrowWorkspacePrefix + id.uuidString
    case .activateProfile(let id): Self.activateProfilePrefix + id.uuidString
    }
  }

  private static let fixedActionByStorageValue: [String: Self] = {
    Dictionary(uniqueKeysWithValues: fixedActions.map { ($0.storageValue, $0) })
  }()

  private static func id(after prefix: String, in value: String) -> UUID? {
    guard value.hasPrefix(prefix) else { return nil }
    return UUID(uuidString: String(value.dropFirst(prefix.count)))
  }

  private func workspaceName(_ id: Workspace.ID, in config: AppConfig) -> String {
    config.profiles.lazy.compactMap { $0.workspaces[id: id]?.name }.first
      ?? "missing workspace"
  }

  private func profileName(_ id: Profile.ID, in config: AppConfig) -> String {
    config.profiles.first(where: { $0.id == id })?.name ?? "missing profile"
  }
}
