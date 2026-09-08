// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TatamiKit

struct AppDocumentTests {
  @Test
  func `repository navigation and metadata disappear while code stays literal`() throws {
    let source = """
      <!-- LANGUAGE-LINKS:START -->
      [English](README.md) · [한국어](ko/README.md)
      <!-- LANGUAGE-LINKS:END -->
      <a id="stable-heading"></a>
      ## 제목
      <!-- Hidden metadata -->
      1. **첫 번째**
      2. [라이선스](../../LICENSE)
      ~~~~text
      <!-- literal code -->
      ~~~~
      """
    let doc = try ParsedAppDocument(markdown: source, document: .projectNotices, language: "ko")
    let text = doc.blocks.map { String($0.text.characters) }.joined(separator: "\n")
    #expect(!text.contains("LANGUAGE-LINKS"))
    #expect(!text.contains("English"))
    #expect(!text.contains("<a id="))
    #expect(!text.contains("Hidden metadata"))
    #expect(text.contains("<!-- literal code -->"))
    #expect(doc.anchors["stable-heading"] != nil)
    #expect(doc.blocks.compactMap(\.marker) == ["1.", "2."])
    #expect(doc.blocks.flatMap { $0.text.runs.compactMap(\.link) }
      .contains(try #require(URL(string: "tatami-document://license"))))
  }

  @Test
  func `Unicode combining marks in heading IDs remain metadata`() throws {
    let parsed = try ParsedAppDocument(markdown: "<a id=\"️-breaking-changes\"></a>\n### ⚠️ Changes\n", document: .cli)
    #expect(parsed.anchors["️-breaking-changes"] != nil)
    #expect(parsed.blocks.count == 1)
  }

  @Test
  func `real markdown preserves table inline formatting and reference links`() throws {
    let doc = try ParsedAppDocument(
      markdown: "# Guide\n\n[Source][ref]\n\n| Action | Value |\n|---|---|\n| **Copy** | `value` |\n\n[ref]: https://example.com/docs",
      document: .cli,
    )
    #expect(doc.blocks.flatMap(\.rows).count == 2)
    #expect(doc.blocks.flatMap(\.rows).flatMap(\.cells).count == 4)
    #expect(doc.blocks.flatMap { $0.text.runs.compactMap(\.link) }
      .contains(try #require(URL(string: "https://example.com/docs"))))
  }

  @Test
  func `relative links use the source language directory and external guides stay valid`() throws {
    #expect(AppDocument.projectNotices.resolveLink(try #require(URL(string: "../../LICENSE")), language: "ja")
      .absoluteString == "tatami-document://license")
    #expect(AppDocument.cli.resolveLink(try #require(URL(string: "CONFIGURATION.md#settings")), language: "ko")
      .absoluteString == "https://github.com/pangmo5/Tatami/blob/main/docs/ko/CONFIGURATION.md#settings")
    #expect(AppDocument.thirdPartyNotices.resolveLink(
      try #require(URL(string: "../../Tools/THIRD_PARTY_NOTICES.md")),
      language: "ko",
    ).absoluteString == "https://github.com/pangmo5/Tatami/blob/main/Tools/THIRD_PARTY_NOTICES.md")
    #expect(AppDocument.cli.resolveLink(try #require(URL(string: "#commands")))
      .absoluteString == "tatami-document://cli#commands")
  }

  @Test(arguments: [("en-US", "en"), ("ko-KR", "ko"), ("ja-JP", "ja"), ("zh-CN", "zh-Hans"), ("zh-TW", "zh-Hant")])
  func `document language follows app language preferences`(_ preference: String, _ expected: String) {
    #expect(AppDocument.language(preferences: [preference]) == expected)
  }

  @Test
  func `internal document links preserve every document identity`() {
    for document in AppDocument.allCases {
      let link = document.resolveLink(document.sourceURL)
      #expect(link.scheme == "tatami-document")
      #expect(link.host.flatMap(AppDocument.init(rawValue:)) == document)
    }
  }

  @Test
  func `every shipped language renders the real guides and original license text`() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
    let resources = directory.appendingPathComponent("Contents/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let info = ["CFBundleIdentifier": "test.tatami.documents", "CFBundlePackageType": "BNDL"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: directory.appendingPathComponent("Contents/Info.plist"))
    for source in [
      "LICENSE",
      "NOTICE.md",
      "THIRD_PARTY_NOTICES.md",
      "CHANGELOG.md",
      "docs/CLI.md",
      "Localization/ThirdPartyNotice.md",
    ] {
      let original = root.appendingPathComponent(source)
      try FileManager.default.copyItem(at: original, to: resources.appendingPathComponent(original.lastPathComponent))
    }
    for language in ["ko", "ja", "zh-Hans", "zh-Hant"] {
      try FileManager.default.copyItem(
        at: root.appendingPathComponent("docs/\(language)"),
        to: resources.appendingPathComponent(language),
      )
    }
    let bundle = try #require(Bundle(url: directory))
    let loader = AppDocumentLoader()
    let englishHistory = try ParsedAppDocument(
      markdown: String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8),
      document: .changelog,
    )
    let firstRelease = String(englishHistory.blocks[0].text.characters)
    for language in ["en", "ko", "ja", "zh-Hans", "zh-Hant"] {
      for document in AppDocument.allCases {
        let parsed = try await loader.load(document, language: language, bundle: bundle)
        #expect(!parsed.blocks.isEmpty)
        let text = parsed.blocks.map { String($0.text.characters) }.joined(separator: "\n")
        let exposesMetadata = text.contains("LANGUAGE-LINKS") || text.contains("<a id=")
        #expect(!exposesMetadata, "\(language) / \(document)")
        let exposesStrongMarkup = parsed.blocks.contains { block in
          if case .code = block.kind { return false }
          return String(block.text.characters).contains("**")
        }
        #expect(!exposesStrongMarkup, "\(language) / \(document)")
        if document == .thirdPartyNotices {
          #expect(parsed.anchors["original-license-notices"] != nil)
          #expect(text.contains("Copyright (c) 2020 Point-Free"))
        }
        if document == .license {
          #expect(String(parsed.blocks[0].text.characters) == (try String(
            contentsOf: root.appendingPathComponent("LICENSE"),
            encoding: .utf8,
          )))
        }
        if document == .changelog { #expect(String(parsed.blocks[0].text.characters) == firstRelease) }
        if document == .cli { #expect(parsed.blocks.contains { !$0.rows.isEmpty }) }
      }
    }
    try FileManager.default.removeItem(at: resources.appendingPathComponent("ko/CLI.md"))
    let freshLoader = AppDocumentLoader()
    await #expect(throws: (any Error).self) { try await freshLoader.load(.cli, language: "ko", bundle: bundle) }
  }
}
