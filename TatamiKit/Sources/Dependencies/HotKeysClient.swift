import Dependencies
import DependenciesMacros
import CoreGraphics
import Foundation
import Magnet

// MARK: - HotKeyAction

/// Every distinct keyboard-driven action Tatami can fire. The enum lives
/// here (not in features) so `HotKeysClient` can stay generic over the
/// command space — features just register bindings and react to events.
public enum HotKeyAction: Sendable, Hashable {
  /// Workspace ops
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

  /// Profiles
  /// Switch to (activate) a specific profile.
  case activateProfile(Profile.ID)

  // Move the focused app to an adjacent workspace (relocate + switch)
  case moveFocusedAppToNextWorkspace
  case moveFocusedAppToPreviousWorkspace

  // Focus the workspace on the next / previous display (looping)
  case focusNextDisplay
  case focusPreviousDisplay

  /// Directional focus
  case focusLeft
  case focusRight
  case focusUp
  case focusDown

  /// Window cycling
  case cycleNextWindow
  case cyclePreviousWindow

  // BSP operations
  case resizeGrow
  case resizeShrink
  case swapLeft
  case swapRight
  case swapUp
  case swapDown
  case toggleOrientation
  case toggleFullscreen
  case balance

  /// Misc toggles
  case toggleFloating
  case toggleSpaceActivated
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
  /// Dismiss the active borrow on the pointer display.
  case dismissBorrow
}

extension HotKeyAction {

  // MARK: Public

  /// Human-readable title, shown in the recorder's "in use" conflict
  /// message. Workspace actions resolve the workspace's current name.
  public func title(in config: AppConfig) -> String {
    switch self {
    case .activateWorkspace(let id):
      String(
        localized:
          "Activate \(config.activeProfile?.workspaces[id: id]?.name ?? String(localized: "workspace"))"
      )
    case .assignFocusedAppToWorkspace(let id):
      String(
        localized:
          "Assign app to \(config.activeProfile?.workspaces[id: id]?.name ?? String(localized: "workspace"))"
      )
    case .borrowWorkspace(let id):
      String(
        localized:
          "Borrow \(config.activeProfile?.workspaces[id: id]?.name ?? String(localized: "workspace"))"
      )
    case .switchToNextWorkspace: String(localized: "Next workspace")
    case .switchToPreviousWorkspace: String(localized: "Previous workspace")
    case .switchToRecentWorkspace: String(localized: "Recent workspace")
    case .activateProfile(let id):
      String(
        localized:
          "Switch to \(config.profiles.first(where: { $0.id == id })?.name ?? String(localized: "profile"))"
      )
    case .moveFocusedAppToNextWorkspace: String(localized: "Move app to next workspace")
    case .moveFocusedAppToPreviousWorkspace: String(localized: "Move app to previous workspace")
    case .focusNextDisplay: String(localized: "Focus next display")
    case .focusPreviousDisplay: String(localized: "Focus previous display")
    case .focusLeft: String(localized: "Focus left")
    case .focusRight: String(localized: "Focus right")
    case .focusUp: String(localized: "Focus up")
    case .focusDown: String(localized: "Focus down")
    case .cycleNextWindow: String(localized: "Cycle next window")
    case .cyclePreviousWindow: String(localized: "Cycle previous window")
    case .resizeGrow: String(localized: "Grow")
    case .resizeShrink: String(localized: "Shrink")
    case .swapLeft: String(localized: "Swap left")
    case .swapRight: String(localized: "Swap right")
    case .swapUp: String(localized: "Swap up")
    case .swapDown: String(localized: "Swap down")
    case .toggleOrientation: String(localized: "Toggle orientation")
    case .toggleFullscreen: String(localized: "Toggle fullscreen")
    case .balance: String(localized: "Balance layout")
    case .toggleFloating: String(localized: "Toggle floating")
    case .toggleSharedFloating: String(localized: "Toggle shared floating")
    case .toggleSpaceActivated: String(localized: "Toggle pause")
    case .toggleFocusedAppInActiveWorkspace: String(localized: "Toggle app in workspace")
    case .toggleAppInSharedApps: String(localized: "Toggle app in Shared Apps")
    case .assignFocusedAppToRecentWorkspace: String(localized: "Assign app to recent workspace")
    case .assignFocusedAppToNextWorkspace: String(localized: "Assign app to next workspace")
    case .assignFocusedAppToPreviousWorkspace: String(localized: "Assign app to previous workspace")
    case .borrowRecentWorkspace: String(localized: "Borrow recent workspace")
    case .borrowNextWorkspace: String(localized: "Borrow next workspace")
    case .borrowPreviousWorkspace: String(localized: "Borrow previous workspace")
    case .dismissBorrow: String(localized: "Dismiss borrow")
    }
  }

  // MARK: Internal

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
    case .activateProfile(let id): "activate-profile-\(id.uuidString)"
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

}

// MARK: - HotKeyBinding

public struct HotKeyBinding: Sendable, Hashable {
  var action: HotKeyAction
  var hotKey: HotKey
}

// MARK: - HotKeysClient

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

// MARK: DependencyKey

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
      },
    )
  }()

  static let testValue = HotKeysClient(
    register: { _ in },
    events: { AsyncStream { _ in } },
    setRecording: { _ in },
  )

  static let previewValue = testValue
}

extension DependencyValues {
  var hotKeys: HotKeysClient {
    get { self[HotKeysClient.self] }
    set { self[HotKeysClient.self] = newValue }
  }
}

// MARK: - ModifierKeysClient

/// Reads the process-independent keyboard modifier state. Window cycling only
/// polls this while a shortcut session is active, which gives us reliable
/// modifier-release semantics without installing another permanent event tap.
@DependencyClient
struct ModifierKeysClient: Sendable {
  var current: @Sendable () -> HotKeyModifiers = { [] }
}

extension ModifierKeysClient: DependencyKey {
  static let liveValue = ModifierKeysClient {
    let flags = CGEventSource.flagsState(.combinedSessionState)
    var modifiers: HotKeyModifiers = []
    if flags.contains(.maskCommand) { modifiers.insert(.command) }
    if flags.contains(.maskShift) { modifiers.insert(.shift) }
    if flags.contains(.maskAlternate) { modifiers.insert(.option) }
    if flags.contains(.maskControl) { modifiers.insert(.control) }
    return modifiers
  }

  static let testValue = ModifierKeysClient()
  static let previewValue = testValue
}

extension DependencyValues {
  var modifierKeys: ModifierKeysClient {
    get { self[ModifierKeysClient.self] }
    set { self[ModifierKeysClient.self] = newValue }
  }
}

// MARK: - HotKeysCenter

/// Bridges Magnet's `HotKeyCenter` (a main-actor global) to the action
/// stream: every `register` clears the previous set and (re)registers the
/// current bindings, each firing its `HotKeyAction` into `events`. Magnet
/// is Carbon-based, so the hotkeys work without the Input Monitoring or
/// Accessibility grant and stay live regardless of which window is key —
/// which the previous KeyboardShortcuts-based path couldn't guarantee in
/// this menu-bar (LSUIElement) app.
private final class HotKeysCenter: @unchecked Sendable {

  // MARK: Lifecycle

  init() {
    var c: AsyncStream<HotKeyAction>.Continuation!
    events = AsyncStream { c = $0 }
    continuation = c
  }

  // MARK: Internal

  let events: AsyncStream<HotKeyAction>

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

  // MARK: Private

  @Dependency(\.debugLog) private var debugLog

  private let continuation: AsyncStream<HotKeyAction>.Continuation
  /// Magnet identifiers currently registered (so the next `register`
  /// unregisters exactly what it put up, not the whole process's hotkeys).
  private var registeredIdentifiers = [String]()
  /// Latest bindings, kept so recording can suspend the live hotkeys and
  /// restore exactly these when it ends — and so a config edit that lands
  /// mid-recording isn't lost (it updates this, applied on resume).
  private var lastBindings = [HotKeyBinding]()
  /// While a recorder is capturing, no global hotkey is registered.
  private var isRecording = false

  @MainActor
  private func apply(_ bindings: [HotKeyBinding]) {
    for identifier in registeredIdentifiers {
      HotKeyCenter.shared.unregisterHotKey(with: identifier)
    }
    var next = [String]()
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
      next.append(identifier)
    }
    registeredIdentifiers = next
    debugLog.log("HotKey", "registered \(next.count) bindings")
  }

}
