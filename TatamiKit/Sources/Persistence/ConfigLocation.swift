// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Resolves the location of Tatami's `config.toml`, honoring the
/// XDG Base Directory specification when `XDG_CONFIG_HOME` is set.
public enum ConfigLocation {
  public static let directoryName = "tatami"
  public static let filename = "config.toml"

  /// Returns `$XDG_CONFIG_HOME/tatami/` when set, otherwise `~/.config/tatami/`.
  public static var directory: URL {
    if let custom = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"],
       !custom.isEmpty
    {
      return URL(fileURLWithPath: custom, isDirectory: true)
        .appendingPathComponent(directoryName, isDirectory: true)
    }
    return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent(".config", isDirectory: true)
      .appendingPathComponent(directoryName, isDirectory: true)
  }

  public static var fileURL: URL {
    directory.appendingPathComponent(filename, isDirectory: false)
  }

  /// Ensures the config directory exists. Idempotent.
  public static func ensureDirectoryExists() throws {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
  }
}
