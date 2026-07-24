import CoreGraphics
import Dependencies
import DependenciesMacros
import os

// MARK: - FocusEventOriginClient

/// Bridges the intent that initiated a focus change to the later AX focus
/// notification. AX itself does not report whether focus came from a pointer
/// hover, keyboard command, or click.
@DependencyClient
struct FocusEventOriginClient: Sendable {
  var recordPointerDrivenFocus: @Sendable (CGWindowID) -> Void
  var consumePointerDrivenFocus: @Sendable (CGWindowID?) -> Bool = { _ in false }
}

// MARK: DependencyKey

extension FocusEventOriginClient: DependencyKey {
  static let liveValue: FocusEventOriginClient = {
    let pending = PointerDrivenFocusQueue()
    return FocusEventOriginClient(
      recordPointerDrivenFocus: { pending.record($0) },
      consumePointerDrivenFocus: { pending.consume($0) },
    )
  }()

  static let testValue = FocusEventOriginClient(
    recordPointerDrivenFocus: { _ in },
    consumePointerDrivenFocus: { _ in false },
  )

  static let previewValue = testValue
}

extension DependencyValues {
  var focusEventOrigin: FocusEventOriginClient {
    get { self[FocusEventOriginClient.self] }
    set { self[FocusEventOriginClient.self] = newValue }
  }
}

// MARK: - PointerDrivenFocusQueue

/// The event-tap callback and AX observer arrive on different executors, while
/// both APIs are synchronous. Only this small pending-ID queue is locked; no AX
/// or focus work happens while the lock is held.
final class PointerDrivenFocusQueue: Sendable {

  // MARK: Internal

  func record(_ windowID: CGWindowID) {
    pending.withLock { ids in
      ids.removeAll { $0 == windowID }
      ids.append(windowID)
      if ids.count > Self.capacity {
        ids.removeFirst(ids.count - Self.capacity)
      }
    }
  }

  func consume(_ windowID: CGWindowID?) -> Bool {
    guard let windowID else { return false }
    return pending.withLock { ids in
      guard let index = ids.firstIndex(of: windowID) else { return false }
      ids.remove(at: index)
      return true
    }
  }

  // MARK: Private

  private static let capacity = 16

  private let pending = OSAllocatedUnfairLock<[CGWindowID]>(initialState: [])

}
