// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Dependencies
import DependenciesMacros
import Foundation

// MARK: - CLIStatus

/// Where the bundled `tatami` CLI lives and whether it's linked onto `PATH`.
public struct CLIStatus: Equatable, Sendable {

  // MARK: Lifecycle

  init(
    isInstalled: Bool = false,
    viaHomebrew: Bool = false,
    isBundled: Bool = false,
    symlinkPath: String = "/usr/local/bin/tatami",
    homebrewPath: String = "/opt/homebrew/bin/tatami",
  ) {
    self.isInstalled = isInstalled
    self.viaHomebrew = viaHomebrew
    self.isBundled = isBundled
    self.symlinkPath = symlinkPath
    self.homebrewPath = homebrewPath
  }

  // MARK: Public

  /// A `PATH` symlink (or Homebrew install) exists.
  public var isInstalled: Bool
  /// Installed via Homebrew (so the in-app install/uninstall is a no-op).
  public var viaHomebrew: Bool
  /// The CLI binary is present in the app bundle (the build embedded it).
  public var isBundled: Bool
  public var symlinkPath: String
  public var homebrewPath: String

}

// MARK: - CLIInstallerClient

/// Manages the bundled `tatami` CLI: the binary ships inside the app bundle
/// (copied into `Contents/Resources` by a build phase); installing creates a
/// `PATH` symlink so it can be scripted from the terminal.
@DependencyClient
struct CLIInstallerClient: Sendable {
  var status: @Sendable () async -> CLIStatus = { CLIStatus() }
  /// Symlink the bundled CLI onto `PATH` (prompts for admin rights).
  var install: @Sendable () async -> Void
  /// Remove the `PATH` symlink (prompts for admin rights).
  var uninstall: @Sendable () async -> Void
}

// MARK: DependencyKey

extension CLIInstallerClient: DependencyKey {
  static let liveValue: CLIInstallerClient = {
    let worker = BlockingWorkQueue(label: "dev.PangMo5.Tatami.cli-installer")
    let bundledPath = Bundle.main.bundlePath + "/Contents/Resources/tatami"
    let symlinkPath = "/usr/local/bin/tatami"
    let homebrewPath = "/opt/homebrew/bin/tatami"

    return CLIInstallerClient(
      status: {
        await worker.run {
          let fm = FileManager.default
          let viaHomebrew = fm.fileExists(atPath: homebrewPath)
          return CLIStatus(
            isInstalled: fm.fileExists(atPath: symlinkPath) || viaHomebrew,
            viaHomebrew: viaHomebrew,
            isBundled: fm.isExecutableFile(atPath: bundledPath),
            symlinkPath: symlinkPath,
            homebrewPath: homebrewPath,
          )
        }
      },
      install: {
        await worker.run {
          let fm = FileManager.default
          guard !(fm.fileExists(atPath: symlinkPath) || fm.fileExists(atPath: homebrewPath))
          else { return }
          runAdminScript("mkdir -p /usr/local/bin && ln -sf \(shellQuoted(bundledPath)) \(shellQuoted(symlinkPath))")
        }
      },
      uninstall: {
        await worker.run {
          guard FileManager.default.fileExists(atPath: symlinkPath) else { return }
          runAdminScript("rm -f \(shellQuoted(symlinkPath))")
        }
      },
    )
  }()

  static let testValue = CLIInstallerClient(
    status: { CLIStatus() },
    install: { },
    uninstall: { },
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
private func shellQuoted(_ value: String) -> String {
  "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

private func runAdminScript(_ command: String) {
  let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
  process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
  let errors = Pipe()
  process.standardError = errors
  process.standardOutput = FileHandle.nullDevice
  @Dependency(\.errorReporter) var reporter
  do {
    try process.run()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let detail = String(decoding: errorData, as: UTF8.self)
      // User cancellation is an intentional refusal of the system prompt.
      if !detail.contains("(-128)") {
        reporter.report("CLIInstall", String(localized: "The CLI installation could not be changed"), detail)
      }
      return
    }
    reporter.resolve("CLIInstall")
  } catch {
    reporter.report(
      "CLIInstall",
      String(localized: "The CLI installation could not be changed"),
      ErrorReportClient.describe(error),
    )
  }
}
