import Dependencies
import DependenciesMacros
import OSLog
import ServiceManagement

/// Registers/unregisters Tatami as a macOS login item via
/// `SMAppService.mainApp`, so it can start automatically at login.
@DependencyClient
struct LoginItemClient: Sendable {
  /// Register (true) or unregister (false) the app as a login item.
  var setEnabled: @Sendable (Bool) -> Void
}

extension LoginItemClient: DependencyKey {
  static let liveValue = LoginItemClient(
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
    }
  )

  /// Tests must not touch the real `SMAppService` registration.
  static let testValue = LoginItemClient(
    setEnabled: { _ in }
  )
  static let previewValue = testValue
}

extension DependencyValues {
  var loginItem: LoginItemClient {
    get { self[LoginItemClient.self] }
    set { self[LoginItemClient.self] = newValue }
  }
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "LoginItem")
