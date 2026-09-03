// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import IdentifiedCollections

/// A named collection of `Workspace`s. The user can switch profiles to
/// completely swap which workspaces, hotkeys, and assignments are active.
public struct Profile: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var name: String
  /// SF Symbol shown for the profile (sidebar, menu bar). Nil = the default
  /// `rectangle.stack`.
  public var symbolIconName: String?
  /// Optional global shortcut that activates this profile.
  public var shortcut: HotKey?
  /// Optional rule that auto-activates this profile when the connected displays
  /// match (nil = manual only). See `ProfileActivation`.
  public var autoActivation: ProfileActivation?
  /// Symmetric workspace groups that switch together across displays. Kept at
  /// profile scope so sibling references have one canonical owner.
  public var workspaceChains: [WorkspaceChain]
  public var workspaces: IdentifiedArrayOf<Workspace>

  public init(
    id: UUID = UUID(),
    name: String,
    symbolIconName: String? = nil,
    shortcut: HotKey? = nil,
    autoActivation: ProfileActivation? = nil,
    workspaceChains: [WorkspaceChain] = [],
    workspaces: IdentifiedArrayOf<Workspace> = []
  ) {
    self.id = id
    self.name = name
    self.symbolIconName = symbolIconName
    self.shortcut = shortcut
    self.autoActivation = autoActivation
    self.workspaceChains = workspaceChains
    self.workspaces = workspaces
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encodeIfPresent(symbolIconName, forKey: .symbolIconName)
    try container.encodeIfPresent(shortcut, forKey: .shortcut)
    try container.encodeIfPresent(autoActivation, forKey: .autoActivation)
    if !workspaceChains.isEmpty {
      try container.encode(workspaceChains, forKey: .workspaceChains)
    }
    try container.encode(workspaces, forKey: .workspaces)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case symbolIconName
    case shortcut
    case autoActivation
    case workspaceChains
    case workspaces
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    symbolIconName = try container.decodeIfPresent(String.self, forKey: .symbolIconName)
    shortcut = try container.decodeIfPresent(HotKey.self, forKey: .shortcut)
    autoActivation = try container.decodeIfPresent(ProfileActivation.self, forKey: .autoActivation)
    workspaceChains = try container.decodeIfPresent(
      [WorkspaceChain].self,
      forKey: .workspaceChains,
    ) ?? []
    workspaces = try container.decode(IdentifiedArrayOf<Workspace>.self, forKey: .workspaces)
  }
}

extension Profile {
  public static let defaultName = "Default"

  public static func makeDefault() -> Profile {
    Profile(name: defaultName)
  }
}
