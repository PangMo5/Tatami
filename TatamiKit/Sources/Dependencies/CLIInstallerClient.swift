import AppKit
import Dependencies
import DependenciesMacros
import Foundation

/// Where the bundled `tatami` CLI lives and whether it's linked onto `PATH`.
public struct CLIStatus: Equatable, Sendable {
  /// A `PATH` symlink (or Homebrew install) exists.
  public var isInstalled: Bool
  /// Installed via Homebrew (so the in-app install/uninstall is a no-op).
  public var viaHomebrew: Bool
  /// The CLI binary is present in the app bundle (the build embedded it).
  public var isBundled: Bool
  public var symlinkPath: String
  public var homebrewPath: String

  init(
    isInstalled: Bool = false,
    viaHomebrew: Bool = false,
    isBundled: Bool = false,
    symlinkPath: String = "/usr/local/bin/tatami",
    homebrewPath: String = "/opt/homebrew/bin/tatami"
  ) {
    self.isInstalled = isInstalled
    self.viaHomebrew = viaHomebrew
    self.isBundled = isBundled
    self.symlinkPath = symlinkPath
    self.homebrewPath = homebrewPath
  }
}

/// Manages the bundled `tatami` CLI: the binary ships inside the app bundle
/// (copied into `Contents/Resources` by a build phase); installing creates a
/// `PATH` symlink so it can be scripted from the terminal.
@DependencyClient
struct CLIInstallerClient: Sendable {
  var status: @Sendable () -> CLIStatus = { CLIStatus() }
  /// Symlink the bundled CLI onto `PATH` (prompts for admin rights).
  var install: @Sendable () async -> Void
  /// Remove the `PATH` symlink (prompts for admin rights).
  var uninstall: @Sendable () async -> Void
}

extension CLIInstallerClient: DependencyKey {
  static let liveValue: CLIInstallerClient = {
    // Captured as plain `let` strings (Sendable) so the closures below stay
    // `@Sendable`; the filesystem checks are cheap, so inline them per call.
    let bundledPath = Bundle.main.bundlePath + "/Contents/Resources/tatami"
    let symlinkPath = "/usr/local/bin/tatami"
    let homebrewPath = "/opt/homebrew/bin/tatami"

    return CLIInstallerClient(
      status: {
        let fm = FileManager.default
        let viaHomebrew = fm.fileExists(atPath: homebrewPath)
        return CLIStatus(
          isInstalled: fm.fileExists(atPath: symlinkPath) || viaHomebrew,
          viaHomebrew: viaHomebrew,
          isBundled: fm.isExecutableFile(atPath: bundledPath),
          symlinkPath: symlinkPath,
          homebrewPath: homebrewPath
        )
      },
      install: {
        let fm = FileManager.default
        guard !(fm.fileExists(atPath: symlinkPath) || fm.fileExists(atPath: homebrewPath))
        else { return }
        await runAdminScript("mkdir -p /usr/local/bin && ln -sf '\(bundledPath)' '\(symlinkPath)'")
      },
      uninstall: {
        guard FileManager.default.fileExists(atPath: symlinkPath) else { return }
        await runAdminScript("rm -f '\(symlinkPath)'")
      }
    )
  }()

  static let testValue = CLIInstallerClient(
    status: { CLIStatus() },
    install: {},
    uninstall: {}
  )
  static let previewValue = testValue
}

extension DependencyValues {
  var cliInstaller: CLIInstallerClient {
    get { self[CLIInstallerClient.self] }
    set { self[CLIInstallerClient.self] = newValue }
  }
}

/// Run a shell command as administrator via AppleScript (surfaces the macOS
/// auth prompt). `with administrator privileges` already elevates to root.
@discardableResult
private func runAdminScript(_ command: String) async -> Bool {
  await MainActor.run {
    let source = "do shell script \"\(command)\" with administrator privileges"
    guard let script = NSAppleScript(source: source) else { return false }
    var error: NSDictionary?
    script.executeAndReturnError(&error)
    return error == nil
  }
}
