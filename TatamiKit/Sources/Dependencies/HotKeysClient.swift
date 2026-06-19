import Dependencies
import DependenciesMacros
import Foundation
import Magnet

/// Every distinct keyboard-driven action Tatami can fire. The enum lives
/// here (not in features) so `HotKeysClient` can stay generic over the
/// command space — features just register bindings and react to events.
public enum HotKeyAction: Sendable, Hashable {
  // Workspace ops
  case activateWorkspace(Workspace.ID)
  /// Assign the focused app to a specific workspace (duplicate assignment)
  /// and switch to it.
  case assignFocusedAppToWorkspace(Workspace.ID)
  /// Borrow a specific workspace into the current screen — arms a one-key
  /// direction pick (h/j/k/l or arrows) to place it.
  case borrowWorkspace(Workspace.ID)
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

  // Recent / next / previous workspace as assign / borrow targets (same key
  // as switching, with the assign / borrow modifier).
  case assignFocusedAppToRecentWorkspace
  case assignFocusedAppToNextWorkspace
  case assignFocusedAppToPreviousWorkspace
  case borrowRecentWorkspace
  case borrowNextWorkspace
  case borrowPreviousWorkspace
  /// Dismiss the active borrow on the focused display.
  case dismissBorrow
}

extension HotKeyAction {
  /// Stable identifier for the Magnet hotkey registration — also the
  /// debug-log tag for a fired action.
  var nameKey: String {
    switch self {
    case .activateWorkspace(let id): "activate-\(id.uuidString)"
    case .assignFocusedAppToWorkspace(let id): "assign-app-\(id.uuidString)"
    case .borrowWorkspace(let id): "borrow-\(id.uuidString)"
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
    case .assignFocusedAppToRecentWorkspace: "assign-app-recent-workspace"
    case .assignFocusedAppToNextWorkspace: "assign-app-next-workspace"
    case .assignFocusedAppToPreviousWorkspace: "assign-app-prev-workspace"
    case .borrowRecentWorkspace: "borrow-recent-workspace"
    case .borrowNextWorkspace: "borrow-next-workspace"
    case .borrowPreviousWorkspace: "borrow-prev-workspace"
    case .dismissBorrow: "dismiss-borrow"
    }
  }

  /// Human-readable title, shown in the recorder's "in use" conflict
  /// message. Workspace actions resolve the workspace's current name.
  public func title(in config: AppConfig) -> String {
    switch self {
    case .activateWorkspace(let id):
      "Activate " + (config.activeProfile?.workspaces[id: id]?.name ?? "workspace")
    case .assignFocusedAppToWorkspace(let id):
      "Assign app to " + (config.activeProfile?.workspaces[id: id]?.name ?? "workspace")
    case .borrowWorkspace(let id):
      "Borrow " + (config.activeProfile?.workspaces[id: id]?.name ?? "workspace")
    case .switchToNextWorkspace: "Next workspace"
    case .switchToPreviousWorkspace: "Previous workspace"
    case .switchToRecentWorkspace: "Recent workspace"
    case .moveFocusedAppToNextWorkspace: "Move app to next workspace"
    case .moveFocusedAppToPreviousWorkspace: "Move app to previous workspace"
    case .focusNextDisplay: "Focus next display"
    case .focusPreviousDisplay: "Focus previous display"
    case .focusLeft: "Focus left"
    case .focusRight: "Focus right"
    case .focusUp: "Focus up"
    case .focusDown: "Focus down"
    case .cycleNextWindow: "Cycle next window"
    case .cyclePreviousWindow: "Cycle previous window"
    case .resizeGrow: "Grow"
    case .resizeShrink: "Shrink"
    case .swapLeft: "Swap left"
    case .swapRight: "Swap right"
    case .swapUp: "Swap up"
    case .swapDown: "Swap down"
    case .toggleOrientation: "Toggle orientation"
    case .toggleFullscreen: "Toggle fullscreen"
    case .balance: "Balance layout"
    case .toggleFloating: "Toggle floating"
    case .toggleSharedFloating: "Toggle shared floating"
    case .toggleSpaceActivated: "Toggle pause"
    case .toggleFocusedAppInActiveWorkspace: "Toggle app in workspace"
    case .toggleAppInSharedApps: "Toggle app in Shared Apps"
    case .assignFocusedAppToRecentWorkspace: "Assign app to recent workspace"
    case .assignFocusedAppToNextWorkspace: "Assign app to next workspace"
    case .assignFocusedAppToPreviousWorkspace: "Assign app to previous workspace"
    case .borrowRecentWorkspace: "Borrow recent workspace"
    case .borrowNextWorkspace: "Borrow next workspace"
    case .borrowPreviousWorkspace: "Borrow previous workspace"
    case .dismissBorrow: "Dismiss borrow"
    }
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
  /// Suspend (`true`) / restore (`false`) every global hotkey while a
  /// shortcut recorder is capturing. Carbon hotkeys are swallowed
  /// system-wide even while we're frontmost, so without this the combo
  /// being recorded would fire its action instead of landing in the field.
  var setRecording: @Sendable (Bool) async -> Void
}

extension HotKeysClient: DependencyKey {
  static let liveValue: HotKeysClient = {
    let center = HotKeysCenter()
    return HotKeysClient(
      register: { bindings in
        await MainActor.run { center.register(bindings) }
      },
      events: { center.events },
      setRecording: { recording in
        await MainActor.run { center.setRecording(recording) }
      }
    )
  }()

  static let testValue = HotKeysClient(
    register: { _ in },
    events: { AsyncStream { _ in } },
    setRecording: { _ in }
  )

  static let previewValue = testValue
}

extension DependencyValues {
  var hotKeys: HotKeysClient {
    get { self[HotKeysClient.self] }
    set { self[HotKeysClient.self] = newValue }
  }
}

/// Bridges Magnet's `HotKeyCenter` (a main-actor global) to the action
/// stream: every `register` clears the previous set and (re)registers the
/// current bindings, each firing its `HotKeyAction` into `events`. Magnet
/// is Carbon-based, so the hotkeys work without the Input Monitoring or
/// Accessibility grant and stay live regardless of which window is key —
/// which the previous KeyboardShortcuts-based path couldn't guarantee in
/// this menu-bar (LSUIElement) app.
private final class HotKeysCenter: @unchecked Sendable {
  @Dependency(\.debugLog) private var debugLog

  let events: AsyncStream<HotKeyAction>
  private let continuation: AsyncStream<HotKeyAction>.Continuation
  /// Magnet identifiers currently registered (so the next `register`
  /// unregisters exactly what it put up, not the whole process's hotkeys).
  private var registeredIdentifiers: [String] = []
  /// Latest bindings, kept so recording can suspend the live hotkeys and
  /// restore exactly these when it ends — and so a config edit that lands
  /// mid-recording isn't lost (it updates this, applied on resume).
  private var lastBindings: [HotKeyBinding] = []
  /// While a recorder is capturing, no global hotkey is registered.
  private var isRecording = false

  init() {
    var c: AsyncStream<HotKeyAction>.Continuation!
    self.events = AsyncStream { c = $0 }
    self.continuation = c
  }

  @MainActor
  func register(_ bindings: [HotKeyBinding]) {
    lastBindings = bindings
    // A recorder is capturing — stay suspended; `setRecording(false)` will
    // apply whatever the latest bindings are.
    guard !isRecording else {
      debugLog.log("HotKey", "register deferred (recording) — \(bindings.count) bindings")
      return
    }
    apply(bindings)
  }

  @MainActor
  func setRecording(_ recording: Bool) {
    guard recording != isRecording else { return }
    isRecording = recording
    if recording {
      for identifier in registeredIdentifiers {
        HotKeyCenter.shared.unregisterHotKey(with: identifier)
      }
      registeredIdentifiers = []
      debugLog.log("HotKey", "suspended for recording")
    } else {
      apply(lastBindings)
      debugLog.log("HotKey", "resumed after recording")
    }
  }

  @MainActor
  private func apply(_ bindings: [HotKeyBinding]) {
    for identifier in registeredIdentifiers {
      HotKeyCenter.shared.unregisterHotKey(with: identifier)
    }
    var next: [String] = []
    for binding in bindings {
      // A stored combo Magnet rejects (no valid KeyCombo) is skipped — the
      // recorder won't produce one, but a hand-edited config might.
      guard let keyCombo = binding.hotKey.keyCombo else {
        debugLog.log("HotKey", "skip \(binding.action.nameKey): invalid key combo")
        continue
      }
      let identifier = binding.action.nameKey
      let action = binding.action
      let continuation = continuation
      let debugLog = debugLog
      let hotKey = Magnet.HotKey(identifier: identifier, keyCombo: keyCombo) { _ in
        // First line of every hotkey trace: separates "the key never
        // reached Tatami" (no line) from "the action misbehaved".
        debugLog.log("HotKey", action.nameKey)
        continuation.yield(action)
      }
      HotKeyCenter.shared.register(with: hotKey)
      debugLog.log("HotKey", "+ \(identifier) = \(binding.hotKey.displayString)")
      next.append(identifier)
    }
    registeredIdentifiers = next
    debugLog.log("HotKey", "registered \(next.count) bindings")
  }
}
