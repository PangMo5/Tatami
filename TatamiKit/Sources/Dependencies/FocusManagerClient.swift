import AppKit
import ApplicationServices
import Dependencies
import DependenciesMacros
import Foundation
import OSLog

/// Window focus-cycling that doesn't fit into the BSP tree's
/// directional model (cmd-tab-style cycling across workspace +
/// floating apps). Directional focus is handled by the activation
/// reducer's `bspFocus(_:)` action, which walks the tree itself, so
/// it doesn't live here anymore.
@DependencyClient
struct FocusManagerClient: Sendable {
  /// Raise + focus a specific window (mirror-restore handshake included —
  /// see the free function `focusWindow(pid:windowID:)`).
  var focusWindow: @Sendable (_ key: WindowKey) async -> Void
}

public enum CycleDirection: Sendable, Hashable {
  case next, previous
}

extension FocusManagerClient: DependencyKey {
  static let liveValue: FocusManagerClient = {
    // The free function in WindowKey.swift (mirror-restore handshake) —
    // aliased outside the initializer call, where the `focusWindow:`
    // endpoint would otherwise shadow it. `forceFront: true`: every caller
    // here is a deliberate switch (cycle / directional / activation), which
    // must transfer the frontmost application (focus-follows-mouse calls the
    // free function directly with forceFront false).
    let raiseAndFocus: @MainActor (pid_t, CGWindowID, Bool) -> Void =
      focusWindow(pid:windowID:forceFront:)
    return FocusManagerClient(
      focusWindow: { key in
        await MainActor.run { raiseAndFocus(key.pid, key.windowID, true) }
      }
    )
  }()

  static let testValue = FocusManagerClient(
    focusWindow: { _ in }
  )

  static let previewValue = testValue
}

extension DependencyValues {
  var focusManager: FocusManagerClient {
    get { self[FocusManagerClient.self] }
    set { self[FocusManagerClient.self] = newValue }
  }
}

