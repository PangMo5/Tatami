// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

// MARK: - WorkspaceKind

/// Normal vs scratchpad. A scratchpad is borrow-only: excluded from cycling
/// and standalone activation, it only appears when summoned into another
/// workspace's composition.
public enum WorkspaceKind: String, Hashable, Sendable, Codable, CaseIterable {
  case normal
  case scratchpad

  public var displayName: LocalizedStringResource {
    switch self {
    case .normal: "Normal"
    case .scratchpad: "Scratchpad"
    }
  }
}

// MARK: - Workspace

/// One unit of "what's visible right now": a named set of app assignments,
/// pinned to a display (or floating across displays in `dynamic` mode).
public struct Workspace: Identifiable, Hashable, Sendable, Codable {

  // MARK: Lifecycle

  public init(
    id: UUID = UUID(),
    name: String,
    displayHint: DisplayName? = nil,
    activateShortcut: HotKey? = nil,
    assignAppShortcut: HotKey? = nil,
    symbolIconName: String? = nil,
    appToFocusBundleId: String? = nil,
    kind: WorkspaceKind = .normal,
    keyEquivalent: String? = nil,
    borrowShortcut: HotKey? = nil,
    borrowEdge: BorrowEdge? = nil,
    borrowFraction: Double? = nil,
    apps: [AppAssignment] = [],
  ) {
    self.id = id
    self.name = name
    self.displayHint = displayHint
    self.activateShortcut = activateShortcut
    self.assignAppShortcut = assignAppShortcut
    self.symbolIconName = symbolIconName
    self.appToFocusBundleId = appToFocusBundleId
    self.kind = kind
    self.keyEquivalent = keyEquivalent
    self.borrowShortcut = borrowShortcut
    self.borrowEdge = borrowEdge
    self.borrowFraction = borrowFraction
    self.apps = apps
  }

  // MARK: Public

  public var id: UUID
  public var name: String
  /// Static-mode display assignment. `nil` means dynamic (follow mouse).
  public var displayHint: DisplayName?
  /// Hotkey that activates this workspace.
  public var activateShortcut: HotKey?
  /// Hotkey that assigns the focused app to this workspace (duplicate
  /// assignment — keeps existing memberships) and switches to it.
  public var assignAppShortcut: HotKey?
  /// SF Symbol name for menu/space-control rendering.
  public var symbolIconName: String?
  /// Bundle identifier of the app to focus when this workspace activates.
  /// Nil = focus the most recently active assigned app.
  public var appToFocusBundleId: String?
  /// Normal vs scratchpad (borrow-only). Scratchpad is skipped by cycling
  /// and standalone activation; it only shows when borrowed.
  public var kind: WorkspaceKind
  /// Single-character key identifying this workspace. The switch-modifier
  /// combo + this key activates it (unless `activateShortcut` overrides), and
  /// pressing it in borrow mode summons it. Lowercased on use; `h`/`j`/`k`/`l`
  /// double as borrow-mode direction keys, so a workspace keyed to one of them
  /// still activates but isn't borrow-summonable.
  public var keyEquivalent: String?
  /// Explicit shortcut overriding the borrow-modifier + key default for
  /// borrowing this workspace; a direction key still follows to place it.
  public var borrowShortcut: HotKey?
  /// Per-workspace override of the default borrow edge (`nil` → fall back to
  /// the global default; if that's also nil, pick a direction after the combo).
  public var borrowEdge: BorrowEdge?
  /// Per-workspace override of the borrowed share of the screen (`nil` →
  /// global default).
  public var borrowFraction: Double?
  public var apps: [AppAssignment]

}

extension Workspace {

  // MARK: Lifecycle

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    displayHint = try container.decodeIfPresent(DisplayName.self, forKey: .displayHint)
    activateShortcut = try container.decodeIfPresent(HotKey.self, forKey: .activateShortcut)
    assignAppShortcut = try container.decodeIfPresent(HotKey.self, forKey: .assignAppShortcut)
    symbolIconName = try container.decodeIfPresent(String.self, forKey: .symbolIconName)
    appToFocusBundleId = try container.decodeIfPresent(String.self, forKey: .appToFocusBundleId)
    kind = try container.decodeIfPresent(WorkspaceKind.self, forKey: .kind) ?? .normal
    keyEquivalent = try container.decodeIfPresent(String.self, forKey: .keyEquivalent)
    borrowShortcut = try container.decodeIfPresent(HotKey.self, forKey: .borrowShortcut)
    borrowEdge = try container.decodeIfPresent(BorrowEdge.self, forKey: .borrowEdge)
    borrowFraction = try container.decodeIfPresent(Double.self, forKey: .borrowFraction)
    apps = try container.decodeIfPresent([AppAssignment].self, forKey: .apps) ?? []
  }

  // MARK: Private

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case displayHint
    case activateShortcut
    case assignAppShortcut
    case symbolIconName
    case appToFocusBundleId
    case kind
    case keyEquivalent
    case borrowShortcut
    case borrowEdge
    case borrowFraction
    case apps
  }

}

extension Workspace {
  public var isDynamic: Bool {
    displayHint == nil
  }
}

// MARK: - BorrowEdge

/// Which screen edge a borrowed workspace block docks to.
public enum BorrowEdge: String, Hashable, Sendable, Codable, CaseIterable {
  case top
  case bottom
  case left
  case right

  public var displayName: LocalizedStringResource {
    switch self {
    case .top: "Top"
    case .bottom: "Bottom"
    case .left: "Left"
    case .right: "Right"
    }
  }

  /// The opposing edge — the host block sits opposite the borrowed dock.
  public var opposite: BorrowEdge {
    switch self {
    case .top: .bottom
    case .bottom: .top
    case .left: .right
    case .right: .left
    }
  }
}

// MARK: - BorrowedSlot

/// One borrowed workspace docked into a host's composition. A borrow is always
/// transient — it's dropped when the host re-tiles (a switch or focus change).
/// Edits in the borrowed block still persist to that workspace (the borrow is
/// live); only the on-screen presence is temporary.
public struct BorrowedSlot: Hashable, Sendable, Codable {
  public init(
    workspace: Workspace.ID,
    edge: BorrowEdge,
    fraction: CGFloat = 0.4,
  ) {
    self.workspace = workspace
    self.edge = edge
    self.fraction = fraction
  }

  public var workspace: Workspace.ID
  public var edge: BorrowEdge
  /// The borrowed block's share of the split axis (0…1).
  public var fraction: CGFloat
}

// MARK: - Composition

/// What one display shows: a host workspace plus borrowed blocks. Absent for
/// a display → it shows its host alone (default, pre-feature behavior).
public struct Composition: Hashable, Sendable, Codable {
  public init(host: Workspace.ID, borrowed: [BorrowedSlot] = []) {
    self.host = host
    self.borrowed = borrowed
  }

  public var host: Workspace.ID
  public var borrowed: [BorrowedSlot]
}
