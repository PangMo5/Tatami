// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - DefaultsGuard

/// The one piece of state the lab cannot isolate.
///
/// `--tatami-config-home` moves `config.toml`, `layouts.json`,
/// `profile-session.json`, and the log into the lab's own directory, but
/// `UserDefaults` is keyed by bundle identifier, so the lab's Tatami and a real
/// installed Tatami share one preferences domain. Three windows live in there
/// that would ruin a take:
///
/// - **Guided Setup** opens when `onboarding.resumeAfterRelaunch` is true, or
///   when onboarding was never completed and the active profile is empty. The
///   `resumeAfterRelaunch` branch short-circuits the others, so a leftover
///   `true` reopens it even on a fully configured install.
/// - **What's New** floats above everything and activates the app when the
///   stored version differs from the running one.
/// - **Any window AppKit restored from the last session**, Settings above all.
///   Window restoration state is stored per bundle id, not per config home, so
///   an operator who last used Settings gets Settings back on camera.
///
/// Rather than write those keys and leave them changed, the lab snapshots the
/// whole domain first and can put it back exactly. The snapshot lives outside
/// ``LabPaths/labRoot`` so `democtl reset` cannot destroy it between takes; see
/// ``LabPaths/defaultsSnapshotRoot``.
public struct DefaultsGuard: Sendable {

  // MARK: Lifecycle

  public init(domain: String, snapshotDirectory: URL) {
    self.domain = domain
    self.snapshotDirectory = snapshotDirectory
  }

  // MARK: Public

  public let domain: String
  public let snapshotDirectory: URL

  /// The exported domain. `defaults export` writes a plist, and it records only
  /// the key/value pairs — never which domain they came from.
  public static func backupURL(in directory: URL) -> URL {
    directory.appendingPathComponent("defaults-backup.plist")
  }

  /// The missing half of the snapshot: the bundle identifier the export was
  /// taken from. `defaults import` replaces whichever domain it is handed, and
  /// this repo ships two bundle ids on purpose (`dev.PangMo5.Tatami` and
  /// `dev.PangMo5.Tatami.debug`), so a restore that guessed the domain would
  /// eventually overwrite the wrong Tatami's real preferences.
  public static func domainStampURL(in directory: URL) -> URL {
    directory.appendingPathComponent("domain.json")
  }

  /// The domain a previous ``captureIfNeeded()`` snapshotted, or nil when the
  /// stamp is absent or unreadable.
  public static func capturedDomain(in directory: URL) -> String? {
    guard
      let data = try? Data(contentsOf: domainStampURL(in: directory)),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let domain = object["domain"] as? String,
      !domain.isEmpty
    else { return nil }
    return domain
  }

  public var backup: URL { Self.backupURL(in: snapshotDirectory) }
  public var domainStamp: URL { Self.domainStampURL(in: snapshotDirectory) }

  public var hasBackup: Bool { FileManager.default.fileExists(atPath: backup.path) }

  /// Snapshots the domain, once. A second call is a no-op so `democtl seed`
  /// stays idempotent and never overwrites the pristine snapshot with one taken
  /// mid-demo — and, because the snapshot outlives `democtl reset`, that holds
  /// across a whole shoot rather than only within one lab lifetime.
  ///
  /// An existing snapshot from a *different* bundle id is an error rather than a
  /// no-op: it means an earlier shoot against another Tatami was never restored,
  /// and suppressing this domain too would leave it with nothing to restore from.
  public func captureIfNeeded() throws {
    if hasBackup {
      guard let captured = Self.capturedDomain(in: snapshotDirectory) else {
        throw DemoCtlError.defaultsSnapshotUnstamped(backup: backup.path, stamp: domainStamp.path)
      }
      guard captured == domain else {
        throw DemoCtlError.defaultsSnapshotForeign(
          captured: captured,
          requested: domain,
          backup: backup.path
        )
      }
      return
    }
    try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
    try Shell.require(Self.defaultsTool, ["export", domain, backup.path])
    // Stamp after the export, so a half-made snapshot is never mistaken for a
    // complete one: no export means no stamp, and no stamp is a loud failure.
    let stamp = try JSONSerialization.data(
      withJSONObject: ["domain": domain],
      options: [.prettyPrinted, .sortedKeys]
    )
    try stamp.write(to: domainStamp, options: .atomic)
  }

  /// Suppresses Guided Setup, What's New, and window restoration for the given
  /// app version.
  ///
  /// Writes go through the `defaults` tool rather than straight to the plist so
  /// `cfprefsd` stays coherent; that is also why Tatami must already be stopped
  /// when this runs, since a live process holds its own defaults image and
  /// would write it back over these values.
  public func suppressFirstRunWindows(appVersion: String?) throws {
    // Start from an empty domain rather than patching keys.
    //
    // Setting `ApplePersistenceIgnoreState` and `NSQuitAlwaysKeepsWindows` is
    // not enough on its own: SwiftUI restores a `Window` scene through its own
    // state, and a measured take still opened Tatami's Settings window into the
    // middle of the shot. Patching individual keys also cannot remove state
    // whose name we do not know. Wiping first is only safe because the whole
    // domain was exported a moment ago and `democtl restore` puts it back
    // byte for byte, which is exactly why the snapshot is taken before this.
    _ = try? Shell.run(Self.defaultsTool, ["delete", domain])

    try Shell.require(
      Self.defaultsTool,
      ["write", domain, "onboarding.completedSchemaVersion", "-int", "1"]
    )
    if let appVersion {
      try Shell.require(
        Self.defaultsTool,
        ["write", domain, "whatsNew.lastShownVersion", "-string", appVersion]
      )
    }

    // Belt and braces on the now-empty domain: these also stop AppKit writing
    // restoration state back during the session, so a second `seed` in the same
    // shoot starts from the same place as the first.
    try Shell.require(Self.defaultsTool, ["write", domain, "ApplePersistenceIgnoreState", "-bool", "true"])
    try Shell.require(Self.defaultsTool, ["write", domain, "NSQuitAlwaysKeepsWindows", "-bool", "false"])
  }

  /// Puts the domain back exactly as it was and drops the snapshot.
  public func restore() throws {
    guard hasBackup else { return }
    try Shell.require(Self.defaultsTool, ["import", domain, backup.path])
    // The import already landed, so this is not a failed restore — but a
    // snapshot left on disk would be imported again by the next `restore`, over
    // a domain that is already pristine, so it has to be said out loud.
    do {
      try FileManager.default.removeItem(at: snapshotDirectory)
    } catch {
      throw DemoCtlError.defaultsSnapshotNotCleared(
        directory: snapshotDirectory.path,
        domain: domain,
        reason: "\(error)"
      )
    }
  }

  // MARK: Private

  private static let defaultsTool = URL(fileURLWithPath: "/usr/bin/defaults")

}
