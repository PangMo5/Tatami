// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - SettingsSearchItem

/// A stable destination in Settings. Search indexes the same localized copy
/// shown by the controls, plus English source keys and explicit abbreviations.
public struct SettingsSearchItem: Identifiable, Sendable {

  // MARK: Lifecycle

  public init(
    id: String,
    pane: String,
    title: LocalizedStringResource,
    detail: LocalizedStringResource? = nil,
    keywords: [LocalizedStringResource] = [],
    aliases: String = "",
  ) {
    self.id = id
    self.pane = pane
    self.title = title
    self.detail = detail
    self.keywords = keywords
    self.aliases = aliases
  }

  // MARK: Public

  public let id: String
  public let pane: String
  public let title: LocalizedStringResource
  public let detail: LocalizedStringResource?
  public let keywords: [LocalizedStringResource]
  public let aliases: String

}

// MARK: - SettingsSearch

public enum SettingsSearch {

  // MARK: Public

  public static func results(
    for query: String,
    in items: [SettingsSearchItem],
    localize: (LocalizedStringResource) -> String = { String(localized: $0) },
  ) -> [SettingsSearchItem] {
    let query = normalize(query)
    let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !terms.isEmpty else { return [] }
    return items.enumerated().compactMap { index, item -> (Int, Int, SettingsSearchItem)? in
      let title = normalize(localize(item.title))
      let resources = [item.title] + (item.detail.map { [$0] } ?? []) + item.keywords
      let fields = resources.flatMap { [localize($0), $0.key] }
        + [item.aliases, item.id]
      let text = normalize(fields.joined(separator: " "))
      guard terms.allSatisfy({ text.contains($0) }) else { return nil }
      let rank = title == query ? 0 : title.hasPrefix(query) ? 1 : terms.allSatisfy(title.contains) ? 2 : 3
      return (rank, index, item)
    }
    .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
    .map(\.2)
  }

  // MARK: Private

  private static func normalize(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

}
