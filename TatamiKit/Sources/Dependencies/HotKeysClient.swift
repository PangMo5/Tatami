import Dependencies
import Foundation
import KeyboardShortcuts

/// Every distinct keyboard-driven action Tatami can fire. The enum lives
/// here (not in features) so `HotKeysClient` can stay generic over the
/// command space — features just register bindings and react to events.
public enum HotKeyAction: Sendable, Hashable {
  // Workspace ops
  case activateWorkspace(Workspace.ID)
  case moveFocusedWindowToWorkspace(Workspace.ID)
  case switchToNextWorkspace
  case switchToPreviousWorkspace
  case switchToRecentWorkspace

  // Directional focus
  case focusLeft, focusRight, focusUp, focusDown

  // Window cycling
  case cycleNextWindow, cyclePreviousWindow

  // BSP operations
  case resizeGrow, resizeShrink
  case swapLeft, swapRight, swapUp, swapDown
  case toggleOrientation, toggleFullscreen

  // Misc toggles
  case toggleFloating, toggleSpaceActivated
}

public struct HotKeyBinding: Sendable, Hashable {
  public var action: HotKeyAction
  public var hotKey: HotKey

  public init(action: HotKeyAction, hotKey: HotKey) {
    self.action = action
    self.hotKey = hotKey
  }
}

/// Side-effect surface for registering global keyboard shortcuts.
public struct HotKeysClient: Sendable {
  public var register: @Sendable ([HotKeyBinding]) async -> Void
  public var events: @Sendable () -> AsyncStream<HotKeyAction>

  public init(
    register: @escaping @Sendable ([HotKeyBinding]) async -> Void,
    events: @escaping @Sendable () -> AsyncStream<HotKeyAction>
  ) {
    self.register = register
    self.events = events
  }
}

extension HotKeysClient: DependencyKey {
  public static let liveValue: HotKeysClient = {
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

  public static let testValue = HotKeysClient(
    register: { _ in },
    events: { AsyncStream { _ in } }
  )

  public static let previewValue = testValue
}

extension DependencyValues {
  public var hotKeys: HotKeysClient {
    get { self[HotKeysClient.self] }
    set { self[HotKeysClient.self] = newValue }
  }
}

private final class HotKeysCenter: @unchecked Sendable {
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
      let key = nameKey(for: binding.action)
      let name = KeyboardShortcuts.Name("tatami.\(key)")
      KeyboardShortcuts.setShortcut(binding.hotKey.shortcut, for: name)
      let action = binding.action
      let continuation = continuation
      KeyboardShortcuts.onKeyDown(for: name) {
        continuation.yield(action)
      }
      next.append((name, binding.action))
    }
    registered = next
  }

  private func nameKey(for action: HotKeyAction) -> String {
    switch action {
    case .activateWorkspace(let id):
      return "activate-\(id.uuidString)"
    case .moveFocusedWindowToWorkspace(let id):
      return "move-window-\(id.uuidString)"
    case .switchToNextWorkspace: return "next-workspace"
    case .switchToPreviousWorkspace: return "prev-workspace"
    case .switchToRecentWorkspace: return "recent-workspace"
    case .focusLeft: return "focus-left"
    case .focusRight: return "focus-right"
    case .focusUp: return "focus-up"
    case .focusDown: return "focus-down"
    case .cycleNextWindow: return "cycle-next"
    case .cyclePreviousWindow: return "cycle-prev"
    case .resizeGrow: return "resize-grow"
    case .resizeShrink: return "resize-shrink"
    case .swapLeft: return "swap-left"
    case .swapRight: return "swap-right"
    case .swapUp: return "swap-up"
    case .swapDown: return "swap-down"
    case .toggleOrientation: return "toggle-orientation"
    case .toggleFullscreen: return "toggle-fullscreen"
    case .toggleFloating: return "toggle-floating"
    case .toggleSpaceActivated: return "toggle-space"
    }
  }
}
