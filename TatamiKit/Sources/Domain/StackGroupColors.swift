// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - StackGroupColors

/// Named groups keep a palette slot when they are renamed, moved, or edited.
/// Shared groups have a separate set of colors so they can appear alongside
/// workspace groups on any display without taking one of their slots.
public enum StackGroupColors {

  // MARK: Public

  public enum Scope: Sendable, Equatable {
    case workspace
    case shared
  }

  public static func colors(for groups: [StackGroup], scope: Scope) -> [StackGroup.ID: String] {
    slots(for: groups).mapValues { color(for: $0, scope: scope) }
  }

  // MARK: Internal

  static func firstAvailableSlot(excluding occupied: Set<Int>) -> Int {
    (0 ... occupied.count).first { !occupied.contains($0) } ?? occupied.count
  }

  static func slots(for groups: [StackGroup]) -> [StackGroup.ID: Int] {
    var occupied = Set<Int>()
    var result = [StackGroup.ID: Int]()
    let ordered = groups.sorted { $0.id.uuidString < $1.id.uuidString }
    // First reserve persisted slots. Sorting makes legacy migration and any
    // duplicate slots from hand-edited configuration independent of row order.
    for group in ordered {
      if let slot = group.colorSlot, slot >= 0, occupied.insert(slot).inserted {
        result[group.id] = slot
      }
    }
    for group in ordered where result[group.id] == nil {
      let slot = firstAvailableSlot(excluding: occupied)
      result[group.id] = slot
      occupied.insert(slot)
    }
    return result
  }

  // MARK: Private

  private static func color(for slot: Int, scope: Scope) -> String {
    let palette =
      switch scope {
      case .workspace: ["#89B4FA", "#FAB387", "#CBA6F7", "#F9E2AF", "#F38BA8", "#74C7EC", "#B4BEFE", "#F5C2E7"]
      case .shared: ["#F1AAA2", "#91DCCB", "#B7CF80", "#DC9FE2", "#8DD4BA", "#E6B9E9", "#C5BB7D", "#92C3DA"]
      }
    if slot < palette.count {
      return palette[slot]
    }

    // Additional groups get a stable hue rather than reusing another group's
    // initial palette color. The scope offset keeps the two sequences apart.
    let offset = scope == .workspace ? 0.0 : 0.5
    let hue = (Double(slot) * 0.61803398875 + offset).truncatingRemainder(dividingBy: 1)
    let chroma = scope == .workspace ? 0.48 : 0.32
    let sector = hue * 6
    let part = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
    let (r, g, b): (Double, Double, Double) =
      switch Int(sector) {
      case 0: (chroma, part, 0)
      case 1: (part, chroma, 0)
      case 2: (0, chroma, part)
      case 3: (0, part, chroma)
      case 4: (part, 0, chroma)
      default: (chroma, 0, part)
      }
    let base = 0.91 - chroma
    return String(format: "#%02X%02X%02X", Int((base + r) * 255), Int((base + g) * 255), Int((base + b) * 255))
  }

}

extension [StackGroup] {
  func assigningStackGroupColors() -> [StackGroup] {
    let slots = StackGroupColors.slots(for: self)
    return map { group in
      var group = group
      group.colorSlot = slots[group.id]
      return group
    }
  }
}
