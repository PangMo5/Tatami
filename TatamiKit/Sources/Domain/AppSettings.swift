import Dependencies
import Foundation

/// Field-tolerant decoding shared by every settings group: a *missing*
/// key falls back to its default so a hand-edited config still loads,
/// while a key that is present but doesn't parse (a typo'd value) is
/// surfaced through the error reporter instead of silently resetting —
/// the same treatment `HotKey` gives invalid shortcuts. The "Settings"
/// domain rides the config decode's report pass (see `TatamiConfigKey`),
/// so fixing the typo resolves the standing report on the next decode.
extension KeyedDecodingContainer {
  func decode<T: Decodable>(_ key: Key, default defaultValue: T) -> T {
    do {
      return try decode(T.self, forKey: key)
    } catch {
      if contains(key) {
        let path = (codingPath + [key]).map(\.stringValue).joined(separator: ".")
        @Dependency(\.errorReporter) var reporter
        reporter.report(
          "Settings",
          "config.toml: '\(path)' has an invalid value — using the default",
          ErrorReportClient.describe(error)
        )
      }
      return defaultValue
    }
  }

  /// Optional variant for fields where absence is meaningful (hotkeys —
  /// which report their own parse failures, so none is added here).
  func decodeIfValid<T: Decodable>(_ key: Key) -> T? {
    try? decode(T.self, forKey: key)
  }
}

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
    self.general = c.decode(.general, default: General())
    self.menuBar = c.decode(.menuBar, default: MenuBar())
    self.hud = c.decode(.hud, default: HUD())
    self.marker = c.decode(.marker, default: Marker())
    self.layout = c.decode(.layout, default: Layout())
    self.focus = c.decode(.focus, default: Focus())
    self.switching = c.decode(.switching, default: Switching())
    self.gestures = c.decode(.gestures, default: Gestures())
    self.shortcuts = c.decode(.shortcuts, default: Shortcuts())
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
      self.launchAtLogin = c.decode(.launchAtLogin, default: false)
      self.checkForUpdatesAutomatically = c.decode(.checkForUpdatesAutomatically, default: true)
      self.checkInterval = c.decode(.checkInterval, default: .daily)
      self.debugLogging = c.decode(.debugLogging, default: false)
    }
  }
}

// MARK: - Menu bar

extension AppSettings {
  public struct MenuBar: Hashable, Sendable, Codable {
    /// Show the active workspace's icon in the menu bar.
    public var showWorkspaceIcon: Bool
    /// Show the active workspace's name in the menu bar.
    public var showWorkspaceName: Bool
    /// Show the active profile's icon (only when more than one profile exists).
    public var showProfileIcon: Bool
    /// Show the active profile's name (only when more than one profile exists).
    public var showProfileName: Bool

    public init(
      showWorkspaceIcon: Bool = true,
      showWorkspaceName: Bool = true,
      showProfileIcon: Bool = true,
      showProfileName: Bool = false
    ) {
      self.showWorkspaceIcon = showWorkspaceIcon
      self.showWorkspaceName = showWorkspaceName
      self.showProfileIcon = showProfileIcon
      self.showProfileName = showProfileName
    }

    private enum CodingKeys: String, CodingKey {
      case showWorkspaceIcon, showWorkspaceName, showProfileIcon, showProfileName
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.showWorkspaceIcon = c.decode(.showWorkspaceIcon, default: true)
      self.showWorkspaceName = c.decode(.showWorkspaceName, default: true)
      self.showProfileIcon = c.decode(.showProfileIcon, default: true)
      self.showProfileName = c.decode(.showProfileName, default: false)
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
    /// Badge the windows of a borrowed block with the borrowed workspace's
    /// icon, so what's on loan is identifiable at a glance.
    public var borrowEnabled: Bool
    /// Borrow-marker badge color (`#RRGGBB` or `#RRGGBBAA`).
    public var borrowColorHex: String
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
      borrowEnabled: Bool = true,
      borrowColorHex: String = "#AF52DE",
      size: Double = 14,
      corner: MarkerCorner = .bottomTrailing,
      hideOnHover: Bool = true
    ) {
      self.floatingEnabled = floatingEnabled
      self.floatingColorHex = floatingColorHex
      self.fullscreenEnabled = fullscreenEnabled
      self.fullscreenColorHex = fullscreenColorHex
      self.borrowEnabled = borrowEnabled
      self.borrowColorHex = borrowColorHex
      self.size = size
      self.corner = corner
      self.hideOnHover = hideOnHover
    }

    private enum CodingKeys: String, CodingKey {
      case floatingEnabled, floatingColorHex
      case fullscreenEnabled, fullscreenColorHex
      case borrowEnabled, borrowColorHex
      case size, corner, hideOnHover
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.floatingEnabled = c.decode(.floatingEnabled, default: true)
      self.floatingColorHex = c.decode(.floatingColorHex, default: "#FF9500")
      self.fullscreenEnabled = c.decode(.fullscreenEnabled, default: true)
      self.fullscreenColorHex = c.decode(.fullscreenColorHex, default: "#007AFF")
      self.borrowEnabled = c.decode(.borrowEnabled, default: true)
      self.borrowColorHex = c.decode(.borrowColorHex, default: "#AF52DE")
      self.size = c.decode(.size, default: 14)
      self.corner = c.decode(.corner, default: .bottomTrailing)
      self.hideOnHover = c.decode(.hideOnHover, default: true)
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
    /// Profile name overlay when switching profiles.
    public var profileSwitch: Bool
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
    /// Borrowing a workspace into / out of the current composition.
    public var borrow: Bool
    /// How long the overlay stays up, in milliseconds. HUDs that carry a
    /// follow-up hint line linger twice as long.
    public var durationMs: Int

    public init(
      enabled: Bool = true,
      workspaceSwitch: Bool = true,
      profileSwitch: Bool = true,
      floating: Bool = true,
      appMembership: Bool = true,
      tilingPaused: Bool = true,
      fullscreen: Bool = true,
      layout: Bool = true,
      borrow: Bool = true,
      durationMs: Int = 900
    ) {
      self.enabled = enabled
      self.workspaceSwitch = workspaceSwitch
      self.profileSwitch = profileSwitch
      self.floating = floating
      self.appMembership = appMembership
      self.tilingPaused = tilingPaused
      self.fullscreen = fullscreen
      self.layout = layout
      self.borrow = borrow
      self.durationMs = durationMs
    }

    private enum CodingKeys: String, CodingKey {
      case enabled, workspaceSwitch, profileSwitch, floating, appMembership, tilingPaused
      case fullscreen, layout, borrow, durationMs
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.enabled = c.decode(.enabled, default: true)
      self.workspaceSwitch = c.decode(.workspaceSwitch, default: true)
      self.profileSwitch = c.decode(.profileSwitch, default: true)
      self.floating = c.decode(.floating, default: true)
      self.appMembership = c.decode(.appMembership, default: true)
      self.tilingPaused = c.decode(.tilingPaused, default: true)
      self.fullscreen = c.decode(.fullscreen, default: true)
      self.layout = c.decode(.layout, default: true)
      self.borrow = c.decode(.borrow, default: true)
      self.durationMs = c.decode(.durationMs, default: 900)
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

    public init(
      gapInner: Int = 8,
      gapOuter: Int = 8,
      autoBalance: AutoBalanceMode = .none,
      splitType: SplitTypePreference = .auto,
      windowPlacement: WindowPlacement = .second
    ) {
      self.gapInner = gapInner
      self.gapOuter = gapOuter
      self.autoBalance = autoBalance
      self.splitType = splitType
      self.windowPlacement = windowPlacement
    }

    // `windowOriginMode` (a yabai `window_origin_display` port) used to
    // live here but was never read: Tatami's workspace-owns-display model
    // subsumes it — a new window is tiled onto its workspace's display
    // (pinned or dynamic) regardless of where it spawned. Old configs
    // that still carry the key are ignored harmlessly.
    private enum CodingKeys: String, CodingKey {
      case gapInner, gapOuter, autoBalance, splitType, windowPlacement
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.gapInner = c.decode(.gapInner, default: 8)
      self.gapOuter = c.decode(.gapOuter, default: 8)
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
      self.splitType = c.decode(.splitType, default: .auto)
      self.windowPlacement = c.decode(.windowPlacement, default: .second)
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

  /// The `BSPNode` child slot this preference maps to.
  public var bspChild: BSPChild {
    self == .first ? .first : .second
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
      self.mouseFollowsFocus = c.decode(.mouseFollowsFocus, default: false)
      self.mouseHidesOnFocus = c.decode(.mouseHidesOnFocus, default: false)
      self.focusFollowsMouse = c.decode(.focusFollowsMouse, default: false)
      self.focusFollowsMouseDisableHotkey =
        c.decode(.focusFollowsMouseDisableHotkey, default: .option)
      self.focusFollowsMouseIgnoreFullscreen =
        c.decode(.focusFollowsMouseIgnoreFullscreen, default: true)
      self.refocusOnClose = c.decode(.refocusOnClose, default: true)
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
    /// Window-cycle granularity. When `false` (default), next/previous-window
    /// cycling steps app-by-app — one representative window per app, so a
    /// press lands on the next app. When `true`, it visits every window
    /// individually, including multiple windows of the same app.
    public var cycleSameAppWindows: Bool
    /// Default edge a borrow docks to. `nil` → no default: a direction key is
    /// picked after the borrow combo. A per-workspace `borrowEdge` overrides.
    public var borrowDefaultEdge: BorrowEdge?
    /// The borrowed block's default share of the screen (0.1…0.9). A
    /// per-workspace `borrowFraction` overrides.
    public var borrowFraction: Double

    public init(
      loop: Bool = true,
      skipEmpty: Bool = false,
      followAppFocus: Bool = true,
      cycleAcrossDisplays: Bool = false,
      switchToRecentWhenEmpty: Bool = false,
      cycleSameAppWindows: Bool = false,
      borrowDefaultEdge: BorrowEdge? = nil,
      borrowFraction: Double = 0.4
    ) {
      self.loop = loop
      self.skipEmpty = skipEmpty
      self.followAppFocus = followAppFocus
      self.cycleAcrossDisplays = cycleAcrossDisplays
      self.switchToRecentWhenEmpty = switchToRecentWhenEmpty
      self.cycleSameAppWindows = cycleSameAppWindows
      self.borrowDefaultEdge = borrowDefaultEdge
      self.borrowFraction = borrowFraction
    }

    private enum CodingKeys: String, CodingKey {
      case loop, skipEmpty, followAppFocus, cycleAcrossDisplays, switchToRecentWhenEmpty
      case cycleSameAppWindows, borrowDefaultEdge, borrowFraction
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.loop = c.decode(.loop, default: true)
      self.skipEmpty = c.decode(.skipEmpty, default: false)
      self.followAppFocus = c.decode(.followAppFocus, default: true)
      self.cycleAcrossDisplays = c.decode(.cycleAcrossDisplays, default: false)
      self.switchToRecentWhenEmpty = c.decode(.switchToRecentWhenEmpty, default: false)
      self.cycleSameAppWindows = c.decode(.cycleSameAppWindows, default: false)
      self.borrowDefaultEdge = c.decodeIfValid(.borrowDefaultEdge)
      self.borrowFraction = c.decode(.borrowFraction, default: 0.4)
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

    /// User-facing sensitivity (0…1): the inverse of the swipe-distance
    /// threshold — higher sensitivity needs a shorter swipe. The single
    /// home for the threshold ↔ sensitivity mapping; the Settings slider
    /// and the legacy `sensitivity` config key both go through it.
    public var sensitivity: Double {
      get { ((0.9 - threshold) / 0.8).clamped(to: 0 ... 1) }
      set { threshold = Self.threshold(fromSensitivity: newValue) }
    }

    public static func threshold(fromSensitivity sensitivity: Double) -> Double {
      roundedThreshold(0.9 - 0.8 * sensitivity.clamped(to: 0 ... 1))
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
      self.enabled = c.decode(.enabled, default: false)
      self.fingerCount = c.decode(.fingerCount, default: 3)
      if let value = try? c.decode(Double.self, forKey: .threshold) {
        self.threshold = Self.roundedThreshold(value)
      } else if let sensitivity = try? c.decode(Double.self, forKey: .sensitivity) {
        // A short-lived dev build stored `sensitivity` (0–1, or an integer
        // percent) instead — map it back so those configs keep working.
        let normalized = sensitivity > 1 ? sensitivity / 100 : sensitivity
        self.threshold = Self.threshold(fromSensitivity: normalized)
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
    /// Modifier combo (skhd tokens, e.g. `["ctrl", "alt"]`) that, together
    /// with a workspace's `keyEquivalent`, activates it — the default
    /// workspace-switch shortcut. Empty disables the auto-binding.
    public var keyEquivalentModifiers: [String]
    /// Modifier combo that, with a workspace's `keyEquivalent`, assigns the
    /// focused app to that workspace (the default Assign shortcut). Empty
    /// disables it. Distinct from the switch modifier so one workspace key
    /// drives both: switch (⌃⌥key) and assign (⌃⌥⇧key).
    public var assignModifiers: [String]
    /// Single-char key equivalents for workspace navigation: switch-modifier +
    /// this key runs the action, unless the matching explicit shortcut below
    /// overrides it.
    public var recentWorkspaceKey: String?
    public var nextWorkspaceKey: String?
    public var previousWorkspaceKey: String?
    /// Explicit overrides of the assign / borrow combos for the nav targets
    /// (the switch override is `switchTo…Workspace` above).
    public var assignRecentWorkspace: HotKey?
    public var assignNextWorkspace: HotKey?
    public var assignPreviousWorkspace: HotKey?
    public var borrowRecentWorkspace: HotKey?
    public var borrowNextWorkspace: HotKey?
    public var borrowPreviousWorkspace: HotKey?
    /// Modifier combo that, with a workspace's `keyEquivalent`, starts a borrow
    /// of that workspace — then a direction key (h/j/k/l or arrows) places it.
    /// Empty disables it.
    public var borrowModifiers: [String]
    /// Dismiss the active borrow on the focused display.
    public var dismissBorrow: HotKey?

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
      toggleAppInSharedApps: HotKey? = nil,
      keyEquivalentModifiers: [String] = ["ctrl", "alt"],
      assignModifiers: [String] = ["ctrl", "alt", "shift"],
      recentWorkspaceKey: String? = nil,
      nextWorkspaceKey: String? = nil,
      previousWorkspaceKey: String? = nil,
      assignRecentWorkspace: HotKey? = nil,
      assignNextWorkspace: HotKey? = nil,
      assignPreviousWorkspace: HotKey? = nil,
      borrowRecentWorkspace: HotKey? = nil,
      borrowNextWorkspace: HotKey? = nil,
      borrowPreviousWorkspace: HotKey? = nil,
      borrowModifiers: [String] = ["ctrl", "alt", "cmd"],
      dismissBorrow: HotKey? = nil
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
      self.keyEquivalentModifiers = keyEquivalentModifiers
      self.assignModifiers = assignModifiers
      self.recentWorkspaceKey = recentWorkspaceKey
      self.nextWorkspaceKey = nextWorkspaceKey
      self.previousWorkspaceKey = previousWorkspaceKey
      self.assignRecentWorkspace = assignRecentWorkspace
      self.assignNextWorkspace = assignNextWorkspace
      self.assignPreviousWorkspace = assignPreviousWorkspace
      self.borrowRecentWorkspace = borrowRecentWorkspace
      self.borrowNextWorkspace = borrowNextWorkspace
      self.borrowPreviousWorkspace = borrowPreviousWorkspace
      self.borrowModifiers = borrowModifiers
      self.dismissBorrow = dismissBorrow
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
      case keyEquivalentModifiers, assignModifiers, borrowModifiers
      case recentWorkspaceKey, nextWorkspaceKey, previousWorkspaceKey
      case assignRecentWorkspace, assignNextWorkspace, assignPreviousWorkspace
      case borrowRecentWorkspace, borrowNextWorkspace, borrowPreviousWorkspace
      case dismissBorrow
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.focusLeft = c.decodeIfValid(.focusLeft)
      self.focusRight = c.decodeIfValid(.focusRight)
      self.focusUp = c.decodeIfValid(.focusUp)
      self.focusDown = c.decodeIfValid(.focusDown)
      self.switchToNextWorkspace = c.decodeIfValid(.switchToNextWorkspace)
      self.switchToPreviousWorkspace = c.decodeIfValid(.switchToPreviousWorkspace)
      self.switchToRecentWorkspace = c.decodeIfValid(.switchToRecentWorkspace)
      self.moveToNextWorkspace = c.decodeIfValid(.moveToNextWorkspace)
      self.moveToPreviousWorkspace = c.decodeIfValid(.moveToPreviousWorkspace)
      self.focusNextDisplay = c.decodeIfValid(.focusNextDisplay)
      self.focusPreviousDisplay = c.decodeIfValid(.focusPreviousDisplay)
      self.cycleNextWindow = c.decodeIfValid(.cycleNextWindow)
      self.cyclePreviousWindow = c.decodeIfValid(.cyclePreviousWindow)
      self.resizeGrow = c.decodeIfValid(.resizeGrow)
      self.resizeShrink = c.decodeIfValid(.resizeShrink)
      self.swapLeft = c.decodeIfValid(.swapLeft)
      self.swapRight = c.decodeIfValid(.swapRight)
      self.swapUp = c.decodeIfValid(.swapUp)
      self.swapDown = c.decodeIfValid(.swapDown)
      self.toggleOrientation = c.decodeIfValid(.toggleOrientation)
      self.toggleFullscreen = c.decodeIfValid(.toggleFullscreen)
      self.balance = c.decodeIfValid(.balance)
      self.toggleFloating = c.decodeIfValid(.toggleFloating)
      self.toggleSharedFloating = c.decodeIfValid(.toggleSharedFloating)
      self.toggleSpaceActivated = c.decodeIfValid(.toggleSpaceActivated)
      self.toggleFocusedAppInActiveWorkspace = c.decodeIfValid(.toggleFocusedAppInActiveWorkspace)
      self.toggleAppInSharedApps = c.decodeIfValid(.toggleAppInSharedApps)
      self.keyEquivalentModifiers = c.decode(.keyEquivalentModifiers, default: ["ctrl", "alt"])
      self.assignModifiers = c.decode(.assignModifiers, default: ["ctrl", "alt", "shift"])
      self.recentWorkspaceKey = c.decodeIfValid(.recentWorkspaceKey)
      self.nextWorkspaceKey = c.decodeIfValid(.nextWorkspaceKey)
      self.previousWorkspaceKey = c.decodeIfValid(.previousWorkspaceKey)
      self.assignRecentWorkspace = c.decodeIfValid(.assignRecentWorkspace)
      self.assignNextWorkspace = c.decodeIfValid(.assignNextWorkspace)
      self.assignPreviousWorkspace = c.decodeIfValid(.assignPreviousWorkspace)
      self.borrowRecentWorkspace = c.decodeIfValid(.borrowRecentWorkspace)
      self.borrowNextWorkspace = c.decodeIfValid(.borrowNextWorkspace)
      self.borrowPreviousWorkspace = c.decodeIfValid(.borrowPreviousWorkspace)
      self.borrowModifiers = c.decode(.borrowModifiers, default: ["ctrl", "alt", "cmd"])
      self.dismissBorrow = c.decodeIfValid(.dismissBorrow)
    }
  }
}

extension AppSettings.Shortcuts {
  /// The starter shortcut set seeded into a *fresh* config (no `config.toml`
  /// on disk yet), so a new install is usable out of the box instead of every
  /// action needing to be recorded by hand. Applied only as the fresh-install
  /// seed (see `TatamiConfigKey`), never as a decode fallback: an existing
  /// config that omits — or deliberately clears — a shortcut keeps it unbound.
  ///
  /// Scheme: `⌃⌥` drives the many window/tile ops (focus, swap, resize,
  /// orientation, fullscreen, balance); workspace *switch* moves to `⌃⌥⇧` and
  /// *assign* to `⌥⇧⌘`, so a workspace's one-key equivalent never collides
  /// with a `⌃⌥` focus key. Window cycling rides the otherwise-free `⌥Tab`.
  public static let recommended = AppSettings.Shortcuts(
    focusLeft: HotKey(parsing: "ctrl + alt - h"),
    focusRight: HotKey(parsing: "ctrl + alt - l"),
    focusUp: HotKey(parsing: "ctrl + alt - k"),
    focusDown: HotKey(parsing: "ctrl + alt - j"),
    moveToNextWorkspace: HotKey(parsing: "ctrl + alt + shift - ]"),
    moveToPreviousWorkspace: HotKey(parsing: "ctrl + alt + shift - ["),
    focusNextDisplay: HotKey(parsing: "ctrl + alt + shift - right"),
    focusPreviousDisplay: HotKey(parsing: "ctrl + alt + shift - left"),
    cycleNextWindow: HotKey(parsing: "alt - tab"),
    cyclePreviousWindow: HotKey(parsing: "alt + shift - tab"),
    resizeGrow: HotKey(parsing: "ctrl + alt - ="),
    resizeShrink: HotKey(parsing: "ctrl + alt - -"),
    swapLeft: HotKey(parsing: "ctrl + alt - left"),
    swapRight: HotKey(parsing: "ctrl + alt - right"),
    swapUp: HotKey(parsing: "ctrl + alt - up"),
    swapDown: HotKey(parsing: "ctrl + alt - down"),
    toggleOrientation: HotKey(parsing: "ctrl + alt - s"),
    toggleFullscreen: HotKey(parsing: "ctrl + alt - return"),
    balance: HotKey(parsing: "ctrl + alt - e"),
    toggleFloating: HotKey(parsing: "alt + cmd - return"),
    toggleSharedFloating: HotKey(parsing: "alt + shift + cmd - return"),
    toggleSpaceActivated: HotKey(parsing: "ctrl + alt + shift + cmd - z"),
    toggleFocusedAppInActiveWorkspace: HotKey(parsing: "ctrl + alt - /"),
    toggleAppInSharedApps: HotKey(parsing: "ctrl + alt + shift - /"),
    keyEquivalentModifiers: ["ctrl", "alt", "shift"],
    assignModifiers: ["alt", "shift", "cmd"],
    recentWorkspaceKey: "\\",
    nextWorkspaceKey: ".",
    previousWorkspaceKey: ",",
    borrowModifiers: ["ctrl", "alt", "cmd"],
    dismissBorrow: HotKey(parsing: "ctrl + alt + cmd - /")
  )
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

  public var displayName: String {
    switch self {
    case .none: "None"
    case .option: "Option (⌥)"
    case .command: "Command (⌘)"
    case .control: "Control (⌃)"
    case .shift: "Shift (⇧)"
    }
  }
}
