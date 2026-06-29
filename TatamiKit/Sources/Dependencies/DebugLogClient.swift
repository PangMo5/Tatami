import Dependencies
import DependenciesMacros
import Foundation
import OSLog
import os

/// Append-only diagnostic log file. Off by default; the Settings tab's
/// "Debug logging" toggle flips it on, after which every instrumented
/// hot-path (AX observer events, window discovery, BSP sync) appends a
/// timestamped line so we can analyze cases like "Notion's second
/// window won't tile" after the fact.
///
/// File lives next to `config.toml`
/// (`~/.config/tatami/tatami.log` by default). Truncated on enable
/// — we want a fresh trace per debugging session.
@DependencyClient
struct DebugLogClient: Sendable {
  /// Flip the writer on/off. When enabling, opens (and truncates) the
  /// log file so the next trace starts clean.
  var setEnabled: @Sendable (Bool) -> Void
  /// Append a line. No-op when the writer is disabled. `category` is
  /// a short tag for the source ("AX", "Tiler", "Activation").
  var log: @Sendable (_ category: String, _ message: String) -> Void
  /// Cheap gate for hot paths: building a log message can itself cost
  /// (string interpolation per mouse-move, per-window reject arrays in
  /// discovery) — check this before assembling anything expensive.
  var isEnabled: @Sendable () -> Bool = { false }
  /// Where the file lives on disk. Exposed so the Settings UI can
  /// surface its path / a "Reveal in Finder" button.
  var fileURL: @Sendable () -> URL = {
    ConfigLocation.directory.appendingPathComponent("tatami.log", isDirectory: false)
  }
}

extension DebugLogClient: DependencyKey {
  static let liveValue: DebugLogClient = {
    let writer = DebugLogWriter()
    return DebugLogClient(
      setEnabled: { writer.setEnabled($0) },
      log: { writer.log(category: $0, message: $1) },
      isEnabled: { writer.isEnabled },
      fileURL: { writer.fileURL }
    )
  }()

  static let testValue = DebugLogClient(
    setEnabled: { _ in },
    log: { _, _ in },
    isEnabled: { false },
    fileURL: { URL(fileURLWithPath: "/dev/null") }
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

/// Serial-queue writer. `enabled` + `handle` mutations all hop onto
/// the queue so callers don't need to synchronise.
private final class DebugLogWriter: @unchecked Sendable {
  private let queue = DispatchQueue(label: "dev.PangMo5.Tatami.debug-log")
  private var handle: FileHandle?
  private var enabledFlag = false
  /// Lock-protected mirror of `enabledFlag`, readable without the queue
  /// hop so hot paths can skip message assembly while logging is off.
  private let fastEnabled = OSAllocatedUnfairLock<Bool>(initialState: false)

  var isEnabled: Bool { fastEnabled.withLock { $0 } }
  /// ISO-8601 formatter is moderately expensive to construct; build
  /// once and reuse on the queue.
  private let formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  let fileURL: URL = ConfigLocation.directory
    .appendingPathComponent("tatami.log", isDirectory: false)

  func setEnabled(_ enabled: Bool) {
    fastEnabled.withLock { $0 = enabled }
    queue.async { [weak self] in
      guard let self else { return }
      if enabled == self.enabledFlag { return }
      self.enabledFlag = enabled
      if enabled {
        self.openTruncated()
      } else {
        self.closeHandle()
      }
    }
  }

  func log(category: String, message: String) {
    queue.async { [weak self] in
      guard let self, self.enabledFlag, let handle = self.handle else { return }
      let ts = self.formatter.string(from: Date())
      let line = "\(ts) [\(category)] \(message)\n"
      guard let data = line.data(using: .utf8) else { return }
      do {
        try handle.write(contentsOf: data)
      } catch {
        osLogger.error("debug log write failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  // MARK: - Private

  private func openTruncated() {
    do {
      try ConfigLocation.ensureDirectoryExists()
      // Preserve the previous session before starting fresh: a freeze that
      // needed a force-quit/reboot leaves its trace in `tatami.log.prev` even
      // after relaunch truncates the live file (otherwise the only evidence is
      // gone the moment the app comes back up). A fresh session still truncates
      // the live file so it doesn't scroll past last week's noise.
      let prevURL = fileURL.deletingLastPathComponent()
        .appendingPathComponent("tatami.log.prev", isDirectory: false)
      if FileManager.default.fileExists(atPath: fileURL.path) {
        try? FileManager.default.removeItem(at: prevURL)
        try? FileManager.default.copyItem(at: fileURL, to: prevURL)
      }
      // Truncate. A fresh debug session shouldn't have to scroll past
      // last week's noise.
      try Data().write(to: fileURL, options: .atomic)
      handle = try FileHandle(forWritingTo: fileURL)
      try handle?.seekToEnd()
      osLogger.info("debug log opened: \(self.fileURL.path, privacy: .public)")
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
