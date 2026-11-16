// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Physical display ownership is independent of the Dock/menu-bar work area.
/// Partially visible and stranded windows still need one deterministic owner.
enum WindowDisplayOwnership {

  // MARK: Internal

  static func owner(
    of window: CGRect,
    displays: [DisplayName: CGRect],
    preferred: DisplayName? = nil,
  ) -> DisplayName? {
    guard isValid(window) else { return nil }
    let screens = displays.filter { isValid($0.value) }
    guard !screens.isEmpty else { return nil }
    let overlap = screens.mapValues { screen -> CGFloat in
      let intersection = window.intersection(screen)
      return intersection.isNull ? 0 : intersection.width * intersection.height
    }
    let largest = overlap.values.max() ?? 0
    let candidates: [DisplayName]
    if largest > 0 {
      candidates = overlap.compactMap { $0.value == largest ? $0.key : nil }
    } else {
      // Display removal, rotation, or resolution changes can strand a live
      // window beyond every screen. Assign the nearest connected display so
      // the next normal tile pass brings it back into a usable work area.
      let center = CGPoint(x: window.midX, y: window.midY)
      let distances = screens.mapValues { screen -> CGFloat in
        let dx = max(0, max(screen.minX - center.x, center.x - screen.maxX))
        let dy = max(0, max(screen.minY - center.y, center.y - screen.maxY))
        return dx * dx + dy * dy
      }
      let nearest = distances.values.min() ?? .infinity
      candidates = distances.compactMap { $0.value == nearest ? $0.key : nil }
    }
    if let preferred {
      let matches = candidates.filter { $0.matches(preferred) }
      if matches.count == 1 {
        return matches[0]
      }
    }
    return candidates.min { ($0.uuid ?? $0.name) < ($1.uuid ?? $1.name) }
  }

  // MARK: Private

  private static func isValid(_ rect: CGRect) -> Bool {
    rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
      && rect.width > 0 && rect.height > 0
  }

}
