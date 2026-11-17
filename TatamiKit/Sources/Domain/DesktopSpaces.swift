// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - DesktopSpaces

/// One coherent WindowServer read, including the desktops that still exist.
/// Space IDs are session-local and must never be persisted as configuration.
public struct DesktopSpaces: Equatable, Sendable {

  // MARK: Public

  public struct Display: Equatable, Sendable {
    public var uuid: String
    public var currentSpace: UInt64
    public var isUserDesktop: Bool
    public var userDesktops: Set<UInt64>
  }

  public var displays: [Display]
  public var focusedDisplayUUID: String? = nil

  // MARK: Internal

  /// Validate the private API boundary in one place. A malformed response is
  /// unavailable evidence, never an empty list of windows or a return home.
  static func decode(_ rows: [[String: Any]], focusedDisplayUUID: String?) -> Self? {
    var displays = [Display]()
    for row in rows {
      guard
        let uuid = row["Display Identifier"] as? String,
        let current = row["Current Space"] as? [String: Any],
        let id = current["id64"] as? NSNumber,
        id.uint64Value != 0,
        let type = current["type"] as? NSNumber,
        let spaces = row["Spaces"] as? [[String: Any]]
      else { return nil }
      var desktops = Set<UInt64>()
      for space in spaces {
        guard let sid = space["id64"] as? NSNumber, let kind = space["type"] as? NSNumber
        else { return nil }
        guard sid.uint64Value != 0 else { return nil }
        if kind.intValue == 0 {
          desktops.insert(sid.uint64Value)
        }
      }
      guard type.intValue != 0 || desktops.contains(id.uint64Value) else { return nil }
      displays.append(Display(
        uuid: uuid,
        currentSpace: id.uint64Value,
        isUserDesktop: type.intValue == 0,
        userDesktops: desktops,
      ))
    }
    guard !displays.isEmpty, Set(displays.map(\.uuid)).count == displays.count else { return nil }
    return Self(displays: displays, focusedDisplayUUID: focusedDisplayUUID)
  }

  func space(on display: DisplayName) -> Display? {
    if let uuid = display.uuid, let exact = displays.first(where: { $0.uuid == uuid }) {
      return exact
    }
    // With separate Spaces disabled, WindowServer reports one shared "Main"
    // space graph. Do not substitute another physical monitor's desktop.
    return displays.count == 1 && displays[0].uuid == "Main" ? displays[0] : nil
  }

}

// MARK: - ManagedDesktops

/// Tatami owns one ordinary macOS Desktop per physical monitor. Visiting any
/// other Space preserves its workspace graph; other monitors keep running.
public struct ManagedDesktops: Equatable, Sendable {

  // MARK: Public

  public var homes = [DisplayName: UInt64]()
  public var snapshot: DesktopSpaces?
  public var isRefreshing = false
  public var observationFailed = false
  public var revision: UInt64 = 0

  // MARK: Internal

  func home(on display: DisplayName) -> UInt64? {
    homes.first(where: { $0.key.matches(display) })?.value
  }

  func isAvailable(on display: DisplayName?) -> Bool {
    guard !isRefreshing, !observationFailed else { return false }
    guard let display, let snapshot else { return true }
    guard let space = snapshot.space(on: display), space.isUserDesktop else { return false }
    return home(on: display).map { $0 == space.currentSpace } ?? true
  }

  mutating func observe(_ snapshot: DesktopSpaces?, displays: Set<DisplayName>) {
    isRefreshing = false
    observationFailed = snapshot == nil
    self.snapshot = snapshot
    guard let snapshot else { return }
    for display in displays {
      guard let space = snapshot.space(on: display), space.isUserDesktop else { continue }
      let previous = home(on: display)
      // Deleting a Desktop moves its windows to a surviving Desktop. Adopt
      // that replacement only when the old ID is authoritatively absent.
      if previous == nil || !space.userDesktops.contains(previous!) {
        adopt(display)
      }
    }
  }

  // MARK: Private

  private mutating func adopt(_ display: DisplayName) {
    guard let space = snapshot?.space(on: display), space.isUserDesktop else { return }
    if snapshot?.displays.count == 1, snapshot?.displays.first?.uuid == "Main" {
      // macOS couples the displays when separate Spaces are disabled.
      for key in homes.keys { homes[key] = space.currentSpace }
    }
    homes = homes.filter { !$0.key.matches(display) }
    homes[display] = space.currentSpace
  }

}

// MARK: - DesktopObservation

/// Optional action payloads distinguish a failed read from a caller that did
/// not perform a read (for example, an injected reducer event).
public struct DesktopObservation: Sendable {
  public var spaces: DesktopSpaces?
  public var revision: UInt64
  public var isCoherent = true
}
