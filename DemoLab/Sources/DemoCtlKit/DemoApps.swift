// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import DemoAppKit
import Foundation

// MARK: - LabControl

/// Where every lab process listens for control commands, decided once.
///
/// The demo apps and the overlay derive their socket path from
/// `DEMOLAB_CONTROL_DIR`, so `democtl` picks the directory, exports it for
/// itself, and hands the same value to everything it launches. Two properties
/// follow from putting it under ``LabPaths/runRoot``: the sockets live with the
/// rest of the lab state, and `democtl reset` removes them with it instead of
/// leaving stale sockets behind in the system temporary directory.
@MainActor
public enum LabControl {

  // MARK: Public

  /// Not isolated: it is an immutable name, and the failure messages that quote
  /// it are built wherever an error is printed.
  public nonisolated static let variable = "DEMOLAB_CONTROL_DIR"

  /// Creates the directory, exports it for this process, and returns the
  /// environment every launched lab process must be given.
  ///
  /// One call site (`democtl`'s path resolution) on purpose: a command that
  /// exported one directory while launching an app into another would send its
  /// state changes into the void.
  @discardableResult
  public static func adopt(_ paths: LabPaths) throws -> [String: String] {
    let directory = paths.controlDirectory
    try requireSocketBudget(directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv(variable, directory.path, 1)
    return environment(paths)
  }

  public static func environment(_ paths: LabPaths) -> [String: String] {
    [variable: paths.controlDirectory.path]
  }

  /// Sends one command and insists on an acknowledgement.
  ///
  /// Every failure here is fatal to the caller. A scene that silently skipped a
  /// state change would film the wrong pixels and nothing would say so, which is
  /// the one failure this rig must never have.
  @discardableResult
  public static func send(_ line: String, to bundleIdentifier: String, named name: String) throws -> String {
    let socket = DemoControl.socket(for: bundleIdentifier).path
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty else {
      throw DemoControlFailure.notRunning(app: name, socket: socket)
    }
    let reply: String
    do {
      reply = try DemoControlClient.send(line, to: bundleIdentifier)
    } catch {
      throw DemoControlFailure.unreachable(app: name, socket: socket, detail: "\(error)")
    }
    guard !reply.isEmpty else {
      throw DemoControlFailure.unreachable(app: name, socket: socket, detail: "the app answered with nothing")
    }
    guard !reply.hasPrefix("err") else {
      throw DemoControlFailure.rejected(app: name, command: line, reply: reply)
    }
    return reply
  }

  // MARK: Private

  /// `sun_path` is 104 bytes, and a socket path longer than that cannot be
  /// bound at all. An app reports that on stderr and then runs on without a
  /// control channel, which surfaces much later as "the app is not answering",
  /// so the budget is checked where the directory is chosen.
  private static func requireSocketBudget(_ directory: URL) throws {
    let leaf = (DemoCatalog.all.map(\.bundleIdentifier) + [DemoCatalog.overlayBundleIdentifier])
      .map { ($0.split(separator: ".").last.map(String.init) ?? $0).utf8.count }
      .max() ?? 0
    // directory + "/" + leaf + ".sock" + the terminating NUL.
    let needed = directory.path.utf8.count + 1 + leaf + 5 + 1
    guard needed <= 104 else {
      throw DemoControlFailure.directoryTooLong(directory: directory.path, needed: needed)
    }
  }

}

// MARK: - DemoControlFailure

/// A control-channel failure. Every case aborts whatever asked for it.
public enum DemoControlFailure: Error, CustomStringConvertible {
  case notRunning(app: String, socket: String)
  case unreachable(app: String, socket: String, detail: String)
  case rejected(app: String, command: String, reply: String)
  case launchTimedOut(app: String, socket: String, seconds: Double)
  case directoryTooLong(directory: String, needed: Int)
  case bundleMissing(app: String, path: String)

  // MARK: Public

  public var description: String {
    switch self {
    case .notRunning(let app, let socket):
      "\(app) is not running, so it cannot be driven (no control socket at \(socket))"

    case .unreachable(let app, let socket, let detail):
      """
      \(app) is running but not answering on \(socket): \(detail)
      An app only listens there when it was launched with \(LabControl.variable) set to that
      directory. `democtl launch` and `democtl seed` do that; an app opened by hand does not.
      """

    case .rejected(let app, let command, let reply):
      "\(app) refused \"\(command)\": \(reply)"

    case .launchTimedOut(let app, let socket, let seconds):
      """
      \(app) was launched but never answered on \(socket) within \(String(format: "%.1f", seconds))s.
      Check that the bundle is the one `democtl build` produced and that \(LabControl.variable)
      names a writable directory.
      """

    case .directoryTooLong(let directory, let needed):
      """
      \(LabControl.variable) would be \(directory), and a socket in it needs \(needed) bytes of the
      104-byte sun_path limit. Move the package somewhere with a shorter path.
      """

    case .bundleMissing(let app, let path):
      "\(app).app is missing at \(path); run `democtl build`"
    }
  }
}

// MARK: - DemoAppsController

/// Starts and stops the demo apps.
///
/// Launching is always "terminate, then launch": relaunching an app that is
/// already up is the only way to guarantee its window count, since there is no
/// way to ask a running app to return to its initial state. That makes
/// `democtl launch` idempotent in the sense that matters — the same command
/// always produces the same windows.
@MainActor
public struct DemoAppsController {

  // MARK: Lifecycle

  public init(paths: LabPaths) {
    self.paths = paths
  }

  // MARK: Public

  public let paths: LabPaths

  public static func running() -> [NSRunningApplication] {
    let identifiers = Set(DemoCatalog.all.map(\.bundleIdentifier))
    return NSWorkspace.shared.runningApplications.filter {
      guard let identifier = $0.bundleIdentifier else { return false }
      return identifiers.contains(identifier) && Shell.processExists($0.processIdentifier)
    }
  }

  public static func isRunning(_ spec: DemoAppSpec) -> Bool {
    NSRunningApplication.runningApplications(withBundleIdentifier: spec.bundleIdentifier).contains { Shell.processExists($0.processIdentifier) }
  }

  /// Whether the app answers on its control socket. `isRunning` is not enough:
  /// an app launched without the lab's `DEMOLAB_CONTROL_DIR` is up on screen and
  /// deaf to every command.
  public static func isListening(_ spec: DemoAppSpec) -> Bool {
    DemoControlClient.isListening(bundleIdentifier: spec.bundleIdentifier)
  }

  /// Counts an app's ordinary on-screen windows.
  ///
  /// `kCGWindowListOptionOnScreenOnly` + a zero window layer is the same shape
  /// Tatami's own window discovery uses. Window *titles* would need the Screen
  /// Recording permission, but owner, layer, and bounds do not — and a count is
  /// all a launch barrier needs.
  public static func onScreenWindowCount(for spec: DemoAppSpec) -> Int {
    let processIDs = Set(
      NSRunningApplication.runningApplications(withBundleIdentifier: spec.bundleIdentifier)
        .map(\.processIdentifier)
    )
    guard !processIDs.isEmpty else { return 0 }
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
      return 0
    }
    return entries.filter { entry in
      guard let owner = entry[kCGWindowOwnerPID as String] as? pid_t, processIDs.contains(owner) else {
        return false
      }
      let layer = entry[kCGWindowLayer as String] as? Int ?? 0
      guard layer == 0 else { return false }
      guard let bounds = entry[kCGWindowBounds as String] as? [String: Any],
            let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double
      else { return false }
      // Filter out the zero-size helper surfaces AppKit sometimes keeps around.
      return width > 40 && height > 40
    }.count
  }

  public func missingBundles(_ specs: [DemoAppSpec]) -> [String] {
    specs
      .filter { !FileManager.default.fileExists(atPath: paths.appBundle($0.name).path) }
      .map(\.name)
  }

  /// Terminates the named apps and waits for them to actually be gone.
  @discardableResult
  public func quit(_ specs: [DemoAppSpec], timeout: Duration = .seconds(8)) -> [String] {
    let identifiers = Set(specs.map(\.bundleIdentifier))
    let victims = Self.running().filter { identifiers.contains($0.bundleIdentifier ?? "") }
    guard !victims.isEmpty else { return [] }
    for application in victims { application.terminate() }

    let stopped = Shell.wait(timeout: timeout) {
      Self.running().allSatisfy { !identifiers.contains($0.bundleIdentifier ?? "") }
    }
    if !stopped {
      for application in Self.running() where identifiers.contains(application.bundleIdentifier ?? "") {
        application.forceTerminate()
      }
      _ = Shell.wait(timeout: .seconds(4)) {
        Self.running().allSatisfy { !identifiers.contains($0.bundleIdentifier ?? "") }
      }
    }
    return victims.compactMap(\.bundleIdentifier)
  }

  /// Quits every demo app, and nothing else.
  ///
  /// Deliberately **not** the overlay. A scene's `quitApps` step uses this to
  /// clear the stage between chapters, and the narration has to survive that:
  /// killing it mid-take leaves every later `caption` step failing against an
  /// app that is gone.
  @discardableResult
  public func quitAll(timeout: Duration = .seconds(8)) -> [String] {
    quit(DemoCatalog.all, timeout: timeout)
  }

  /// Quits the demo apps *and* the narration overlay, for tearing a session
  /// down rather than clearing the stage inside one. An overlay left running
  /// would caption the next take with the last one's words.
  @discardableResult
  public func quitAllIncludingOverlay(timeout: Duration = .seconds(8)) -> [String] {
    quitAll(timeout: timeout) + OverlayController(paths: paths).quit()
  }

  /// Sends one command to a demo app and returns its reply.
  @discardableResult
  public func send(_ line: String, to spec: DemoAppSpec) throws -> String {
    try LabControl.send(line, to: spec.bundleIdentifier, named: spec.name)
  }

  /// Sets the number of real native windows for off-camera preparation.
  @discardableResult
  public func setWindowCount(_ count: Int, of spec: DemoAppSpec) throws -> String {
    guard (0...8).contains(count) else {
      throw DemoCtlError.usage("\(spec.name): windows must be 0...8, got \(count)")
    }
    return try send("windows \(count)", to: spec)
  }

  /// Launches apps one at a time, in the given order, waiting for each one's
  /// windows before starting the next.
  ///
  /// Order matters on camera: Tatami inserts each new window at the shallowest
  /// tile, so a fixed launch order is what makes the resulting BSP layout the
  /// same in every take. Launching them concurrently would race.
  public func launch(
    _ specs: [DemoAppSpec],
    windowCounts: [DemoAppID: Int] = [:],
    settle: Duration = .milliseconds(350),
    timeout: Duration = .seconds(15)
  ) throws {
    let missing = missingBundles(specs)
    guard missing.isEmpty else { throw DemoCtlError.bundlesMissing(missing) }

    // Relaunch rather than reuse: a running app cannot be reset to its initial
    // window count.
    quit(specs)

    for spec in specs {
      let bundle = paths.appBundle(spec.name)
      var arguments = ["-n", "-a", bundle.path, "--args"]
      let requested = windowCounts[spec.id] ?? spec.defaultWindowCount
      arguments += ["--windows", String(requested)]
      // The control directory is handed over at launch because it cannot be
      // passed any other way: Tatami's `autoOpen` starts these apps with no argv
      // at all, so the address is derived from the environment instead.
      try Shell.require(
        URL(fileURLWithPath: "/usr/bin/open"),
        arguments,
        environment: LabControl.environment(paths)
      )

      let expected = max(requested, 0)
      if expected > 0 {
        let appeared = Shell.wait(timeout: timeout) {
          Self.onScreenWindowCount(for: spec) >= expected
        }
        guard appeared else {
          throw DemoCtlError.waitTimedOut(
            what: "\(spec.name) to show \(expected) window(s)",
            seconds: 15
          )
        }
      }
      // The control channel is the barrier every later activation step depends
      // on, and its absence is invisible until one of them fails mid-take.
      let control = Duration.seconds(8)
      let answered = Shell.wait(timeout: control) { Self.isListening(spec) }
      guard answered else {
        throw DemoControlFailure.launchTimedOut(
          app: spec.name,
          socket: DemoControl.socket(for: spec.bundleIdentifier).path,
          seconds: Shell.seconds(control)
        )
      }
      // A short settle after the window appears lets Tatami's AX observers see
      // it and finish tiling before the next app lands on top of the work.
      Shell.sleep(settle)
    }
  }

}

// MARK: - OverlayController

/// Starts, stops and drives the narration overlay.
///
/// The overlay is not a demo app. It is never assigned to a workspace, never
/// tiled, and never takes focus, so it is addressed by bundle identifier rather
/// than by a catalog spec and lives outside ``DemoAppsController``'s app set.
/// What it shares with the demo apps is the control channel: every command is
/// absolute and acknowledged, so a scene can put a caption on screen and know it
/// is there before the next step runs.
@MainActor
public struct OverlayController {

  // MARK: Lifecycle

  public init(paths: LabPaths) {
    self.paths = paths
  }

  // MARK: Public

  /// The bundle is `DemoOverlay.app`; the identifier's last component, and so
  /// the socket's leaf, is `Overlay`.
  public static let bundleName = "DemoOverlay"

  public let paths: LabPaths

  public static var socketPath: String {
    DemoControl.socket(for: DemoCatalog.overlayBundleIdentifier).path
  }

  /// Whether the overlay answers on its control socket, which is the only state
  /// worth testing: a running overlay that cannot be driven shows nothing.
  public static var isListening: Bool {
    DemoControlClient.isListening(bundleIdentifier: DemoCatalog.overlayBundleIdentifier)
  }

  public var bundle: URL { paths.appBundle(Self.bundleName) }

  public var bundleExists: Bool { FileManager.default.fileExists(atPath: bundle.path) }

  public static func running() -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: DemoCatalog.overlayBundleIdentifier).filter { Shell.processExists($0.processIdentifier) }
  }

  /// Launches the overlay and waits for it to answer.
  ///
  /// `open` rather than the executable so LaunchServices reads the bundle's
  /// `LSUIElement`: as an accessory app the overlay never takes focus, never
  /// appears in the Dock or the app switcher, and so cannot steal the keystroke
  /// a scene is about to send to Tatami.
  public func launch(timeout: Duration = .seconds(15)) throws {
    guard bundleExists else {
      throw DemoControlFailure.bundleMissing(app: Self.bundleName, path: bundle.path)
    }
    // Relaunch rather than reuse: an overlay left over from an earlier run still
    // holds that run's caption, and it bound its socket in that run's control
    // directory.
    quit()
    try Shell.require(
      URL(fileURLWithPath: "/usr/bin/open"),
      ["-n", "-a", bundle.path],
      environment: LabControl.environment(paths)
    )
    let answered = Shell.wait(timeout: timeout) { Self.isListening }
    guard answered else {
      throw DemoControlFailure.launchTimedOut(
        app: "Overlay",
        socket: Self.socketPath,
        seconds: Shell.seconds(timeout)
      )
    }
    // Every take starts on a blank layer.
    try clear()
  }

  @discardableResult
  public func quit(timeout: Duration = .seconds(6)) -> [String] {
    let victims = Self.running()
    guard !victims.isEmpty else { return [] }
    for application in victims { application.terminate() }
    let stopped = Shell.wait(timeout: timeout) { Self.running().isEmpty }
    if !stopped {
      for application in Self.running() { application.forceTerminate() }
      _ = Shell.wait(timeout: .seconds(3)) { Self.running().isEmpty }
    }
    return victims.compactMap(\.bundleIdentifier)
  }

  @discardableResult
  public func send(_ line: String) throws -> String {
    try LabControl.send(line, to: DemoCatalog.overlayBundleIdentifier, named: "Overlay")
  }

  /// The small pill at the top of the screen.
  @discardableResult
  public func chapter(_ text: String) throws -> String {
    try send("chapter \(text)")
  }

  /// The card at the bottom. Everything after `" | "` is the "why" line, and an
  /// empty text clears the card.
  @discardableResult
  public func caption(_ text: String) throws -> String {
    try send("caption \(text)")
  }

  /// The keycaps at the bottom right, written in Tatami's own shortcut spelling
  /// (`"ctrl + alt + shift - 2"`). An empty chord clears them.
  @discardableResult
  public func keys(_ chord: String) throws -> String {
    try send("keys \(chord)")
  }

  @discardableResult
  public func clear() throws -> String {
    try send("clear")
  }


}
