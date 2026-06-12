import Dependencies
import DependenciesMacros
import Foundation
import KeyboardShortcuts

/// Every distinct keyboard-driven action Tatami can fire. The enum lives
/// here (not in features) so `HotKeysClient` can stay generic over the
/// command space — features just register bindings and react to events.
public enum HotKeyAction: Sendable, Hashable {
  // Workspace ops
  case activateWorkspace(Workspace.ID)
  /// Assign the focused app to a specific workspace (duplicate assignment)
  /// and switch to it.
  case assignFocusedAppToWorkspace(Workspace.ID)
  case switchToNextWorkspace
  case switchToPreviousWorkspace
  case switchToRecentWorkspace

  // Move the focused app to an adjacent workspace (relocate + switch)
  case moveFocusedAppToNextWorkspace
  case moveFocusedAppToPreviousWorkspace

  // Focus the workspace on the next / previous display (looping)
  case focusNextDisplay
  case focusPreviousDisplay

  // Directional focus
  case focusLeft, focusRight, focusUp, focusDown

  // Window cycling
  case cycleNextWindow, cyclePreviousWindow

  // BSP operations
  case resizeGrow, resizeShrink
  case swapLeft, swapRight, swapUp, swapDown
  case toggleOrientation, toggleFullscreen
  case balance

  // Misc toggles
  case toggleFloating, toggleSpaceActivated
  /// Float toggle against Shared Apps instead of the active workspace:
  /// not shared yet → added as shared floating; already shared → flip
  /// `floating` only (membership stays).
  case toggleSharedFloating
  /// Toggle the focused window's app's membership in the active
  /// workspace's registered set — equivalent to manually adding /
  /// removing the app on the workspace detail screen, but without
  /// taking the user out of whatever they're doing.
  case toggleFocusedAppInActiveWorkspace
  /// Toggle the focused window's app in Shared Apps (added tiled).
  case toggleAppInSharedApps
}

extension HotKeyAction {
  /// Stable key segment used to build the `KeyboardShortcuts.Name`.
  /// Shared by the registrar and the Settings recorders so both target
  /// the exact same shortcut slot.
  var nameKey: String {
    switch self {
    case .activateWorkspace(let id): "activate-\(id.uuidString)"
    case .assignFocusedAppToWorkspace(let id): "assign-app-\(id.uuidString)"
    case .switchToNextWorkspace: "next-workspace"
    case .switchToPreviousWorkspace: "prev-workspace"
    case .switchToRecentWorkspace: "recent-workspace"
    case .moveFocusedAppToNextWorkspace: "move-app-next-workspace"
    case .moveFocusedAppToPreviousWorkspace: "move-app-prev-workspace"
    case .focusNextDisplay: "focus-next-display"
    case .focusPreviousDisplay: "focus-prev-display"
    case .focusLeft: "focus-left"
    case .focusRight: "focus-right"
    case .focusUp: "focus-up"
    case .focusDown: "focus-down"
    case .cycleNextWindow: "cycle-next"
    case .cyclePreviousWindow: "cycle-prev"
    case .resizeGrow: "resize-grow"
    case .resizeShrink: "resize-shrink"
    case .swapLeft: "swap-left"
    case .swapRight: "swap-right"
    case .swapUp: "swap-up"
    case .swapDown: "swap-down"
    case .toggleOrientation: "toggle-orientation"
    case .toggleFullscreen: "toggle-fullscreen"
    case .balance: "balance"
    case .toggleFloating: "toggle-floating"
    case .toggleSharedFloating: "toggle-shared-floating"
    case .toggleSpaceActivated: "toggle-space"
    case .toggleFocusedAppInActiveWorkspace: "toggle-focused-app-membership"
    case .toggleAppInSharedApps: "toggle-shared-membership"
    }
  }

  public var keyboardShortcutName: KeyboardShortcuts.Name {
    KeyboardShortcuts.Name("tatami.\(nameKey)")
  }
}

public struct HotKeyBinding: Sendable, Hashable {
  var action: HotKeyAction
  var hotKey: HotKey

  init(action: HotKeyAction, hotKey: HotKey) {
    self.action = action
    self.hotKey = hotKey
  }
}

/// Side-effect surface for registering global keyboard shortcuts.
@DependencyClient
struct HotKeysClient: Sendable {
  var register: @Sendable ([HotKeyBinding]) async -> Void
  var events: @Sendable () -> AsyncStream<HotKeyAction> = { AsyncStream { _ in } }
}

extension HotKeysClient: DependencyKey {
  static let liveValue: HotKeysClient = {
    let center = HotKeysCenter()
    return HotKeysClient(
      register: { bindings in
        await MainActor.run {
          center.register(bindings)
        }
      },
      events: { center.events }
    )
  }()

  static let testValue = HotKeysClient(
    register: { _ in },
    events: { AsyncStream { _ in } }
  )

  static let previewValue = testValue
}

extension DependencyValues {
  var hotKeys: HotKeysClient {
    get { self[HotKeysClient.self] }
    set { self[HotKeysClient.self] = newValue }
  }
}

private final class HotKeysCenter: @unchecked Sendable {
  @Dependency(\.debugLog) private var debugLog

  let events: AsyncStream<HotKeyAction>
  private let continuation: AsyncStream<HotKeyAction>.Continuation
  private var registered: [(KeyboardShortcuts.Name, HotKeyAction)] = []

  init() {
    var c: AsyncStream<HotKeyAction>.Continuation!
    self.events = AsyncStream { c = $0 }
    self.continuation = c
  }

  @MainActor
  func register(_ bindings: [HotKeyBinding]) {
    if !registered.isEmpty {
      KeyboardShortcuts.removeAllHandlers()
    }
    var next: [(KeyboardShortcuts.Name, HotKeyAction)] = []
    for binding in bindings {
      let name = binding.action.keyboardShortcutName
      KeyboardShortcuts.setShortcut(binding.hotKey.shortcut, for: name)
      let action = binding.action
      let continuation = continuation
      let debugLog = debugLog
      KeyboardShortcuts.onKeyDown(for: name) {
        // First line of every hotkey trace: separates "the key never
        // reached Tatami" (no line) from "the action misbehaved".
        debugLog.log("HotKey", action.nameKey)
        continuation.yield(action)
      }
      next.append((name, binding.action))
    }
    registered = next
    debugLog.log("HotKey", "registered \(next.count) bindings")
  }
}
