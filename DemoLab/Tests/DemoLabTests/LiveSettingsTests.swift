// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import DemoCtlKit

struct LiveSettingsTests {

  // MARK: Internal

  @Test
  func `live layout and display settings retain their TOML types and unrelated values`() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".toml")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data(Self.fixture.utf8).write(to: file)
    try LiveConfigEditor.update(file: file, key: "autoBalance", value: "\"both\"")
    try LiveConfigEditor.update(file: file, key: "bringScratchpadToPointerDisplay", value: "false")
    try LiveConfigEditor.update(file: file, key: "focusFollowsMouseIgnoreFullscreen", value: "false")
    let settings = try TomlLite.parse(String(contentsOf: file, encoding: .utf8))["settings"]
    #expect(settings?["layout"]?["autoBalance"] == .string("both"))
    #expect(settings?["layout"]?["gapInner"] == .integer(10))
    #expect(settings?["switching"]?["bringScratchpadToPointerDisplay"] == .bool(false))
    #expect(settings?["focus"]?["focusFollowsMouseIgnoreFullscreen"] == .bool(false))
    #expect(settings?["focus"]?["mouseFollowsFocus"] == .bool(true))
  }

  @Test(arguments: [
    ("autoBalance", "\"invalid\""),
    ("bringScratchpadToPointerDisplay", "\"false\""),
    ("focusFollowsMouseIgnoreFullscreen", "1"),
  ])
  func `invalid live setting values leave the fixture unchanged`(key: String, value: String) throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".toml")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data(Self.fixture.utf8).write(to: file)
    #expect(throws: DemoCtlError.self) {
      try LiveConfigEditor.update(file: file, key: key, value: value)
    }
    #expect(try String(contentsOf: file, encoding: .utf8) == Self.fixture)
  }

  // MARK: Private

  private static let fixture = """
    [settings.layout]
    autoBalance = "none"
    gapInner = 10
    [settings.focus]
    mouseFollowsFocus = true
    focusFollowsMouseIgnoreFullscreen = true
    [settings.switching]
    bringScratchpadToPointerDisplay = true
    """

}
