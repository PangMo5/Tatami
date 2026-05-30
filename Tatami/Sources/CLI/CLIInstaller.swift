import Foundation

/// Manages the bundled `tatami` CLI. The binary ships inside the app bundle
/// (copied into `Contents/Resources` by a build phase); installing creates a
/// symlink on `PATH` so it can be scripted from the terminal. Mirrors
/// FlashSpace's one-click approach.
enum CLIInstaller {
  /// The CLI binary embedded in the app bundle.
  static var bundledPath: String {
    Bundle.main.bundlePath + "/Contents/Resources/tatami"
  }

  /// User-facing symlink created on install. `/usr/local/bin` is on the
  /// default `PATH` but writing there needs administrator rights.
  static var symlinkPath: String { "/usr/local/bin/tatami" }

  /// Where a Homebrew-installed `tatami` would live (Apple Silicon prefix).
  static var homebrewPath: String { "/opt/homebrew/bin/tatami" }

  static var isInstalledViaHomebrew: Bool {
    FileManager.default.fileExists(atPath: homebrewPath)
  }

  static var isInstalled: Bool {
    FileManager.default.fileExists(atPath: symlinkPath) || isInstalledViaHomebrew
  }

  /// The CLI binary is present in the bundle (i.e. the build embedded it).
  static var isBundled: Bool {
    FileManager.default.isExecutableFile(atPath: bundledPath)
  }

  /// Create the `PATH` symlink, prompting for admin rights. Returns `false`
  /// on failure or if the user cancels the auth prompt.
  @discardableResult
  static func install() -> Bool {
    guard !isInstalled else { return true }
    return runAdminScript(
      "mkdir -p /usr/local/bin && ln -sf '\(bundledPath)' '\(symlinkPath)'"
    )
  }

  /// Remove the `PATH` symlink (no-op for Homebrew installs).
  @discardableResult
  static func uninstall() -> Bool {
    guard FileManager.default.fileExists(atPath: symlinkPath) else { return true }
    return runAdminScript("rm -f '\(symlinkPath)'")
  }

  /// Run a shell command as administrator via AppleScript, surfacing the
  /// macOS auth prompt. `with administrator privileges` already elevates to
  /// root, so no `sudo` is needed. Returns `false` on error or cancellation.
  private static func runAdminScript(_ command: String) -> Bool {
    let source = "do shell script \"\(command)\" with administrator privileges"
    guard let script = NSAppleScript(source: source) else { return false }
    var error: NSDictionary?
    script.executeAndReturnError(&error)
    return error == nil
  }
}
