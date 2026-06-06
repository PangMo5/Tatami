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
  public var marker: Marker
  public var layout: Layout
  public var focus: Focus
  public var switching: Switching
  public var gestures: Gestures
  public var shortcuts: Shortcuts

  public init(
    general: General = General(),
    menuBar: MenuBar = MenuBar(),
    hud: HUD = HUD(),
    marker: Marker = Marker(),
    layout: Layout = Layout(),
    focus: Focus = Focus(),
    switching: Switching = Switching(),
    gestures: Gestures = Gestures(),
    shortcuts: Shortcuts = Shortcuts()
  ) {
    self.general = general
    self.menuBar = menuBar
    self.hud = hud
    self.marker = marker
    self.layout = layout
    self.focus = focus
    self.switching = switching
    self.gestures = gestures
    self.shortcuts = shortcuts
  }

  private enum CodingKeys: String, CodingKey {
    case general, menuBar, hud, marker, layout, focus, switching, gestures, shortcuts
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.general = (try? c.decode(General.self, forKey: .general)) ?? General()
    self.menuBar = (try? c.decode(MenuBar.self, forKey: .menuBar)) ?? MenuBar()
    self.hud = (try? c.decode(HUD.self, forKey: .hud)) ?? HUD()
    self.marker = (try? c.decode(Marker.self, forKey: .marker)) ?? Marker()
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
    /// Register Tatami as a login item so it starts at login.
    public var launchAtLogin: Bool
    public var checkForUpdatesAutomatically: Bool
    /// How often Sparkle checks for updates in the background.
    public var checkInterval: UpdateCheckInterval
    /// When on, the diagnostic log file is opened and every
    /// instrumented hot-path appends a line. File at
    /// `~/.config/tatami/tatami.log`. Off by default — it churns disk
    /// and adds work on every window event.
    public var debugLogging: Bool

    public init(
      launchAtLogin: Bool = false,
      checkForUpdatesAutomatically: Bool = true,
      checkInterval: UpdateCheckInterval = .daily,
      debugLogging: Bool = false
    ) {
      self.launchAtLogin = launchAtLogin
      self.checkForUpdatesAutomatically = checkForUpdatesAutomatically
      self.checkInterval = checkInterval
      self.debugLogging = debugLogging
    }

    private enum CodingKeys: String, CodingKey {
      case launchAtLogin, checkForUpdatesAutomatically, checkInterval, debugLogging
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.launchAtLogin = (try? c.decode(Bool.self, forKey: .launchAtLogin)) ?? false
      self.checkForUpdatesAutomatically =
        (try? c.decode(Bool.self, forKey: .checkForUpdatesAutomatically)) ?? true
      self.checkInterval =
        (try? c.decode(UpdateCheckInterval.self, forKey: .checkInterval)) ?? .daily
      self.debugLogging = (try? c.decode(Bool.self, forKey: .debugLogging)) ?? false
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

// MARK: - Marker

extension AppSettings {
  public struct Marker: Hashable, Sendable, Codable {
    /// Show a corner dot on floating windows.
    public var floatingEnabled: Bool
    /// Floating-window dot color (`#RRGGBB` or `#RRGGBBAA`).
    public var floatingColorHex: String
    /// Show a corner dot on the zoomed (workspace fullscreen) window.
    public var fullscreenEnabled: Bool
    /// Fullscreen-window dot color (`#RRGGBB` or `#RRGGBBAA`).
    public var fullscreenColorHex: String
    /// Dot diameter in points.
    public var size: Double
    /// Which window corner the dot is pinned to.
    public var corner: MarkerCorner
    /// Fade the dot out while the cursor hovers over it, so it stops
    /// blocking the window's title-bar controls.
    public var hideOnHover: Bool

    public init(
      floatingEnabled: Bool = true,
      floatingColorHex: String = "#FF9500",
      fullscreenEnabled: Bool = true,
      fullscreenColorHex: String = "#007AFF",
      size: Double = 14,
      corner: MarkerCorner = .bottomTrailing,
      hideOnHover: Bool = true
    ) {
      self.floatingEnabled = floatingEnabled
      self.floatingColorHex = floatingColorHex
      self.fullscreenEnabled = fullscreenEnabled
      self.fullscreenColorHex = fullscreenColorHex
      self.size = size
      self.corner = corner
      self.hideOnHover = hideOnHover
    }

    private enum CodingKeys: String, CodingKey {
      case floatingEnabled, floatingColorHex
      case fullscreenEnabled, fullscreenColorHex
      case size, corner, hideOnHover
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.floatingEnabled = (try? c.decode(Bool.self, forKey: .floatingEnabled)) ?? true
      self.floatingColorHex = (try? c.decode(String.self, forKey: .floatingColorHex)) ?? "#FF9500"
      self.fullscreenEnabled = (try? c.decode(Bool.self, forKey: .fullscreenEnabled)) ?? true
      self.fullscreenColorHex = (try? c.decode(String.self, forKey: .fullscreenColorHex)) ?? "#007AFF"
      self.size = (try? c.decode(Double.self, forKey: .size)) ?? 14
      self.corner = (try? c.decode(MarkerCorner.self, forKey: .corner)) ?? .bottomTrailing
      self.hideOnHover = (try? c.decode(Bool.self, forKey: .hideOnHover)) ?? true
    }
  }
}

/// Which corner of the host window a `Marker` dot is pinned to.
public enum MarkerCorner: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
  case topLeading
  case topTrailing
  case bottomLeading
  case bottomTrailing

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .topLeading: "Top-left"
    case .topTrailing: "Top-right"
    case .bottomLeading: "Bottom-left"
    case .bottomTrailing: "Bottom-right"
    }
  }
}

// MARK: - HUD

extension AppSettings {
  public struct HUD: Hashable, Sendable, Codable {
    /// Master switch for every on-screen overlay.
    public var enabled: Bool
    /// Workspace name overlay when switching workspaces.
    public var workspaceSwitch: Bool
    /// Float state changes — per-workspace and shared.
    public var floating: Bool
    /// App added to / removed from a workspace or Shared Apps.
    public var appMembership: Bool
    /// Tiling paused / resumed.
    public var tilingPaused: Bool
    /// Fullscreen zoom entered / exited.
    public var fullscreen: Bool
    /// Layout commands without an obvious visual cue of their own
    /// (balance).
    public var layout: Bool
    /// How long the overlay stays up, in milliseconds. HUDs that carry a
    /// follow-up hint line linger twice as long.
    public var durationMs: Int

    public init(
      enabled: Bool = true,
      workspaceSwitch: Bool = true,
      floating: Bool = true,
      appMembership: Bool = true,
      tilingPaused: Bool = true,
      fullscreen: Bool = true,
      layout: Bool = true,
      durationMs: Int = 900
    ) {
      self.enabled = enabled
      self.workspaceSwitch = workspaceSwitch
      self.floating = floating
      self.appMembership = appMembership
      self.tilingPaused = tilingPaused
      self.fullscreen = fullscreen
      self.layout = layout
      self.durationMs = durationMs
    }

    private enum CodingKeys: String, CodingKey {
      case enabled, workspaceSwitch, floating, appMembership, tilingPaused
      case fullscreen, layout, durationMs
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
      self.workspaceSwitch = (try? c.decode(Bool.self, forKey: .workspaceSwitch)) ?? true
      self.floating = (try? c.decode(Bool.self, forKey: .floating)) ?? true
      self.appMembership = (try? c.decode(Bool.self, forKey: .appMembership)) ?? true
      self.tilingPaused = (try? c.decode(Bool.self, forKey: .tilingPaused)) ?? true
      self.fullscreen = (try? c.decode(Bool.self, forKey: .fullscreen)) ?? true
      self.layout = (try? c.decode(Bool.self, forKey: .layout)) ?? true
      self.durationMs = (try? c.decode(Int.self, forKey: .durationMs)) ?? 900
    }

    /// Effective visibility for one HUD category — the master switch
    /// gates everything.
    public func shows(_ category: KeyPath<Self, Bool>) -> Bool {
      enabled && self[keyPath: category]
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
    /// Which axes to rebalance after every insert/remove. Exposed as
    /// an enum instead of a Bool so users can balance just rows, just
    /// columns, or both.
    public var autoBalance: AutoBalanceMode
    /// How a leaf's split axis is chosen when the user hasn't pinned
    /// one via `--insert`. `.auto` uses the aspect-ratio heuristic.
    public var splitType: SplitTypePreference
    /// Which child of the new split holds the newly-inserted window.
    /// `.second` (default) puts new windows on the right / bottom of
    /// the new split.
    public var windowPlacement: WindowPlacement
    /// Global default for how workspaces remember their BSP layout.
    /// A workspace's own `tilingMemory` overrides this when set.
    public var defaultTilingMemory: TilingMemory

    public init(
      gapInner: Int = 8,
      gapOuter: Int = 8,
      autoBalance: AutoBalanceMode = .none,
      splitType: SplitTypePreference = .auto,
      windowPlacement: WindowPlacement = .second,
      defaultTilingMemory: TilingMemory = .session
    ) {
      self.gapInner = gapInner
      self.gapOuter = gapOuter
      self.autoBalance = autoBalance
      self.splitType = splitType
      self.windowPlacement = windowPlacement
      self.defaultTilingMemory = defaultTilingMemory
    }

    // `windowOriginMode` (a yabai `window_origin_display` port) used to
    // live here but was never read: Tatami's workspace-owns-display model
    // subsumes it — a new window is tiled onto its workspace's display
    // (pinned or dynamic) regardless of where it spawned. Old configs
    // that still carry the key are ignored harmlessly.
    private enum CodingKeys: String, CodingKey {
      case gapInner, gapOuter, autoBalance, splitType, windowPlacement
      case defaultTilingMemory
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.gapInner = (try? c.decode(Int.self, forKey: .gapInner)) ?? 8
      self.gapOuter = (try? c.decode(Int.self, forKey: .gapOuter)) ?? 8
      // Bool autoBalance values from older configs decode as `.both`
      // (the Bool-true meaning) or `.none` (Bool-false). Hand-edited
      // configs with the new enum string take priority.
      if let mode = try? c.decode(AutoBalanceMode.self, forKey: .autoBalance) {
        self.autoBalance = mode
      } else if let flag = try? c.decode(Bool.self, forKey: .autoBalance) {
        self.autoBalance = flag ? .both : .none
      } else {
        self.autoBalance = .none
      }
      self.splitType = (try? c.decode(SplitTypePreference.self, forKey: .splitType)) ?? .auto
      self.windowPlacement = (try? c.decode(WindowPlacement.self, forKey: .windowPlacement))
        ?? .second
      self.defaultTilingMemory =
        (try? c.decode(TilingMemory.self, forKey: .defaultTilingMemory)) ?? .session
    }
  }
}

/// Auto-balance axis selector. Picks which split axes the tree
/// re-equalizes after every insert/remove.
public enum AutoBalanceMode: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
  case none
  case horizontal
  case vertical
  case both
  public var id: String { rawValue }
  public var displayName: String {
    switch self {
    case .none: "Off"
    case .horizontal: "Rows only"
    case .vertical: "Columns only"
    case .both: "Both axes"
    }
  }
}

/// Default split axis used when no per-leaf override is set.
public enum SplitTypePreference: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
  case auto, horizontal, vertical
  public var id: String { rawValue }
  public var displayName: String {
    switch self {
    case .auto: "Auto (by aspect)"
    case .horizontal: "Always horizontal"
    case .vertical: "Always vertical"
    }
  }
}

/// Which side of the new split holds the newly-inserted window.
public enum WindowPlacement: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
  case first
  case second
  public var id: String { rawValue }
  public var displayName: String {
    switch self {
    case .first: "Top / left"
    case .second: "Bottom / right"
    }
  }
}

// MARK: - Focus + mouse

extension AppSettings {
  public struct Focus: Hashable, Sendable, Codable {
    public var mouseFollowsFocus: Bool
    public var mouseHidesOnFocus: Bool
    public var focusFollowsMouse: Bool
    public var focusFollowsMouseDisableHotkey: FocusFollowsMouseModifier
    /// When `focusFollowsMouse` is on, don't shift focus to a window that
    /// fills the whole display (a full-screen / maximized window) — you reach
    /// those by clicking, not by skimming the cursor across them.
    public var focusFollowsMouseIgnoreFullscreen: Bool
    /// When the focused window in a workspace closes (and focus would
    /// otherwise be stranded on a now-windowless app), move focus to a
    /// remaining window in that workspace.
    public var refocusOnClose: Bool

    public init(
      mouseFollowsFocus: Bool = false,
      mouseHidesOnFocus: Bool = false,
      focusFollowsMouse: Bool = false,
      focusFollowsMouseDisableHotkey: FocusFollowsMouseModifier = .option,
      focusFollowsMouseIgnoreFullscreen: Bool = true,
      refocusOnClose: Bool = true
    ) {
      self.mouseFollowsFocus = mouseFollowsFocus
      self.mouseHidesOnFocus = mouseHidesOnFocus
      self.focusFollowsMouse = focusFollowsMouse
      self.focusFollowsMouseDisableHotkey = focusFollowsMouseDisableHotkey
      self.focusFollowsMouseIgnoreFullscreen = focusFollowsMouseIgnoreFullscreen
      self.refocusOnClose = refocusOnClose
    }

    private enum CodingKeys: String, CodingKey {
      case mouseFollowsFocus, mouseHidesOnFocus, focusFollowsMouse
      case focusFollowsMouseDisableHotkey
      case focusFollowsMouseIgnoreFullscreen
      case refocusOnClose
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.mouseFollowsFocus = (try? c.decode(Bool.self, forKey: .mouseFollowsFocus)) ?? false
      self.mouseHidesOnFocus = (try? c.decode(Bool.self, forKey: .mouseHidesOnFocus)) ?? false
      self.focusFollowsMouse = (try? c.decode(Bool.self, forKey: .focusFollowsMouse)) ?? false
      self.focusFollowsMouseDisableHotkey = (try? c.decode(
        FocusFollowsMouseModifier.self, forKey: .focusFollowsMouseDisableHotkey
      )) ?? .option
      self.focusFollowsMouseIgnoreFullscreen = (try? c.decode(
        Bool.self, forKey: .focusFollowsMouseIgnoreFullscreen
      )) ?? true
      self.refocusOnClose = (try? c.decode(Bool.self, forKey: .refocusOnClose)) ?? true
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
    /// Next/previous-workspace cycling spans every display's workspaces.
    /// When `false` (default), cycling stays within the workspaces on the
    /// display under the cursor.
    public var cycleAcrossDisplays: Bool
    /// When the active workspace's last window closes (nothing tiled and
    /// no workspace-specific floating window left), switch to the recent
    /// workspace. Shared apps don't count — they join every workspace, so
    /// they can't anchor you to an empty one.
    public var switchToRecentWhenEmpty: Bool

    public init(
      loop: Bool = true,
      skipEmpty: Bool = false,
      followAppFocus: Bool = false,
      cycleAcrossDisplays: Bool = false,
      switchToRecentWhenEmpty: Bool = false
    ) {
      self.loop = loop
      self.skipEmpty = skipEmpty
      self.followAppFocus = followAppFocus
      self.cycleAcrossDisplays = cycleAcrossDisplays
      self.switchToRecentWhenEmpty = switchToRecentWhenEmpty
    }

    private enum CodingKeys: String, CodingKey {
      case loop, skipEmpty, followAppFocus, cycleAcrossDisplays, switchToRecentWhenEmpty
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.loop = (try? c.decode(Bool.self, forKey: .loop)) ?? true
      self.skipEmpty = (try? c.decode(Bool.self, forKey: .skipEmpty)) ?? false
      self.followAppFocus = (try? c.decode(Bool.self, forKey: .followAppFocus)) ?? false
      self.cycleAcrossDisplays =
        (try? c.decode(Bool.self, forKey: .cycleAcrossDisplays)) ?? false
      self.switchToRecentWhenEmpty =
        (try? c.decode(Bool.self, forKey: .switchToRecentWhenEmpty)) ?? false
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
    /// Accumulated normalized swipe distance required to trigger a switch
    /// (lower = more sensitive). Kept to two decimal places so the TOML
    /// stays clean — `0.3`, not float noise.
    public var threshold: Double

    /// Two-decimal normalization shared by the initializer, decoder, and
    /// the Settings slider.
    public static func roundedThreshold(_ value: Double) -> Double {
      (value.clamped(to: 0.1 ... 0.9) * 100).rounded() / 100
    }

    public init(
      enabled: Bool = false,
      fingerCount: Int = 3,
      threshold: Double = 0.3
    ) {
      self.enabled = enabled
      self.fingerCount = fingerCount
      self.threshold = Self.roundedThreshold(threshold)
    }

    private enum CodingKeys: String, CodingKey {
      case enabled, fingerCount, threshold, sensitivity
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
      self.fingerCount = (try? c.decode(Int.self, forKey: .fingerCount)) ?? 3
      if let value = try? c.decode(Double.self, forKey: .threshold) {
        self.threshold = Self.roundedThreshold(value)
      } else if let sensitivity = try? c.decode(Double.self, forKey: .sensitivity) {
        // A short-lived dev build stored `sensitivity` (0–1, or an integer
        // percent) instead — map it back so those configs keep working.
        let normalized = sensitivity > 1 ? sensitivity / 100 : sensitivity
        self.threshold = Self.roundedThreshold(0.9 - 0.8 * normalized)
      } else {
        self.threshold = 0.3
      }
    }

    public func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(enabled, forKey: .enabled)
      try c.encode(fingerCount, forKey: .fingerCount)
      try c.encode(Self.roundedThreshold(threshold), forKey: .threshold)
    }
  }
}

extension Comparable {
  func clamped(to range: ClosedRange<Self>) -> Self {
    Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
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

    // Move the focused app to an adjacent workspace (relocate + switch)
    public var moveToNextWorkspace: HotKey?
    public var moveToPreviousWorkspace: HotKey?

    // Focus the workspace active on the next / previous display
    public var focusNextDisplay: HotKey?
    public var focusPreviousDisplay: HotKey?

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
    public var balance: HotKey?

    // Misc toggles
    public var toggleFloating: HotKey?
    /// Same structure as `toggleFloating`, but on Shared Apps: not shared
    /// yet → added as shared floating; already shared → flip `floating`
    /// only (membership stays).
    public var toggleSharedFloating: HotKey?
    public var toggleSpaceActivated: HotKey?
    /// Toggle the focused window's app's membership in the active
    /// workspace's registered set.
    public var toggleFocusedAppInActiveWorkspace: HotKey?
    /// Toggle the focused window's app in Shared Apps (added tiled).
    public var toggleAppInSharedApps: HotKey?

    public init(
      focusLeft: HotKey? = nil,
      focusRight: HotKey? = nil,
      focusUp: HotKey? = nil,
      focusDown: HotKey? = nil,
      switchToNextWorkspace: HotKey? = nil,
      switchToPreviousWorkspace: HotKey? = nil,
      switchToRecentWorkspace: HotKey? = nil,
      moveToNextWorkspace: HotKey? = nil,
      moveToPreviousWorkspace: HotKey? = nil,
      focusNextDisplay: HotKey? = nil,
      focusPreviousDisplay: HotKey? = nil,
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
      balance: HotKey? = nil,
      toggleFloating: HotKey? = nil,
      toggleSharedFloating: HotKey? = nil,
      toggleSpaceActivated: HotKey? = nil,
      toggleFocusedAppInActiveWorkspace: HotKey? = nil,
      toggleAppInSharedApps: HotKey? = nil
    ) {
      self.focusLeft = focusLeft
      self.focusRight = focusRight
      self.focusUp = focusUp
      self.focusDown = focusDown
      self.switchToNextWorkspace = switchToNextWorkspace
      self.switchToPreviousWorkspace = switchToPreviousWorkspace
      self.switchToRecentWorkspace = switchToRecentWorkspace
      self.moveToNextWorkspace = moveToNextWorkspace
      self.moveToPreviousWorkspace = moveToPreviousWorkspace
      self.focusNextDisplay = focusNextDisplay
      self.focusPreviousDisplay = focusPreviousDisplay
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
      self.balance = balance
      self.toggleFloating = toggleFloating
      self.toggleSharedFloating = toggleSharedFloating
      self.toggleSpaceActivated = toggleSpaceActivated
      self.toggleFocusedAppInActiveWorkspace = toggleFocusedAppInActiveWorkspace
      self.toggleAppInSharedApps = toggleAppInSharedApps
    }

    private enum CodingKeys: String, CodingKey {
      case focusLeft, focusRight, focusUp, focusDown
      case switchToNextWorkspace, switchToPreviousWorkspace, switchToRecentWorkspace
      case moveToNextWorkspace, moveToPreviousWorkspace
      case focusNextDisplay, focusPreviousDisplay
      case cycleNextWindow, cyclePreviousWindow
      case resizeGrow, resizeShrink
      case swapLeft, swapRight, swapUp, swapDown
      case toggleOrientation, toggleFullscreen
      case balance
      case toggleFloating, toggleSharedFloating, toggleSpaceActivated
      case toggleFocusedAppInActiveWorkspace, toggleAppInSharedApps
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
      self.moveToNextWorkspace = try? c.decode(HotKey.self, forKey: .moveToNextWorkspace)
      self.moveToPreviousWorkspace = try? c.decode(HotKey.self, forKey: .moveToPreviousWorkspace)
      self.focusNextDisplay = try? c.decode(HotKey.self, forKey: .focusNextDisplay)
      self.focusPreviousDisplay = try? c.decode(HotKey.self, forKey: .focusPreviousDisplay)
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
      self.balance = try? c.decode(HotKey.self, forKey: .balance)
      self.toggleFloating = try? c.decode(HotKey.self, forKey: .toggleFloating)
      self.toggleSharedFloating = try? c.decode(HotKey.self, forKey: .toggleSharedFloating)
      self.toggleSpaceActivated = try? c.decode(HotKey.self, forKey: .toggleSpaceActivated)
      self.toggleFocusedAppInActiveWorkspace =
        try? c.decode(HotKey.self, forKey: .toggleFocusedAppInActiveWorkspace)
      self.toggleAppInSharedApps = try? c.decode(HotKey.self, forKey: .toggleAppInSharedApps)
    }
  }
}

/// How often Sparkle checks for updates in the background.
public enum UpdateCheckInterval: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
  case hourly
  case daily
  case weekly

  public var id: String { rawValue }

  public var seconds: TimeInterval {
    switch self {
    case .hourly: 3600
    case .daily: 86400
    case .weekly: 604_800
    }
  }

  public var displayName: String {
    switch self {
    case .hourly: "Every hour"
    case .daily: "Every day"
    case .weekly: "Every week"
    }
  }
}

/// Modifier key that temporarily suspends `focusFollowsMouse`.
public enum FocusFollowsMouseModifier: String, Codable, Hashable, Sendable, CaseIterable {
  case none
  case option = "Alt"
  case command = "Cmd"
  case control = "Ctrl"
  case shift = "Shift"
}
