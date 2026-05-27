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
  /// Hide the cursor until the user moves the mouse.
  public var hide: @Sendable () -> Void
  /// Force the cursor visible immediately (paired with `hide`).
  public var show: @Sendable () -> Void
}

extension MouseClient: DependencyKey {
  public static let liveValue = MouseClient(
    warp: { point in
      CGWarpMouseCursorPosition(point)
      CGAssociateMouseAndMouseCursorPosition(1)
    },
    hide: {
      // CGDisplayHideCursor must be paired with show; macOS keeps a
      // reference count so don't call hide repeatedly.
      CGDisplayHideCursor(CGMainDisplayID())
    },
    show: {
      CGDisplayShowCursor(CGMainDisplayID())
    }
  )

  public static let testValue = MouseClient(
    warp: { _ in },
    hide: {},
    show: {}
  )

  public static let previewValue = testValue
}

extension DependencyValues {
  public var mouse: MouseClient {
    get { self[MouseClient.self] }
    set { self[MouseClient.self] = newValue }
  }
}
