import Dependencies
import Foundation
import Sharing
import TOML

extension SharedReaderKey where Self == FileStorageKey<AppConfig>.Default {
  /// `@Shared(.tatamiConfig)` reads and writes the user's config TOML at
  /// `$XDG_CONFIG_HOME/tatami/config.toml`, falling back to an empty default
  /// `AppConfig` (with a `Default` profile) when the file is missing.
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
          // "Shortcuts" reports fire from inside HotKey's decode; the pass
          // confirms a still-broken shortcut quietly and resolves a fixed one.
          reporter.beginPass(["Shortcuts"])
          do {
            let decoder = TOMLDecoder()
            let config = try decoder.decode(AppConfig.self, from: toml)
            reporter.commitPass(["Shortcuts"])
            reporter.resolve("Config")
            return config
          } catch {
            // Decode failed wholesale — shortcut state is unknown, keep it.
            reporter.abortPass(["Shortcuts"])
            reporter.report(
              "Config",
              "config.toml could not be parsed — keeping previous settings",
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
              "config.toml could not be saved",
              ErrorReportClient.describe(error)
            )
            throw error
          }
        }
      ),
      default: AppConfig()
    ]
  }
}
