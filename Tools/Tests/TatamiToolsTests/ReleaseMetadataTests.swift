// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Testing
@testable import TatamiToolsKit

@Test
func `appcast accumulates only the current minor and preserves signatures`() throws {
  let fixture = try TemporaryFixture()
  defer { fixture.remove() }
  try fixture.directory.at("CHANGELOG.md").write("""
    # Changelog
    ## 1.2.2 (2026-09-07)
    ### Fixed
    - Keep **focus** and `code` together.
    ## 1.2.1 (2026-09-06)
    - Read [the guide](https://example.com/?a=1&b=2).
    ## 1.1.0 (2026-08-01)
    - Previous series.
    """)
  let english = try fixture.directory.at("CHANGELOG.md").text()
  for locale in locales.dropFirst() {
    try fixture.directory.at("docs/\(locale)/CHANGELOG.md").write(english.replacingOccurrences(
      of: "Keep **focus**",
      with: "\(locale) **focus**",
    ))
  }
  let appcast = fixture.directory.at("appcast.xml")
  try appcast
    .write(
      #"<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><enclosure url="https://example.com/Tatami.dmg" length="123" sparkle:edSignature="unchanged-signature"/></item></channel></rss>"#
    )
  let metadata = ReleaseMetadata(workspace: Workspace(root: fixture.directory))
  try metadata.embedNotes(file: appcast, version: "1.2.2")
  let document = try XMLDocument(contentsOf: appcast)
  let items = try document.nodes(forXPath: "/rss/channel/item")
  let item = try #require(items.first as? XMLElement)
  let description = try #require(item.elements(forName: "description").first?.stringValue)
  #expect(description.contains("<strong>focus</strong>"))
  #expect(description.contains("<code>code</code>"))
  #expect(description.contains("1.2.2"))
  #expect(description.contains("1.2.1"))
  #expect(!description.contains("Previous series"))
  let enclosure = try #require(item.elements(forName: "enclosure").first)
  #expect(enclosure.attribute(forName: "sparkle:edSignature")?.stringValue == "unchanged-signature")
  #expect(enclosure.attribute(forName: "length")?.stringValue == "123")
  #expect(item.elements(forName: "description").count == 5)
  #expect(Set(item.elements(forName: "description").compactMap { $0.attribute(forName: "xml:lang")?.stringValue }) ==
    Set(locales))
  #expect(item.elements(forName: "description").first { $0.attribute(forName: "xml:lang")?.stringValue == "ko" }?.stringValue?
    .contains("ko <strong>focus</strong>") == true)
  let before = try appcast.text()
  try metadata.embedNotes(file: appcast, version: "1.2.2")
  #expect(try appcast.text() == before)
  #expect(throws: (any Error).self) { try metadata.embedNotes(file: appcast, version: "9.9.9") }
  #expect(try appcast.text() == before)
}
