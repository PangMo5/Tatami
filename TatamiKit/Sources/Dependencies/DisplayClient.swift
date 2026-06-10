import AppKit
import Dependencies
import DependenciesMacros
import Foundation

/// Read-only view of the connected macOS displays. Tatami identifies
/// displays by their localized name so reconnecting the same monitor
/// keeps workspace assignments stable across `CGDirectDisplayID` resets.
@DependencyClient
struct DisplayClient: Sendable {
  var all: @Sendable () -> [DisplayName] = { [] }
  var current: @Sendable () -> DisplayName?
  /// AX work area (top-left origin, anchored to the primary screen) of
  /// the named display — the main screen when `nil`.
  var workArea: @Sendable (_ name: DisplayName?) -> CGRect = { _ in .zero }
  /// The *connected* screen matching `name` (UUID first, then name), if any.
  var connected: @Sendable (_ name: DisplayName) -> DisplayName?
  /// The primary display.
  var primary: @Sendable () -> DisplayName?
  /// `name` resolved to a connected screen, falling back to the primary —
  /// where a workspace pinned to `name` actually tiles.
  var resolveOrPrimary: @Sendable (_ name: DisplayName) -> DisplayName?
  /// Emits the fresh display list whenever the screen configuration changes
  /// (monitor plugged/unplugged, arrangement/resolution change), so UI lists
  /// don't go stale.
  var changes: @Sendable () -> AsyncStream<[DisplayName]> = { .finished }
}

/// Holds the screen-change observer so it can be removed from the stream's
/// `@Sendable` termination handler. Only touched on the notification queue.
private final class ScreenObserver: @unchecked Sendable {
  var token: (any NSObjectProtocol)?
  func remove() {
    if let token { NotificationCenter.default.removeObserver(token) }
  }
}

private func currentDisplayNames() -> [DisplayName] {
  NSScreen.screens.compactMap(\.displayName)
}

extension DisplayClient: DependencyKey {
  static let liveValue = DisplayClient(
    all: { MainActor.assumeIsolated { currentDisplayNames() } },
    current: {
      MainActor.assumeIsolated {
        // The display under the cursor — more reliable than `NSScreen.main`
        // (key-window screen) for "where is the user acting right now",
        // especially with focus-follows-mouse. Falls back to the primary.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
          ?? DisplayResolver.primaryScreen()
        return screen?.displayName
      }
    },
    workArea: { name in
      MainActor.assumeIsolated { ScreenGeometry.workArea(for: name) }
    },
    connected: { name in
      MainActor.assumeIsolated { DisplayResolver.connectedScreen(for: name)?.displayName }
    },
    primary: {
      MainActor.assumeIsolated { DisplayResolver.primaryScreen()?.displayName }
    },
    resolveOrPrimary: { name in
      MainActor.assumeIsolated { DisplayResolver.screenOrPrimary(for: name)?.displayName }
    },
    changes: {
      AsyncStream { continuation in
        let observer = ScreenObserver()
        observer.token = NotificationCenter.default.addObserver(
          forName: NSApplication.didChangeScreenParametersNotification,
          object: nil,
          queue: .main
        ) { _ in continuation.yield(currentDisplayNames()) }
        continuation.onTermination = { _ in observer.remove() }
      }
    }
  )

  static let testValue = DisplayClient(
    all: { [DisplayName("Test Display")] },
    current: { DisplayName("Test Display") },
    workArea: { _ in CGRect(x: 0, y: 0, width: 1920, height: 1080) },
    connected: { $0 },
    primary: { DisplayName("Test Display") },
    resolveOrPrimary: { $0 },
    changes: { .finished }
  )

  static let previewValue = DisplayClient(
    all: { [DisplayName("Built-in Retina Display"), DisplayName("External Monitor")] },
    current: { DisplayName("Built-in Retina Display") },
    workArea: { _ in CGRect(x: 0, y: 0, width: 1920, height: 1080) },
    connected: { $0 },
    primary: { DisplayName("Built-in Retina Display") },
    resolveOrPrimary: { $0 },
    changes: { .finished }
  )
}

extension DependencyValues {
  var displays: DisplayClient {
    get { self[DisplayClient.self] }
    set { self[DisplayClient.self] = newValue }
  }
}
