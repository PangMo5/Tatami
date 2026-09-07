// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import DemoAppKit
import DemoCtlKit
import Foundation
import Testing

@Suite("Localized demo contracts")
struct LocalizationTests {
  @Test("localized fixture data still demonstrates a failing draft and a passing revision", arguments: DemoLocale.allCases)
  func localizedCopyChecks(locale: DemoLocale) {
    var story = LaunchStory(locale: locale)
    #expect(story.headline.count > 40)
    #expect(story.evaluateCopy().filter(\.passed).count == 2)
    story.headline = locale.string("A calmer way to work.")
    #expect(story.evaluateCopy().allSatisfy { $0.passed })
    if locale != .en { #expect(story.headline != "A calmer way to work.") }
  }

  @Test("every catalog entry has all five displayed values and matching placeholders")
  func catalogCompleteness() throws {
    let root = try #require(LabPaths.discoverPackageRoot())
    let file = root.appendingPathComponent("Localization/Localizable.xcstrings")
    let catalog = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let strings = try #require(catalog["strings"] as? [String: [String: Any]])
    let pattern = try NSRegularExpression(pattern: #"%(?:\d+\$)?(?:lld|ld|d|@)"#)
    func placeholders(_ text: String) -> [String] {
      pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
        String(text[Range($0.range, in: text)!]).replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression)
      }.sorted()
    }
    for (key, entry) in strings {
      let translations = try #require(entry["localizations"] as? [String: [String: Any]])
      for locale in DemoLocale.allCases {
        let unit = try #require(translations[locale.rawValue]?["stringUnit"] as? [String: String])
        let text = try #require(unit["value"])
        #expect(!text.isEmpty, "Missing \(locale.rawValue): \(key)")
        #expect(placeholders(text) == placeholders(key), "Changed placeholders: \(key) / \(locale.rawValue)")
        #expect(!text.contains("—"), "Displayed em dash: \(key) / \(locale.rawValue)")
      }
    }
  }
}
