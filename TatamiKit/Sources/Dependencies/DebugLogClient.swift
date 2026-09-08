// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Dependencies
import DependenciesMacros
import Foundation
import os
import OSLog

// MARK: - DebugLogClient

/// Append-only diagnostic log file. Off by default; the Settings tab's
/// "Debug logging" toggle flips it on, after which every instrumented
/// hot-path (AX observer events, window discovery, BSP sync) appends a
/// timestamped line so we can analyze cases like "Notion's second
/// window won't tile" after the fact.
///
/// File lives next to `config.toml`
/// (`~/.config/tatami/tatami.log` by default). That path points to a unique
/// session log, so app/session restoration cannot erase crash evidence.
@DependencyClient
struct DebugLogClient: Sendable {
  /// Flip the writer on/off. Enabling opens a fresh, retained session log.
  var setEnabled: @Sendable (Bool) -> Void
  /// Append a line. No-op when the writer is disabled. `category` is
  /// a short tag for the source ("AX", "Tiler", "Activation").
  var log: @Sendable (_ category: String, _ message: String) -> Void
  /// Cheap gate for hot paths: building a log message can itself cost
  /// (string interpolation per mouse-move, per-window reject arrays in
  /// discovery) — check this before assembling anything expensive.
  var isEnabled: @Sendable () -> Bool = { false }
}

// MARK: DependencyKey

extension DebugLogClient: DependencyKey {
  static let liveValue: DebugLogClient = {
    let writer = DebugLogWriter()
    return DebugLogClient(
      setEnabled: { writer.setEnabled($0) },
      log: { writer.log(category: $0, message: $1) },
      isEnabled: { writer.isEnabled },
    )
  }()

  static let testValue = DebugLogClient(
    setEnabled: { _ in },
    log: { _, _ in },
    isEnabled: { false },
  )

  static let previewValue = testValue
}

extension DependencyValues {
  var debugLog: DebugLogClient {
    get { self[DebugLogClient.self] }
    set { self[DebugLogClient.self] = newValue }
  }
}

private let osLogger = Logger(subsystem: "dev.PangMo5.Tatami", category: "DebugLog")

// MARK: - DebugLogWriter

/// Serial-queue writer. `enabled` + `handle` mutations all hop onto
/// the queue so callers don't need to synchronise.
final class DebugLogWriter: @unchecked Sendable {

  // MARK: Lifecycle

  init(fileURL: URL = ConfigLocation.directory.appendingPathComponent("tatami.log")) {
    self.fileURL = fileURL
  }

  // MARK: Internal

  let fileURL: URL

  var isEnabled: Bool {
    fastEnabled.withLock { $0 }
  }

  func setEnabled(_ enabled: Bool) {
    fastEnabled.withLock { $0 = enabled }
    queue.async { [weak self] in
      guard let self else { return }
      if enabled == enabledFlag { return }
      enabledFlag = enabled
      if enabled {
        openSession()
      } else {
        closeHandle()
      }
    }
  }

  func log(category: String, message: String) {
    guard isEnabled else { return }
    let recordedAt = Date()
    queue.async { [weak self] in
      guard let self, enabledFlag, let handle else { return }
      let ts = formatter.string(from: recordedAt)
      let line = "\(ts) [\(category)] \(message)\n"
      guard let data = line.data(using: .utf8) else { return }
      do {
        try handle.write(contentsOf: data)
      } catch {
        osLogger.error("debug log write failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  func flush() async {
    await withCheckedContinuation { continuation in
      queue.async {
        try? self.handle?.synchronize()
        continuation.resume()
      }
    }
  }

  // MARK: Private

  private let queue = DispatchQueue(label: "dev.PangMo5.Tatami.debug-log")
  private var handle: FileHandle?
  private var enabledFlag = false
  /// Lock-protected mirror of `enabledFlag`, readable without the queue
  /// hop so hot paths can skip message assembly while logging is off.
  private let fastEnabled = OSAllocatedUnfairLock<Bool>(initialState: false)

  /// ISO-8601 formatter is moderately expensive to construct; build
  /// once and reuse on the queue.
  private let formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  private func openSession() {
    do {
      let directory = fileURL.deletingLastPathComponent()
      let logs = directory.appendingPathComponent("logs", isDirectory: true)
      let files = FileManager.default
      try files.createDirectory(at: logs, withIntermediateDirectories: true)
      let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
      let session = "\(stamp)-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
      let sessionURL = logs.appendingPathComponent("tatami-\(session).log")
      try Data().write(to: sessionURL, options: .withoutOverwriting)
      handle = try FileHandle(forWritingTo: sessionURL)
      // A previous Release may still use a regular tatami.log. Preserve it
      // before publishing the new pointer; later atomic writes by that Release
      // can replace the pointer but cannot overwrite this session's file.
      if
        files.fileExists(atPath: fileURL.path),
        (try? files.destinationOfSymbolicLink(atPath: fileURL.path)) == nil
      {
        guard try files.attributesOfItem(atPath: fileURL.path)[.type] as? FileAttributeType == .typeRegular else {
          throw CocoaError(.fileWriteFileExists)
        }
        try files.moveItem(at: fileURL, to: logs.appendingPathComponent("previous-\(session).log"))
      }
      let pointer = directory.appendingPathComponent(".tatami-log-\(UUID().uuidString)")
      try files.createSymbolicLink(at: pointer, withDestinationURL: sessionURL)
      let replaced = pointer.path.withCString { source in
        fileURL.path.withCString { destination in rename(source, destination) }
      }
      if replaced != 0 {
        let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        try? files.removeItem(at: pointer)
        throw error
      }
      osLogger.info("debug log opened: \(sessionURL.path, privacy: .public)")
    } catch {
      osLogger.error("debug log open failed: \(error.localizedDescription, privacy: .public)")
      handle = nil
      enabledFlag = false
      fastEnabled.withLock { $0 = false }
    }
  }

  private func closeHandle() {
    try? handle?.close()
    handle = nil
    osLogger.info("debug log closed")
  }

}
