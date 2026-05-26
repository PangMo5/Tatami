import Foundation

/// Application-wide settings persisted in `config.toml`. Grows as the
/// app gains features; each new field is optional with a sensible
/// default so older config files keep decoding.
public struct AppSettings: Hashable, Sendable, Codable {
  // MARK: General

  public var checkForUpdatesAutomatically: Bool

  // MARK: Layout / gaps

  /// Pixels between sibling windows inside a BSP/stack workspace.
  public var gapInner: Int
  /// Pixels between the outermost windows and the display work area.
  public var gapOuter: Int

  // MARK: Focus + Mouse (yabai-style)

  public var mouseFollowsFocus: Bool
  public var mouseHidesOnFocus: Bool
  public var focusFollowsMouse: Bool
  public var focusFollowsMouseDisableHotkey: FocusFollowsMouseModifier

  /// Bundle identifiers that may briefly steal focus without triggering
  /// a workspace switch (Spotlight, Raycast, KeyCastr, etc.). Mirrors
  /// rift's `auto_focus_blacklist`.
  public var autoFocusBlacklist: [String]

  /// When true, `WorkspaceManagerClient.activate` is a no-op. Toggled
  /// via the `toggleSpaceActivated` hotkey.
  public var isPaused: Bool

  // MARK: Directional focus

  public var focusLeft: HotKey?
  public var focusRight: HotKey?
  public var focusUp: HotKey?
  public var focusDown: HotKey?

  // MARK: Workspace navigation

  public var switchToNextWorkspace: HotKey?
  public var switchToPreviousWorkspace: HotKey?
  public var switchToRecentWorkspace: HotKey?

  // MARK: Window cycling

  public var cycleNextWindow: HotKey?
  public var cyclePreviousWindow: HotKey?

  // MARK: BSP operations

  public var resizeGrow: HotKey?
  public var resizeShrink: HotKey?
  public var swapLeft: HotKey?
  public var swapRight: HotKey?
  public var swapUp: HotKey?
  public var swapDown: HotKey?
  public var toggleOrientation: HotKey?
  public var toggleFullscreen: HotKey?

  // MARK: Misc toggles

  public var toggleFloating: HotKey?
  public var toggleSpaceActivated: HotKey?

  public init(
    checkForUpdatesAutomatically: Bool = true,
    gapInner: Int = 8,
    gapOuter: Int = 8,
    mouseFollowsFocus: Bool = false,
    mouseHidesOnFocus: Bool = false,
    focusFollowsMouse: Bool = false,
    focusFollowsMouseDisableHotkey: FocusFollowsMouseModifier = .option,
    autoFocusBlacklist: [String] = [],
    isPaused: Bool = false,
    focusLeft: HotKey? = nil,
    focusRight: HotKey? = nil,
    focusUp: HotKey? = nil,
    focusDown: HotKey? = nil,
    switchToNextWorkspace: HotKey? = nil,
    switchToPreviousWorkspace: HotKey? = nil,
    switchToRecentWorkspace: HotKey? = nil,
    cycleNextWindow: HotKey? = nil,
    cyclePreviousWindow: HotKey? = nil,
    resizeGrow: HotKey? = nil,
    resizeShrink: HotKey? = nil,
    swapLeft: HotKey? = nil,
    swapRight: HotKey? = nil,
    swapUp: HotKey? = nil,
    swapDown: HotKey? = nil,
    toggleOrientation: HotKey? = nil,
    toggleFullscreen: HotKey? = nil,
    toggleFloating: HotKey? = nil,
    toggleSpaceActivated: HotKey? = nil
  ) {
    self.checkForUpdatesAutomatically = checkForUpdatesAutomatically
    self.gapInner = gapInner
    self.gapOuter = gapOuter
    self.mouseFollowsFocus = mouseFollowsFocus
    self.mouseHidesOnFocus = mouseHidesOnFocus
    self.focusFollowsMouse = focusFollowsMouse
    self.focusFollowsMouseDisableHotkey = focusFollowsMouseDisableHotkey
    self.autoFocusBlacklist = autoFocusBlacklist
    self.isPaused = isPaused
    self.focusLeft = focusLeft
    self.focusRight = focusRight
    self.focusUp = focusUp
    self.focusDown = focusDown
    self.switchToNextWorkspace = switchToNextWorkspace
    self.switchToPreviousWorkspace = switchToPreviousWorkspace
    self.switchToRecentWorkspace = switchToRecentWorkspace
    self.cycleNextWindow = cycleNextWindow
    self.cyclePreviousWindow = cyclePreviousWindow
    self.resizeGrow = resizeGrow
    self.resizeShrink = resizeShrink
    self.swapLeft = swapLeft
    self.swapRight = swapRight
    self.swapUp = swapUp
    self.swapDown = swapDown
    self.toggleOrientation = toggleOrientation
    self.toggleFullscreen = toggleFullscreen
    self.toggleFloating = toggleFloating
    self.toggleSpaceActivated = toggleSpaceActivated
  }
}

extension AppSettings {
  private enum CodingKeys: String, CodingKey {
    case checkForUpdatesAutomatically
    case gapInner, gapOuter
    case mouseFollowsFocus, mouseHidesOnFocus, focusFollowsMouse
    case focusFollowsMouseDisableHotkey
    case autoFocusBlacklist
    case isPaused
    case focusLeft, focusRight, focusUp, focusDown
    case switchToNextWorkspace, switchToPreviousWorkspace, switchToRecentWorkspace
    case cycleNextWindow, cyclePreviousWindow
    case resizeGrow, resizeShrink
    case swapLeft, swapRight, swapUp, swapDown
    case toggleOrientation, toggleFullscreen
    case toggleFloating, toggleSpaceActivated
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.checkForUpdatesAutomatically = (try? c.decode(Bool.self, forKey: .checkForUpdatesAutomatically)) ?? true
    self.gapInner = (try? c.decode(Int.self, forKey: .gapInner)) ?? 8
    self.gapOuter = (try? c.decode(Int.self, forKey: .gapOuter)) ?? 8
    self.mouseFollowsFocus = (try? c.decode(Bool.self, forKey: .mouseFollowsFocus)) ?? false
    self.mouseHidesOnFocus = (try? c.decode(Bool.self, forKey: .mouseHidesOnFocus)) ?? false
    self.focusFollowsMouse = (try? c.decode(Bool.self, forKey: .focusFollowsMouse)) ?? false
    self.focusFollowsMouseDisableHotkey = (try? c.decode(
      FocusFollowsMouseModifier.self, forKey: .focusFollowsMouseDisableHotkey
    )) ?? .option
    self.autoFocusBlacklist = (try? c.decode([String].self, forKey: .autoFocusBlacklist)) ?? []
    self.isPaused = (try? c.decode(Bool.self, forKey: .isPaused)) ?? false
    self.focusLeft = try? c.decode(HotKey.self, forKey: .focusLeft)
    self.focusRight = try? c.decode(HotKey.self, forKey: .focusRight)
    self.focusUp = try? c.decode(HotKey.self, forKey: .focusUp)
    self.focusDown = try? c.decode(HotKey.self, forKey: .focusDown)
    self.switchToNextWorkspace = try? c.decode(HotKey.self, forKey: .switchToNextWorkspace)
    self.switchToPreviousWorkspace = try? c.decode(HotKey.self, forKey: .switchToPreviousWorkspace)
    self.switchToRecentWorkspace = try? c.decode(HotKey.self, forKey: .switchToRecentWorkspace)
    self.cycleNextWindow = try? c.decode(HotKey.self, forKey: .cycleNextWindow)
    self.cyclePreviousWindow = try? c.decode(HotKey.self, forKey: .cyclePreviousWindow)
    self.resizeGrow = try? c.decode(HotKey.self, forKey: .resizeGrow)
    self.resizeShrink = try? c.decode(HotKey.self, forKey: .resizeShrink)
    self.swapLeft = try? c.decode(HotKey.self, forKey: .swapLeft)
    self.swapRight = try? c.decode(HotKey.self, forKey: .swapRight)
    self.swapUp = try? c.decode(HotKey.self, forKey: .swapUp)
    self.swapDown = try? c.decode(HotKey.self, forKey: .swapDown)
    self.toggleOrientation = try? c.decode(HotKey.self, forKey: .toggleOrientation)
    self.toggleFullscreen = try? c.decode(HotKey.self, forKey: .toggleFullscreen)
    self.toggleFloating = try? c.decode(HotKey.self, forKey: .toggleFloating)
    self.toggleSpaceActivated = try? c.decode(HotKey.self, forKey: .toggleSpaceActivated)
  }
}

/// Modifier key that temporarily suspends `focusFollowsMouse`, matching
/// yabai's `focus_follows_mouse_disable_hotkey` config knob.
public enum FocusFollowsMouseModifier: String, Codable, Hashable, Sendable, CaseIterable {
  case none
  case option = "Alt"
  case command = "Cmd"
  case control = "Ctrl"
  case shift = "Shift"
}
