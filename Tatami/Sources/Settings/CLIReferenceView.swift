// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

// MARK: - CLIReferenceView

/// Renders the bundled `docs/CLI.md` so the app and website share one source.
struct CLIReferenceView: View {

  // MARK: Internal

  var body: some View {
    NavigationStack {
      Group {
        if let blocks {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
              ForEach(blocks) { block in
                blockView(block)
              }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        } else if let loadErrorMessage {
          ContentUnavailableView(
            "Unable to Open Document",
            systemImage: "doc.badge.exclamationmark",
            description: Text(loadErrorMessage),
          )
        } else {
          ProgressView("Loading document…")
        }
      }
      .navigationTitle("CLI Guide")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
    }
    .frame(minWidth: 720, minHeight: 600)
    .task {
      do {
        blocks = try await MarkdownBlock.loadCLIReference()
      } catch {
        loadErrorMessage = error.localizedDescription
      }
    }
  }

  // MARK: Private

  @Environment(\.dismiss) private var dismiss
  @State private var blocks: [MarkdownBlock]?
  @State private var loadErrorMessage: String?

  @ViewBuilder
  private func blockView(_ block: MarkdownBlock) -> some View {
    switch block.content {
    case .heading(let level, let text):
      Text(inline(text))
        .font(headingFont(level))
        .padding(.top, level == 1 ? 0 : 10)
        .textSelection(.enabled)

    case .paragraph(let text):
      Text(inline(text))
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)

    case .bullet(let text):
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("•")
          .foregroundStyle(.secondary)
        Text(inline(text))
          .fixedSize(horizontal: false, vertical: true)
      }
      .textSelection(.enabled)

    case .code(let text):
      ScrollView(.horizontal) {
        Text(verbatim: text)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .padding(12)
      }
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

    case .table(let rows):
      ScrollView(.horizontal) {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
          ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
            GridRow {
              ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                Text(inline(cell))
                  .fontWeight(rowIndex == 0 ? .semibold : .regular)
                  .fixedSize(horizontal: true, vertical: false)
              }
            }
          }
        }
        .textSelection(.enabled)
        .padding(12)
      }
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
  }

  private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: .title2.weight(.semibold)
    case 2: .title3.weight(.semibold)
    default: .headline
    }
  }

  private func inline(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
  }

}

// MARK: - MarkdownBlock

private struct MarkdownBlock: Identifiable, Sendable {

  // MARK: Internal

  enum Content: Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case code(String)
    case table([[String]])
  }

  let id: Int
  let content: Content

  static func loadCLIReference() async throws -> [Self] {
    guard let url = Bundle.main.url(forResource: "CLI", withExtension: "md") else {
      throw CocoaError(.fileNoSuchFile)
    }

    return try await Task.detached(priority: .userInitiated) {
      let source = try String(contentsOf: url, encoding: .utf8)
      return parse(source)
    }.value
  }

  // MARK: Private

  private static func parse(_ source: String) -> [Self] {
    let lines = source.components(separatedBy: .newlines)
    var contents = [Content]()
    var index = 0

    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if trimmed.isEmpty {
        index += 1
        continue
      }

      if trimmed.hasPrefix("```") {
        index += 1
        var codeLines = [String]()
        while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
          codeLines.append(lines[index])
          index += 1
        }
        if index < lines.count {
          index += 1
        }
        contents.append(.code(codeLines.joined(separator: "\n")))
        continue
      }

      if let heading = heading(from: trimmed) {
        contents.append(heading)
        index += 1
        continue
      }

      if trimmed.hasPrefix("|"), trimmed.hasSuffix("|") {
        var rows = [[String]]()
        while index < lines.count {
          let candidate = lines[index].trimmingCharacters(in: .whitespaces)
          guard candidate.hasPrefix("|"), candidate.hasSuffix("|") else { break }
          let cells = candidate
            .split(separator: "|", omittingEmptySubsequences: false)
            .dropFirst()
            .dropLast()
            .map { $0.trimmingCharacters(in: .whitespaces) }
          if !cells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" } }) {
            rows.append(cells)
          }
          index += 1
        }
        contents.append(.table(rows))
        continue
      }

      if trimmed.hasPrefix("- ") {
        var parts = [String(trimmed.dropFirst(2))]
        index += 1
        while index < lines.count, isContinuation(lines[index]) {
          parts.append(lines[index].trimmingCharacters(in: .whitespaces))
          index += 1
        }
        contents.append(.bullet(parts.joined(separator: " ")))
        continue
      }

      var paragraphLines = [trimmed]
      index += 1
      while index < lines.count, isContinuation(lines[index]) {
        paragraphLines.append(lines[index].trimmingCharacters(in: .whitespaces))
        index += 1
      }
      contents.append(.paragraph(paragraphLines.joined(separator: " ")))
    }

    return contents.enumerated().map { Self(id: $0.offset, content: $0.element) }
  }

  private static func heading(from line: String) -> Content? {
    let markerCount = line.prefix { $0 == "#" }.count
    guard (1...3).contains(markerCount), line.dropFirst(markerCount).hasPrefix(" ") else {
      return nil
    }
    return .heading(
      level: markerCount,
      text: String(line.dropFirst(markerCount + 1)),
    )
  }

  private static func isContinuation(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return !trimmed.isEmpty
      && !trimmed.hasPrefix("#")
      && !trimmed.hasPrefix("```")
      && !trimmed.hasPrefix("- ")
      && !(trimmed.hasPrefix("|") && trimmed.hasSuffix("|"))
  }

}
