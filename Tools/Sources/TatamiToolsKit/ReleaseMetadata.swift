// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import cmark_gfm
import Markdown

// MARK: - MarkdownStructure

struct MarkdownStructure {

  // MARK: Lifecycle

  init(_ source: String) {
    var headings = [Int]()
    var code = Set<Int>()
    func visit(_ node: any Markup) {
      if node is Heading, let range = node.range { headings.append(range.lowerBound.line - 1) }
      if node is CodeBlock, let range = node.range { code.formUnion((range.lowerBound.line - 1)...(range.upperBound.line - 1)) }
      for child in node.children { visit(child) }
    }
    visit(Document(parsing: source))
    headingLines = headings
    codeLines = code
  }

  // MARK: Internal

  let headingLines: [Int]
  let codeLines: Set<Int>

  static func html(_ source: String) throws -> String {
    guard let html = cmark_markdown_to_html(source, source.utf8.count, 0) else { throw ToolError("Markdown rendering failed") }
    defer { free(html) }
    return String(cString: html)
  }

}

// MARK: - ReleaseMetadata

struct ReleaseMetadata {
  let workspace: Workspace

  func embedNotes(file: URL, version: String) throws {
    try require(fullMatch(#"\d+\.\d+\.\d+"#, version), "Invalid appcast version")
    let source = try workspace.root.at("CHANGELOG.md").text()
    let sourceLines = lines(source)
    let structure = MarkdownStructure(source)
    let sections = structure.headingLines.filter { sourceLines[$0].hasPrefix("## ") }
    let minor = version.split(separator: ".").prefix(2).joined(separator: ".")
    var collected = [String]()
    var started = false
    for (index, line) in sections.enumerated() {
      let heading = String(sourceLines[line].dropFirst(3))
      let sectionVersion = matches(#"^v?(\d+\.\d+\.\d+)"#, heading).first?[1]
      if sectionVersion == version { started = true }
      if !started { continue }
      if sectionVersion?.split(separator: ".").prefix(2).joined(separator: ".") != minor { break }
      let end = index + 1 < sections.count ? sections[index + 1] : sourceLines.count
      collected.append(sourceLines[line..<end].joined(separator: "\n"))
    }
    try require(!collected.isEmpty, "No changelog section for \(version)")
    let document = try XMLDocument(contentsOf: file, options: [.nodePreserveAll])
    let items = try document.nodes(forXPath: "/rss/channel/item")
    try require(items.count == 1, "Expected a single release item in the generated appcast")
    guard let item = items.first as? XMLElement else { throw ToolError("Missing appcast item") }
    if !item.elements(forName: "description").isEmpty { print("Appcast description already exists")
      return
    }
    let html = try MarkdownStructure.html(collected.joined(separator: "\n"))
    let description = XMLElement(name: "description", stringValue: html)
    item.addChild(description)
    // XMLDocument escapes the HTML as text, preserving XML validity even for ]]>.
    // Sparkle accepts the same description content without requiring CDATA syntax.
    try document.xmlData.write(to: file, options: .atomic)
    print("Appcast: embedded release notes (\(collected.count) sections)")
  }
}
