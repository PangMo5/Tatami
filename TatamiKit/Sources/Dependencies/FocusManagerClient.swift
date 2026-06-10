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
public struct FocusManagerClient: Sendable {
  public var cycleApp: @Sendable (_ direction: CycleDirection, _ bundleIds: [String]) async -> Void
  /// Raise + focus a specific window (mirror-restore handshake included —
  /// see the free function `focusWindow(pid:windowID:)`).
  public var focusWindow: @Sendable (_ key: WindowKey) async -> Void
}

public enum CycleDirection: Sendable, Hashable {
  case next, previous
}

extension FocusManagerClient: DependencyKey {
  public static let liveValue: FocusManagerClient = {
    // The free function in WindowKey.swift (mirror-restore handshake) —
    // aliased outside the initializer call, where the `focusWindow:`
    // endpoint would otherwise shadow it.
    let raiseAndFocus: @MainActor (pid_t, CGWindowID) -> Void = focusWindow(pid:windowID:)
    return FocusManagerClient(
      cycleApp: { direction, bundleIds in
        await MainActor.run {
          FocusEngine.cycleApp(direction, bundleIds: bundleIds)
        }
      },
      focusWindow: { key in
        await MainActor.run { raiseAndFocus(key.pid, key.windowID) }
      }
    )
  }()

  public static let testValue = FocusManagerClient(
    cycleApp: { _, _ in },
    focusWindow: { _ in }
  )

  public static let previewValue = testValue
}

extension DependencyValues {
  public var focusManager: FocusManagerClient {
    get { self[FocusManagerClient.self] }
    set { self[FocusManagerClient.self] = newValue }
  }
}

private enum FocusEngine {
  @MainActor
  static func cycleApp(_ direction: CycleDirection, bundleIds: [String]) {
    let running = bundleIds.compactMap { bundleId in
      NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleId)
        .first(where: { !$0.isTerminated && $0.activationPolicy == .regular })
    }
    guard !running.isEmpty else { return }
    let frontmost = NSWorkspace.shared.frontmostApplication
    let currentIndex = running.firstIndex { $0 == frontmost } ?? -1
    let count = running.count
    let step = direction == .next ? 1 : -1
    let nextIndex = (currentIndex + step + count) % count
    running[nextIndex].activate(options: [.activateIgnoringOtherApps])
  }
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "FocusManager")
