// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - StackGroup

/// Apps whose tiled windows share one tile wherever this group applies.
public struct StackGroup: Identifiable, Hashable, Sendable, Codable {

  // MARK: Lifecycle

  public init(id: UUID = UUID(), name: String, bundleIdentifiers: [String], colorSlot: Int? = nil) {
    self.id = id
    self.name = name
    self.bundleIdentifiers = bundleIdentifiers
    self.colorSlot = colorSlot
  }

  // MARK: Public

  public var id: UUID
  public var name: String
  public var bundleIdentifiers: [String]
  /// Stable palette slot within the group’s configuration scope.
  public var colorSlot: Int?

  // MARK: Internal

  static func validate(_ groups: [StackGroup], codingPath: [any CodingKey]) throws {
    var ids = Set<ID>()
    var members = Set<String>()
    for group in groups {
      guard ids.insert(group.id).inserted else {
        throw DecodingError.dataCorrupted(.init(
          codingPath: codingPath,
          debugDescription: "Duplicate stack group ID: \(group.id)",
        ))
      }
      for bundleId in group.bundleIdentifiers where !members.insert(bundleId).inserted {
        throw DecodingError.dataCorrupted(.init(
          codingPath: codingPath,
          debugDescription: "App \(bundleId) belongs to more than one stack group in the same scope.",
        ))
      }
    }
  }

}

extension [StackGroup] {
  /// Apply an edit against the current assignments, since the picker may have
  /// been open while the configuration changed elsewhere.
  mutating func save(
    _ group: StackGroup,
    movingFrom sourceGroups: [String: StackGroup.ID] = [:],
    availableBundleIds: Set<String>,
  ) -> Set<String> {
    let selected = Set(group.bundleIdentifiers)
    let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !selected.isEmpty, selected.isSubset(of: availableBundleIds) else { return [] }

    var currentOwners = [String: StackGroup.ID]()
    for other in self where other.id != group.id {
      for bundleId in other.bundleIdentifiers where selected.contains(bundleId) {
        guard currentOwners.updateValue(other.id, forKey: bundleId) == nil else { return [] }
      }
    }
    // Confirmed source IDs must still match at save time. One transaction moves
    // the selected apps and removes any source groups emptied by the transfer.
    guard currentOwners == sourceGroups else { return [] }
    var updated = group
    updated.name = name
    updated.bundleIdentifiers = selected.sorted()
    let colored = assigningStackGroupColors()
    let previous = colored.first { $0.id == group.id }
    let usedSlots = Set(colored.compactMap(\.colorSlot))
    updated.colorSlot = previous?.colorSlot ?? StackGroupColors.firstAvailableSlot(excluding: usedSlots)
    guard previous != updated || !sourceGroups.isEmpty else { return [] }

    let sourceIds = Set(sourceGroups.values)
    self = colored.compactMap { existing in
      if existing.id == group.id {
        return updated
      }
      guard sourceIds.contains(existing.id) else { return existing }
      var source = existing
      source.bundleIdentifiers.removeAll { sourceGroups[$0] == existing.id }
      return source.bundleIdentifiers.isEmpty ? nil : source
    }
    if previous == nil {
      append(updated)
    }
    return selected.union(previous?.bundleIdentifiers ?? [])
  }

  mutating func remove(id: StackGroup.ID) -> Set<String> {
    guard let index = firstIndex(where: { $0.id == id }) else { return [] }
    self = assigningStackGroupColors()
    return Set(remove(at: index).bundleIdentifiers)
  }
}
