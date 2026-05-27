import Foundation

/// Application-wide settings persisted in `config.toml`.
///
/// Grouped into nested tables (`[settings.layout]`, `[settings.focus]`,
/// …) so the TOML stays navigable instead of one flat blob. Each group
/// decodes field-by-field with a default, so a hand-edited config that
/// omits a key (or a whole group) still loads.
public struct AppSettings: Hashable, Sendable, Codable {
  public var general: General
  public var menuBar: MenuBar
  public var hud: HUD
  public var layout: Layout
  public var focus: Focus
  public var switching: Switching
  public var gestures: Gestures
  public var shortcuts: Shortcuts

  public init(
    general: General = General(),
    menuBar: MenuBar = MenuBar(),
    hud: HUD = HUD(),
    layout: Layout = Layout(),
    focus: Focus = Focus(),
    switching: Switching = Switching(),
    gestures: Gestures = Gestures(),
    shortcuts: Shortcuts = Shortcuts()
  ) {
    self.general = general
    self.menuBar = menuBar
    self.hud = hud
    self.layout = layout
    self.focus = focus
    self.switching = switching
    self.gestures = gestures
    self.shortcuts = shortcuts
  }

  private enum CodingKeys: String, CodingKey {
    case general, menuBar, hud, layout, focus, switching, gestures, shortcuts
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.general = (try? c.decode(General.self, forKey: .general)) ?? General()
    self.menuBar = (try? c.decode(MenuBar.self, forKey: .menuBar)) ?? MenuBar()
    self.hud = (try? c.decode(HUD.self, forKey: .hud)) ?? HUD()
    self.layout = (try? c.decode(Layout.self, forKey: .layout)) ?? Layout()
    self.focus = (try? c.decode(Focus.self, forKey: .focus)) ?? Focus()
    self.switching = (try? c.decode(Switching.self, forKey: .switching)) ?? Switching()
    self.gestures = (try? c.decode(Gestures.self, forKey: .gestures)) ?? Gestures()
    self.shortcuts = (try? c.decode(Shortcuts.self, forKey: .shortcuts)) ?? Shortcuts()
  }
}

// MARK: - General

extension AppSettings {
  public struct General: Hashable, Sendable, Codable {
    public var checkForUpdatesAutomatically: Bool
    /// When true, `WorkspaceManagerClient.activate` is a no-op. Toggled
    /// via the `toggleSpaceActivated` hotkey.
    public var isPaused: Bool

    public init(
      checkForUpdatesAutomatically: Bool = true,
      isPaused: Bool = false
    ) {
      self.checkForUpdatesAutomatically = checkForUpdatesAutomatically
      self.isPaused = isPaused
    }

    private enum CodingKeys: String, CodingKey {
      case checkForUpdatesAutomatically, isPaused
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.checkForUpdatesAutomatically =
        (try? c.decode(Bool.self, forKey: .checkForUpdatesAutomatically)) ?? true
      self.isPaused = (try? c.decode(Bool.self, forKey: .isPaused)) ?? false
    }
  }
}

// MARK: - Menu bar

extension AppSettings {
  public struct MenuBar: Hashable, Sendable, Codable {
    /// Show the active workspace's name next to the icon in the menu bar.
    public var showWorkspaceName: Bool

    public init(showWorkspaceName: Bool = true) {
      self.showWorkspaceName = showWorkspaceName
    }

    private enum CodingKeys: String, CodingKey { case showWorkspaceName }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.showWorkspaceName = (try? c.decode(Bool.self, forKey: .showWorkspaceName)) ?? true
    }
  }
}

// MARK: - HUD

extension AppSettings {
  public struct HUD: Hashable, Sendable, Codable {
    /// Show the on-screen overlay when switching workspaces.
    public var enabled: Bool

    public init(enabled: Bool = true) {
      self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey { case enabled }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
    }
  }
}

// MARK: - Layout / gaps

extension AppSettings {
  public struct Layout: Hashable, Sendable, Codable {
    /// Pixels between sibling windows inside a BSP/stack workspace.
    public var gapInner: Int
    /// Pixels between the outermost windows and the display work area.
    public var gapOuter: Int
    /// When true, every insert/remove rebalances the BSP tree so all
    /// leaves end up with equal area. Yabai's `auto_balance` knob.
    public var autoBalance: Bool
    /// Global default for how workspaces remember their BSP layout.
    /// A workspace's own `tilingMemory` overrides this when set.
    public var defaultTilingMemory: TilingMemory

    public init(
      gapInner: Int = 8,
      gapOuter: Int = 8,
      autoBalance: Bool = false,
      defaultTilingMemory: TilingMemory = .session
    ) {
      self.gapInner = gapInner
      self.gapOuter = gapOuter
      self.autoBalance = autoBalance
      self.defaultTilingMemory = defaultTilingMemory
    }

    private enum CodingKeys: String, CodingKey {
      case gapInner, gapOuter, autoBalance, defaultTilingMemory
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.gapInner = (try? c.decode(Int.self, forKey: .gapInner)) ?? 8
      self.gapOuter = (try? c.decode(Int.self, forKey: .gapOuter)) ?? 8
      self.autoBalance = (try? c.decode(Bool.self, forKey: .autoBalance)) ?? false
      self.defaultTilingMemory =
        (try? c.decode(TilingMemory.self, forKey: .defaultTilingMemory)) ?? .session
    }
  }
}

// MARK: - Focus + mouse (yabai-style)

extension AppSettings {
  public struct Focus: Hashable, Sendable, Codable {
    public var mouseFollowsFocus: Bool
    public var mouseHidesOnFocus: Bool
    public var focusFollowsMouse: Bool
    public var focusFollowsMouseDisableHotkey: FocusFollowsMouseModifier
    /// Bundle identifiers that may briefly steal focus without triggering
    /// a workspace switch (Spotlight, Raycast, KeyCastr, etc.). Mirrors
    /// rift's `auto_focus_blacklist`.
    public var autoFocusBlacklist: [String]

    public init(
      mouseFollowsFocus: Bool = false,
      mouseHidesOnFocus: Bool = false,
      focusFollowsMouse: Bool = false,
      focusFollowsMouseDisableHotkey: FocusFollowsMouseModifier = .option,
      autoFocusBlacklist: [String] = []
    ) {
      self.mouseFollowsFocus = mouseFollowsFocus
      self.mouseHidesOnFocus = mouseHidesOnFocus
      self.focusFollowsMouse = focusFollowsMouse
      self.focusFollowsMouseDisableHotkey = focusFollowsMouseDisableHotkey
      self.autoFocusBlacklist = autoFocusBlacklist
    }

    private enum CodingKeys: String, CodingKey {
      case mouseFollowsFocus, mouseHidesOnFocus, focusFollowsMouse
      case focusFollowsMouseDisableHotkey, autoFocusBlacklist
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.mouseFollowsFocus = (try? c.decode(Bool.self, forKey: .mouseFollowsFocus)) ?? false
      self.mouseHidesOnFocus = (try? c.decode(Bool.self, forKey: .mouseHidesOnFocus)) ?? false
      self.focusFollowsMouse = (try? c.decode(Bool.self, forKey: .focusFollowsMouse)) ?? false
      self.focusFollowsMouseDisableHotkey = (try? c.decode(
        FocusFollowsMouseModifier.self, forKey: .focusFollowsMouseDisableHotkey
      )) ?? .option
      self.autoFocusBlacklist = (try? c.decode([String].self, forKey: .autoFocusBlacklist)) ?? []
    }
  }
}

// MARK: - Workspace switching

extension AppSettings {
  public struct Switching: Hashable, Sendable, Codable {
    /// Wrap around from last→first (and first→last) when cycling.
    public var loop: Bool
    /// Skip workspaces with no running app when cycling next/previous.
    public var skipEmpty: Bool
    /// When an app is activated (cmd-tab etc.), switch to the workspace
    /// that owns it.
    public var followAppFocus: Bool

    public init(
      loop: Bool = true,
      skipEmpty: Bool = false,
      followAppFocus: Bool = false
    ) {
      self.loop = loop
      self.skipEmpty = skipEmpty
      self.followAppFocus = followAppFocus
    }

    private enum CodingKeys: String, CodingKey {
      case loop, skipEmpty, followAppFocus
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.loop = (try? c.decode(Bool.self, forKey: .loop)) ?? true
      self.skipEmpty = (try? c.decode(Bool.self, forKey: .skipEmpty)) ?? false
      self.followAppFocus = (try? c.decode(Bool.self, forKey: .followAppFocus)) ?? false
    }
  }
}

// MARK: - Gestures

extension AppSettings {
  public struct Gestures: Hashable, Sendable, Codable {
    /// Horizontal trackpad swipe switches workspaces.
    public var enabled: Bool
    /// Number of fingers required for the swipe (3 or 4).
    public var fingerCount: Int
    /// Accumulated normalized swipe distance required to trigger a switch.
    public var threshold: Double

    public init(
      enabled: Bool = false,
      fingerCount: Int = 3,
      threshold: Double = 0.3
    ) {
      self.enabled = enabled
      self.fingerCount = fingerCount
      self.threshold = threshold
    }

    private enum CodingKeys: String, CodingKey {
      case enabled, fingerCount, threshold
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
      self.fingerCount = (try? c.decode(Int.self, forKey: .fingerCount)) ?? 3
      self.threshold = (try? c.decode(Double.self, forKey: .threshold)) ?? 0.3
    }
  }
}

// MARK: - Shortcuts

extension AppSettings {
  public struct Shortcuts: Hashable, Sendable, Codable {
    // Directional focus
    public var focusLeft: HotKey?
    public var focusRight: HotKey?
    public var focusUp: HotKey?
    public var focusDown: HotKey?

    // Workspace navigation
    public var switchToNextWorkspace: HotKey?
    public var switchToPreviousWorkspace: HotKey?
    public var switchToRecentWorkspace: HotKey?

    // Window cycling
    public var cycleNextWindow: HotKey?
    public var cyclePreviousWindow: HotKey?

    // BSP operations
    public var resizeGrow: HotKey?
    public var resizeShrink: HotKey?
    public var swapLeft: HotKey?
    public var swapRight: HotKey?
    public var swapUp: HotKey?
    public var swapDown: HotKey?
    public var toggleOrientation: HotKey?
    public var toggleFullscreen: HotKey?

    // Misc toggles
    public var toggleFloating: HotKey?
    public var toggleSpaceActivated: HotKey?

    public init(
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

    private enum CodingKeys: String, CodingKey {
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
