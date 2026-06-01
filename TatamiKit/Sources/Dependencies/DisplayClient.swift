import AppKit
import Dependencies
import DependenciesMacros
import Foundation

/// Read-only view of the connected macOS displays. Tatami identifies
/// displays by their localized name so reconnecting the same monitor
/// keeps workspace assignments stable across `CGDirectDisplayID` resets.
@DependencyClient
public struct DisplayClient: Sendable {
  public var all: @Sendable () -> [DisplayName] = { [] }
  public var current: @Sendable () -> DisplayName?
  /// Emits the fresh display list whenever the screen configuration changes
  /// (monitor plugged/unplugged, arrangement/resolution change), so UI lists
  /// don't go stale.
  public var changes: @Sendable () -> AsyncStream<[DisplayName]> = { .finished }
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
  public static let liveValue = DisplayClient(
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

  public static let testValue = DisplayClient(
    all: { [DisplayName("Test Display")] },
    current: { DisplayName("Test Display") },
    changes: { .finished }
  )

  public static let previewValue = DisplayClient(
    all: { [DisplayName("Built-in Retina Display"), DisplayName("External Monitor")] },
    current: { DisplayName("Built-in Retina Display") },
    changes: { .finished }
  )
}

extension DependencyValues {
  public var displays: DisplayClient {
    get { self[DisplayClient.self] }
    set { self[DisplayClient.self] = newValue }
  }
}
