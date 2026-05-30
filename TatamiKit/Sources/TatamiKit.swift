import Foundation

/// TatamiKit umbrella — re-exports the feature surface so the App target imports
/// only TatamiKit.
public enum TatamiKit {
  /// Marketing version, read from the host app bundle's Info.plist
  /// (`CFBundleShortVersionString`, injected from `MARKETING_VERSION`).
  /// TatamiKit links statically into the app, so `Bundle.main` is the app.
  public static let version: String =
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
}
