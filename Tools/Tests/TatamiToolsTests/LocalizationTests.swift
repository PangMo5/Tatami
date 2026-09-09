// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TatamiToolsKit

@Test
func `inline code and link destinations survive reordered prose`() throws {
  let source = "Run `tatami workspace list`, then read [the guide](CLI.md#json)."
  let catalog = TextCatalog(
    values: .object([(textKey("Run {0}, then read [the guide]({1})."), .object([("ko", .string("[안내]({1})를 읽고 {0}을 실행해요."))]))]),
    locale: "ko",
  )
  #expect(try inlineUnit(source, catalog, "test") == "[안내](CLI.md#json)를 읽고 `tatami workspace list`을 실행해요.")
}

@Test
func `translation fails for missing or changed placeholders`() {
  #expect(throws: (any Error).self) { try TextCatalog(locale: "ja").text("Use {0}.", "test") }
  let values = JSON.object([(textKey("Use {0}."), .object([("ja", .string("使ってください。"))]))])
  #expect(throws: (any Error).self) { try TextCatalog(values: values, locale: "ja").text("Use {0}.", "test") }
}

@Test
func `emphasis moves with the sentence`() throws {
  let values = JSON.object([(textKey("The window {0}is{1} real."), .object([("ko", .string("{0}실제 창{1}이에요."))]))])
  #expect(try translateHTML("<p>The window <em>is</em> real.</p>", TextCatalog(values: values, locale: "ko"), "test")
    .render() == "<p><em>실제 창</em>이에요.</p>")
}

@Test
func `translation scope excludes agent guidance, internal Demo Lab docs, and local reports`() throws {
  let root = fm.temporaryDirectory.at(UUID().uuidString)
  try root.at("docs").makeDirectory()
  defer { try? fm.removeItem(at: root) }
  for name in ["LOCALIZATION.md", "CONCURRENCY.md", "RESPONSIVENESS_AUDIT.md", "NEW_AGENT_GUIDE.md"] {
    try root.at("docs").at(name).write("# Agent guidance")
  }
  let builder = DocumentBuilder(workspace: Workspace(root: root))
  #expect(builder.documents.contains("docs/CLI.md"))
  #expect(!builder.documents.contains { $0.hasPrefix("DemoLab/") })
  #expect(!builder.documents
    .contains { $0.contains("LOCALIZATION") || $0.contains("CONCURRENCY") || $0.contains("AUDIT") || $0.contains("AGENT") })
}

@Test
func `quote is one sentence and admonition is syntax`() throws {
  let values = JSON.object([(textKey("A window stays where you put it."), .object([("ko", .string("창이 놓아둔 자리에 남아요."))]))])
  #expect(try markdownUnits(
    "> [!NOTE]\n> A window stays\n> where you put it.\n",
    TextCatalog(values: values, locale: "ko"),
    "test",
  ) == "> [!NOTE]\n> 창이 놓아둔 자리에 남아요.\n")
}

@Test
func `generated documents match reviewed files`() throws {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
  let builder = DocumentBuilder(workspace: Workspace(root: root))
  for (file, text) in try builder.outputs() { #expect(try file.text() == text, "\(file.path)") }
}

@Test
func `equivalent JSON preserves accepted scene bytes`() throws {
  let source = "{\n  \"z\": 1,\n  \"a\": [\n    \"한국어\",\n    1.0,\n    true\n  ]\n}\n"
  let directory = fm.temporaryDirectory.at(UUID().uuidString)
  try directory.makeDirectory()
  defer { try? fm.removeItem(at: directory) }
  let file = directory.at("scene.json")
  try file.write(source)
  let value = try JSON.parse(source)
  try value.write(file)
  #expect(try file.text() == source)
  #expect(try JSON.parse(value.rendered()) == value)
  #expect(throws: (any Error).self) { try JSON.parse("{invalid}") }
}
