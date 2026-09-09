// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct DocumentBuilder {
  static let navigationPattern = #"(?s)\n?<!-- LANGUAGE-LINKS:START -->.*?<!-- LANGUAGE-LINKS:END -->\n?"#

  let workspace: Workspace

  /// Only user-facing documentation belongs in the translation pipeline.
  /// Adding a contributor guide or local report under docs must not publish it.
  let documents = [
    "README.md",
    "CHANGELOG.md",
    "docs/CLI.md",
    "docs/CONFIGURATION.md",
    "docs/TROUBLESHOOTING.md",
    "NOTICE.md",
    "THIRD_PARTY_NOTICES.md",
  ]

  func destination(_ source: String, _ locale: String) -> URL {
    let file = workspace.root.at(source)
    if locale == "en" { return file }
    if !source.contains("/") { return workspace.root.at("docs").at(locale).at(file.lastPathComponent) }
    return file.deletingLastPathComponent().at(locale).at(file.lastPathComponent)
  }

  func localizedNoticeLink(_ value: String, locale: String) -> String {
    guard locale != "en" else { return value }
    for source in ["NOTICE.md", "THIRD_PARTY_NOTICES.md"] where value.hasSuffix("/" + source) {
      let localized = relativePath(destination(source, locale), from: workspace.root)
      if value.hasSuffix("/" + localized) { return value }
      return String(value.dropLast(source.count)) + localized
    }
    return value
  }

  func languageLinks(_ source: String, _ locale: String) -> String {
    let parent = destination(source, locale).deletingLastPathComponent()
    return "<!-- LANGUAGE-LINKS:START -->\n" + locales.map { "[" + languageNames[$0]! + "](" + relativePath(
      destination(source, $0),
      from: parent,
    ) + ")" }.joined(separator: " · ") + "\n<!-- LANGUAGE-LINKS:END -->\n\n"
  }

  func headings(_ source: String) -> [String] {
    var result = [String]()
    var used = [String: Int]()
    let sourceLines = lines(source)
    for lineNumber in MarkdownStructure(source).headingLines {
      let line = sourceLines[lineNumber]
      if let heading = matches(#"^#{1,6}\s+(.+)"#, line).first {
        let label = replacing("<[^>]+>", in: heading[1]) { _ in "" }
        let slug = trim(replacing(#"[^\w\s-]"#, in: label.lowercased()) { _ in "" }).replacingOccurrences(of: " ", with: "-")
        let count = used[slug, default: 0]
        used[slug] = count + 1
        result.append(slug + (count > 0 ? "-\(count)" : ""))
      }
    }
    return result
  }

  func anchorHeadings(_ source: String, _ anchors: [String]) throws -> String {
    var result = [String]()
    var index = 0
    let headingLines = Set(MarkdownStructure(source).headingLines)
    for (lineNumber, line) in lines(source).enumerated() {
      if headingLines.contains(lineNumber), !matches(#"^#{1,6}\s"#, line).isEmpty {
        try require(index < anchors.count, "Changed documentation heading count")
        result.append("<a id=\"" + anchors[index] + "\"></a>")
        index += 1
      }
      result.append(line)
    }
    try require(index == anchors.count, "Changed documentation heading count")
    return result.joined(separator: "\n") + "\n"
  }

  func rewriteLinks(_ text: String, _ source: String, _ locale: String) throws -> String {
    let current = destination(source, locale)
    let known = Set(documents)
    func url(_ value: String) -> String {
      guard var parts = URLComponents(string: value) else { return value }
      if parts.host == "pangmo5.dev" && (parts.path == "/Tatami" || parts.path.hasPrefix("/Tatami/")) {
        let tail = String(parts.path.dropFirst("/Tatami".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.path = "/Tatami/" + locale + "/" + tail
        return parts.string ?? value
      }
      if parts.scheme != nil || parts.host != nil || parts.path.isEmpty { return value }
      let absolute = workspace.root.at(source).deletingLastPathComponent().at(parts.path).standardizedFileURL
      guard absolute.path.hasPrefix(workspace.root.path + "/") else { return value }
      let relative = relativePath(absolute, from: workspace.root)
      var localized = known.contains(relative) && relative != "THIRD_PARTY_NOTICES.md" ? destination(relative, locale) : absolute
      if
        absolute.deletingLastPathComponent() == workspace.root.at("web"),
        absolute.pathExtension == "jpg" { localized = workspace.root.at("web/media").at(locale).at(absolute.lastPathComponent) }
      // Preserve the original query and fragment; code fences never enter this path.
      let suffix = (value.contains("?") ? "?" + (parts.percentEncodedQuery ?? "") : "") + (value.contains("#")
        ? "#" + (parts.percentEncodedFragment ?? "")
        : "")
      return relativePath(localized, from: current.deletingLastPathComponent()) + suffix
    }
    var result = [String]()
    let codeLines = MarkdownStructure(text).codeLines
    for (lineNumber, original) in lines(text).enumerated() {
      var line = original
      if codeLines.contains(lineNumber) { result.append(line)
        continue
      }
      line = replacing(#"(?<=\]\()([^\s)]+)(?=\))"#, in: line) { url($0[0]) }
      line = replacing(#"\b(href|src)="([^"]+)""#, in: line) { $0[1] + "=\"" + url($0[2]) + "\"" }
      line = replacing(#"^(\[[^]]+\]:\s*)(\S+)"#, in: line) { $0[1] + url($0[2]) }
      result.append(line)
    }
    return result.joined(separator: "\n") + "\n"
  }

  func outputs(selected: [String] = []) throws -> [(URL, String)] {
    let values = try JSON.read(workspace.root.at("Localization/Docs.json"))
    var outputs = [(URL, String)]()
    for source in documents where selected.isEmpty || selected.contains(source) {
      let text = replacing(Self.navigationPattern, in: try workspace.root.at(source).text()) { _ in "" }
        .drop(while: { $0 == "\n" })
      let localizedSource = try source == "THIRD_PARTY_NOTICES.md"
        ? workspace.root.at("Localization/ThirdPartyNotice.md").text()
        : String(text)
      for locale in locales.dropFirst() {
        var translated = try markdownUnits(localizedSource, TextCatalog(values: values, locale: locale), source)
        translated = try anchorHeadings(translated, headings(localizedSource))
        outputs.append((
          destination(source, locale),
          try languageLinks(source, locale) + rewriteLinks(translated, source, locale),
        ))
      }
      outputs.append((destination(source, "en"), languageLinks(source, "en") + text))
    }
    return outputs
  }

  func build(selected: [String] = [], check: Bool = false) throws {
    let outputs = try outputs(selected: selected)
    for (file, text) in outputs {
      if check { try require(try file.text() == text, "Generated document drift: \(file.path)") }
      else { try file.write(text) }
    }
    print("\(check ? "Verified" : "Generated") \(outputs.count) localized documents")
  }
}
