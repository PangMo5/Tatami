// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - TatamiInstall

/// A located Tatami installation. The Demo Lab drives the **real** app — none
/// of its window, workspace, profile, Borrow, or tiling behavior is simulated
/// here — so everything below is about finding that app and talking to its
/// published interfaces.
public struct TatamiInstall: Sendable {

  // MARK: Lifecycle

  public init(bundle: URL, bundleIdentifier: String, version: String?) {
    self.bundle = bundle
    self.bundleIdentifier = bundleIdentifier
    self.version = version
  }

  // MARK: Public

  /// `dev.PangMo5.Tatami` or `dev.PangMo5.Tatami.debug`. Tatami's own
  /// `MacApp.isTatami` uses exactly this test, and the lab's demo apps live
  /// under `dev.PangMo5.DemoLab.` specifically so they can never match it.
  public static func isTatami(_ bundleIdentifier: String) -> Bool {
    bundleIdentifier == "dev.PangMo5.Tatami" || bundleIdentifier.hasPrefix("dev.PangMo5.Tatami.")
  }

  public static func locate(explicit: String? = nil) throws -> TatamiInstall {
    var candidates = [URL]()
    if let explicit { candidates.append(URL(fileURLWithPath: explicit)) }
    if let fromEnvironment = ProcessInfo.processInfo.environment["DEMOLAB_TATAMI_APP"],
       !fromEnvironment.isEmpty {
      candidates.append(URL(fileURLWithPath: fromEnvironment))
    }
    candidates.append(URL(fileURLWithPath: "/Applications/Tatami.app"))
    candidates.append(
      URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/Tatami.app")
    )
    // The repository's local Debug build, so the lab works on a dev machine
    // before a release is installed.
    if let root = LabPaths.discoverPackageRoot() {
      let repository = root.deletingLastPathComponent()
      candidates.append(
        repository.appendingPathComponent("DerivedData/Build/Products/Debug/Tatami.app")
      )
      candidates.append(
        repository.appendingPathComponent("DerivedData/Build/Products/Release/Tatami.app")
      )
    }

    for candidate in candidates {
      guard FileManager.default.fileExists(atPath: candidate.path),
            let bundle = Bundle(url: candidate),
            let identifier = bundle.bundleIdentifier,
            isTatami(identifier)
      else { continue }
      let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      return TatamiInstall(bundle: candidate, bundleIdentifier: identifier, version: version)
    }

    throw DemoCtlError.tatamiNotFound(candidates.map(\.path))
  }

  public let bundle: URL
  public let bundleIdentifier: String
  public let version: String?

  /// Tatami embeds its CLI in the app bundle; using this copy rather than
  /// `/usr/local/bin/tatami` guarantees the CLI and the running app are the
  /// same build, which matters because a newer CLI refuses plain output from an
  /// older app when `--json` was requested.
  public var cli: URL { bundle.appendingPathComponent("Contents/Resources/tatami") }

  public var executable: URL {
    bundle.appendingPathComponent("Contents/MacOS")
      .appendingPathComponent(bundle.deletingPathExtension().lastPathComponent)
  }

  public func validate() throws {
    guard FileManager.default.isExecutableFile(atPath: cli.path) else {
      throw DemoCtlError.tatamiCLIMissing(cli.path)
    }
  }

}

// MARK: - TatamiProcess

/// Starts and stops the Tatami process the lab owns.
@MainActor
public enum TatamiProcess {

  // MARK: Public

  public static func running() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter {
      guard let identifier = $0.bundleIdentifier else { return false }
      return TatamiInstall.isTatami(identifier) && Shell.processExists($0.processIdentifier)
    }
  }

  /// Quits every running Tatami, not only one the lab started.
  ///
  /// Two Tatami processes would both tile the same windows, so a demo run
  /// cannot share the machine with another instance. This is deliberately
  /// visible in `democtl`'s output rather than silent: on a developer's own
  /// Mac it stops the app they were using. It never touches that app's
  /// configuration, which lives in a separate config home.
  @discardableResult
  public static func quitAll(timeout: Duration = .seconds(10)) -> [String] {
    let victims = running()
    guard !victims.isEmpty else { return [] }
    let names = victims.map { $0.bundleIdentifier ?? "Tatami" }
    for application in victims { application.terminate() }
    let stopped = Shell.wait(timeout: timeout) { running().isEmpty }
    if !stopped {
      for application in running() { application.forceTerminate() }
      _ = Shell.wait(timeout: .seconds(5)) { running().isEmpty }
    }
    return names
  }

  /// Closes Tatami's own window if it opened at launch.
  ///
  /// `Window("Tatami", id: "main")` is the first scene in Tatami's `body`, and
  /// on macOS 14 the first window scene opens automatically. There is no
  /// `defaultLaunchBehavior(.suppressed)` before macOS 15, and neither
  /// `ApplePersistenceIgnoreState` nor wiping the preferences domain suppresses
  /// it, because it is not restoration at all. So a seeded lab would start every
  /// take with Tatami's Settings window sitting in the middle of the shot.
  ///
  /// This presses the window's close button through Accessibility, which is the
  /// same thing as clicking the red dot. It reads no Tatami state and changes
  /// none: the scene that actually wants that window opens it again with the
  /// published Command-comma shortcut.
  ///
  /// - Returns: how many windows were closed.
  @discardableResult
  public static func closeOwnWindows(timeout: Duration = .seconds(6)) -> Int {
    guard AXIsProcessTrusted() else { return -1 }
    var closed = 0
    _ = Shell.wait(timeout: timeout, poll: .milliseconds(250)) {
      var sawWindow = false
      for application in running() {
        let element = AXUIElementCreateApplication(application.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { continue }
        for window in windows {
          sawWindow = true
          var button: CFTypeRef?
          guard AXUIElementCopyAttributeValue(
            window,
            kAXCloseButtonAttribute as CFString,
            &button
          ) == .success, let raw = button, CFGetTypeID(raw) == AXUIElementGetTypeID() else { continue }
          let closeButton = unsafeDowncast(raw, to: AXUIElement.self)
          if AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success {
            closed += 1
          }
        }
      }
      // Stop as soon as a pass finds nothing left to close. The window can take
      // a moment to exist at all, which is why this polls rather than looking once.
      return !sawWindow && closed > 0
    }
    return closed
  }

  /// How the Tatami process is started.
  ///
  /// The same correctness question as the recorder's ``RecorderController/LaunchPath``,
  /// with the same answer for the same reason. macOS attributes a Screen
  /// Recording grant to the *responsible* process, and Tatami needs one for
  /// **Always on Top**, whose windows are ScreenCaptureKit mirrors.
  ///
  /// - On a desktop, `democtl` runs from a terminal that holds no such grant,
  ///   so Tatami has to become its own responsible process. That means
  ///   LaunchServices, and it is the only path a person can grant.
  /// - In a VM driven by `tart exec`, the parent already holds the grant and a
  ///   direct child inherits it. This is not a nicety: a hand-written TCC row
  ///   for Tatami was measured being ignored by macOS 26's tccd even with SIP
  ///   off, so inheritance is the only way Always on Top works in a guest.
  ///   Without it Tatami raises a standing Problem and puts a warning triangle
  ///   in the menu bar, in shot, for the whole take.
  public enum LaunchPath: Sendable {
    case auto
    case viaLaunchServices
    case direct
  }

  /// Launches Tatami with the lab's isolation flags.
  public static func launch(
    install: TatamiInstall,
    paths: LabPaths,
    launchPath: LaunchPath = .auto
  ) throws {
    let arguments = [
      "--tatami-config-home", paths.configHome.path,
      "--tatami-socket-path", paths.socketPath.path,
    ]
    let resolved: LaunchPath = {
      switch launchPath {
      case .auto: CGPreflightScreenCaptureAccess() ? .direct : .viaLaunchServices
      case let explicit: explicit
      }
    }()

    switch resolved {
    case .direct, .auto:
      // Detached: Tatami outlives `democtl`, and a child holding the caller's
      // stdout keeps a shell pipeline open forever after `democtl` has exited.
      try Shell.launchDetached(
        install.executable,
        arguments,
        log: paths.runRoot.appendingPathComponent("tatami-stdout.log")
      )

    case .viaLaunchServices:
      try Shell.require(
        URL(fileURLWithPath: "/usr/bin/open"),
        ["-n", "-a", install.bundle.path, "--args"] + arguments
      )
    }
  }

}

// MARK: - TatamiClient

/// A thin, faithful wrapper over the `tatami` CLI.
///
/// It only ever runs commands that exist. The command surface was read out of
/// `TatamiCLI.swift` rather than remembered, and two of its rules shape every
/// call site here:
///
/// - `--json` is a *leaf* option. `tatami --json workspace list` is a parse
///   error; `tatami workspace list --json` is correct.
/// - Only `profile activate` and `workspace activate` report `"completed"`.
///   Every other dispatcher route replies `"accepted"` the moment the command
///   is enqueued, which says nothing about whether a window moved. Scene
///   barriers therefore use activation replies or hook events, never exit codes.
public struct TatamiClient: Sendable {

  // MARK: Lifecycle

  public init(install: TatamiInstall, paths: LabPaths) {
    self.install = install
    self.paths = paths
  }

  // MARK: Public

  public let install: TatamiInstall
  public let paths: LabPaths

  public var isRunning: Bool {
    (try? runRaw(["version", "--json"]))?.succeeded ?? false
  }

  /// Runs a leaf command with `--json` appended and returns the decoded value.
  @discardableResult
  public func json(_ arguments: [String]) throws -> Any {
    let result = try runRaw(arguments + ["--json"])
    guard result.succeeded else {
      throw DemoCtlError.tatamiCommandFailed(
        command: arguments.joined(separator: " "),
        message: Self.errorMessage(from: result)
      )
    }
    let text = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = text.data(using: .utf8), !data.isEmpty,
          let value = try? JSONSerialization.jsonObject(with: data)
    else {
      throw DemoCtlError.tatamiCommandFailed(
        command: arguments.joined(separator: " "),
        message: "expected JSON on stdout, got: \(text)"
      )
    }
    return value
  }

  /// Activates a workspace and waits for the activation pipeline to finish.
  /// This is the only synchronous confirmation Tatami offers that a switch
  /// actually landed, so scenes lean on it wherever they can.
  public func activateWorkspace(_ name: String, profile: String? = nil) throws {
    var arguments = ["workspace", "activate", name]
    if let profile { arguments += ["--profile", profile] }
    let value = try json(arguments)
    try expect(status: "completed", in: value, command: arguments.joined(separator: " "))
  }

  public func activateProfile(_ name: String) throws {
    let arguments = ["profile", "activate", name]
    let value = try json(arguments)
    try expect(status: "completed", in: value, command: arguments.joined(separator: " "))
  }

  /// Dispatcher routes that only ever report `accepted`.
  public func dispatch(_ arguments: [String]) throws {
    let value = try json(arguments)
    try expect(status: "accepted", in: value, command: arguments.joined(separator: " "))
  }

  public func workspaceNames(profile: String? = nil) throws -> [String] {
    var arguments = ["workspace", "list"]
    if let profile { arguments += ["--profile", profile] }
    guard let rows = try json(arguments) as? [[String: Any]] else { return [] }
    return rows.compactMap { $0["name"] as? String }
  }

  public func workspaces(profile: String? = nil) throws -> [[String: Any]] {
    var arguments = ["workspace", "list"]
    if let profile { arguments += ["--profile", profile] }
    return (try json(arguments) as? [[String: Any]]) ?? []
  }

  public func profiles() throws -> [[String: Any]] {
    (try json(["profile", "list"]) as? [[String: Any]]) ?? []
  }

  public func activeProfileName() throws -> String? {
    try profiles().first { ($0["isActive"] as? Bool) == true }?["name"] as? String
  }

  public func hooks() throws -> [[String: Any]] {
    (try json(["hook", "list"]) as? [[String: Any]]) ?? []
  }

  public func runningVersion() throws -> String? {
    (try json(["version"]) as? [String: Any])?["version"] as? String
  }

  // MARK: Private

  private static func errorMessage(from result: CommandResult) -> String {
    let stderr = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
    if let data = stderr.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let message = object["error"] as? String {
      return message
    }
    return stderr.isEmpty ? result.standardOutput : stderr
  }

  private func runRaw(_ arguments: [String]) throws -> CommandResult {
    try Shell.run(
      install.cli,
      arguments,
      environment: ["TATAMI_SOCKET_PATH": paths.socketPath.path]
    )
  }

  private func expect(status: String, in value: Any, command: String) throws {
    guard let object = value as? [String: Any] else {
      throw DemoCtlError.tatamiCommandFailed(command: command, message: "unexpected JSON shape")
    }
    guard let actual = object["status"] as? String else {
      throw DemoCtlError.tatamiCommandFailed(command: command, message: "reply carried no status")
    }
    guard actual == status else {
      throw DemoCtlError.tatamiCommandFailed(
        command: command,
        message: "expected status \(status), got \(actual)"
      )
    }
  }

}
