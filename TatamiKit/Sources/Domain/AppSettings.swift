import Foundation

/// Application-wide settings persisted in `config.toml`. Grows as the
/// app gains features; each new field is optional with a sensible
/// default so older config files keep decoding.
public struct AppSettings: Hashable, Sendable, Codable {
  // MARK: General

  public var checkForUpdatesAutomatically: Bool

  // MARK: Focus + Mouse (yabai-style)

  /// Move the cursor to the center of the focused window automatically.
  public var mouseFollowsFocus: Bool
  /// Hide the cursor whenever focus changes (revealed by mouse movement).
  public var mouseHidesOnFocus: Bool
  /// Focus the window under the cursor while it moves.
  public var focusFollowsMouse: Bool
  /// Holding this modifier temporarily disables `focusFollowsMouse`.
  public var focusFollowsMouseDisableHotkey: FocusFollowsMouseModifier

  // MARK: Focus Manager hotkeys

  public var focusLeft: HotKey?
  public var focusRight: HotKey?
  public var focusUp: HotKey?
  public var focusDown: HotKey?

  public init(
    checkForUpdatesAutomatically: Bool = true,
    mouseFollowsFocus: Bool = false,
    mouseHidesOnFocus: Bool = false,
    focusFollowsMouse: Bool = false,
    focusFollowsMouseDisableHotkey: FocusFollowsMouseModifier = .option,
    focusLeft: HotKey? = nil,
    focusRight: HotKey? = nil,
    focusUp: HotKey? = nil,
    focusDown: HotKey? = nil
  ) {
    self.checkForUpdatesAutomatically = checkForUpdatesAutomatically
    self.mouseFollowsFocus = mouseFollowsFocus
    self.mouseHidesOnFocus = mouseHidesOnFocus
    self.focusFollowsMouse = focusFollowsMouse
    self.focusFollowsMouseDisableHotkey = focusFollowsMouseDisableHotkey
    self.focusLeft = focusLeft
    self.focusRight = focusRight
    self.focusUp = focusUp
    self.focusDown = focusDown
  }
}

extension AppSettings {
  private enum CodingKeys: String, CodingKey {
    case checkForUpdatesAutomatically
    case mouseFollowsFocus
    case mouseHidesOnFocus
    case focusFollowsMouse
    case focusFollowsMouseDisableHotkey
    case focusLeft
    case focusRight
    case focusUp
    case focusDown
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    checkForUpdatesAutomatically = try container.decodeIfPresent(
      Bool.self,
      forKey: .checkForUpdatesAutomatically
    ) ?? true
    mouseFollowsFocus = try container.decodeIfPresent(Bool.self, forKey: .mouseFollowsFocus)
      ?? false
    mouseHidesOnFocus = try container.decodeIfPresent(Bool.self, forKey: .mouseHidesOnFocus)
      ?? false
    focusFollowsMouse = try container.decodeIfPresent(Bool.self, forKey: .focusFollowsMouse)
      ?? false
    focusFollowsMouseDisableHotkey = try container.decodeIfPresent(
      FocusFollowsMouseModifier.self,
      forKey: .focusFollowsMouseDisableHotkey
    ) ?? .option
    focusLeft = try container.decodeIfPresent(HotKey.self, forKey: .focusLeft)
    focusRight = try container.decodeIfPresent(HotKey.self, forKey: .focusRight)
    focusUp = try container.decodeIfPresent(HotKey.self, forKey: .focusUp)
    focusDown = try container.decodeIfPresent(HotKey.self, forKey: .focusDown)
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
