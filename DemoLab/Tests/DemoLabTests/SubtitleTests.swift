// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import DemoAppKit
@testable import DemoCtlKit
import Foundation
import Testing

// MARK: - KeyChordFormatterTests

@Suite("Key chords")
struct KeyChordFormatterTests {

  @Test("reads Tatami's own spelling into caps, in keyboard order")
  func caps() {
    #expect(KeyChordFormatter.caps(from: "ctrl + alt - l") == ["⌃", "⌥", "L"])
    // Config order is whatever the author typed; the caps are always canonical.
    #expect(KeyChordFormatter.caps(from: "cmd + shift + ctrl - 3") == ["⌃", "⇧", "⌘", "3"])
    #expect(KeyChordFormatter.caps(from: "alt - return") == ["⌥", "↩"])
    #expect(KeyChordFormatter.caps(from: "f1") == ["F1"])
    #expect(KeyChordFormatter.caps(from: "  ").isEmpty)
  }

  @Test("finds the separator from the end, so a literal dash is still a key")
  func literalDash() {
    #expect(KeyChordFormatter.caps(from: "ctrl + alt - -") == ["⌃", "⌥", "-"])
  }

  @Test("spells long-form modifiers the same as short ones")
  func synonyms() {
    #expect(
      KeyChordFormatter.caps(from: "control + option + command - k")
        == KeyChordFormatter.caps(from: "ctrl + alt + cmd - k")
    )
  }

}

// MARK: - SubtitleTests

@MainActor
@Suite("Subtitles")
struct SubtitleTests {

  @Test("the sidecar carries what the overlay did not draw")
  func complement() {
    let timeline = SceneTimeline(scene: "t", t0: .now)
    timeline.record(.chapter, text: "Chapter", at: 0)
    timeline.record(.caption, text: "Headline | why", at: 1)
    timeline.record(.keys, text: "ctrl + alt - l", at: 2)
    timeline.finish(at: 3)

    // A take shot with `--overlay keys` has the caps in its pixels already.
    let burnable = SceneSubtitles.ass(timeline, resolution: .fallback, drawnLive: [.keys])
    #expect(!burnable.contains("Keys,,"))
    #expect(burnable.contains("Caption,,"))
    #expect(burnable.contains("Chapter,,"))

    // With the overlay off, the sidecar is the whole narration.
    let complete = SceneSubtitles.ass(timeline, resolution: .fallback)
    #expect(complete.contains("Keys,,"))
  }

  @Test("keycaps are burned as caps, never as the config spelling")
  func keycaps() {
    let timeline = SceneTimeline(scene: "t", t0: .now)
    timeline.record(.keys, text: "ctrl + alt - l", at: 0)
    timeline.finish(at: 2)

    let ass = SceneSubtitles.ass(timeline, resolution: .fallback)
    #expect(ass.contains("⌃ ⌥ L"))
    #expect(!ass.contains("ctrl + alt - l"))
  }

  @Test("a caption stays in the export footer without an opaque box")
  func captionIsOneEvent() {
    let timeline = SceneTimeline(scene: "t", t0: .now)
    timeline.record(.caption, text: "Headline\(SceneTimeline.captionSeparator)why it matters", at: 0)
    timeline.finish(at: 2)

    let ass = SceneSubtitles.ass(timeline, resolution: .fallback)
    let captions = ass.split(separator: "\n").filter { $0.contains(",Caption,,") }
    #expect(captions.count == 1)
    let event = String(captions[0])
    #expect(event.contains("Headline"))
    #expect(event.contains("why it matters"))
    // `\r` restarts the style mid-event, and with it the box: that is what put
    // a step in the card. Inline overrides keep one box.
    #expect(!event.contains("\\r"))

    // The export footer carries plain text, without an opaque box or outline.
    #expect(styleField("BorderStyle", of: "Caption", in: ass) == "1")
    #expect(styleField("Outline", of: "Caption", in: ass) == "0")
  }

  @Test("a clear ends the words rather than writing an empty line")
  func clears() {
    let timeline = SceneTimeline(scene: "t", t0: .now)
    timeline.record(.caption, text: "Headline", at: 0)
    timeline.record(.caption, text: "", at: 1)
    timeline.finish(at: 2)

    let ass = SceneSubtitles.ass(timeline, resolution: .fallback)
    #expect(ass.split(separator: "\n").filter { $0.hasPrefix("Dialogue:") }.count == 1)
  }

  // MARK: Private

  /// Reads a `Style:` row through its own `Format:` header rather than by a
  /// counted offset, because the offset is exactly the thing that goes wrong
  /// when a column is added.
  private func styleField(_ column: String, of style: String, in ass: String) -> String? {
    let rows = ass.split(separator: "\n", omittingEmptySubsequences: false)
    guard
      let format = rows.first(where: { $0.hasPrefix("Format: Name,") }),
      let row = rows.first(where: { $0.hasPrefix("Style: \(style),") })
    else { return nil }
    let columns = format.dropFirst("Format: ".count)
      .components(separatedBy: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
    let values = row.dropFirst("Style: ".count).components(separatedBy: ",")
    guard let index = columns.firstIndex(of: column), values.indices.contains(index) else { return nil }
    return values[index]
  }

}

// MARK: - EscapingTests

@Suite("ASS escaping")
struct EscapingTests {

  @Test("a literal backslash stays one backslash")
  func backslash() {
    // The `\` key's own keycast. Doubling it, which is what most formats want,
    // put two backslashes on screen.
    #expect(SceneSubtitles.escaped("\\") == "\\")
    #expect(SceneSubtitles.escaped("⌃ ⌥ ⇧ \\") == "⌃ ⌥ ⇧ \\")
  }

  @Test("a backslash cannot turn the text after it into a command")
  func neutralisesCommands() {
    // `\N` is a hard break, `\h` a hard space: text holding either must not
    // become one.
    #expect(SceneSubtitles.escaped("C:\\next") == "C:\\{}next")
    #expect(SceneSubtitles.escaped("a\\Nb") == "a\\{}Nb")
    #expect(SceneSubtitles.escaped("a\\hb") == "a\\{}hb")
  }

  @Test("braces cannot open an override block")
  func braces() {
    // The point is the braces: whatever the renderer makes of the rest, it can
    // no longer be read as styling.
    #expect(SceneSubtitles.escaped("{\\an8}") == "\\{\\an8\\}")
  }

  @Test("a real newline becomes the hard break, and survives the pass above")
  func newlines() {
    #expect(SceneSubtitles.escaped("a\nb") == "a\\Nb")
    #expect(SceneSubtitles.escaped("a\r\nb") == "a\\Nb")
  }

}
