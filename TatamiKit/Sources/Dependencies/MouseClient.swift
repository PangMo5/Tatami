import AppKit
import ApplicationServices
import Dependencies
import DependenciesMacros
import Foundation

/// Cursor side-effects. Wraps `CGWarpMouseCursorPosition` and the
/// hide/show cursor pair so reducers stay testable.
@DependencyClient
public struct MouseClient: Sendable {
  /// Move the cursor to a screen coordinate.
  public var warp: @Sendable (CGPoint) -> Void
  /// Hide the cursor immediately (reference-counted at the OS level —
  /// each call must be paired with `show`).
  public var hide: @Sendable () -> Void
  /// Force the cursor visible immediately.
  public var show: @Sendable () -> Void
  /// Hide the cursor and bring it back the next time the user moves
  /// the mouse. Used by activation when `mouseHidesOnFocus` is on so
  /// the cursor doesn't get in the way of the focused tile right after
  /// a workspace switch.
  public var hideUntilMouseMoves: @Sendable () -> Void
}

extension MouseClient: DependencyKey {
  public static let liveValue: MouseClient = MainActor.assumeIsolated {
    let controller = CursorHidingController()
    return MouseClient(
      warp: { point in
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
      },
      hide: {
        CGDisplayHideCursor(CGMainDisplayID())
      },
      show: {
        CGDisplayShowCursor(CGMainDisplayID())
      },
      hideUntilMouseMoves: {
        Task { @MainActor in controller.hideUntilMouseMoves() }
      }
    )
  }

  public static let testValue = MouseClient(
    warp: { _ in },
    hide: {},
    show: {},
    hideUntilMouseMoves: {}
  )

  public static let previewValue = testValue
}

extension DependencyValues {
  public var mouse: MouseClient {
    get { self[MouseClient.self] }
    set { self[MouseClient.self] = newValue }
  }
}

/// Hides the cursor on demand; the first global mouse-moved event
/// brings it back. The controller is owned by the `MouseClient` live
/// instance — there's no `.shared` singleton. Reference-counts hides
/// so back-to-back activations don't double-hide.
@MainActor
private final class CursorHidingController {
  private var monitor: Any?
  private var isHidden = false

  func hideUntilMouseMoves() {
    if !isHidden {
      CGDisplayHideCursor(CGMainDisplayID())
      isHidden = true
    }
    guard monitor == nil else { return }
    monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
      Task { @MainActor in self?.show() }
    }
  }

  func show() {
    if isHidden {
      CGDisplayShowCursor(CGMainDisplayID())
      isHidden = false
    }
    if let m = monitor {
      NSEvent.removeMonitor(m)
      monitor = nil
    }
  }
}
