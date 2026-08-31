// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Dependencies
import Foundation
import Sharing

// MARK: - ConfigPersistenceClient

/// Performs a durable configuration transaction before publishing its value
/// through `@Shared`. The raw revision is captured before asynchronous layout
/// work, and the custom shared key suppresses the matching didSet write after
/// the transaction has already replaced the file.
struct ConfigPersistenceClient: Sendable {
  var captureRevision: @Sendable (_ expected: AppConfig) throws -> Data?
  var commit: @Sendable (
    _ config: Shared<AppConfig>,
    _ baseline: AppConfig,
    _ revision: Data?,
    _ updated: AppConfig,
    _ reserve: @Sendable () -> Bool,
  ) throws -> Void
}

// MARK: DependencyKey

extension ConfigPersistenceClient: DependencyKey {
  static let liveValue = ConfigPersistenceClient(
    captureRevision: { expected in
      try TatamiConfigTransactionCoordinator.shared.captureRevision(expected: expected)
    },
    commit: { config, baseline, revision, updated, reserve in
      try config.withLock { current in
        guard current.hasSamePersistedContent(as: baseline) else {
          throw ConfigPersistenceError.changedInMemory
        }
        var next = updated
        next.activeProfileId = current.activeProfileId
        try TatamiConfigTransactionCoordinator.shared.replace(
          revision: revision,
          with: next,
          reserve: reserve,
        )
        current = next
      }
    },
  )

  static let testValue = ConfigPersistenceClient(
    captureRevision: { _ in nil },
    commit: { config, baseline, _, updated, reserve in
      try config.withLock { current in
        guard current.hasSamePersistedContent(as: baseline) else {
          throw ConfigPersistenceError.changedInMemory
        }
        var next = updated
        next.activeProfileId = current.activeProfileId
        guard reserve() else { throw ConfigPersistenceError.transactionExpired }
        current = next
      }
    },
  )
  static let previewValue = testValue
}

// MARK: - TatamiConfigTransactionCoordinator

final class TatamiConfigTransactionCoordinator: @unchecked Sendable {

  // MARK: Internal

  static let shared = TatamiConfigTransactionCoordinator()

  func serialize<R>(_ operation: () throws -> R) rethrows -> R {
    try lock.withLock(operation)
  }

  func consumeSuppressedDidSet(_ value: AppConfig) -> Bool {
    lock.withLock {
      guard
        let suppressedDidSet,
        suppressedDidSet.hasSamePersistedContent(as: value)
      else { return false }
      self.suppressedDidSet = nil
      return true
    }
  }

  func recordSelfWrite(_ value: AppConfig) {
    lock.withLock {
      sessionProfileID = value.activeProfileId
      recentSelfWrite = (value, Date.now.addingTimeInterval(2))
    }
  }

  func preservingSessionProfile(in decoded: AppConfig) -> AppConfig {
    lock.withLock {
      var decoded = decoded
      if
        let sessionProfileID,
        decoded.profiles.contains(where: { $0.id == sessionProfileID })
      {
        decoded.activeProfileId = sessionProfileID
      }
      return decoded
    }
  }

  func shouldSuppressFileEcho(_ value: AppConfig) -> Bool {
    lock.withLock {
      guard let recentSelfWrite else { return false }
      guard recentSelfWrite.expiresAt >= .now else {
        self.recentSelfWrite = nil
        return false
      }
      return recentSelfWrite.value.hasSamePersistedContent(as: value)
    }
  }

  func captureRevision(
    expected: AppConfig,
    at url: URL = ConfigLocation.fileURL,
  ) throws -> Data? {
    try serialize {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true,
      )
      let revision = try readConfigDataIfPresent(at: url)
      try validateConfigRevision(revision, expected: expected)
      return revision
    }
  }

  func replace(
    revision: Data?,
    with updated: AppConfig,
    at url: URL = ConfigLocation.fileURL,
    reserve: @Sendable () -> Bool = { true },
    afterPreflightCheck: @Sendable () -> Void = { },
    afterInitialExchange: @Sendable () -> Void = { },
  ) throws {
    try serialize {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true,
      )
      let data = try encodeTatamiConfig(updated)
      var coordinationError: NSError?
      var operationError: (any Error)?
      NSFileCoordinator().coordinate(
        writingItemAt: url,
        options: .forReplacing,
        error: &coordinationError,
      ) { coordinatedURL in
        do {
          try compareAndSwapConfigFile(
            at: coordinatedURL,
            expectedRevision: revision,
            updatedData: data,
            reserve: reserve,
            afterPreflightCheck: afterPreflightCheck,
            afterInitialExchange: afterInitialExchange,
          )
        } catch {
          operationError = error
        }
      }
      if let operationError { throw operationError }
      if let coordinationError { throw coordinationError }
      suppressedDidSet = updated
      sessionProfileID = updated.activeProfileId
      recentSelfWrite = (updated, Date.now.addingTimeInterval(2))
    }
  }

  // MARK: Private

  private let lock = NSRecursiveLock()
  private var recentSelfWrite: (value: AppConfig, expiresAt: Date)?
  private var sessionProfileID: Profile.ID?
  private var suppressedDidSet: AppConfig?

}

// MARK: - Revision validation

private let freshConfigSeed = AppConfig(settings: AppSettings(shortcuts: .recommended))

func validateConfigRevision(_ revision: Data?, expected: AppConfig) throws {
  if let revision, !revision.isEmpty {
    let onDisk = try decodeTatamiConfig(revision)
    guard onDisk.hasSamePersistedContent(as: expected) else {
      throw ConfigPersistenceError.changedOnDisk
    }
  } else {
    guard hasSameFreshSeedContent(expected) else {
      throw ConfigPersistenceError.changedOnDisk
    }
  }
}

private func hasSameFreshSeedContent(_ config: AppConfig) -> Bool {
  guard config.profiles.count == 1, freshConfigSeed.profiles.count == 1 else { return false }
  var normalized = config
  // The default profile UUID is generated per installation. Normalize only
  // that identity while still comparing every persisted user-facing field.
  normalized.profiles[0].id = freshConfigSeed.profiles[0].id
  return normalized.hasSamePersistedContent(as: freshConfigSeed)
}

// MARK: - ConfigPersistenceError

enum ConfigPersistenceError: Error, LocalizedError {
  case changedInMemory
  case changedOnDisk
  case outcomeUnknown(recoveryPath: String?)
  case transactionExpired

  // MARK: Internal

  var errorDescription: String? {
    switch self {
    case .changedInMemory:
      "Configuration changed while the command was running"

    case .changedOnDisk:
      "config.toml changed on disk while the command was running"

    case .outcomeUnknown(let recoveryPath):
      if let recoveryPath {
        "The config transaction outcome is unknown; preserved displaced data at \(recoveryPath)"
      } else {
        "The config transaction outcome is unknown"
      }

    case .transactionExpired:
      "The CLI connection expired before the command could commit"
    }
  }
}

private func readConfigDataIfPresent(at url: URL = ConfigLocation.fileURL) throws -> Data? {
  do {
    return try Data(contentsOf: url)
  } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
    return nil
  }
}

/// Atomically exchanges the candidate with the live file, then validates the
/// displaced bytes. This preserves a POSIX/rename writer that landed after
/// revision capture but did not participate in NSFileCoordinator.
private func compareAndSwapConfigFile(
  at url: URL,
  expectedRevision: Data?,
  updatedData: Data,
  reserve: @Sendable () -> Bool,
  afterPreflightCheck: @Sendable () -> Void,
  afterInitialExchange: @Sendable () -> Void,
) throws {
  let temporaryURL = url.deletingLastPathComponent()
    .appendingPathComponent(".tatami-config-\(UUID().uuidString).tmp")
  var shouldRemoveTemporary = true
  defer {
    if shouldRemoveTemporary {
      try? FileManager.default.removeItem(at: temporaryURL)
    }
  }
  try updatedData.write(to: temporaryURL, options: .atomic)
  let candidateIdentity = try configFileIdentity(at: temporaryURL)
  // Reject the common stale-revision case before touching the live inode. The
  // exchange and displaced-byte validation below remain necessary for a writer
  // that lands in the narrow interval after this check.
  let liveRevision = try readConfigDataIfPresent(at: url)
  guard liveRevision == expectedRevision else {
    throw ConfigPersistenceError.changedOnDisk
  }
  afterPreflightCheck()
  guard reserve() else { throw ConfigPersistenceError.transactionExpired }

  if expectedRevision == nil {
    let result = renameConfigFile(temporaryURL, url, flags: UInt32(RENAME_EXCL))
    guard result == 0 else {
      if errno == EEXIST { throw ConfigPersistenceError.changedOnDisk }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return
  }

  let swapResult = renameConfigFile(temporaryURL, url, flags: UInt32(RENAME_SWAP))
  guard swapResult == 0 else {
    if errno == ENOENT { throw ConfigPersistenceError.changedOnDisk }
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
  afterInitialExchange()

  let displaced: Data
  let displacedIdentity: ConfigFileIdentity
  do {
    displaced = try Data(contentsOf: temporaryURL)
    displacedIdentity = try configFileIdentity(at: temporaryURL)
  } catch {
    shouldRemoveTemporary = false
    throw ConfigPersistenceError.outcomeUnknown(recoveryPath: temporaryURL.path)
  }
  guard displaced == expectedRevision else {
    do {
      try restoreDisplacedConfig(
        at: url,
        temporaryURL: temporaryURL,
        displaced: displaced,
        displacedIdentity: displacedIdentity,
        candidate: updatedData,
        candidateIdentity: candidateIdentity,
      )
    } catch {
      shouldRemoveTemporary = false
      throw ConfigPersistenceError.outcomeUnknown(recoveryPath: temporaryURL.path)
    }
    throw ConfigPersistenceError.changedOnDisk
  }
}

/// Restores the value displaced by a failed exchange without deleting a newer
/// uncoordinated writer. After each swap, the bytes moved into the temporary
/// path prove whether the expected live value was replaced. If another writer
/// won the race, that newer value becomes the next restoration candidate.
private func restoreDisplacedConfig(
  at url: URL,
  temporaryURL: URL,
  displaced: Data,
  displacedIdentity: ConfigFileIdentity,
  candidate: Data,
  candidateIdentity: ConfigFileIdentity,
) throws {
  var desiredLive = displaced
  var desiredLiveIdentity = displacedIdentity
  var expectedLive = candidate
  var expectedLiveIdentity = candidateIdentity
  for _ in 0 ..< 8 {
    let result = renameConfigFile(
      temporaryURL,
      url,
      flags: UInt32(RENAME_SWAP),
    )
    guard result == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let swappedOut = try Data(contentsOf: temporaryURL)
    let swappedOutIdentity = try configFileIdentity(at: temporaryURL)
    if swappedOut == expectedLive, swappedOutIdentity == expectedLiveIdentity {
      return
    }
    expectedLive = desiredLive
    expectedLiveIdentity = desiredLiveIdentity
    desiredLive = swappedOut
    desiredLiveIdentity = swappedOutIdentity
  }
  throw ConfigPersistenceError.outcomeUnknown(recoveryPath: temporaryURL.path)
}

// MARK: - ConfigFileIdentity

/// Stable across `RENAME_SWAP`, but changes when the same inode is rewritten.
/// Darwin updates ctime for the swap itself, so mtime is the content-generation
/// clock here; nanosecond precision plus size closes the same-byte ABA that a
/// device/inode pair alone cannot distinguish.
private struct ConfigFileIdentity: Equatable {
  var device: dev_t
  var inode: ino_t
  var size: off_t
  var modifiedSeconds: Int64
  var modifiedNanoseconds: Int64
}

private func configFileIdentity(at url: URL) throws -> ConfigFileIdentity {
  var metadata = stat()
  let result = url.path.withCString { Darwin.lstat($0, &metadata) }
  guard result == 0 else {
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
  return ConfigFileIdentity(
    device: metadata.st_dev,
    inode: metadata.st_ino,
    size: metadata.st_size,
    modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
    modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
  )
}

private func renameConfigFile(_ source: URL, _ destination: URL, flags: UInt32) -> Int32 {
  source.path.withCString { sourcePath in
    destination.path.withCString { destinationPath in
      renameatx_np(AT_FDCWD, sourcePath, AT_FDCWD, destinationPath, flags)
    }
  }
}

extension DependencyValues {
  var configPersistence: ConfigPersistenceClient {
    get { self[ConfigPersistenceClient.self] }
    set { self[ConfigPersistenceClient.self] = newValue }
  }
}
