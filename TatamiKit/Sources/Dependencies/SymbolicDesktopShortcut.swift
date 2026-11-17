// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Darwin
import Foundation

/// Runtime symbolic-hotkey discovery follows Silica's SISystemWideElement:
/// https://github.com/ianyh/Silica/blob/09353df41c25ecaf5ab76b2a7db6d6d5de142f4a/Silica/Sources/SISystemWideElement.m
/// This driver only runs on ManagedDesktopNavigator's serial IPC worker.
final class SymbolicDesktopShortcut: @unchecked Sendable {

  // MARK: Lifecycle

  init() {
    let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
    self.handle = handle
    func symbol(_ names: [String]) -> UnsafeMutableRawPointer? {
      for name in names {
        if let handle, let value = dlsym(handle, name) {
          return value
        }
      }
      return nil
    }
    get = symbol(["CGSGetSymbolicHotKeyValue", "SLSGetSymbolicHotKeyValue"]).map { unsafeBitCast($0, to: Get.self) }
    isEnabled = symbol(["CGSIsSymbolicHotKeyEnabled", "SLSIsSymbolicHotKeyEnabled"]).map { unsafeBitCast($0, to: IsEnabled.self) }
    setEnabled = symbol(["CGSSetSymbolicHotKeyEnabled", "SLSSetSymbolicHotKeyEnabled"]).map { unsafeBitCast(
      $0,
      to: SetEnabled.self,
    ) }
  }

  // MARK: Internal

  struct Lease: Sendable {
    var id: Int32
    var keyCode: UInt16
    var modifiers: UInt32
    var wasEnabled: Bool
    var ordinaryOrder: [UInt64]
  }

  struct Failure: Error, LocalizedError, Sendable {
    init(_ message: String) {
      self.message = message
    }

    var errorDescription: String? {
      message
    }

    private let message: String
  }

  static func ordinaryOrder(in snapshot: DesktopSpaces) -> [UInt64]? {
    guard snapshot.displays.allSatisfy({ !$0.spaceOrder.isEmpty }) else { return nil }
    let order = snapshot.displays.flatMap { row in row.spaceOrder.filter { row.userDesktops.contains($0) } }
    return Set(order).count == order.count ? order : nil
  }

  func acquire(home: UInt64, snapshot: DesktopSpaces) throws -> Lease {
    guard let get, let isEnabled, let setEnabled else { throw Failure("Native Desktop shortcut APIs are unavailable") }
    guard let order = Self.ordinaryOrder(in: snapshot), let index = order.firstIndex(of: home), index < 16 else {
      throw Failure("The managed Desktop has no supported system shortcut")
    }
    let id = Int32(118 + index)
    var character: UInt16 = 0
    var keyCode: UInt16 = 0
    var modifiers: UInt32 = 0
    guard
      get(id, &character, &keyCode, &modifiers) == 0,
      keyCode < 128,
      modifiers != 0 || Self.functionKeys.contains(keyCode)
    else {
      throw Failure("The managed Desktop system shortcut is not configured")
    }
    let original = isEnabled(id)
    if !original {
      guard setEnabled(id, true) == 0, isEnabled(id) else {
        _ = setEnabled(id, false)
        throw Failure("The managed Desktop system shortcut could not be enabled")
      }
    }
    return Lease(id: id, keyCode: keyCode, modifiers: modifiers, wasEnabled: original, ordinaryOrder: order)
  }

  func post(_ lease: Lease) throws {
    guard
      let source = CGEventSource(stateID: .privateState),
      let down = CGEvent(keyboardEventSource: source, virtualKey: lease.keyCode, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: lease.keyCode, keyDown: false)
    else {
      throw Failure("The native Desktop key event could not be created")
    }
    source.localEventsSuppressionInterval = 0
    down.flags = CGEventFlags(rawValue: UInt64(lease.modifiers))
    up.flags = []
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
  }

  func restore(_ lease: Lease) throws {
    guard let get, let isEnabled, let setEnabled else { throw Failure("Native Desktop shortcut APIs became unavailable") }
    var key: UInt16 = 0
    var flags: UInt32 = 0
    guard get(lease.id, nil, &key, &flags) == 0, key == lease.keyCode, flags == lease.modifiers else {
      throw Failure("The native Desktop shortcut was edited during activation; its new settings were preserved")
    }
    if isEnabled(lease.id) != lease.wasEnabled {
      guard setEnabled(lease.id, lease.wasEnabled) == 0, isEnabled(lease.id) == lease.wasEnabled else {
        throw Failure("The native Desktop shortcut enablement could not be restored")
      }
    }
  }

  // MARK: Private

  private typealias Get = @convention(c) (
    Int32,
    UnsafeMutablePointer<UInt16>?,
    UnsafeMutablePointer<UInt16>?,
    UnsafeMutablePointer<UInt32>?,
  ) -> Int32
  private typealias IsEnabled = @convention(c) (Int32) -> Bool
  private typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32

  private static let functionKeys: Set<UInt16> = [
    122,
    120,
    99,
    118,
    96,
    97,
    98,
    100,
    101,
    109,
    103,
    111,
    105,
    107,
    113,
    106,
    64,
    79,
    80,
    90,
  ]

  private let handle: UnsafeMutableRawPointer?
  private let get: Get?
  private let isEnabled: IsEnabled?
  private let setEnabled: SetEnabled?

}
