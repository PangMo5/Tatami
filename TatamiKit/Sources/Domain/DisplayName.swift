import AppKit
import Foundation

/// A reference to a macOS display: a stable per-monitor `uuid` (from
/// `CGDisplayCreateUUIDFromDisplayID`) plus the human-readable `name`
/// (`localizedName`).
///
/// Matching prefers the UUID (so two identical-model monitors are
/// distinguishable and a renamed display still resolves), and falls back to
/// the name (so an assignment made before the UUID was learned — or in a
/// hand-edited config — still works). When neither resolves to a connected
/// display, callers fall back to the primary display.
///
/// Persisted form (TOML, kept human-readable): `"<uuid>::<name>"`, or just
/// `"<name>"` when the UUID isn't known yet (legacy / hand-edited).
public struct DisplayName: Hashable, Sendable, Codable, ExpressibleByStringLiteral {
  /// Stable per-physical-display identifier; `nil` until learned.
  public var uuid: String?
  /// Localized display name, shown in the UI and used as a matching fallback.
  public var name: String

  public init(uuid: String? = nil, name: String) {
    self.uuid = uuid
    self.name = name
  }

  /// Name-only (no UUID). Convenience for tests / literals / hand-edits.
  public init(_ name: String) {
    self.uuid = nil
    self.name = name
  }

  public init(stringLiteral value: StringLiteralType) {
    self.init(value)
  }

  /// Same physical display? UUID match wins; otherwise compare names. (Not
  /// `==`, which uses the canonical key for stable hashing.)
  public func matches(_ other: DisplayName) -> Bool {
    if let uuid, let otherUUID = other.uuid { return uuid == otherUUID }
    return name == other.name
  }

  /// Canonical identity for `Hashable`: the UUID when known, else the name.
  private var canonicalKey: String { uuid ?? name }

  public static func == (lhs: DisplayName, rhs: DisplayName) -> Bool {
    lhs.canonicalKey == rhs.canonicalKey
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(canonicalKey)
  }

  // MARK: Codable — single string "<uuid>::<name>" (or "<name>")

  private static let separator = "::"

  public init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    if let range = raw.range(of: Self.separator) {
      self.uuid = String(raw[raw.startIndex ..< range.lowerBound])
      self.name = String(raw[range.upperBound...])
    } else {
      self.uuid = nil
      self.name = raw
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    if let uuid, !uuid.isEmpty {
      try container.encode("\(uuid)\(Self.separator)\(name)")
    } else {
      try container.encode(name)
    }
  }
}

extension DisplayName: CustomStringConvertible {
  public var description: String { name }
}

// MARK: - NSScreen display identity

extension NSScreen {
  /// The `CGDirectDisplayID` backing this screen, if available.
  public var displayID: CGDirectDisplayID? {
    deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
  }

  /// Stable UUID string for this screen's physical display.
  public var displayUUID: String? {
    guard let id = displayID,
          let cfUUID = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
    else { return nil }
    return CFUUIDCreateString(nil, cfUUID) as String?
  }

  /// `DisplayName` (uuid + localized name) for this screen.
  public var displayName: DisplayName? {
    guard !localizedName.isEmpty else { return nil }
    return DisplayName(uuid: displayUUID, name: localizedName)
  }
}

// MARK: - Resolution

public enum DisplayResolver {
  /// The primary display (menu-bar display) — the fallback used everywhere
  /// when a pinned display isn't connected.
  @MainActor
  public static func primaryScreen() -> NSScreen? {
    let main = CGMainDisplayID()
    return NSScreen.screens.first { $0.displayID == main } ?? NSScreen.screens.first
  }

  /// The *connected* screen a reference points at — UUID match, then name
  /// match — or `nil` if that display isn't currently connected. (No primary
  /// fallback here, so callers can tell "matched" from "fell back" — e.g. to
  /// avoid healing a pin to the wrong display when it's unplugged.)
  @MainActor
  public static func connectedScreen(for ref: DisplayName) -> NSScreen? {
    let screens = NSScreen.screens
    if let uuid = ref.uuid,
       let byUUID = screens.first(where: { $0.displayUUID == uuid }) {
      return byUUID
    }
    return screens.first { $0.localizedName == ref.name }
  }

  /// The screen for a reference, falling back to the primary display when the
  /// reference is `nil` or its display isn't connected. Use for geometry.
  @MainActor
  public static func screenOrPrimary(for ref: DisplayName?) -> NSScreen? {
    guard let ref else { return primaryScreen() }
    return connectedScreen(for: ref) ?? primaryScreen()
  }
}
