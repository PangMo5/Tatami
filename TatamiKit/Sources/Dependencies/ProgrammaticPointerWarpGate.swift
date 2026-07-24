import CoreGraphics
import Darwin
import Foundation

/// Separates real pointer movement from the mouse events caused by Tatami's
/// own MFF cursor warps.
///
/// A warp establishes a new generation. Mouse moves captured before that
/// generation, plus the synthetic move that lands at the warp destination,
/// must not feed back into FFM. The first later move away from the destination
/// is real user input and disarms the spatial gate immediately.
final class ProgrammaticPointerWarpGate: @unchecked Sendable {

  // MARK: Lifecycle

  init() { }

  // MARK: Internal

  struct Evaluation: Equatable, Sendable {
    var generation: UInt64
    var allowsFocus: Bool
  }

  static let shared = ProgrammaticPointerWarpGate()

  func recordWarp(to destination: CGPoint, timestamp: CGEventTimestamp = mach_absolute_time()) {
    lock.lock()
    defer { lock.unlock() }

    generation &+= 1
    pendingWarp = PendingWarp(
      timestamp: timestamp,
      destination: destination,
    )
  }

  func evaluateMouseMove(
    at location: CGPoint,
    timestamp: CGEventTimestamp,
  ) -> Evaluation {
    lock.lock()
    defer { lock.unlock() }

    guard let pendingWarp else {
      return Evaluation(generation: generation, allowsFocus: true)
    }

    // The event tap can deliver a move that was captured before the main
    // actor performed an MFF warp. Never let that stale target regain focus.
    guard timestamp > pendingWarp.timestamp else {
      return Evaluation(generation: generation, allowsFocus: false)
    }

    // CGWarpMouseCursorPosition produces a mouseMoved event at (or within a
    // rounding point of) its destination. It confirms the programmatic move;
    // it is not an FFM intent.
    let dx = location.x - pendingWarp.destination.x
    let dy = location.y - pendingWarp.destination.y
    guard (dx * dx) + (dy * dy) > Self.destinationToleranceSquared else {
      return Evaluation(generation: generation, allowsFocus: false)
    }

    // A newer event away from the destination can only be physical pointer
    // movement. Disarm without a timer so FFM responds on this very event.
    self.pendingWarp = nil
    return Evaluation(generation: generation, allowsFocus: true)
  }

  func isCurrent(generation expectedGeneration: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return generation == expectedGeneration
  }

  // MARK: Private

  private struct PendingWarp {
    var timestamp: CGEventTimestamp
    var destination: CGPoint
  }

  private static let destinationToleranceSquared: CGFloat = 4

  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var pendingWarp: PendingWarp?

}
