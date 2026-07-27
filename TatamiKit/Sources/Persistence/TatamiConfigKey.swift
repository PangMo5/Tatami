import Dependencies
import Foundation
import Sharing
import TOML

extension SharedReaderKey where Self == FileStorageKey<AppConfig>.Default {
  /// `@Shared(.tatamiConfig)` reads and writes the user's config TOML at
  /// `$XDG_CONFIG_HOME/tatami/config.toml`, falling back to a seeded default
  /// `AppConfig` (a `Default` profile + the recommended starter shortcuts)
  /// when the file is missing — so a fresh install is usable out of the box.
  /// The seed only fills a missing file; an existing config decodes as-is
  /// (`Shortcuts.recommended` is deliberately not a per-field decode fallback).
  ///
  /// The directory is created on first access; serialization uses TOMLKit so
  /// existing dotfiles-style edits made outside the app are preserved.
  public static var tatamiConfig: Self {
    Self[
      .fileStorage(
        ConfigLocation.fileURL,
        decode: { data in
          let toml = String(decoding: data, as: UTF8.self)
          @Dependency(\.errorReporter) var reporter
          // "Shortcuts" reports fire from inside HotKey's decode and
          // "Settings" from the field-tolerant decode helper; the pass
          // confirms a still-broken value quietly and resolves a fixed one.
          reporter.beginPass(["Shortcuts", "Settings"])
          do {
            let decoder = TOMLDecoder()
            let config = try decoder.decode(AppConfig.self, from: toml)
            reporter.commitPass(["Shortcuts", "Settings"])
            reporter.resolve("Config")
            return config
          } catch {
            // Decode failed wholesale — shortcut/typo state is unknown, keep it.
            reporter.abortPass(["Shortcuts", "Settings"])
            reporter.report(
              "Config",
              String(localized: "config.toml could not be parsed — keeping previous settings"),
              ErrorReportClient.describe(error)
            )
            FileHandle.standardError.write(
              Data("[Tatami] config.toml decode failed: \(error)\n".utf8)
            )
            throw error
          }
        },
        encode: { config in
          @Dependency(\.errorReporter) var reporter
          do {
            let encoder = TOMLEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(config)
            reporter.resolve("ConfigSave")
            return data
          } catch {
            reporter.report(
              "ConfigSave",
              String(localized: "config.toml could not be saved"),
              ErrorReportClient.describe(error)
            )
            throw error
          }
        }
      ),
      default: AppConfig(settings: AppSettings(shortcuts: .recommended))
    ]
  }
}
