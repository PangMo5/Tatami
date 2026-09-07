// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreGraphics
import DemoAppKit
import DemoDriverKit
import Foundation
import CryptoKit

// MARK: - DemoCtl

/// The Demo Lab's command surface.
///
/// Argument parsing is hand-rolled because the package deliberately has zero
/// external dependencies: `swift build` has to work offline inside a freshly
/// cloned VM that has only the Command Line Tools.
@MainActor
public enum DemoCtl {

  // MARK: Public

  /// App sets that mirror the workspaces in `config/tatami-demo.toml.in`.
  /// Workspace apps have `autoOpen = true`, so activating a workspace already
  /// opens them; these sets exist for staging a shot by hand.
  public static let appSets: [String: [DemoAppID]] = [
    "code": [.editor, .terminal, .docs],
    "review": [.review, .docs],
    "chat": [.chat],
    "docs": [.docs],
    "notes": [.notes],
    "monitor": [.monitor],
    "all": DemoAppID.allCases,
  ]

  public static func main() -> Int32 {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
      print(usage)
      return 2
    }
    arguments.removeFirst()

    do {
      switch command {
      case "help", "--help", "-h": print(usage)
      case "build": try build(arguments)
      case "inspect":
        let paths = try resolvePaths()
        let name = arguments.first ?? "Tatami"
        let install = try resolveInstall(explicit: nil)
        let bundle = name == "Tatami" ? install.bundleIdentifier : DemoCatalog.spec(named:name)?.bundleIdentifier
        guard let bundle else {throw DemoCtlError.usage("unknown app")}
        _ = paths
        print(try NativeInteractionDriver.snapshot(bundleIdentifier:bundle))
      case "display":
        let paths = try resolvePaths()
        if arguments.first == "connect" {try VirtualDisplayController.connect(paths)}
        else if arguments.first == "disconnect" {try VirtualDisplayController.disconnect(paths)}
        else {throw DemoCtlError.usage("display connect|disconnect")}
      case "doctor": try doctor(arguments)
      case "displays": try displays()
      case "reset": try reset(arguments)
      case "seed": try seed(arguments)
      case "launch": try launch(arguments)
      case "app": try app(arguments)
      case "overlay": try overlay(arguments)
      case "quit": try quit()
      case "scene": try scene(arguments)
      case "take": try take(arguments)
      case "record": try record(arguments)
      case "subtitle": try subtitle(arguments)
      case "events": try events(arguments)
      case "config": try config(arguments)
      case "restore": try restore(arguments)
      default:
        FileHandle.standardError.write(Data("unknown command \"\(command)\"\n\n".utf8))
        print(usage)
        return 2
      }
      return 0
    } catch let error as DemoCtlError {
      FileHandle.standardError.write(Data("democtl: \(error.description)\n".utf8))
      return error.isUsage ? 2 : 1
    } catch {
      FileHandle.standardError.write(Data("democtl: \(error)\n".utf8))
      return 1
    }
  }

  // MARK: Private

  private static let usage = """
  democtl — Tatami Demo Lab control

  Setup
    build                       Build every demo app, the recorder and the tools into .build/DemoLab
    doctor                      Check everything that must be true before a take
    displays                    Print each screen's Tatami display-hint string

  Run
    reset [--restore-defaults] [--tatami-app <path>]
                                Quit the demo apps and Tatami, then delete all lab state
    seed [options]              Render the config, start an isolated Tatami, verify it round-trips
    launch <set|App...>         Launch an app set (\(appSets.keys.sorted().joined(separator: ", ")))
    app <Name> windows <n>      Open or close that app's windows until it has n
    app --list                  Every app, its role, and whether it answers
    overlay caption <text>      Narrate: "<headline> | <why>", or empty text to clear the card
    overlay chapter <text>      The pill at the top of the screen, or empty text to clear it
    overlay keys <chord>        Keycaps for an action that was not a keystroke
    overlay mode all|keys|off   How much of the narration layer is drawn at all
    overlay clear               Wipe the whole narration layer
    quit                        Quit the demo apps, the overlay, and the lab's Tatami

  Record
    scene <name> [--dry-run] [--overlay full|keys|off] [--keycast-hold <ms>]
                                Play a scene
    take <name> [options]       Record a scene end to end and write the .mov plus its sidecars
    record start|stop|status    Drive the recorder on its own
    record warmup [--seconds N] Throw away a short recording so the screen-capture consent panel,
                                which macOS 15+ re-shows periodically, appears now and not mid-take
    record preflight            Report whether DemoRecorder holds Screen Recording access
    subtitle burn <movie> [--ass <file>] [--output <file>]
                                Burn a take's .ass sidecar into a copy of the movie. Needs an
                                ffmpeg with libass, or mpv. Neither is in the recording VM, so
                                this is a host-side step after fetch-recordings.sh
    events [--all]              Print the Tatami lifecycle events the hooks logged

  Inspect
    config [--print]            Show or validate the rendered config
    restore [--tatami-app <path>]
                                Put Tatami's UserDefaults domain back as it was before `seed`

  seed options
    --pulse floating|unmanaged|tiled   Shared Pulse as Always on Top (default), Leave As Is, or Tiled
    --borrow-edge top|bottom|left|right
    --focus-follows-mouse              Turn FFM on (off by default: it is hard to film)
    --no-mouse-follows-focus           Turn MFF off (on by default)
    --debug-logging                    Ask Tatami to write its debug log into the lab directory
    --no-launch                        Render and verify the config without starting Tatami

  take options
    --output <path.mov>   --display <index|main|all>   --fps <n>   --keep-running
    --display takes an index from `democtl displays` (0-based, the same index a
    scene `pointer` step uses), or `main`, or `all` for one file per display
    --overlay full|keys|off    How much narration is drawn into the frame. Default `off` for a
                               take: every word and keycap goes to <name>.ass instead, where a
                               capture stream cannot drop it and an editor can restyle it.
                               Default `full` for `scene`, which nobody is recording
    --keycast-hold <ms>        How long the keycaps are held, and so how long they run in the
                               sidecar (default \(SceneRunner.defaultKeycastHoldMilliseconds))

  Every take writes two sidecars next to the .mov, with the same basename:
    <name>.ass             the subtitles, restyle or translate them and burn them in later
    <name>.timeline.json   every narration event with its start and end, for any other tool
  They are written even when the scene fails partway, so a failed take is still diagnosable.

  Global
    --tatami-app <path>   Use a specific Tatami.app (or set DEMOLAB_TATAMI_APP)
  """

  private static func resolvePaths() throws -> LabPaths {
    guard let root = LabPaths.discoverPackageRoot() else { throw DemoCtlError.packageRootNotFound }
    let paths = LabPaths(packageRoot: root)
    // Every command goes through here, which is exactly why the control
    // directory is decided here: `democtl` and everything it launches then read
    // the same `DEMOLAB_CONTROL_DIR`, and the sockets are removed by `reset`
    // with the rest of the lab state.
    try LabControl.adopt(paths)
    return paths
  }

  private static func resolveInstall(_ arguments: inout [String]) throws -> TatamiInstall {
    try resolveInstall(explicit: takeOption(&arguments, "--tatami-app"))
  }

  private static func resolveInstall(explicit: String?) throws -> TatamiInstall {
    let install = try TatamiInstall.locate(explicit: explicit)
    try install.validate()
    return install
  }

  private static func takeOption(_ arguments: inout [String], _ name: String) throws -> String? {
    guard let index = arguments.firstIndex(of: name) else { return nil }
    arguments.remove(at: index)
    // A missing value used to be reported as "option absent", and `rejectUnknown`
    // could not catch it because the token was already gone. A recording
    // parameter that quietly reverts to its default is the one failure this rig
    // must never have.
    guard index < arguments.count else {
      throw DemoCtlError.usage("\(name) requires a value")
    }
    let value = arguments.remove(at: index)
    // No option here takes a value that looks like a flag, and swallowing the
    // next flag as a value is the same silent failure in a different shape.
    guard !value.hasPrefix("--") else {
      throw DemoCtlError.usage("\(name) requires a value, got the option \"\(value)\"")
    }
    return value
  }

  /// Resolves `--display` to the `id:<CGDirectDisplayID>` form the recorder
  /// takes.
  ///
  /// Two different display enumerations exist and they do not agree: everything
  /// `democtl` prints (`displays`, and a scene's `pointer` step) is 0-based over
  /// `NSScreen`s sorted left to right, the same order Tatami uses, while the
  /// recorder's own index is 1-based over whatever order ScreenCaptureKit hands
  /// back. Passing a bare number through would silently record a different
  /// screen than the one the operator picked — and on a two-display take, the
  /// screen the action is not happening on. Resolving to the display's stable
  /// identifier here removes the ambiguity instead of documenting it.
  private static func displayOption(_ arguments: inout [String]) throws -> String {
    guard let value = try takeOption(&arguments, "--display") else { return "main" }
    if value == "main" || value == "all" { return value }
    if value.hasPrefix("id:") { return value }

    let displays = DisplayInfo.all()
    guard let index = Int(value), displays.indices.contains(index) else {
      let known = displays
        .map { "\($0.index) = \($0.name)" }
        .joined(separator: ", ")
      throw DemoCtlError.usage(
        "--display expects \"main\", \"all\", or a display index from `democtl displays` "
          + "(\(known.isEmpty ? "none detected" : known)), got \"\(value)\""
      )
    }
    guard displays[index].displayID != 0 else {
      throw DemoCtlError.usage("display \(index) reports no CGDirectDisplayID and cannot be recorded")
    }
    return "id:\(displays[index].displayID)"
  }

  /// Mirrors `RecorderCommand.parseInt`'s 1...240 bound, so a bad rate is a
  /// usage error here instead of a 20s wait for a recorder that already exited.
  private static func fpsOption(_ arguments: inout [String]) throws -> Int {
    guard let raw = try takeOption(&arguments, "--fps") else { return 60 }
    guard let fps = Int(raw), (1...240).contains(fps) else {
      throw DemoCtlError.usage("--fps expects an integer in 1...240, got \"\(raw)\"")
    }
    return fps
  }

  /// Resolves `--overlay`.
  ///
  /// The default differs by command and that is the point: `scene` is played to
  /// be watched, so it draws everything, while `take` is played to be recorded
  /// and its captions live in the sidecar instead.
  private static func overlayModeOption(
    _ arguments: inout [String],
    default fallback: OverlayMode
  ) throws -> OverlayMode {
    guard let raw = try takeOption(&arguments, "--overlay") else { return fallback }
    guard let mode = OverlayMode(rawValue: raw) else {
      throw DemoCtlError.usage(
        "--overlay expects \(OverlayMode.allCases.map(\.rawValue).joined(separator: ", ")), got \"\(raw)\""
      )
    }
    return mode
  }

  /// How long the keycaps stay up after a keystroke. Zero is allowed and clears
  /// them the instant the key is posted, which is what they used to do.
  private static func keycastHoldOption(_ arguments: inout [String]) throws -> Int {
    guard let raw = try takeOption(&arguments, "--keycast-hold") else {
      return SceneRunner.defaultKeycastHoldMilliseconds
    }
    guard let milliseconds = Int(raw), (0...10_000).contains(milliseconds) else {
      throw DemoCtlError.usage("--keycast-hold expects an integer in 0...10000, got \"\(raw)\"")
    }
    return milliseconds
  }

  private static func takeFlag(_ arguments: inout [String], _ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
  }

  private static func rejectUnknown(_ arguments: [String], command: String) throws {
    let unknown = arguments.filter { $0.hasPrefix("--") }
    guard unknown.isEmpty else {
      throw DemoCtlError.usage("\(command): unknown option(s) \(unknown.joined(separator: ", "))")
    }
  }

  // MARK: - Commands

  private static func build(_ arguments: [String]) throws {
    let paths = try resolvePaths()
    let script = paths.packageRoot.appendingPathComponent("scripts/bundle-apps.sh")
    guard FileManager.default.isExecutableFile(atPath: script.path) else {
      throw DemoCtlError.usage("scripts/bundle-apps.sh is missing or not executable")
    }
    let result = try Shell.run(script, arguments, currentDirectory: paths.packageRoot)
    print(result.standardOutput, terminator: "")
    if !result.standardError.isEmpty {
      FileHandle.standardError.write(Data(result.standardError.utf8))
    }
    guard result.succeeded else {
      throw DemoCtlError.usage("bundle-apps.sh failed with exit \(result.status)")
    }
  }

  private static func doctor(_ arguments: [String]) throws {
    var arguments = arguments
    let paths = try resolvePaths()
    // The option is taken out here rather than inside `resolveInstall` so a
    // missing value stays a usage error; only the *lookup* is allowed to fail
    // quietly, because reporting that is what doctor is for.
    let explicit = try takeOption(&arguments, "--tatami-app")
    let install = try? resolveInstall(explicit: explicit)
    let checks = Doctor(paths: paths, install: install).run()
    for check in checks {
      let detail = check.detail.isEmpty ? "" : "  \(check.detail)"
      print("[\(check.status.marker)] \(check.title)\(detail)")
    }
    if checks.contains(where: { $0.status == .fail }) {
      throw DemoCtlError.usage("doctor found blocking problems (see FAIL rows above)")
    }
  }

  private static func displays() throws {
    let displays = DisplayInfo.all()
    print("Tatami identifies a display as \"<uuid>::<name>\". Paste one of these into a")
    print("workspace's `displayHint` to pin it. The shipped config deliberately pins nothing.")
    print("")
    for display in displays {
      print("[\(display.index)] \(display.displayHint)")
      print(
        "     \(Int(display.frame.width))x\(Int(display.frame.height)) at "
          + "(\(Int(display.frame.minX)), \(Int(display.frame.minY)))  scale \(display.scale)x"
      )
    }
  }

  /// The guard for an existing defaults snapshot, or nil when there is nothing
  /// to restore.
  ///
  /// The domain comes from the stamp `seed` wrote, never from `locate()`:
  /// `defaults import` replaces whichever domain it is handed, this repo ships
  /// two bundle ids on purpose, and a second source of truth for "which Tatami"
  /// is how a snapshot ends up in the wrong one. `--tatami-app` is accepted only
  /// as a cross-check.
  private static func restoreGuard(paths: LabPaths, explicit: String?) throws -> DefaultsGuard? {
    let directory = paths.defaultsSnapshotRoot
    let backup = DefaultsGuard.backupURL(in: directory)
    guard FileManager.default.fileExists(atPath: backup.path) else { return nil }
    guard let domain = DefaultsGuard.capturedDomain(in: directory) else {
      throw DemoCtlError.defaultsSnapshotUnstamped(
        backup: backup.path,
        stamp: DefaultsGuard.domainStampURL(in: directory).path
      )
    }
    if let explicit {
      let install = try TatamiInstall.locate(explicit: explicit)
      guard install.bundleIdentifier == domain else {
        throw DemoCtlError.defaultsSnapshotForeign(
          captured: domain,
          requested: install.bundleIdentifier,
          backup: backup.path
        )
      }
    }
    return DefaultsGuard(domain: domain, snapshotDirectory: directory)
  }

  private static func reset(_ arguments: [String]) throws {
    var arguments = arguments
    let restoreDefaults = takeFlag(&arguments, "--restore-defaults")
    let explicit = try takeOption(&arguments, "--tatami-app")
    try rejectUnknown(arguments, command: "reset")

    let paths = try resolvePaths()
    // Resolved before anything is quit or deleted: a snapshot that cannot be
    // matched to a domain has to stop the command, not be discovered halfway
    // through it.
    var guardian: DefaultsGuard?
    if restoreDefaults { guardian = try restoreGuard(paths: paths, explicit: explicit) }
    let apps = DemoAppsController(paths: paths)

    // `quitAll` covers the narration overlay as well as the demo apps: one left
    // running would caption the next take with the last one's words.
    let quitApps = apps.quitAllIncludingOverlay()
    if quitApps.isEmpty { print("demo apps: none running") } else {
      print("demo apps: quit \(quitApps.count) (\(quitApps.joined(separator: ", ")))")
    }

    // Every Tatami, not only one the lab started: two instances would both tile
    // the same windows. Their configuration is untouched — it lives elsewhere.
    let quitTatami = TatamiProcess.quitAll()
    print(quitTatami.isEmpty ? "Tatami: none running" : "Tatami: quit \(quitTatami.joined(separator: ", "))")

    if restoreDefaults {
      if let guardian {
        try guardian.restore()
        print("defaults: restored \(guardian.domain)")
      } else {
        print("defaults: no snapshot at \(paths.defaultsSnapshotRoot.path), nothing to restore")
      }
    } else if let held = DefaultsGuard.capturedDomain(in: paths.defaultsSnapshotRoot) {
      // The snapshot survives reset on purpose, which also means the suppression
      // survives it: say so, or a shoot ends with the user's real Tatami still
      // told that onboarding is done.
      print("defaults: \(held) is still suppressed; finish the shoot with `democtl restore`")
    }

    // The whole point of running Tatami against an isolated config home: reset
    // is one directory removal, and it is idempotent by construction. The
    // defaults snapshot deliberately lives outside this tree — removing it here
    // would make the next `seed` snapshot an already-suppressed domain and call
    // it pristine, and `democtl restore` could never undo the suppression again.
    if FileManager.default.fileExists(atPath: paths.labRoot.path) {
      try FileManager.default.removeItem(at: paths.labRoot)
      print("lab state: removed \(paths.labRoot.path)")
    } else {
      print("lab state: already clean")
    }
    try paths.ensureRuntimeDirectories()
  }

  private static func seed(_ arguments: [String]) throws {
    var arguments = arguments
    let install = try resolveInstall(&arguments)
    let paths = try resolvePaths()

    guard FileManager.default.isExecutableFile(atPath: paths.bundlesRoot.appendingPathComponent("bin/demohook").path) else {
      throw DemoCtlError.bundlesMissing(["demohook"])
    }
    var options = SeedOptions()
    if let pulse = try takeOption(&arguments, "--pulse") { options.pulseLayout = pulse }
    if let edge = try takeOption(&arguments, "--borrow-edge") { options.borrowEdge = edge }
    if takeFlag(&arguments, "--focus-follows-mouse") { options.focusFollowsMouse = true }
    if takeFlag(&arguments, "--no-mouse-follows-focus") { options.mouseFollowsFocus = false }
    if takeFlag(&arguments, "--debug-logging") { options.debugLogging = true }
    let skipLaunch = takeFlag(&arguments, "--no-launch")
    let keepWindow = takeFlag(&arguments, "--keep-window")
    try rejectUnknown(arguments, command: "seed")
    options = try options.validated()

    // Tatami must be stopped before its defaults domain is touched: a live
    // process keeps its own image of that domain and writes it back on change.
    TatamiProcess.quitAll()
    try paths.ensureRuntimeDirectories()

    let guardian = DefaultsGuard(
      domain: install.bundleIdentifier,
      snapshotDirectory: paths.defaultsSnapshotRoot
    )
    try guardian.captureIfNeeded()
    try guardian.suppressFirstRunWindows(appVersion: install.version)
    for domain in [install.bundleIdentifier] + DemoCatalog.all.map(\.bundleIdentifier) {
      _ = try Shell.require(URL(fileURLWithPath: "/usr/bin/defaults"), ["write", domain, "AppleLanguages", "-array", DemoLocale.selected.rawValue])
    }
    print(
      "defaults: Guided Setup, What's New and window restoration suppressed for "
        + "\(guardian.domain) (`democtl restore` puts them back)"
    )

    let renderer = ConfigRenderer(paths: paths)
    try StoryRepository(file: paths.controlDirectory.appendingPathComponent("launch-story.json")).write(LaunchStory())
    let cliContext = DemoCLIContext(executable: install.cli.path, socket: paths.socketPath.path,
      scripts: paths.packageRoot.appendingPathComponent("config/automation").path, config: paths.configFile.path)
    try JSONEncoder().encode(cliContext).write(to: DemoCLIContext.file, options: .atomic)
    try renderer.write(options)
    print("config: wrote \(paths.configFile.path)")

    let events = EventLog(url: paths.eventLog)
    try events.reset()

    guard !skipLaunch else {
      print("seed: --no-launch given, Tatami not started")
      return
    }

    let mark = events.mark
    try TatamiProcess.launch(install: install, paths: paths)
    print("Tatami: launched with an isolated config home and socket")

    let client = TatamiClient(install: install, paths: paths)
    let answered = Shell.wait(timeout: .seconds(30)) { client.isRunning }
    guard answered else { throw DemoCtlError.tatamiNotRunning(socket: paths.socketPath.path) }

    // `tatamiLaunched` fires once startup has resolved the active profile, so
    // it confirms both that the hooks work and that the config was accepted.
    _ = try events.wait(
      since: mark,
      timeout: .seconds(20),
      describing: "Tatami's tatamiLaunched hook"
    ) { $0.event == "tatamiLaunched" }
    print("hooks: tatamiLaunched received — the scene barrier works")

    // Tatami's own window opens itself at launch (its `Window` scene is first,
    // and macOS 14 has no way to suppress that). Closing it here keeps it out of
    // every take; `scenes/settings.json` opens it again on purpose.
    switch keepWindow ? 0 : TatamiProcess.closeOwnWindows() {
    case -1:
      print("Tatami window: still open — this process is not trusted for Accessibility, close it by hand")
    case 0:
      break
    case let count:
      print("Tatami window: closed \(count) (scenes/settings.json reopens it with Command-comma)")
    }

    // Tatami rewrites config.toml on every launch. Re-validating what is now on
    // disk is the only way to know it read what we meant: unknown keys and bad
    // enum spellings are silently defaulted with no warning anywhere.
    let roundTripped = try String(contentsOf: paths.configFile, encoding: .utf8)
    let report = ConfigValidator.report(roundTripped)
    for warning in report.warnings { print("config warning: \(warning)") }
    guard report.isClean else { throw DemoCtlError.configInvalid(report.problems) }

    let profiles = try client.profiles().compactMap { $0["name"] as? String }
    let workspaces = try client.workspaceNames()
    print("profiles: \(profiles.joined(separator: ", "))")
    print("workspaces (active profile): \(workspaces.joined(separator: ", "))")

    // Last, and only once Tatami is up: the overlay draws at `.screenSaver`
    // level over windows Tatami has already tiled, and it is what a scene's
    // captions and keycaps talk to.
    let overlay = OverlayController(paths: paths)
    try overlay.launch()
    print("overlay: answering on \(OverlayController.socketPath)")
    print("seed: ready")
  }

  private static func launch(_ arguments: [String]) throws {
    try rejectUnknown(arguments, command: "launch")
    guard !arguments.isEmpty else {
      throw DemoCtlError.usage("launch needs an app set (\(appSets.keys.sorted().joined(separator: ", "))) or app names")
    }

    let paths = try resolvePaths()
    var specs = [DemoAppSpec]()
    for token in arguments {
      if let set = appSets[token.lowercased()] {
        specs += set.map { DemoCatalog.spec($0) }
      } else if let spec = DemoCatalog.spec(named: token) {
        specs.append(spec)
      } else {
        throw DemoCtlError.usage("unknown app set or app \"\(token)\"")
      }
    }
    // Preserve order, drop repeats: launch order decides the resulting BSP tree.
    var seen = Set<DemoAppID>()
    specs = specs.filter { seen.insert($0.id).inserted }

    try DemoAppsController(paths: paths).launch(specs)
    print("launched: \(specs.map(\.name).joined(separator: ", "))")
  }

  /// Drives one running demo app over its control channel.
  ///
  /// Nothing here is best effort. An app that is not running, or that answers
  /// `err`, aborts the command with a non-zero exit: a scene that silently
  /// skipped a state change would film the wrong pixels and say nothing.
  private static func app(_ arguments: [String]) throws {
    var arguments = arguments
    let paths = try resolvePaths()

    let list = takeFlag(&arguments, "--list")
    try rejectUnknown(arguments, command: "app")
    guard !list, !arguments.isEmpty else {
      listApps(paths)
      return
    }

    let controller = DemoAppsController(paths: paths)
    let name = arguments.removeFirst()
    guard let spec = DemoCatalog.spec(named: name) else {
      throw DemoCtlError.usage(
        "unknown demo app \"\(name)\" (\(DemoCatalog.all.map(\.name).joined(separator: ", ")))"
      )
    }
    guard !arguments.isEmpty else {
      throw DemoCtlError.usage("app \(spec.name) needs an action: windows <n>")
    }
    let action = arguments.removeFirst()
    guard let raw = arguments.first else {
      throw DemoCtlError.usage("app \(spec.name) \(action) needs a number")
    }
    arguments.removeFirst()
    guard let value = Int(raw) else {
      throw DemoCtlError.usage("app \(spec.name) \(action): \"\(raw)\" is not a number")
    }
    guard arguments.isEmpty else {
      throw DemoCtlError.usage("app: unexpected argument \"\(arguments[0])\"")
    }

    switch action {
    case "windows": print(try controller.setWindowCount(value, of: spec))
    default: throw DemoCtlError.usage("app: unknown action \"\(action)\" (windows)")
    }
  }

  /// Every app, its role in the workflow, and whether it is
  /// reachable right now. The control directory is printed first because a whole
  /// column of "not answering" usually means an app was launched without it.
  private static func listApps(_ paths: LabPaths) {
    print("control sockets: \(DemoControl.directory.path)")
    for spec in DemoCatalog.all {
      print("")
      print("\(spec.name)  \(spec.bundleIdentifier)  [\(status(of: spec))]")
      print("  \(spec.role)")
    }
    print("")
    let overlayStatus = OverlayController.isListening
      ? "answering"
      : (OverlayController.running().isEmpty ? "not running" : "running, not answering")
    print("Overlay  \(DemoCatalog.overlayBundleIdentifier)  [\(overlayStatus)]  narration only, no states")
  }

  private static func status(of spec: DemoAppSpec) -> String {
    if DemoAppsController.isListening(spec) { return "answering" }
    return DemoAppsController.isRunning(spec) ? "running, not answering" : "not running"
  }

  /// Drives the narration overlay. Same rule as `app`: a caption that did not
  /// land is a failure, never a shrug.
  private static func overlay(_ arguments: [String]) throws {
    var arguments = arguments
    let paths = try resolvePaths()
    let overlay = OverlayController(paths: paths)

    guard let action = arguments.first else {
      throw DemoCtlError.usage(
        "overlay needs caption <text>, chapter <text>, keys <chord>, mode <all|keys|off> or clear"
      )
    }
    arguments.removeFirst()
    // Joined rather than required as one token: an unquoted caption arrives as
    // several arguments, and refusing it would be a papercut with no upside.
    let text = arguments.joined(separator: " ")

    switch action {
    case "caption": print(try overlay.caption(text))
    case "chapter": print(try overlay.chapter(text))
    case "keys": print(try overlay.keys(text))
    // The same command `scene` and `take` send through --overlay, reachable by
    // hand for staging a shot. The overlay validates the value, so a typo comes
    // back as a rejection rather than as a silently different mode.
    case "mode": print(try overlay.send("mode \(text)"))
    case "clear":
      guard text.isEmpty else { throw DemoCtlError.usage("overlay clear takes no text") }
      print(try overlay.clear())
    default:
      throw DemoCtlError.usage(
        "overlay: unknown action \"\(action)\" (caption, chapter, keys, mode or clear)"
      )
    }
  }

  private static func quit() throws {
    let paths = try resolvePaths()
    let apps = DemoAppsController(paths: paths).quitAllIncludingOverlay()
    let tatami = TatamiProcess.quitAll()
    print("quit demo apps and overlay: \(apps.isEmpty ? "none" : apps.joined(separator: ", "))")
    print("quit Tatami: \(tatami.isEmpty ? "none" : tatami.joined(separator: ", "))")
  }

  private static func scene(_ arguments: [String]) throws {
    var arguments = arguments
    let install = try resolveInstall(&arguments)
    let dryRun = takeFlag(&arguments, "--dry-run")
    // `full`: a scene is played to be watched, live, by whoever is tuning it.
    // Nothing is being recorded, so there is no sidecar for the captions to
    // duplicate and every reason to see them.
    let overlayMode = try overlayModeOption(&arguments, default: .full)
    let keycastHold = try keycastHoldOption(&arguments)
    let paths = try resolvePaths()

    if takeFlag(&arguments, "--list") || arguments.isEmpty {
      print("scenes: \(SceneLoader.available(in: paths).joined(separator: ", "))")
      guard !arguments.isEmpty else { return }
    }
    try rejectUnknown(arguments, command: "scene")

    let name = arguments[0]
    let scene = try SceneLoader.load(name, paths: paths)
    let client = TatamiClient(install: install, paths: paths)
    guard dryRun || client.isRunning else {
      throw DemoCtlError.tatamiNotRunning(socket: paths.socketPath.path)
    }

    // No timeline: there is no movie here for a sidecar to sit beside, and an
    // .ass file with nothing to caption is a file someone would later burn into
    // the wrong take.
    let runner = SceneRunner(
      paths: paths,
      client: client,
      apps: DemoAppsController(paths: paths),
      log: { print($0); fflush(stdout) },
      overlayMode: overlayMode,
      keycastHoldMilliseconds: keycastHold
    )
    defer {runner.restoreClipboard()}
    try runner.prepare(scene, dryRun: dryRun)
    try runner.run(scene, dryRun: dryRun)
  }

  private static func take(_ arguments: [String]) throws {
    var arguments = arguments
    let install = try resolveInstall(&arguments)
    let paths = try resolvePaths()

    let display = try displayOption(&arguments)
    let fps = try fpsOption(&arguments)
    let explicitOutput = try takeOption(&arguments, "--output")
    let keepRunning = takeFlag(&arguments, "--keep-running")
    // Keep the original footage clean; all presentation is rendered from sidecars.
    let overlayMode = try overlayModeOption(&arguments, default: .off)
    let keycastHold = try keycastHoldOption(&arguments)
    try rejectUnknown(arguments, command: "take")

    guard let name = arguments.first else { throw DemoCtlError.usage("take needs a scene name") }
    let sceneData = try Data(contentsOf: paths.sceneFile(name))
    let scene = try JSONDecoder().decode(Scene.self, from: sceneData)

    let client = TatamiClient(install: install, paths: paths)
    guard client.isRunning else { throw DemoCtlError.tatamiNotRunning(socket: paths.socketPath.path) }

    let recorder = RecorderController(paths: paths)
    // The stamp is the only value in the lab that is allowed to vary: it names
    // the file, and never appears on screen.
    let stamp = Self.stamp()
    let output = explicitOutput.map { URL(fileURLWithPath: $0) }
      ?? recorder.nextOutputURL(scene: name, stamp: stamp)

    guard !FileManager.default.fileExists(atPath: output.path) else {
      throw DemoCtlError.usage("refusing to overwrite an existing take: \(output.path)")
    }
    let preparation = SceneRunner(paths: paths, client: client,
      apps: DemoAppsController(paths: paths), log: { print($0); fflush(stdout) }, overlayMode: .off)
    defer {preparation.restoreClipboard()}
    try preparation.prepare(scene)
    try recorder.start(output: output, display: display, fps: fps)
    defer {
      if recorder.runningPID != nil {
        do { try recorder.stop() }
        catch { FileHandle.standardError.write(Data("democtl: recorder cleanup failed: \(error)\n".utf8)) }
      }
    }
    // Sidecar zero is the first encoded frame, not the controller's poll of a PID.
    let elapsed = try recorder.elapsedSinceFirstFrame()
    let timeline = SceneTimeline(scene: name, t0: .now.advanced(by: .seconds(-elapsed)))
    // Announced as a destination, not as a result: `--display all` writes one
    // file per display, and the real paths only exist once the recorder says so.
    if display == "all" {
      print("recording: one file per display, next to \(output.path)")
    } else {
      print("recording: \(output.path)")
    }
    // A moment of clean screen before the first action still reads better than
    // cutting in mid-transition, but half of what it was: the reviewer's note
    // was that a long take opens with dead air, and this is the part of that
    // dead air no scene file can shorten.
    let runner = SceneRunner(
      paths: paths,
      client: client,
      apps: DemoAppsController(paths: paths),
      log: { print($0); fflush(stdout) },
      timeline: timeline,
      overlayMode: overlayMode,
      keycastHoldMilliseconds: keycastHold
    )

    if scene.captureSecondary == true {
      runner.secondaryCapture = (output.deletingPathExtension().appendingPathExtension("secondary.mov"), fps)
    }
    defer {runner.restoreClipboard()}
    var sceneFailure: (any Error)?
    do {
      try CaptureGate.requireCleanDesktop()
      try runner.run(scene)
      Shell.sleep(.milliseconds(200))
    } catch {
      sceneFailure = error
    }
    // Before the recorder is asked to stop, so the last caption ends with the
    // last frame rather than with however long the writer takes to drain.
    do { try runner.finishSecondaryCapture() } catch { if sceneFailure == nil { sceneFailure = error } }
    timeline.finish()

    var outcome: RecordingOutcome?
    var stopFailure: (any Error)?
    do { outcome = try recorder.stop() } catch { stopFailure = error }

    // A failed take gets its sidecars too: they are the record of how far it
    // got. When the recorder itself failed there is no list of finalized files,
    // so they go next to the path the take was aiming at.
    var movies = outcome?.outputs ?? []
    if movies.isEmpty { movies = [output] }

    let resolution = scriptResolution(display: display, paths: paths)
    var sidecarFailure: (any Error)?
    do {
      for movie in movies {
        for file in try SceneSidecars.write(
          timeline,
          besides: movie,
          resolution: resolution,
          drawnLive: overlayMode.liveTracks
        ) {
          print("wrote \(file.path)")
        }
      }
    } catch {
      sidecarFailure = error
    }

    // The scene failure is the headline, the recorder's is next, and a sidecar
    // that could not be written is last. Whichever are not thrown are still said
    // out loud, because a second failure hidden behind the first is how a take
    // gets re-shot for the wrong reason.
    let failures = [sceneFailure, stopFailure, sidecarFailure].compactMap { $0 }
    for extra in failures.dropFirst() {
      FileHandle.standardError.write(Data("democtl: this take also failed: \(extra)\n".utf8))
    }
    for movie in movies {
      let stats = outcome == nil ? [:] : try recorder.outputStatistics(for: movie)
      let metadata = outcome == nil ? [:] : try recorder.captureMetadata(for: movie)
      let record: [String: Any] = [
        "capture": metadata,
        "locale": DemoLocale.selected.rawValue,
        "schemaVersion": 2, "scene": name, "status": failures.isEmpty ? "passed" : "failed",
        "tatamiVersion": install.version ?? "unknown", "overlay": overlayMode.rawValue,
        "frames": stats["frames"] ?? 0, "droppedFrames": stats["dropped"] ?? 0,
        "durationSeconds": timeline.durationSeconds,
        "sceneSHA256": SHA256.hash(data: sceneData).map { String(format: "%02x", $0) }.joined(),
      ]
      try sceneData.write(to: movie.deletingPathExtension().appendingPathExtension("scene.json"), options: .atomic)
      try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        .write(to: movie.deletingPathExtension().appendingPathExtension("take.json"), options: .atomic)
    }
    if let headline = failures.first { throw headline }
    if let outcome { report(outcome) }
    if let movie = movies.first {
      print("subtitles: burn them in where ffmpeg lives with `democtl subtitle burn \(movie.path)`")
    }

    if !keepRunning {
      DemoAppsController(paths: paths).quitAllIncludingOverlay()
    }
  }

  /// The pixel size the sidecars declare.
  ///
  /// An ASS file positions and sizes everything in `PlayResX`/`PlayResY` units
  /// that a player maps onto the movie, so declaring a size the movie does not
  /// have never fails: it silently scales every font and margin by the
  /// mismatch. Hence three sources in order of authority, and the last one says
  /// out loud that it is a guess.
  private static func scriptResolution(display: String, paths: LabPaths) -> SceneSubtitles.Resolution {
    if let reported = reportedResolution(paths.recorderResultFile) {
      print("subtitles: \(reported.width)x\(reported.height), as the recorder reported it")
      return reported
    }
    if let screen = recordedDisplay(display) {
      let size = SceneSubtitles.Resolution(
        width: evenFloor(Int((screen.frame.width * screen.scale).rounded())),
        height: evenFloor(Int((screen.frame.height * screen.scale).rounded()))
      )
      print("subtitles: \(size.width)x\(size.height), the backing pixels of display \(screen.index)")
      if display == "all" {
        print(
          "subtitles: --display all records one movie per display and they need not be the same "
            + "size; check PlayResY in the sidecar of any movie from another display"
        )
      }
      return size
    }
    let fallback = SceneSubtitles.Resolution.fallback
    print(
      "subtitles: no display resolved for --display \(display), so the sidecars declare "
        + "\(fallback.width)x\(fallback.height); correct PlayResX/PlayResY by hand if the movie differs"
    )
    return fallback
  }

  /// The display a take was recorded from, in the recorder's own `id:` spelling.
  private static func recordedDisplay(_ display: String) -> DisplayInfo? {
    let displays = DisplayInfo.all()
    if display.hasPrefix("id:") {
      guard let identifier = UInt32(display.dropFirst(3)) else { return nil }
      return displays.first { $0.displayID == identifier }
    }
    // `all` lands here too. With several displays recorded at once there is no
    // way from this side to tell which movie came from which, so the main
    // display is the answer and the caller says so.
    return displays.first { $0.displayID == CGMainDisplayID() } ?? displays.first
  }

  /// A size out of the recorder's result file, if it reports one.
  ///
  /// Read leniently on purpose: DemoCtlKit does not link DemoRecorderKit, that
  /// file is a cross-process contract like the exit codes, and a recorder that
  /// does not report a size has to fall through to the next source rather than
  /// fail a take that is otherwise finished.
  private static func reportedResolution(_ file: URL) -> SceneSubtitles.Resolution? {
    guard
      let data = try? Data(contentsOf: file),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let width = firstInt(object["width"]),
      let height = firstInt(object["height"]),
      width > 0, height > 0
    else { return nil }
    return SceneSubtitles.Resolution(width: width, height: height)
  }

  /// One number, whether the recorder reported one or a list of them.
  private static func firstInt(_ value: Any?) -> Int? {
    if let number = value as? Int { return number }
    if let numbers = value as? [Int] { return numbers.first }
    return nil
  }

  /// Mirrors `DisplayRecorder.evenFloor`. Encoders reject odd dimensions, so the
  /// movie is even and a sidecar that claimed otherwise would be off by a pixel.
  private static func evenFloor(_ value: Int) -> Int {
    max(2, value - (value % 2))
  }

  private static func record(_ arguments: [String]) throws {
    var arguments = arguments
    let paths = try resolvePaths()
    let recorder = RecorderController(paths: paths)
    guard let action = arguments.first else {
      throw DemoCtlError.usage("record needs start, stop, status, warmup or preflight")
    }
    arguments.removeFirst()

    switch action {
    case "start":
      let display = try displayOption(&arguments)
      let fps = try fpsOption(&arguments)
      let output = try takeOption(&arguments, "--output").map { URL(fileURLWithPath: $0) }
        ?? recorder.nextOutputURL(scene: "manual", stamp: Self.stamp())
      try rejectUnknown(arguments, command: "record start")
      try recorder.start(output: output, display: display, fps: fps)
      if display == "all" {
        print("recording: one file per display, next to \(output.path)")
      } else {
        print("recording: \(output.path)")
      }

    case "stop":
      report(try recorder.stop())

    case "warmup":
      try warmup(&arguments, recorder: recorder, paths: paths)

    case "status":
      if let pid = recorder.runningPID { print("recording (pid \(pid))") } else { print("idle") }

    case "preflight":
      let granted = try recorder.preflight()
      print(granted ? "screen recording: granted" : "screen recording: denied")
      if !granted { throw DemoCtlError.usage("grant Screen Recording to DemoRecorder.app, then relaunch it") }

    default:
      throw DemoCtlError.usage("record: unknown action \"\(action)\"")
    }
  }

  // MARK: - Subtitles

  /// Burns a take's ASS sidecar into a copy of the movie.
  ///
  /// Deliberately a host-side step. ffmpeg is not installed in the recording VM
  /// and is on a typical developer's Mac, and putting one in the guest would
  /// spend VM time re-encoding a movie that has to be copied to the host anyway
  /// (`vm/tart/fetch-recordings.sh`). So a missing ffmpeg is reported as exactly
  /// that, with the command to run somewhere else, and never quietly skipped: a
  /// "burned" take that turns out to have no subtitles in it is precisely the
  /// silent difference between two takes this lab exists to prevent.
  private static func subtitle(_ arguments: [String]) throws {
    var arguments = arguments
    guard let action = arguments.first else {
      throw DemoCtlError.usage("subtitle needs an action: burn <movie> [--ass <file>] [--output <file>]")
    }
    arguments.removeFirst()
    guard action == "burn" else {
      throw DemoCtlError.usage("subtitle: unknown action \"\(action)\" (burn)")
    }

    let assOption = try takeOption(&arguments, "--ass")
    let outputOption = try takeOption(&arguments, "--output")
    try rejectUnknown(arguments, command: "subtitle burn")
    guard let moviePath = arguments.first else {
      throw DemoCtlError.usage("subtitle burn needs the movie to burn the subtitles into")
    }
    guard arguments.count == 1 else {
      throw DemoCtlError.usage("subtitle burn: unexpected argument \"\(arguments[1])\"")
    }

    let movie = URL(fileURLWithPath: moviePath)
    let subtitles = assOption.map { URL(fileURLWithPath: $0) } ?? LabPaths.subtitleFile(for: movie)
    let output = outputOption.map { URL(fileURLWithPath: $0) } ?? LabPaths.burnedInFile(for: movie)

    guard FileManager.default.fileExists(atPath: movie.path) else {
      throw DemoCtlError.usage("no movie at \(movie.path)")
    }
    guard FileManager.default.fileExists(atPath: subtitles.path) else {
      throw DemoCtlError.usage(
        """
        no subtitle sidecar at \(subtitles.path).
        `democtl take` writes one next to every movie it records, and
        vm/tart/fetch-recordings.sh copies it out of the guest with the movie.
        Pass --ass <file> to burn a different one in.
        """
      )
    }
    // Reading and writing one path truncates it, and the source is the single
    // copy of a take that cannot be regenerated.
    guard output.standardizedFileURL != movie.standardizedFileURL else {
      throw DemoCtlError.usage("--output must not be the movie itself (\(movie.path))")
    }

    let ffmpegArguments = burnArguments(movie: movie, subtitles: subtitles, output: output)

    // Two renderers, tried in order, because "ffmpeg is installed" is not the
    // same question as "ffmpeg can read an ASS file". A stock Homebrew ffmpeg
    // on this machine reports no `ass` filter at all, while mpv links libass
    // directly and always can. Falling through to mpv turns a hard stop into a
    // burn that works, and the choice is printed so nobody has to guess which
    // one produced the file.
    let renderer: (name: String, tool: URL, arguments: [String])
    if let ffmpeg = locateFFmpeg(), rendersASS(ffmpeg) {
      renderer = ("ffmpeg", ffmpeg, ffmpegArguments)
    } else if let mpv = locate("mpv") {
      renderer = ("mpv", mpv, mpvBurnArguments(movie: movie, subtitles: subtitles, output: output))
    } else {
      let ffmpeg = locateFFmpeg()
      throw DemoCtlError.usage(
        """
        nothing on this machine can burn the subtitles in, so nothing was written.
        \(ffmpeg.map { "\($0.path) exists but was built without libass, so it has no `ass` filter." }
          ?? "ffmpeg is not installed.")
        mpv is not installed either, and it is the easier fix because it always ships libass.

        This step is host side on purpose: the recording VM has no ffmpeg, and the movie and its
        sidecar have to be copied to the host anyway (vm/tart/fetch-recordings.sh).

          brew install mpv          # or a build of ffmpeg that lists `ass` in -filters

        The sidecar itself is fine. Any player that reads ASS can also just load it beside the
        movie without burning anything: mpv \(quoted(movie.path)) --sub-file \(quoted(subtitles.path))
        """
      )
    }

    print("burning \(subtitles.path)")
    print("     into \(output.path)")
    print("     with \(renderer.name)")
    let process = Process()
    process.executableURL = renderer.tool
    process.arguments = renderer.arguments
    // Inherited stdio: a burn is minutes of re-encoding, and the renderer's own
    // progress is the only sign it is still working.
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw DemoCtlError.usage(
        "\(renderer.name) failed (exit \(process.terminationStatus)); its own diagnosis is above this line."
      )
    }

    // ffmpeg can exit 0 having written a header and little else, so the result
    // is checked rather than trusted, exactly as a recording is.
    let attributes = try? FileManager.default.attributesOfItem(atPath: output.path)
    let size = attributes?[.size] as? Int
    guard let size, size >= minimumUsableMovieBytes else {
      throw DemoCtlError.recordingFailed([
        "\(output.path) is \(size.map { "only \($0) bytes" } ?? "not on disk") "
          + "after ffmpeg reported success",
      ])
    }
    print("wrote \(output.path) (\(size / 1_048_576) MB)")
  }

  /// A finalized movie carries a moov atom and real frames. Anything smaller is
  /// a stub, the same threshold `RecorderController` holds a take to.
  private static let minimumUsableMovieBytes = 65_536

  /// mpv renders the subtitles through libass in its own video chain, so `--vf=sub`
  /// is what actually bakes them in; without it the encode is a clean copy.
  /// h264 rather than HEVC because mpv tags its HEVC output `hev1`, which
  /// AVFoundation refuses to open, and a file QuickTime cannot play is not a
  /// deliverable.
  ///
  /// The bitrate is capped because `h264_videotoolbox` left to itself targets a
  /// quality, not a size, and a 60fps desktop capture is nearly still: it spent
  /// 221 MB on 114 seconds of a take that is mostly flat panels. 12 Mbps is far
  /// more than this content needs and an order of magnitude friendlier to a
  /// README or a web page.
  private static func mpvBurnArguments(movie: URL, subtitles: URL, output: URL) -> [String] {
    [
      movie.path,
      "--sub-file=\(subtitles.path)",
      "--sub-visibility=yes",
      "--no-config",
      "--vf=lavfi=[scale=iw*0.8666666667:ih*0.8666666667:flags=lanczos,pad=iw/0.8666666667:ih/0.8666666667:(ow-iw)/2:oh*0.04:color=0x\(FilmTheme.background)],sub",
      "--no-audio",
      "--o=\(output.path)",
      "--ovc=h264_videotoolbox",
      "--ovcopts=profile=high,b=12000000,maxrate=16000000,bufsize=24000000",
      "--really-quiet",
    ]
  }

  private static func locate(_ tool: String) -> URL? {
    for directory in searchPath() {
      let candidate = URL(fileURLWithPath: directory).appendingPathComponent(tool)
      if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    return nil
  }

  private static func burnArguments(movie: URL, subtitles: URL, output: URL) -> [String] {
    [
      "-y",
      "-i", movie.path,
      "-vf", "scale=iw*0.8666666667:ih*0.8666666667:flags=lanczos,pad=iw/0.8666666667:ih/0.8666666667:(ow-iw)/2:oh*0.04:color=0x\(FilmTheme.background),ass=filename=\(filterEscaped(subtitles.path))",
      // Named rather than left to the container's default: a demo has to play
      // everywhere, and a silently chosen mpeg4 stream does not.
      "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p",
      // Copied, never re-encoded. A take with no audio track simply has none.
      "-c:a", "copy",
      output.path,
    ]
  }

  /// Escapes a path for an ffmpeg filter argument.
  ///
  /// ffmpeg unescapes a filtergraph twice: `:` separates one filter option from
  /// the next, and `,` and `;` separate filters from each other. A path holding
  /// any of them would be read as graph syntax and produce a confusing parse
  /// error, or worse, a graph that runs without the subtitles in it.
  private static func filterEscaped(_ path: String) -> String {
    var out = path.replacingOccurrences(of: "\\", with: "\\\\")
    for character in [":", "'", "[", "]", ",", ";"] {
      out = out.replacingOccurrences(of: character, with: "\\" + character)
    }
    return out
  }

  /// Where ffmpeg is looked for: `PATH`, plus Homebrew's two prefixes.
  ///
  /// Those two are added because `democtl` is often started by something with a
  /// minimal environment (`tart exec`, launchd), where a perfectly good Homebrew
  /// ffmpeg is installed and invisible.
  private static func searchPath() -> [String] {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let entries = path.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    var seen = Set<String>()
    return (entries + ["/opt/homebrew/bin", "/usr/local/bin"]).filter { seen.insert($0).inserted }
  }

  private static func locateFFmpeg() -> URL? {
    for directory in searchPath() {
      let candidate = URL(fileURLWithPath: directory).appendingPathComponent("ffmpeg")
      if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    return nil
  }

  /// Whether this ffmpeg can render subtitles at all.
  ///
  /// The `ass` filter is libass, and libass is an optional build dependency: a
  /// perfectly working ffmpeg can have been built without it, and Homebrew has
  /// shipped such a bottle. Asking first turns ffmpeg's "No such filter", buried
  /// in a page of filtergraph noise, into a sentence saying what to install.
  private static func rendersASS(_ ffmpeg: URL) -> Bool {
    // An unreadable answer is not proof of absence: let the burn run and let
    // ffmpeg speak for itself rather than refusing the take on a guess.
    guard let result = try? Shell.run(ffmpeg, ["-hide_banner", "-filters"]), result.succeeded else {
      return true
    }
    // A listing row reads `` .. ass  V->V  Render ASS subtitles ...``, so the
    // name is the second field. Matched as a field and not as a substring,
    // because plenty of filter descriptions contain the word.
    return result.standardOutput.split(separator: "\n").contains { line in
      let fields = line.split(separator: " ", omittingEmptySubsequences: true)
      return fields.count >= 2 && fields[1] == "ass"
    }
  }

  /// Shell quoting, for a command printed for somebody to paste into a terminal
  /// on another machine. Display only: nothing here is ever run through a shell.
  private static func quoted(_ token: String) -> String {
    let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/:=-")
    guard !token.isEmpty, token.allSatisfy({ safe.contains($0) }) else {
      return "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    return token
  }

  /// Records a few seconds and throws the file away.
  ///
  /// macOS 15 and later periodically re-confirm screen capture for any app that
  /// does not use `SCContentSharingPicker`, and that panel has already appeared
  /// on camera mid-take in a real run. Provoking it deliberately before the
  /// golden snapshot is the only way to keep it out of a take: the entitlement
  /// that suppresses the panel needs Apple's approval, and the MDM key that
  /// suppresses it needs a real MDM server.
  private static func warmup(
    _ arguments: inout [String],
    recorder: RecorderController,
    paths: LabPaths
  ) throws {
    let seconds = try secondsOption(&arguments, default: 3)
    try rejectUnknown(arguments, command: "record warmup")

    // Written into the lab's run directory, never into `recordings/`: this file
    // is a probe, and it must not be mistaken for a take.
    let output = paths.runRoot.appendingPathComponent("warmup-\(Self.stamp()).mov")
    try recorder.start(output: output, display: "main", fps: 60)
    print("warmup: recording \(seconds)s — approve the screen-capture panel now if it appears")
    Shell.sleep(.seconds(seconds))

    // Verified like any other take on purpose: a warmup that quietly produced
    // nothing would have proved nothing about the consent state either.
    let outcome = try recorder.stop()
    for file in outcome.outputs {
      try FileManager.default.removeItem(at: file)
    }
    print("warmup: capture confirmed, \(outcome.outputs.count) throwaway file(s) deleted")
  }

  /// Prints what the recorder actually wrote. Dropped frames are a visible
  /// stutter and the classic way two takes differ without anyone noticing, so
  /// they are reported even on the success path.
  private static func report(_ outcome: RecordingOutcome) {
    for file in outcome.outputs { print("wrote \(file.path)") }
    if let dropped = outcome.droppedFrames, dropped > 0 {
      let total = outcome.frames.map { " of \($0)" } ?? ""
      print("warning: the recorder dropped \(dropped) frame(s)\(total); re-shoot if the motion stutters")
    }
  }

  private static func secondsOption(_ arguments: inout [String], default fallback: Int) throws -> Int {
    guard let raw = try takeOption(&arguments, "--seconds") else { return fallback }
    guard let seconds = Int(raw), (1...600).contains(seconds) else {
      throw DemoCtlError.usage("--seconds expects an integer in 1...600, got \"\(raw)\"")
    }
    return seconds
  }

  private static func events(_ arguments: [String]) throws {
    var arguments = arguments
    _ = takeFlag(&arguments, "--all")
    try rejectUnknown(arguments, command: "events")
    let paths = try resolvePaths()
    let log = EventLog(url: paths.eventLog)
    let all = log.events(since: 0)
    guard !all.isEmpty else {
      print("no events yet (\(paths.eventLog.path))")
      return
    }
    for event in all {
      print("\(event.event)\tprofile=\(event.profile)\tworkspace=\(event.workspace)\tdisplay=\(event.display)")
    }
  }

  private static func config(_ arguments: [String]) throws {
    var arguments = arguments
    let printOnly = takeFlag(&arguments, "--print")
    try rejectUnknown(arguments, command: "config")
    let paths = try resolvePaths()

    guard let text = try? String(contentsOf: paths.configFile, encoding: .utf8) else {
      throw DemoCtlError.usage("no rendered config at \(paths.configFile.path); run `democtl seed`")
    }
    if printOnly {
      print(text)
      return
    }
    let report = ConfigValidator.report(text)
    for warning in report.warnings { print("warn: \(warning)") }
    guard report.isClean else { throw DemoCtlError.configInvalid(report.problems) }
    print("config ok: \(paths.configFile.path)")
  }

  private static func restore(_ arguments: [String]) throws {
    var arguments = arguments
    let explicit = try takeOption(&arguments, "--tatami-app")
    try rejectUnknown(arguments, command: "restore")
    let paths = try resolvePaths()

    guard let guardian = try restoreGuard(paths: paths, explicit: explicit) else {
      print("nothing to restore: no defaults snapshot at \(paths.defaultsSnapshotRoot.path)")
      return
    }
    // Tatami holds its own image of the domain and writes it back on change, so
    // the import has to land on a stopped app.
    TatamiProcess.quitAll()
    try guardian.restore()
    print("restored the \(guardian.domain) defaults domain")
  }

  private static func stamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
  }

}

extension DemoCtlError {
  fileprivate var isUsage: Bool {
    if case .usage = self { return true }
    return false
  }
}
