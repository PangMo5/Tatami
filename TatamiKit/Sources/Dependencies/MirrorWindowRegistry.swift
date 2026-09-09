// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import os

/// Maps floating-mirror panel window numbers to the real window each one
/// mirrors. Written by `FloatingOverlayController` (main thread) and read
/// by the focus-follows-mouse hit-test (event-tap thread): when the
/// cursor sits on a mirror, FFM must focus the mirrored window — not the
/// tile that happens to lie underneath the panel — or the two fight over
/// focus and the hand-off flickers.
final class MirrorWindowRegistry: Sendable {

  // MARK: Internal

  struct Target: Equatable, Sendable {
    init(pid: pid_t, windowID: CGWindowID) {
      self.pid = pid
      self.windowID = windowID
    }

    var pid: pid_t
    var windowID: CGWindowID
  }

  static let shared = MirrorWindowRegistry()

  /// Register (or, with `nil`, unregister) a mirror panel's window number.
  func set(mirror windowID: CGWindowID, target: Target?, frame: CGRect? = nil) {
    guard windowID != 0 else { return }
    entries.withLock { entries in
      entries[windowID] = target.map { Entry(target: $0, frame: frame) }
    }
  }

  /// Only a coarse admission gate. Actual occlusion/input ownership comes
  /// from WindowServer's read-only hit test, never from these rectangles.
  func mayContainMirror(at point: CGPoint) -> Bool {
    entries.withLock { $0.values.contains { $0.frame?.contains(point) == true } }
  }

  /// Snapshot of every registered mirror → target mapping. The FFM
  /// hit-test walks the full on-screen window list per fire; one lock
  /// acquisition for the snapshot beats one per window entry.
  func allTargets() -> [CGWindowID: Target] {
    entries.withLock { $0.mapValues(\.target) }
  }

  /// The floating overlay registers here to learn that Tatami itself is
  /// about to move focus to `pid`'s window (focus-follows-mouse, BSP focus,
  /// hotkeys). Restoring mirrors *before* the focus moves lands them in the
  /// same frame as the z-order change — reacting to
  /// `didActivateApplication` afterwards is one beat too late and the
  /// floating window visibly drops behind the tile first.
  ///
  /// The async handler verifies visibility off-main and commits presentation
  /// on the main actor before focus can move. Nil means a newer focus intent
  /// superseded preparation; Bool indicates whether a mirror was restored and its presentation verified.
  func setWillFocusHandler(_ handler: (@Sendable (pid_t) async -> Bool?)?) {
    willFocusHandler.withLock { $0 = handler }
  }

  /// Returns true after restored mirrors have been verified as presented.
  func notifyWillFocus(pid: pid_t) async -> Bool? {
    guard let handler = willFocusHandler.withLock({ $0 }) else { return false }
    return await handler(pid)
  }

  /// A same-app focus change emits no application-activation notification.
  /// Notify the mirror owner after the exact native focus request completes.
  func setDidFocusHandler(_ handler: (@Sendable (Target) async -> Void)?) {
    didFocusHandler.withLock { $0 = handler }
  }

  func notifyDidFocus(pid: pid_t, windowID: CGWindowID) async {
    guard let handler = didFocusHandler.withLock({ $0 }) else { return }
    await handler(Target(pid: pid, windowID: windowID))
  }

  /// Frames (global top-left CG coordinates) of the floating windows whose
  /// mirror is currently suppressed because their app holds focus. The
  /// mouse-down tap reads these to recognize a click that is about to move
  /// focus *away* from the floating app.
  func setSuppressedFrames(_ frames: [CGWindowID: CGRect]) {
    suppressedFrames.withLock { $0 = frames }
  }

  func suppressedWindowFrames() -> [CGRect] {
    suppressedFrames.withLock { Array($0.values) }
  }

  func setNativeInputActive(_ active: Bool) {
    nativeInputActive.withLock { $0 = active }
  }

  func isNativeInputActive() -> Bool {
    nativeInputActive.withLock { $0 }
  }

  // MARK: Private

  private struct Entry: Sendable {
    var target: Target
    var frame: CGRect?
  }

  private let nativeInputActive = OSAllocatedUnfairLock(initialState: false)

  private let entries = OSAllocatedUnfairLock<[CGWindowID: Entry]>(initialState: [:])
  private let willFocusHandler =
    OSAllocatedUnfairLock<(@Sendable (pid_t) async -> Bool?)?>(initialState: nil)
  private let didFocusHandler =
    OSAllocatedUnfairLock<(@Sendable (Target) async -> Void)?>(initialState: nil)
  private let suppressedFrames =
    OSAllocatedUnfairLock<[CGWindowID: CGRect]>(initialState: [:])

}
