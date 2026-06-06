import SwiftUI

/// Renders the bundled CHANGELOG.md — reachable from the About pane and
/// the post-update What's New window. Lightweight line-based markdown:
/// version headings, sub-headings, and bullets with inline styling;
/// everything else falls through as body text. Good enough for our
/// changelog's strict structure without pulling in a markdown engine.
public struct ChangelogView: View {
  @Environment(\.dismiss) private var dismiss

  public init() {}

  private static let lines: [Line] = load()

  public var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Changelog")
          .font(.headline)
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(12)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(Self.lines.enumerated()), id: \.offset) { _, line in
            render(line)
          }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(width: 600, height: 520)
  }

  @ViewBuilder
  private func render(_ line: Line) -> some View {
    switch line {
    case .version(let text):
      Text(text)
        .font(.title3.weight(.semibold))
        .padding(.top, 14)
    case .section(let text):
      // Breaking-change sections get the warning tint so they stand out
      // when skimming.
      Text(text)
        .font(.headline)
        .foregroundStyle(
          text.localizedCaseInsensitiveContains("breaking")
            ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary)
        )
        .padding(.top, 6)
    case .bullet(let text):
      HStack(alignment: .top, spacing: 8) {
        Text("•")
          .foregroundStyle(.secondary)
        Text(inline(text))
          .fixedSize(horizontal: false, vertical: true)
      }
      .font(.callout)
    case .body(let text):
      Text(inline(text))
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// Inline markdown (bold / code / links); falls back to the raw string.
  private func inline(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text)) ?? AttributedString(text)
  }

  private enum Line {
    case version(String)
    case section(String)
    case bullet(String)
    case body(String)
  }

  private static func load() -> [Line] {
    guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
          let content = try? String(contentsOf: url, encoding: .utf8)
    else { return [.body("Changelog not bundled with this build.")] }

    var lines: [Line] = []
    for raw in content.split(separator: "\n", omittingEmptySubsequences: true) {
      let line = String(raw)
      if line.hasPrefix("# ") {
        // The file's own "# Changelog" title + preamble — the window
        // already has a title, skip down to the first version heading.
        continue
      } else if line.hasPrefix("## ") {
        lines.append(.version(String(line.dropFirst(3))))
      } else if line.hasPrefix("### ") {
        lines.append(.section(String(line.dropFirst(4))))
      } else if line.hasPrefix("- ") {
        lines.append(.bullet(String(line.dropFirst(2))))
      } else if lines.isEmpty {
        // Preamble paragraphs before the first version — skip.
        continue
      } else {
        lines.append(.body(line))
      }
    }
    return lines
  }
}
