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
          let decoder = TOMLDecoder()
          return try decoder.decode(AppConfig.self, from: toml)
        },
        encode: { config in
          let encoder = TOMLEncoder()
          encoder.outputFormatting = [.sortedKeys]
          return try encoder.encode(config)
        }
      ),
      default: AppConfig()
    ]
  }
}
