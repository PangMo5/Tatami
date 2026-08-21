// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Dependencies
import DependenciesMacros
import Foundation
import OSLog
import os

/// A user-relevant failure. One report per `domain` — a newer report for the
/// same domain replaces the older one.
public struct ErrorReport: Equatable, Sendable, Identifiable {
  /// Stable grouping key ("Config", "Shortcuts", "Layouts", "CLI", …).
  var domain: String
  /// Short, user-facing description shown in the HUD and the menu bar.
  public var message: String
  /// Optional first-line error detail (HUD subtitle / log).
  var detail: String?

  public var id: String { domain }

  init(domain: String, message: String, detail: String? = nil) {
    self.domain = domain
    self.message = message
    self.detail = detail
  }
}

public enum ErrorReportEvent: Equatable, Sendable {
  case reported(ErrorReport)
  case resolved(domain: String)
}

/// Central channel for surfacing internal failures (config parse errors,
/// invalid shortcuts, I/O failures) in the UI instead of just a log line.
/// Reporters call `report`/`resolve`; the app reducer subscribes to `events`
/// and shows a warning HUD plus a persistent menu bar indicator.
@DependencyClient
struct ErrorReportClient: Sendable {
  /// Record a failure. Replaces the domain's current report; an identical
  /// consecutive report is dropped so retry loops don't spam the HUD.
  var report: @Sendable (_ domain: String, _ message: String, _ detail: String?) -> Void
  /// Mark a domain healthy again (e.g. the next config reload parsed).
  /// Emits `.resolved` only if a report was actually standing.
  var resolve: @Sendable (_ domain: String) -> Void
  /// Re-evaluation pass for domains whose reporters fire *during* a larger
  /// operation (config decode reports invalid shortcuts mid-parse). `begin`
  /// marks the domains' standing reports provisional; a re-report of the
  /// same content quietly confirms them (no duplicate event); `commit`
  /// resolves whatever stayed provisional (the failure is gone); `abort`
  /// reinstates provisionals untouched (the operation failed — state unknown).
  var beginPass: @Sendable (_ domains: [String]) -> Void
  var commitPass: @Sendable (_ domains: [String]) -> Void
  var abortPass: @Sendable (_ domains: [String]) -> Void
  /// Current + future events. Replays unresolved reports on subscribe, so
  /// failures that happen before the app reducer starts (config decode runs
  /// at the first `@Shared` access) are not lost.
  var events: @Sendable () -> AsyncStream<ErrorReportEvent> = { .finished }

  /// First line of an error's description, bounded for HUD/menu display.
  static func describe(_ error: any Error) -> String {
    let line = String(describing: error)
      .split(separator: "\n", maxSplits: 1)[0]
    return String(line.prefix(200))
  }
}

extension ErrorReportClient: DependencyKey {
  static let liveValue: ErrorReportClient = {
    let hub = Hub()
    return ErrorReportClient(
      report: { domain, message, detail in
        let report = ErrorReport(domain: domain, message: message, detail: detail)
        guard hub.upsert(report) else { return }
        logger.error(
          "\(domain, privacy: .public): \(message, privacy: .public) \(detail ?? "", privacy: .public)"
        )
        @Dependency(\.debugLog) var debugLog
        debugLog.log("Error", "\(domain): \(message)\(detail.map { " — \($0)" } ?? "")")
      },
      resolve: { hub.resolve($0) },
      beginPass: { hub.beginPass($0) },
      commitPass: { hub.commitPass($0) },
      abortPass: { hub.abortPass($0) },
      events: { hub.stream() }
    )
  }()

  static let testValue = ErrorReportClient(
    report: { _, _, _ in },
    resolve: { _ in },
    beginPass: { _ in },
    commitPass: { _ in },
    abortPass: { _ in },
    events: { .finished }
  )
  static let previewValue = testValue
}

extension DependencyValues {
  var errorReporter: ErrorReportClient {
    get { self[ErrorReportClient.self] }
    set { self[ErrorReportClient.self] = newValue }
  }
}

/// Lock-guarded report store fanning events out to every subscriber.
private final class Hub: Sendable {
  private struct State {
    var reports: [String: ErrorReport] = [:]
    var provisional: Set<String> = []
    var continuations: [UUID: AsyncStream<ErrorReportEvent>.Continuation] = [:]
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Returns false when the identical report is already standing (dedupe).
  func upsert(_ report: ErrorReport) -> Bool {
    state.withLock { s in
      if s.reports[report.domain] == report {
        // Same failure re-observed — confirm it if a pass was running.
        s.provisional.remove(report.domain)
        return false
      }
      s.reports[report.domain] = report
      s.provisional.remove(report.domain)
      for c in s.continuations.values { c.yield(.reported(report)) }
      return true
    }
  }

  func resolve(_ domain: String) {
    state.withLock { s in
      guard s.reports.removeValue(forKey: domain) != nil else { return }
      s.provisional.remove(domain)
      for c in s.continuations.values { c.yield(.resolved(domain: domain)) }
    }
  }

  func beginPass(_ domains: [String]) {
    state.withLock { s in
      for domain in domains where s.reports[domain] != nil {
        s.provisional.insert(domain)
      }
    }
  }

  func commitPass(_ domains: [String]) {
    state.withLock { s in
      for domain in domains where s.provisional.contains(domain) {
        s.provisional.remove(domain)
        guard s.reports.removeValue(forKey: domain) != nil else { continue }
        for c in s.continuations.values { c.yield(.resolved(domain: domain)) }
      }
    }
  }

  func abortPass(_ domains: [String]) {
    state.withLock { s in
      for domain in domains { s.provisional.remove(domain) }
    }
  }

  func stream() -> AsyncStream<ErrorReportEvent> {
    AsyncStream { continuation in
      let id = UUID()
      state.withLock { s in
        for report in s.reports.values { continuation.yield(.reported(report)) }
        s.continuations[id] = continuation
      }
      continuation.onTermination = { [state] _ in
        state.withLock { _ = $0.continuations.removeValue(forKey: id) }
      }
    }
  }
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "ErrorReport")
