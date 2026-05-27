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
}

extension DisplayClient: DependencyKey {
  public static let liveValue = DisplayClient(
    all: {
      MainActor.assumeIsolated {
        NSScreen.screens.compactMap { screen in
          screen.localizedName.isEmpty ? nil : DisplayName(screen.localizedName)
        }
      }
    },
    current: {
      MainActor.assumeIsolated {
        guard let name = NSScreen.main?.localizedName, !name.isEmpty else { return nil }
        return DisplayName(name)
      }
    }
  )

  public static let testValue = DisplayClient(
    all: { [DisplayName("Test Display")] },
    current: { DisplayName("Test Display") }
  )

  public static let previewValue = DisplayClient(
    all: { [DisplayName("Built-in Retina Display"), DisplayName("External Monitor")] },
    current: { DisplayName("Built-in Retina Display") }
  )
}

extension DependencyValues {
  public var displays: DisplayClient {
    get { self[DisplayClient.self] }
    set { self[DisplayClient.self] = newValue }
  }
}
