// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import DemoAppKit
import Foundation

// MARK: - SceneTimeline

/// Every word the narration put on screen during a take, and the times it was
/// there.
///
/// Captions used to be burned into the frame as the take was shot, which made
/// the words as permanent as the pixels: restyling them, fixing a typo, or
/// translating them all meant shooting the take again. This records them
/// instead, and ``SceneSubtitles`` turns the record into an ASS sidecar that any
/// player can restyle and any translator can edit.
///
/// Times are measured from a `t0` the caller supplies rather than from the first
/// event, because a sidecar has to line up with the movie: `t0` is the moment
/// the recorder started, so a take's pre-roll is part of the offset.
///
/// This is the one part of the lab that reads a clock, and it is measuring the
/// take rather than rendering it. `ContinuousClock` and never `Date`: these are
/// elapsed times, and a wall clock can step underneath them.
@MainActor
public final class SceneTimeline {

  // MARK: Lifecycle

  /// - Parameters:
  ///   - scene: named in both sidecars, so a stray file can be traced back.
  ///   - t0: the instant recording started. A caller that samples this *after*
  ///     the pre-roll shifts every subtitle in the file by that pre-roll.
  public init(scene: String, t0: ContinuousClock.Instant) {
    self.scene = scene
    self.t0 = t0
  }

  // MARK: Public

  /// The three things the overlay draws, and so the three things a sidecar has
  /// to carry. Each is independent: a caption replaces a caption, never a
  /// chapter.
  public enum Track: String, Sendable, CaseIterable {
    case chapter
    case caption
    case keys
  }

  // MARK: - Entry

  /// One stretch of narration: what was on that track, and between which times.
  public struct Entry: Sendable {

    // MARK: Lifecycle

    public init(track: Track, text: String, start: Double, end: Double) {
      self.track = track
      self.text = text
      self.start = start
      self.end = end
    }

    // MARK: Public

    public let track: Track
    public let text: String
    public let start: Double
    public let end: Double

    /// A clear. It carries no words, so it becomes a gap in the subtitles rather
    /// than a line, but it still records the moment the words left the screen.
    public var isClear: Bool { text.isEmpty }

  }

  /// The separator between a caption's headline and the why behind it, spelled
  /// once. The live overlay splits on the same string, so the sidecar and the
  /// screen cannot disagree about where the second line begins.
  ///
  /// `nonisolated` because it is an immutable name: the writer that splits on it
  /// renders text and has no business hopping to the main actor to read a
  /// constant.
  public nonisolated static let captionSeparator = " | "

  public let scene: String

  /// Every recorded event with its end resolved: the next event on the same
  /// track, or the end of the take.
  public var entries: [Entry] {
    records.map { record in
      let close = record.end ?? endOfTake ?? record.start
      return Entry(
        track: record.track,
        text: record.text,
        start: Self.rounded(record.start),
        end: Self.rounded(max(close, record.start))
      )
    }
  }

  /// How long the take ran, or how far it got before it failed.
  public var durationSeconds: Double {
    Self.rounded(endOfTake ?? records.map(\.start).max() ?? 0)
  }

  /// Stamps `text` onto `track` at the current elapsed time.
  ///
  /// Empty text is a clear, and is recorded rather than dropped: whoever
  /// retimes or translates this needs to know when the words left the screen,
  /// not only when they arrived.
  public func record(_ track: Track, text: String) {
    record(track, text: text, at: elapsed)
  }

  public func record(_ track: Track, text: String, at seconds: Double) {
    // The overlay holds whatever it was last told, so re-sending the same words
    // changes nothing on screen. Splitting them into two entries would put a
    // one-frame flicker into a burned copy that the live take never had.
    if let index = openIndex(of: track), records[index].text == text { return }
    closeOpen(track, at: seconds)
    records.append(Record(track: track, text: text, start: seconds, end: nil))
  }

  /// Ends the take. Whatever each track was still showing ends here, which is
  /// what makes the last caption run to the last frame instead of vanishing.
  public func finish(at seconds: Double? = nil) {
    let end = seconds ?? elapsed
    endOfTake = end
    for track in Track.allCases { closeOpen(track, at: end) }
  }

  // MARK: Private

  // MARK: - Record

  /// The mutable form. `end` is nil while that stretch of narration is still on
  /// screen, which is what lets a later event close it.
  private struct Record {
    let track: Track
    let text: String
    let start: Double
    var end: Double?
  }

  private let t0: ContinuousClock.Instant
  private var records = [Record]()
  private var endOfTake: Double?

  /// Centiseconds, because that is all an ASS timestamp can express. Rounding
  /// here rather than in the writer keeps the JSON sidecar and the ASS sidecar
  /// describing the same instants rather than two roundings of them.
  private static func rounded(_ seconds: Double) -> Double {
    (max(0, seconds) * 100).rounded() / 100
  }

  private var elapsed: Double {
    Shell.seconds(ContinuousClock.now - t0)
  }

  private func openIndex(of track: Track) -> Int? {
    records.lastIndex { $0.track == track && $0.end == nil }
  }

  private func closeOpen(_ track: Track, at seconds: Double) {
    guard let index = openIndex(of: track) else { return }
    // Never before its own start: a clock that measured the two events in the
    // wrong order must not produce a negative duration downstream.
    records[index].end = max(seconds, records[index].start)
  }

}

// MARK: - SceneSubtitles

/// Renders a ``SceneTimeline`` as the two sidecars that travel with a take: the
/// ASS subtitles, and the raw event list for anything else that wants them.
///
/// Getting ASS wrong is quiet. A malformed timestamp, an unescaped brace or a
/// style name that does not exist does not raise anything: the line simply never
/// appears. Everything here is written for that.
public enum SceneSubtitles {

  // MARK: Public

  // MARK: - Resolution

  /// The pixel size of the movie the subtitles belong to.
  public struct Resolution: Sendable, Equatable {

    // MARK: Lifecycle

    public init(width: Int, height: Int) {
      self.width = width
      self.height = height
    }

    // MARK: Public

    /// What the demo VM records at, and only a last resort. `PlayResX`/`PlayResY`
    /// that do not match the movie scale every font size and margin in the file
    /// by the mismatch, silently.
    public static let fallback = Resolution(width: 1920, height: 1200)

    public let width: Int
    public let height: Int

  }

  /// The whole `.ass` file.
  ///
  /// - Parameter drawnLive: tracks the overlay already painted into the frames.
  ///   They are left out, because this file exists to be burned in and burning
  ///   a track that is already in the pixels draws it twice. A take shot with
  ///   `--overlay keys` did exactly that once: the overlay's `⌃ ⌥ L` with the
  ///   sidecar's copy stacked above it. The full record of the take, live
  ///   tracks included, is in the `.timeline.json` beside this.
  @MainActor
  public static func ass(
    _ timeline: SceneTimeline,
    resolution: Resolution,
    drawnLive: Set<SceneTimeline.Track> = []
  ) -> String {
    let omitted = SceneTimeline.Track.allCases
      .filter { drawnLive.contains($0) }
      .map(\.rawValue)
    var lines = [
      "[Script Info]",
      "; Written by democtl for scene \(timeline.scene).",
      "; Restyle or translate this file and burn it in with:",
      ";   democtl subtitle burn <movie> --ass <this file>",
      omitted.isEmpty
        ? "; Carries every track: the take was shot with the overlay off."
        : "; Omits \(omitted.joined(separator: ", ")): the take already has "
          + "\(omitted.count == 1 ? "that" : "those") drawn into the frames.",
      "Title: \(timeline.scene)",
      "ScriptType: v4.00+",
      // 0 = wrap inside the margins, evenly. `\N` is still a hard break in this
      // mode, so a caption keeps its two lines; what this buys is that a long
      // one folds rather than running off both edges of the frame, which is what
      // WrapStyle 2 does and does silently.
      "WrapStyle: 0",
      "ScaledBorderAndShadow: yes",
      "YCbCr Matrix: None",
      "PlayResX: \(resolution.width)",
      "PlayResY: \(resolution.height)",
      "",
      "[V4+ Styles]",
      "Format: \(styleFormat)",
    ]
    lines += styles(for: resolution).map(\.row)
    lines += ["", "[Events]", "Format: \(eventFormat)"]
    lines += timeline.entries
      .filter { !drawnLive.contains($0.track) }
      .compactMap { dialogue($0, resolution: resolution) }
    // A trailing newline: a file that ends mid-line is a file some parsers drop
    // the last event from.
    return lines.joined(separator: "\n") + "\n"
  }

  /// The same events as data, for any tool that is not a subtitle renderer.
  /// Clears are included: "the words left here" is as much of the timeline as
  /// "the words arrived here".
  @MainActor
  public static func timelineJSON(_ timeline: SceneTimeline, resolution: Resolution) throws -> Data {
    let events: [[String: Any]] = timeline.entries.map { entry in
      [
        "track": entry.track.rawValue,
        "text": entry.text,
        "start": seconds(entry.start),
        "end": seconds(entry.end),
      ]
    }
    let payload: [String: Any] = [
      "scene": timeline.scene,
      "captionSeparator": SceneTimeline.captionSeparator,
      "durationSeconds": seconds(timeline.durationSeconds),
      "resolution": ["width": resolution.width, "height": resolution.height],
      "events": events,
    ]
    // Sorted and pretty on purpose: this file lands in a repository next to the
    // movie, and a diffable sidecar is worth the bytes.
    return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
  }

  /// ASS escaping.
  ///
  /// `{` opens an override block, so a caption holding one would render as
  /// styling, or not at all, with nothing said about it.
  ///
  /// A backslash is the awkward one: ASS has no escape for it, and doubling it
  /// the way most formats would is simply wrong here. It rendered the `\` key's
  /// keycast as two backslashes. Only three sequences are special — `\N`, `\n`
  /// and `\h` — so the backslash is emitted as itself and an empty override
  /// block is slipped in front of the letter that would have made it a command.
  /// `{}` draws nothing and breaks the sequence.
  public static func escaped(_ text: String) -> String {
    // Braces first, so the empty block inserted below is not escaped in turn.
    var out = text.replacingOccurrences(of: "{", with: "\\{")
    out = out.replacingOccurrences(of: "}", with: "\\}")
    out = out.replacingOccurrences(
      of: "\\\\([nNh])",
      with: "\\\\{}$1",
      options: .regularExpression
    )
    // A hard line break inside an event is `\N`, and this runs last so the
    // break it produces is not itself neutralised. A real newline would end the
    // Dialogue row and truncate the caption to its first line.
    out = out.replacingOccurrences(of: "\r\n", with: "\\N")
    out = out.replacingOccurrences(of: "\n", with: "\\N")
    out = out.replacingOccurrences(of: "\r", with: "\\N")
    return out
  }

  /// `H:MM:SS.cc`, the only time format ASS accepts.
  public static func timestamp(_ seconds: Double) -> String {
    let total = Int((max(0, seconds) * 100).rounded())
    return String(
      format: "%d:%02d:%02d.%02d",
      total / 360_000,
      (total / 6_000) % 60,
      (total / 100) % 60,
      total % 100
    )
  }

  // MARK: Private

  private static let styleFormat = "Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding"
  private static let eventFormat = "Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"
  private static let referenceHeight = 1200.0

  private struct Style {
    let row: String
  }

  /// Narration, chapters and actual keys are drawn inside the desktop image.
  /// A translucent backing keeps them readable over both light and dark apps.
  private static func styles(for resolution: Resolution) -> [Style] {
    func style(_ name: String, size: Double, color: String, bold: Int, alignment: Int,
               left: Double, right: Double, vertical: Double) -> Style {
      Style(row: "Style: \(name),Helvetica Neue,\(scaled(size, resolution)),\(color),\(color),&H40141414,&H40141414,\(bold),0,0,0,100,100,0,0,3,10,0,\(alignment),\(scaled(left, resolution)),\(scaled(right, resolution)),\(scaled(vertical, resolution)),1")
    }
    return [
      style("Caption", size: 42, color: FilmTheme.text, bold: -1, alignment: 2,
            left: 110, right: 110, vertical: 96),
      style("Chapter", size: 26, color: FilmTheme.accent, bold: -1, alignment: 7,
            left: 32, right: 700, vertical: 54),
      style("Keys", size: 38, color: FilmTheme.accent, bold: 0, alignment: 9,
            left: 1300, right: 32, vertical: 54),
    ]
  }

  /// A time, as two decimals rather than as a `Double`.
  ///
  /// A double already rounded to centiseconds still serializes as
  /// `0.80000000000000004`, because 0.8 has no exact binary form. The number is
  /// correct and the file is unreadable, and this one is meant to be read and
  /// diffed by people.
  private static func seconds(_ value: Double) -> NSDecimalNumber {
    NSDecimalNumber(string: String(format: "%.2f", value))
  }

  private static func scaled(_ value: Double, _ resolution: Resolution) -> Int {
    Int((value * Double(resolution.height) / referenceHeight).rounded())
  }

  private static func dialogue(
    _ entry: SceneTimeline.Entry,
    resolution: Resolution
  ) -> String? {
    guard !entry.isClear else { return nil }
    // A centisecond is the finest gap an ASS timestamp can express, so a line
    // whose end rounds onto its start renders for no frames at all. Nudged
    // rather than dropped: the words stay in the file, where a person editing
    // it can see the scene replaced them instantly and fix the scene.
    let end = max(entry.end, entry.start + 0.01)
    let style: String
    let text: String
    switch entry.track {
    case .chapter:
      style = "Chapter"
      text = escaped(entry.text)
    case .caption:
      style = "Caption"
      text = captionText(entry.text, resolution: resolution)
    case .keys:
      style = "Keys"
      // The caps, not the config spelling. A scene records the chord exactly as
      // `config.toml` writes it, and a viewer reads `⌃⌥L`, not `ctrl + alt - l`.
      text = escaped(KeyChordFormatter.display(from: entry.text))
    }
    // The keycast is on its own layer so it draws over the caption card if a
    // long caption ever reaches across to it.
    let layer = entry.track == .keys ? 1 : 0
    return "Dialogue: \(layer),\(timestamp(entry.start)),\(timestamp(end)),\(style),,0,0,0,,{\\fad(100,100)}\(text)"
  }

  /// A caption is `"<headline> | <why>"`. The headline carries the sentence, the
  /// explanation goes below it, smaller and dimmer, over the captured desktop.
  private static func captionText(_ raw: String, resolution: Resolution) -> String {
    let parts = raw.components(separatedBy: SceneTimeline.captionSeparator)
    let headline = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
    let why = parts.count > 1
      ? parts.dropFirst().joined(separator: SceneTimeline.captionSeparator)
        .trimmingCharacters(in: .whitespaces)
      : ""
    let pad = ""
    guard !why.isEmpty else { return pad + escaped(headline) + pad }
    let whySize = "\\fs\(scaled(25, resolution))"
    return pad + escaped(headline) + pad
      + "\\N{\(whySize)\\b0\\1c&H\(FilmTheme.secondary.dropFirst(4))&}"
      + pad + escaped(why) + pad
  }

}

// MARK: - SceneSidecars

/// Writes the two sidecars next to a take.
public enum SceneSidecars {

  /// Writes `<movie>.ass` and `<movie>.timeline.json`.
  ///
  /// Called even when the scene failed partway through: the half of a take that
  /// did happen is exactly the part somebody has to diagnose, and a failed take
  /// with no record of what it managed to narrate is a take nobody can read.
  @MainActor
  @discardableResult
  public static func write(
    _ timeline: SceneTimeline,
    besides movie: URL,
    resolution: SceneSubtitles.Resolution,
    drawnLive: Set<SceneTimeline.Track> = []
  ) throws -> [URL] {
    let subtitles = LabPaths.subtitleFile(for: movie)
    let json = LabPaths.timelineFile(for: movie)
    try FileManager.default.createDirectory(
      at: movie.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let ass = SceneSubtitles.ass(timeline, resolution: resolution, drawnLive: drawnLive)
    try Data(ass.utf8).write(to: subtitles, options: .atomic)
    try SceneSubtitles.timelineJSON(timeline, resolution: resolution).write(to: json, options: .atomic)
    return [subtitles, json]
  }

}
