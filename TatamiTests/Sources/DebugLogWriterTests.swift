// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TatamiKit

struct DebugLogWriterTests {
  @Test
  func `new sessions and legacy writers cannot erase an earlier session`() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let current = directory.appendingPathComponent("tatami.log")
    let first = DebugLogWriter(fileURL: current)
    first.setEnabled(true)
    first.log(category: "Test", message: "before crash")
    await first.flush()
    let firstURL = URL(fileURLWithPath: try FileManager.default.destinationOfSymbolicLink(atPath: current.path))

    let second = DebugLogWriter(fileURL: current)
    second.setEnabled(true)
    second.log(category: "Test", message: "after restoration")
    await second.flush()
    let secondURL = URL(fileURLWithPath: try FileManager.default.destinationOfSymbolicLink(atPath: current.path))
    #expect(try String(contentsOf: firstURL, encoding: .utf8).contains("before crash"))
    #expect(try String(contentsOf: current, encoding: .utf8).contains("after restoration"))

    // An older installed build replaces tatami.log atomically on startup.
    try Data("legacy writer".utf8).write(to: current, options: .atomic)
    #expect(try String(contentsOf: secondURL, encoding: .utf8).contains("after restoration"))
    first.log(category: "Test", message: "independent session")
    await first.flush()
    #expect(try String(contentsOf: firstURL, encoding: .utf8).contains("independent session"))
    #expect(try String(contentsOf: current, encoding: .utf8) == "legacy writer")
    first.setEnabled(false)
    second.setEnabled(false)
    await first.flush()
    await second.flush()
  }

  @Test
  func `legacy regular log is retained when a new session opens`() async throws {
    let files = FileManager.default
    let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? files.removeItem(at: directory) }
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    let current = directory.appendingPathComponent("tatami.log")
    try Data("earlier evidence".utf8).write(to: current)
    let writer = DebugLogWriter(fileURL: current)
    writer.setEnabled(true)
    writer.log(category: "Test", message: "new session")
    await writer.flush()
    let archived = try files.contentsOfDirectory(at: directory.appendingPathComponent("logs"), includingPropertiesForKeys: nil)
    let legacy = try #require(archived.first { $0.lastPathComponent.hasPrefix("previous-") })
    #expect(try String(contentsOf: legacy, encoding: .utf8) == "earlier evidence")
    #expect(try String(contentsOf: current, encoding: .utf8).contains("new session"))
    writer.setEnabled(false)
    await writer.flush()
  }
}
