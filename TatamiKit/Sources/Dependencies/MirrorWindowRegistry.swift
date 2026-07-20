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
  static let shared = MirrorWindowRegistry()

  struct Target: Sendable {
    var pid: pid_t
    var windowID: CGWindowID

    init(pid: pid_t, windowID: CGWindowID) {
      self.pid = pid
      self.windowID = windowID
    }
  }

  private let entries = OSAllocatedUnfairLock<[CGWindowID: Target]>(initialState: [:])
  private let willFocusHandler =
    OSAllocatedUnfairLock<(@Sendable (pid_t) -> Bool)?>(initialState: nil)
  private let suppressedFrames =
    OSAllocatedUnfairLock<[CGWindowID: CGRect]>(initialState: [:])

  /// Register (or, with `nil`, unregister) a mirror panel's window number.
  func set(mirror windowID: CGWindowID, target: Target?) {
    guard windowID != 0 else { return }
    entries.withLock { $0[windowID] = target }
  }

  /// Snapshot of every registered mirror → target mapping. The FFM
  /// hit-test walks the full on-screen window list per fire; one lock
  /// acquisition for the snapshot beats one per window entry.
  func allTargets() -> [CGWindowID: Target] {
    entries.withLock { $0 }
  }

  /// The floating overlay registers here to learn that Tatami itself is
  /// about to move focus to `pid`'s window (focus-follows-mouse, BSP focus,
  /// hotkeys). Restoring mirrors *before* the focus moves lands them in the
  /// same frame as the z-order change — reacting to
  /// `didActivateApplication` afterwards is one beat too late and the
  /// floating window visibly drops behind the tile first.
  ///
  /// Contract: `notifyWillFocus` is only called from `@MainActor` code
  /// (`focusWindow`), so the handler may assume main-actor isolation. The
  /// handler returns whether any mirror was actually restored — the caller
  /// then gives the window server a beat to commit before activating.
  func setWillFocusHandler(_ handler: (@Sendable (pid_t) -> Bool)?) {
    willFocusHandler.withLock { $0 = handler }
  }

  /// Returns true when mirrors were restored and need a frame to commit.
  func notifyWillFocus(pid: pid_t) -> Bool {
    willFocusHandler.withLock { $0 }?(pid) ?? false
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
}
