// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Dependencies
import Foundation
import Sharing

// MARK: - AsyncConfigStore

/// Owns config I/O, decoding, watches, and write ordering on one blocking lane.
/// The main thread only admits intents and publishes completed values. It never
/// waits for this queue, including during startup and subscription cancellation.
final class AsyncConfigStore: @unchecked Sendable {

  // MARK: Lifecycle

  init(url: URL) {
    self.url = url
  }

  // MARK: Internal

  static let shared = AsyncConfigStore(url: ConfigLocation.fileURL)

  let url: URL

  func load(_ continuation: LoadContinuation<AppConfig>) {
    let shouldRead = intentLock.withLock {
      pendingLoads.append(continuation)
      guard !loadInFlight else { return false }
      loadInFlight = true
      return true
    }
    guard shouldRead else { return }
    enqueue {
      do {
        let token = self.intentLock.withLock { self.generation }
        let data = try self.read()
        let value = try data.flatMap { $0.isEmpty ? nil : try decodeTatamiConfig($0) }
        DispatchQueue.main.sync {
          let (pending, continuations) = self.intentLock.withLock {
            let pending = self.generation != token || self.generation != self.committedGeneration
              ? self.latestIntent
              : nil
            let continuations = self.pendingLoads
            self.pendingLoads = []
            self.loadInFlight = false
            return (pending, continuations)
          }
          if pending == nil {
            self.revision = data
            self.persistedValue = value
            self.hasLoaded = true
          }
          let published = pending ?? value.map {
            TatamiConfigTransactionCoordinator.shared.preservingSessionProfile(in: $0)
          }
          for continuation in continuations {
            if let published { continuation.resume(returning: published) }
            else { continuation.resumeReturningInitialValue() }
          }
        }
      } catch {
        let continuations = self.intentLock.withLock {
          let continuations = self.pendingLoads
          self.pendingLoads = []
          self.loadInFlight = false
          return continuations
        }
        for continuation in continuations { continuation.resume(throwing: error) }
      }
    }
  }

  func subscribe(_ subscriber: SharedSubscriber<AppConfig>) -> SharedSubscription {
    let id = UUID()
    enqueue {
      self.subscribers[id] = subscriber
      do { try self.installWatches() }
      catch { subscriber.yield(throwing: error) }
    }
    return SharedSubscription { [self] in
      enqueue {
        self.subscribers[id] = nil
        if self.subscribers.isEmpty {
          self.fileSource?.cancel()
          self.directorySource?.cancel()
          self.fileSource = nil
          self.directorySource = nil
        }
      }
    }
  }

  func save(_ value: AppConfig, continuation: SaveContinuation) {
    // Admission and queue submission are one ordering edge, including edits
    // originating outside the main actor. No I/O occurs under this lock.
    intentLock.lock()
    defer { intentLock.unlock() }
    generation &+= 1
    latestIntent = value
    let token = generation
    enqueue {
      do {
        guard token > self.committedGeneration else {
          continuation.resume()
          return
        }
        guard self.hasLoaded else { throw ConfigPersistenceError.notLoaded }
        if self.persistedValue?.hasSamePersistedContent(as: value) == true {
          // Session-only profile changes do not rewrite the editable TOML.
          TatamiConfigTransactionCoordinator.shared.recordSelfWrite(value)
          self.committedGeneration = token
          self.pendingWriteError = nil
          continuation.resume()
          return
        }
        // Every admitted save completes in order, so an explicit flush and
        // termination wait include all writes already requested by the UI.
        let encoded = try TatamiConfigTransactionCoordinator.shared.replace(
          revision: self.revision,
          with: value,
          at: self.url,
          suppressDidSet: false,
        )
        self.revision = encoded
        self.persistedValue = value
        self.committedGeneration = token
        self.pendingWriteError = nil
        continuation.resume()
      } catch {
        self.pendingWriteError = error
        @Dependency(\.errorReporter) var reporter
        reporter.report("ConfigSave", String(localized: "config.toml could not be saved"), ErrorReportClient.describe(error))
        continuation.resume(throwing: error)
      }
    }
  }

  /// Called on the shared persistence lane with the value matching `data`,
  /// never with a newer GUI value observed after the publication callback.
  func didCommit(_ value: AppConfig, data: Data) {
    let publication = intentLock.withLock {
      let publication = durablePublicationGeneration
      durablePublicationGeneration = nil
      return publication
    }
    guard let publication else { preconditionFailure("Durable config publication must precede commit acknowledgement") }
    revision = data
    persistedValue = value
    hasLoaded = true
    committedGeneration = publication
    pendingWriteError = nil
  }

  /// Called inside the brief main-actor publication. Older automatic saves
  /// queued behind the transaction cannot undo its newly published value.
  func recordDurablePublication(_ value: AppConfig) {
    intentLock.withLock {
      generation &+= 1
      latestIntent = value
      durablePublicationGeneration = generation
    }
  }

  @discardableResult
  func flush() async -> (any Error)? {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: self.pendingWriteError) }
    }
  }

  // MARK: Private

  private let queue = TatamiConfigTransactionCoordinator.queue
  private let intentLock = NSLock()
  private var generation: UInt64 = 0
  private var latestIntent: AppConfig?
  private var pendingLoads = [LoadContinuation<AppConfig>]()
  private var loadInFlight = false
  private var durablePublicationGeneration: UInt64?
  // Confined to queue (including brief main-thread publications awaited by it).
  private var committedGeneration: UInt64 = 0
  private var revision: Data?
  private var persistedValue: AppConfig?
  private var hasLoaded = false
  private var pendingWriteError: (any Error)?
  private var subscribers = [UUID: SharedSubscriber<AppConfig>]()
  private var fileSource: (any DispatchSourceFileSystemObject)?
  private var directorySource: (any DispatchSourceFileSystemObject)?

  private func enqueue(_ operation: @escaping @Sendable () -> Void) {
    withEscapedDependencies { dependencies in
      queue.async { dependencies.yield(operation) }
    }
  }

  private func read() throws -> Data? {
    do { return try Data(contentsOf: url) }
    catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
  }

  private func installWatches() throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if directorySource == nil {
      directorySource = try makeSource(url.deletingLastPathComponent(), events: [.write, .rename, .delete])
    }
    fileSource?.cancel()
    fileSource = nil
    if FileManager.default.fileExists(atPath: url.path) {
      fileSource = try makeSource(url, events: [.write, .rename, .delete])
    }
  }

  private func makeSource(_ path: URL, events: DispatchSource.FileSystemEvent) throws -> any DispatchSourceFileSystemObject {
    let descriptor = open(path.path, O_EVTONLY)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: events, queue: queue)
    let dependencies = withEscapedDependencies { $0 }
    source.setEventHandler { [weak self] in
      dependencies.yield { self?.reloadFromDisk() }
    }
    source.setCancelHandler { close(descriptor) }
    source.resume()
    return source
  }

  private func reloadFromDisk() {
    do {
      try installWatches()
      let token = intentLock.withLock { generation }
      guard token == committedGeneration else { return }
      let data = try read()
      guard data != revision else { return }
      let decoded = try data.flatMap { $0.isEmpty ? nil : try decodeTatamiConfig($0) }
      // Main never waits for queue. A short publication on main makes the
      // generation check and Shared update atomic relative to GUI edits.
      DispatchQueue.main.sync {
        guard self.intentLock.withLock({ self.generation == token }) else { return }
        self.revision = data
        self.persistedValue = decoded
        for subscriber in self.subscribers.values {
          if let decoded {
            let value = TatamiConfigTransactionCoordinator.shared.preservingSessionProfile(in: decoded)
            subscriber.yield(value)
          } else {
            subscriber.yieldReturningInitialValue()
          }
        }
      }
    } catch {
      for subscriber in subscribers.values { subscriber.yield(throwing: error) }
    }
  }

}

/// Complete all already-admitted config writes before normal application quit.
public func flushConfigurationWrites() async -> String? {
  await AsyncConfigStore.shared.flush().map(ErrorReportClient.describe)
}
