import AppKit
import Dependencies
import Foundation

/// Snapshot of the macOS apps currently runnable by the user. Wrapping
/// `NSWorkspace.shared.runningApplications` behind a `@Dependency` lets
/// reducers stay testable.
public struct RunningAppsClient: Sendable {
  public var current: @Sendable () -> [MacApp]

  public init(current: @escaping @Sendable () -> [MacApp]) {
    self.current = current
  }
}

extension RunningAppsClient: DependencyKey {
  public static let liveValue = RunningAppsClient(
    current: {
      NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular }
        .compactMap { app -> MacApp? in
          guard let bundleId = app.bundleIdentifier, !bundleId.isEmpty else {
            return nil
          }
          return MacApp(
            bundleIdentifier: bundleId,
            name: app.localizedName ?? bundleId,
            iconPath: app.bundleURL?.path
          )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
  )

  public static let testValue = RunningAppsClient(current: { [] })
  public static let previewValue = RunningAppsClient(
    current: {
      [
        MacApp(bundleIdentifier: "com.apple.Safari", name: "Safari"),
        MacApp(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode"),
        MacApp(bundleIdentifier: "com.apple.Terminal", name: "Terminal"),
      ]
    }
  )
}

extension DependencyValues {
  public var runningApps: RunningAppsClient {
    get { self[RunningAppsClient.self] }
    set { self[RunningAppsClient.self] = newValue }
  }
}
