// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Dependencies
import Foundation
import Sharing
import TOML

// MARK: - TatamiConfigKey

/// Uses a dedicated persistence lane for live files. In-memory dependency
/// storage remains synchronous and isolated in tests and previews.
public struct TatamiConfigKey: SharedKey {

  // MARK: Public

  public var id: FileStorageKeyID {
    base.id
  }

  public func load(
    context: LoadContext<AppConfig>,
    continuation: LoadContinuation<AppConfig>,
  ) {
    if let store { store.load(continuation) }
    else { base.load(context: context, continuation: continuation) }
  }

  public func subscribe(
    context: LoadContext<AppConfig>,
    subscriber: SharedSubscriber<AppConfig>,
  ) -> SharedSubscription {
    if let store { return store.subscribe(subscriber) }
    return base.subscribe(
      context: context,
      subscriber: SharedSubscriber(
        callback: { result in
          if case .success(.some(let decoded)) = result {
            let value = TatamiConfigTransactionCoordinator.shared
              .preservingSessionProfile(in: decoded)
            if TatamiConfigTransactionCoordinator.shared.shouldSuppressFileEcho(value) {
              return
            }
            subscriber.yield(value)
          } else {
            subscriber.yield(with: result)
          }
        },
        onLoading: { subscriber.yieldLoading($0) },
      ),
    )
  }

  public func save(
    _ value: AppConfig,
    context: SaveContext,
    continuation: SaveContinuation,
  ) {
    if context == .didSet, ConfigPublication.isPublishing {
      continuation.resume()
      return
    }
    if
      context == .didSet,
      store == nil,
      TatamiConfigTransactionCoordinator.shared.consumeSuppressedDidSet(value)
    {
      continuation.resume()
      return
    }
    if let store {
      store.save(value, continuation: continuation)
      return
    }
    // A user-initiated FileStorage save is immediate and cancels any old
    // coalesced work inherited from a previous app version. Record its echo
    // only after storage confirms success.
    base.save(
      value,
      context: .userInitiated,
      continuation: SaveContinuation { result in
        switch result {
        case .success:
          TatamiConfigTransactionCoordinator.shared.recordSelfWrite(value)
          continuation.resume()

        case .failure(let error):
          continuation.resume(throwing: error)
        }
      },
    )
  }

  // MARK: Internal

  let base: FileStorageKey<AppConfig>
  var store: AsyncConfigStore? = nil

}

extension SharedReaderKey where Self == TatamiConfigKey.Default {
  /// `@Shared(.tatamiConfig)` reads and writes the user's config TOML at
  /// `$XDG_CONFIG_HOME/tatami/config.toml`, falling back to a seeded default
  /// `AppConfig` (a `Default` profile + the recommended starter shortcuts)
  /// when the file is missing — so a fresh install is usable out of the box.
  /// The seed only fills a missing file; an existing config decodes as-is.
  public static var tatamiConfig: Self {
    let storage = FileStorageKey<AppConfig>.fileStorage(
      ConfigLocation.fileURL,
      decode: decodeTatamiConfig,
      encode: encodeTatamiConfig,
    )
    @Dependency(\.defaultFileStorage) var fileStorage
    return Self[
      TatamiConfigKey(base: storage, store: fileStorage == .fileSystem ? .shared : nil),
      default: AppConfig(settings: AppSettings(shortcuts: .recommended)),
    ]
  }
}

// MARK: - Serialization

func decodeTatamiConfig(_ data: Data) throws -> AppConfig {
  let toml = String(decoding: data, as: UTF8.self)
  @Dependency(\.errorReporter) var reporter
  // "Shortcuts" reports fire from inside HotKey's decode and "Settings"
  // from the field-tolerant decode helper.
  reporter.beginPass(["Shortcuts", "Settings"])
  do {
    let config = try TOMLDecoder().decode(AppConfig.self, from: toml)
    reporter.commitPass(["Shortcuts", "Settings"])
    reporter.resolve("Config")
    return config
  } catch {
    reporter.abortPass(["Shortcuts", "Settings"])
    reporter.report(
      "Config",
      String(localized: "config.toml could not be parsed. Keeping previous settings"),
      ErrorReportClient.describe(error),
    )
    FileHandle.standardError.write(
      Data("[Tatami] config.toml decode failed: \(error)\n".utf8)
    )
    throw error
  }
}

func encodeTatamiConfig(_ config: AppConfig) throws -> Data {
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
      ErrorReportClient.describe(error),
    )
    throw error
  }
}
