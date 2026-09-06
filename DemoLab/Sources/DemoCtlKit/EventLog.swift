// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - TatamiEvent

public struct TatamiEvent: Sendable, Equatable {

  // MARK: Lifecycle

  public init(event: String, profile: String, workspace: String, kind: String, display: String) {
    self.event = event
    self.profile = profile
    self.workspace = workspace
    self.kind = kind
    self.display = display
  }

  // MARK: Public

  public let event: String
  public let profile: String
  public let workspace: String
  public let kind: String
  public let display: String

  public var summary: String {
    switch event {
    case "workspaceActivated":
      display.isEmpty ? "workspace \(workspace)" : "workspace \(workspace) on \(display)"
    case "profileChanged":
      "profile \(profile)"
    default:
      event
    }
  }

}

// MARK: - EventLog

/// Reads the append-only log the `demolab-hook` script writes.
///
/// This is the lab's only reliable "it actually happened" signal for anything
/// other than `workspace activate` / `profile activate`. Tatami's dispatcher
/// answers `accepted` as soon as a command is enqueued, which is true and
/// useless for a scene: it says nothing about whether a window moved. The hook
/// fires from inside the activation pipeline, so a line here means a display
/// really published new state.
public struct EventLog: Sendable {

  // MARK: Lifecycle

  public init(url: URL) {
    self.url = url
  }

  // MARK: Public

  public let url: URL

  /// Byte offset to read from. Take one *before* issuing a command, so a
  /// matching line from an earlier take can never satisfy the wait.
  public var mark: UInt64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
  }

  public func reset() throws {
    try? FileManager.default.removeItem(at: url)
    FileManager.default.createFile(atPath: url.path, contents: Data())
  }

  public func events(since offset: UInt64) -> [TatamiEvent] {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? handle.close() }
    do {
      try handle.seek(toOffset: offset)
      let data = try handle.readToEnd() ?? Data()
      return Self.parse(String(decoding: data, as: UTF8.self))
    } catch {
      return []
    }
  }

  @discardableResult
  public func wait(
    since offset: UInt64,
    timeout: Duration,
    describing description: String,
    matching predicate: @escaping (TatamiEvent) -> Bool
  ) throws -> TatamiEvent {
    var found: TatamiEvent?
    let satisfied = Shell.wait(timeout: timeout, poll: .milliseconds(40)) {
      found = events(since: offset).first(where: predicate)
      return found != nil
    }
    guard satisfied, let found else {
      throw DemoCtlError.waitTimedOut(
        what: description,
        seconds: Double(timeout.components.seconds)
      )
    }
    return found
  }

  // MARK: Private

  private static func parse(_ text: String) -> [TatamiEvent] {
    text.split(separator: "\n").compactMap { line in
      let fields = line.components(separatedBy: "\t")
      guard fields.count >= 6 else { return nil }
      return TatamiEvent(
        event: fields[1],
        profile: fields[2],
        workspace: fields[3],
        kind: fields[4],
        display: fields[5]
      )
    }
  }

}
