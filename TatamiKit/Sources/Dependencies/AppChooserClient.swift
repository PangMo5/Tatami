import AppKit
import Dependencies
import DependenciesMacros
import UniformTypeIdentifiers

/// Presents an open panel to pick an `.app` bundle from disk, for adding an
/// app that isn't currently running. Wrapped in a dependency so reducers
/// stay testable.
@DependencyClient
struct AppChooserClient: Sendable {
  /// Returns the chosen app, or nil if the panel was cancelled or the
  /// selected bundle has no identifier.
  var choose: @Sendable () async -> MacApp? = { nil }
}

extension AppChooserClient: DependencyKey {
  static let liveValue = AppChooserClient(
    choose: {
      await MainActor.run {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        panel.message = "Choose an application to add."
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleId = bundle.bundleIdentifier
        else { return nil }
        let name = bundle.infoDictionary?["CFBundleDisplayName"] as? String
          ?? bundle.infoDictionary?["CFBundleName"] as? String
          ?? url.deletingPathExtension().lastPathComponent
        return MacApp(bundleIdentifier: bundleId, name: name, iconPath: url.path)
      }
    }
  )

  static let testValue = AppChooserClient(choose: { nil })
  static let previewValue = testValue
}

extension DependencyValues {
  var appChooser: AppChooserClient {
    get { self[AppChooserClient.self] }
    set { self[AppChooserClient.self] = newValue }
  }
}
