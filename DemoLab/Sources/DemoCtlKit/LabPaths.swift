// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import DemoAppKit

// MARK: - LabPaths

/// Every path the Demo Lab touches.
///
/// The central design decision lives here: the lab **isolates** rather than
/// resets. Tatami accepts `--tatami-config-home` and `--tatami-socket-path`, so
/// the whole demo runs against its own config directory and its own socket, and
/// a real installed Tatami's `~/.config/tatami` is never read, written, or
/// backed up. "Reset" then means deleting one directory, which is inherently
/// idempotent.
///
/// The one thing isolation does *not* cover is `UserDefaults` — Tatami's
/// preferences domain is keyed by bundle id, not by config home. ``DefaultsGuard``
/// handles that separately by backing up the few keys the lab has to change.
public struct LabPaths: Sendable {

  // MARK: Lifecycle

  public init(packageRoot: URL) {
    self.packageRoot = packageRoot
  }

  // MARK: Public

  /// The DemoLab package directory, located by walking up from the running
  /// executable until a directory containing `Package.swift` and `Sources` is
  /// found. Works for `.build/debug/democtl`, `.build/release/democtl`, and a
  /// copy placed in `.build/DemoLab/bin`.
  public static func discoverPackageRoot(
    from executable: URL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
  ) -> URL? {
    if let override = ProcessInfo.processInfo.environment["DEMOLAB_ROOT"], !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    // The executable path covers `.build/{debug,release}/democtl` and a copy in
    // `.build/DemoLab/bin`. `#filePath` covers the test bundle, whose argv[0] is
    // the test runner rather than anything under the package. Both are verified
    // against real files before being accepted, so a stale compile-time path
    // simply fails the check instead of pointing somewhere wrong.
    let starts = [
      executable.deletingLastPathComponent(),
      URL(fileURLWithPath: #filePath).deletingLastPathComponent(),
      Bundle.main.bundleURL,
    ]
    for start in starts {
      var directory = start
      for _ in 0..<8 {
        let manifest = directory.appendingPathComponent("Package.swift")
        let sources = directory.appendingPathComponent("Sources/DemoAppKit")
        if FileManager.default.fileExists(atPath: manifest.path),
           FileManager.default.fileExists(atPath: sources.path) {
          return directory
        }
        let parent = directory.deletingLastPathComponent()
        if parent == directory { break }
        directory = parent
      }
    }
    return nil
  }

  public let packageRoot: URL

  public var buildRoot: URL { packageRoot.appendingPathComponent(".build") }
  /// Where `scripts/bundle-apps.sh` assembles the `.app` bundles.
  public var bundlesRoot: URL { buildRoot.appendingPathComponent("DemoLab") }
  public var binRoot: URL { bundlesRoot.appendingPathComponent("bin") }

  /// The pristine `UserDefaults` snapshot and the stamp naming the domain it
  /// came from. Deliberately **outside** ``labRoot``: `democtl reset` removes
  /// that whole tree between takes, and a snapshot destroyed there would let the
  /// next `seed` export an already-suppressed domain and call it pristine —
  /// after which `democtl restore` can never undo the suppression on the user's
  /// real Tatami. ``DefaultsGuard`` owns the file names inside this directory so
  /// the stamp cannot drift away from the export it describes.
  public var defaultsSnapshotRoot: URL { buildRoot.appendingPathComponent("defaults-snapshot") }

  /// Everything the lab creates at run time. `democtl reset` deletes this whole
  /// tree, so nothing outside it may hold demo state.
  public var labRoot: URL { buildRoot.appendingPathComponent("lab") }
  /// Passed to Tatami as `--tatami-config-home`; it appends `tatami/`.
  public var configHome: URL { labRoot.appendingPathComponent("xdg") }
  /// The directory Tatami actually reads, i.e. `<configHome>/tatami`.
  public var tatamiConfigDirectory: URL { configHome.appendingPathComponent("tatami") }
  public var configFile: URL { tatamiConfigDirectory.appendingPathComponent("config.toml") }
  public var layoutsFile: URL { tatamiConfigDirectory.appendingPathComponent("layouts.json") }
  public var profileSessionFile: URL {
    tatamiConfigDirectory.appendingPathComponent("profile-session.json")
  }

  public var runRoot: URL { labRoot.appendingPathComponent("run") }
  /// Kept short on purpose: a UNIX socket path has a hard `sun_path` limit and
  /// Tatami's CLI does not length-check an override before truncating it.
  public var socketPath: URL { runRoot.appendingPathComponent("t.sock") }
  /// Where the demo apps and the overlay bind their control sockets.
  ///
  /// `democtl` exports it as `DEMOLAB_CONTROL_DIR` for itself and for everything
  /// it launches, so the lab's sockets live with the rest of the lab state and
  /// `democtl reset` removes them with it. Kept to one short component for the
  /// same reason ``socketPath`` is: a UNIX socket path has a hard `sun_path`
  /// limit, and the socket's own leaf name is added on top of this directory.
  public var controlDirectory: URL { runRoot.appendingPathComponent("ctl") }
  public var eventLog: URL { runRoot.appendingPathComponent("events.tsv") }
  public var recorderPidFile: URL { runRoot.appendingPathComponent("recorder.pid") }
  /// The recorder's machine-readable outcome: it shares the pid file's basename
  /// and is written before the pid file goes away, so the pid-file wait doubles
  /// as the barrier for reading it. A cross-process contract with DemoRecorder,
  /// like the exit codes.
  public var recorderResultFile: URL {
    recorderPidFile.deletingPathExtension().appendingPathExtension("json")
  }

  public var seedStamp: URL { runRoot.appendingPathComponent("seed.json") }

  public var recordingsRoot: URL { packageRoot.appendingPathComponent("recordings") }

  // MARK: - Take sidecars

  /// The subtitle sidecar for a take: same directory, same basename, `.ass`.
  ///
  /// Static, and shaped only by the movie's own path, because three places have
  /// to agree on it and none of them can ask another: `democtl take` writes it,
  /// `democtl subtitle burn` reads it, and `vm/tart/fetch-recordings.sh` copies
  /// it out of the guest. A sidecar named by a rule that lives in only one of
  /// them is a sidecar the other two lose.
  public static func subtitleFile(for movie: URL) -> URL {
    movie.deletingPathExtension().appendingPathExtension("ass")
  }

  /// The machine-readable half of the same record: every narration event with
  /// its times, for a tool that is not a subtitle renderer.
  public static func timelineFile(for movie: URL) -> URL {
    movie.deletingPathExtension().appendingPathExtension("timeline.json")
  }

  /// Where `democtl subtitle burn` puts the burned-in copy.
  ///
  /// Beside the source and never over it. Burning is a re-encode, the source is
  /// the one copy of a take that cannot be regenerated, and ffmpeg reading and
  /// writing the same path truncates it.
  public static func burnedInFile(for movie: URL) -> URL {
    let base = movie.deletingPathExtension().lastPathComponent
    let ext = movie.pathExtension.isEmpty ? "mov" : movie.pathExtension
    return movie.deletingLastPathComponent().appendingPathComponent("\(base)-subtitled.\(ext)")
  }

  public var templateFile: URL {
    packageRoot.appendingPathComponent("config/tatami-demo.toml.in")
  }

  public var hookScript: URL {
    packageRoot.appendingPathComponent("config/hooks/demolab-hook")
  }

  public var scenesRoot: URL { packageRoot.appendingPathComponent("scenes") }

  public func sceneFile(_ name: String) -> URL {
    (DemoLocale.selected == .en ? scenesRoot : scenesRoot.appendingPathComponent(DemoLocale.selected.rawValue))
      .appendingPathComponent("\(name).json")
  }

  public func appBundle(_ name: String) -> URL {
    bundlesRoot.appendingPathComponent("\(name).app")
  }

  public var recorderBundle: URL { bundlesRoot.appendingPathComponent("DemoRecorder.app") }

  public func ensureRuntimeDirectories() throws {
    for directory in [labRoot, configHome, tatamiConfigDirectory, runRoot, controlDirectory] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
  }

}
