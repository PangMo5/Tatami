import AppKit
import ApplicationServices
import Dependencies
import DependenciesMacros
import Foundation

/// Cursor side-effects. Wraps `CGWarpMouseCursorPosition` and the
/// hide/show cursor pair so reducers stay testable.
@DependencyClient
struct MouseClient: Sendable {
  /// Move the cursor to a screen coordinate.
  var warp: @Sendable (CGPoint) -> Void
  /// Hide the cursor and bring it back the next time the user moves
  /// the mouse. Used by activation when `mouseHidesOnFocus` is on so
  /// the cursor doesn't get in the way of the focused tile right after
  /// a workspace switch.
  var hideUntilMouseMoves: @MainActor @Sendable () -> Void
  /// Cursor position in AX coordinates (top-left origin, anchored to the
  /// primary screen — the space `ScreenGeometry.workArea` and the BSP
  /// frames use). Call on the main actor.
  var axLocation: @Sendable () -> CGPoint = { .zero }
}

extension MouseClient: DependencyKey {
  static let liveValue: MouseClient = MainActor.assumeIsolated {
    let controller = CursorHidingController()
    return MouseClient(
      warp: { point in
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
      },
      hideUntilMouseMoves: { controller.hideUntilMouseMoves() },
      axLocation: {
        MainActor.assumeIsolated {
          let cocoa = NSEvent.mouseLocation
          // Flip against the primary display (CGMainDisplayID), matching
          // AXWindowGeometry.flip / the BSP frame space — `screens.first` (the
          // origin screen) can differ and skew the flipped y.
          let primaryHeight = DisplayResolver.primaryScreen()?.frame.height ?? cocoa.y
          return CGPoint(x: cocoa.x, y: primaryHeight - cocoa.y)
        }
      }
    )
  }

  static let testValue = MouseClient(
    warp: { _ in },
    hideUntilMouseMoves: {},
    axLocation: { .zero }
  )

  static let previewValue = testValue
}

extension DependencyValues {
  var mouse: MouseClient {
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
