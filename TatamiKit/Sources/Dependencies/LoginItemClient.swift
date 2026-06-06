import Dependencies
import DependenciesMacros
import OSLog
import ServiceManagement

/// Registers/unregisters Tatami as a macOS login item via
/// `SMAppService.mainApp`, so it can start automatically at login.
@DependencyClient
public struct LoginItemClient: Sendable {
  /// Register (true) or unregister (false) the app as a login item.
  public var setEnabled: @Sendable (Bool) -> Void
  /// Whether the app is currently registered as a login item.
  public var isEnabled: @Sendable () -> Bool = { false }
}

extension LoginItemClient: DependencyKey {
  public static let liveValue = LoginItemClient(
    setEnabled: { enabled in
      let service = SMAppService.mainApp
      @Dependency(\.errorReporter) var reporter
      do {
        switch (enabled, service.status) {
        case (true, let status) where status != .enabled:
          try service.register()
        case (false, .enabled):
          try service.unregister()
        default:
          break
        }
        reporter.resolve("Login Item")
      } catch {
        logger.error("login item \(enabled ? "register" : "unregister") failed: \(error.localizedDescription, privacy: .public)")
        reporter.report(
          "Login Item",
          "Launch at Login could not be \(enabled ? "enabled" : "disabled")",
          ErrorReportClient.describe(error)
        )
      }
    },
    isEnabled: { SMAppService.mainApp.status == .enabled }
  )
}

extension DependencyValues {
  public var loginItem: LoginItemClient {
    get { self[LoginItemClient.self] }
    set { self[LoginItemClient.self] = newValue }
  }
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "LoginItem")
