// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TatamiToolsKit

var testWorkspace: Workspace {
  Workspace(root: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent())
}

// MARK: - TemporaryFixture

struct TemporaryFixture {
  init() throws {
    directory = fm.temporaryDirectory.at("tatami-tools-test-" + UUID().uuidString)
    try directory.makeDirectory()
  }

  let directory: URL

  func remove() {
    try? fm.removeItem(at: directory)
  }
}

@Test
func `localized scenes still match accepted scene data`() throws {
  for (file, text) in try SceneLocalizer(workspace: testWorkspace).outputs() { #expect(
    try JSON.read(file) == JSON.parse(text),
    "\(file.path)",
  ) }
}

@Test
func `narration edits preserve input and clock`() throws {
  let fixture = try TemporaryFixture()
  defer { fixture.remove() }
  let movie = fixture.directory.at("demo.mov")
  let current = fixture.directory.at("current.json")
  var scene = try JSON
    .parse(
      #"{"name":"demo","title":"Title","steps":[{"kind":"caption","text":"Old words"},{"kind":"key","chord":"cmd - n"},{"kind":"beat","ms":1200},{"kind":"typeText","app":"Docs","text":"Actual input"}]}"#
    )
  try scene.write(movie.replacingExtension("scene.json"))
  let record = try JSON.object([("sceneSHA256", .string(sha(movie.replacingExtension("scene.json"))))])
  let timeline = try JSON
    .parse(
      #"{"events":[{"track":"caption","text":"Old words","start":0.2,"end":3},{"track":"keys","text":"cmd - n","start":0.8,"end":2}]}"#
    )
  try timeline.write(movie.replacingExtension("timeline.json"))
  scene["steps"][0]["text"] = .string("New words")
  try scene.write(current)
  let narration = Narration(workspace: testWorkspace)
  let revised = try narration.revisedTimeline(movie: movie, asset: .object([]), record: record, current: current)
  #expect(revised["events"][0] == timeline["events"][0].merging([("text", .string("New words"))]))
  #expect(revised["events"][1] == timeline["events"][1])
  for (index, field, value) in [
    (1, "chord", JSON.string("cmd - w")),
    (2, "ms", .integer(1500)),
    (3, "text", .string("Different input")),
  ] {
    var changed = scene
    changed["steps"][index][field] = value
    try changed.write(current)
    #expect(throws: (any Error).self) { try narration.revisedTimeline(
      movie: movie,
      asset: .object([]),
      record: record,
      current: current,
    ) }
  }
  try scene.write(current)
  try movie.replacingExtension("rejected.json").write("{}")
  #expect(throws: (any Error).self) { try narration.verifiedScenes(
    movie: movie,
    asset: .object([]),
    record: record,
    current: current,
  ) }
  try fm.removeItem(at: movie.replacingExtension("rejected.json"))
  try movie.replacingExtension("scene.json").write("{}")
  #expect(throws: (any Error).self) { try narration.verifiedScenes(
    movie: movie,
    asset: .object([]),
    record: record,
    current: current,
  ) }
}

@Test
func `revised subtitles keep actual keycasts`() throws {
  let key = "Dialogue: 1,0:00:00.80,0:00:02.00,Keys,,0,0,0,,⌘N"
  let original = "Dialogue: 0,0:00:00.20,0:00:03.00,Caption,,0,0,0,,Old words\n" + key
  let timeline = try JSON.parse(#"{"events":[{"track":"caption","text":"새 창이 열려요.","start":0.2,"end":3}]}"#)
  let output = try Narration.reviseASS(original, timeline: timeline)
  #expect(output.contains(key))
  #expect(!output.contains("Old words"))
  #expect(output.contains("새 창이 열려요."))
  #expect(Narration.escaped(#"{x}\N"#) == #"｛x｝\{}N"#)
}

@Test
func `subtitle styles remain inside the desktop`() throws {
  let styles = ["Caption", "Chapter", "Keys"].map { name in
    "Style: " + [
      name,
      "Helvetica Neue",
      "36",
      "&HFFFFFF",
      "&HFFFFFF",
      "&HFF000000",
      "&HFF000000",
      "0",
      "0",
      "0",
      "0",
      "100",
      "100",
      "0",
      "0",
      "1",
      "0",
      "0",
      "1",
      "128",
      "530",
      "24",
      "1",
    ].joined(separator: ",")
  }.joined(separator: "\n")
  let result = try FilmPresentation(workspace: testWorkspace).restyle(styles, locale: "ko")
  let rows = lines(result).map { String($0.dropFirst(7)).components(separatedBy: ",") }
  #expect(Array(rows[0][18..<22]) == ["2", "110", "110", "96"])
  #expect(Array(rows[1][18..<22]) == ["7", "32", "700", "54"])
  #expect(Array(rows[2][18..<22]) == ["9", "1300", "32", "54"])
  #expect(rows.allSatisfy { $0[15] == "3" })
}

@Test
func `fonts must match and cover every caption glyph`() async throws {
  await #expect(throws: (any Error).self) { try await FilmPresentation.requireFont(
    "zh-Hant",
    texts: ["視窗"],
    resolved: "Verdana\n20-7e\n",
  ) }
  await #expect(throws: (any Error).self) { try await FilmPresentation.requireFont(
    "zh-Hant",
    texts: ["視窗"],
    resolved: "Heiti TC\n20-7e\n",
  ) }
  try await FilmPresentation.requireFont("en", texts: ["A window"], resolved: "Helvetica Neue\n20-7e\n")
}

@Test
func `export rejects unaccepted captures`() async throws {
  let fixture = try TemporaryFixture()
  defer { fixture.remove() }
  let movie = fixture.directory.at("tour.mov")
  let asset = try JSON.parse(#"{"scene":"tour","maxSeconds":48}"#)
  try copy(testWorkspace.scene(asset), movie.replacingExtension("scene.json"))
  var record = try JSON
    .parse(#"{"schemaVersion":2,"status":"passed","scene":"tour","overlay":"off","frames":1800,"droppedFrames":0}"#)
  record["sceneSHA256"] = .string(try sha(testWorkspace.scene(asset)))
  let timeline = try JSON.parse(#"{"durationSeconds":30,"events":[{"track":"caption","text":"Start","start":0.1}]}"#)
  let info = try JSON.parse(#"{"format":{"duration":"30.1"},"streams":[{"codec_type":"video","width":1920,"height":1200}]}"#)
  try record.write(movie.replacingExtension("take.json"))
  try timeline.write(movie.replacingExtension("timeline.json"))
  let exporter = VideoExporter(workspace: testWorkspace)
  #expect(try await exporter.validateTake(movie: movie, asset: asset, info: info).1 == 30.1)
  for (key, value) in [
    ("status", JSON.string("failed")),
    ("sceneSHA256", .string("stale")),
    ("overlay", .string("keys")),
    ("droppedFrames", .integer(25)),
  ] {
    try record.merging([(key, value)]).write(movie.replacingExtension("take.json"))
    await #expect(throws: (any Error).self) { try await exporter.validateTake(movie: movie, asset: asset, info: info) }
  }
  try record.write(movie.replacingExtension("take.json"))
  try timeline.merging([("durationSeconds", .integer(26))]).write(movie.replacingExtension("timeline.json"))
  await #expect(throws: (any Error).self) { try await exporter.validateTake(movie: movie, asset: asset, info: info) }
  var late = timeline
  late["events"][0]["start"] = .decimal(1.5)
  try late.write(movie.replacingExtension("timeline.json"))
  await #expect(throws: (any Error).self) { try await exporter.validateTake(movie: movie, asset: asset, info: info) }
  try timeline.write(movie.replacingExtension("timeline.json"))
  var long = info
  long["format"]["duration"] = .string("60")
  await #expect(throws: (any Error).self) { try await exporter.validateTake(movie: movie, asset: asset, info: long) }
}

@Test
func `process arguments remain literal and failures propagate`() async throws {
  let literal = #"spaces; $(not-a-command) `unchanged`"#
  #expect(try await runProcess(["/bin/echo", literal], capture: true) == literal + "\n")
  await #expect(throws: (any Error).self) { try await runProcess(["/usr/bin/false"], capture: true) }
}

@Test
func `cancelled subprocess does not outlive its task`() async throws {
  let started = ContinuousClock.now
  let child = Task { try await runProcess(["/bin/sleep", "30"], capture: true) }
  try await Task.sleep(for: .milliseconds(100))
  child.cancel()
  await #expect(throws: (any Error).self) { try await child.value }
  #expect(started.duration(to: .now) < .seconds(5))
}

@Test
func `incomplete publication cannot become an empty successful batch`() throws {
  let fixture = try TemporaryFixture()
  defer { fixture.remove() }
  let workspace = Workspace(root: fixture.directory)
  let file = fixture.directory.at("DemoLab/publication.json")
  for invalid in [#"{}"#, #"{"assets":[]}"#, #"{"assets":[{"scene":"demo"}]}"#] {
    try file.write(invalid)
    #expect(throws: (any Error).self) { try workspace.assets }
  }
}

@Test
func `invalid copy cannot remove an existing artifact`() throws {
  let fixture = try TemporaryFixture()
  defer { fixture.remove() }
  let artifact = fixture.directory.at("accepted.json")
  try artifact.write("accepted evidence")
  #expect(throws: (any Error).self) { try copy(artifact, artifact) }
  #expect(throws: (any Error).self) { try copy(fixture.directory.at("missing.json"), artifact) }
  #expect(try artifact.text() == "accepted evidence")
}

@Test
func `replacing poster changes its cache key without changing the video URL`() throws {
  let fixture = try TemporaryFixture()
  defer { fixture.remove() }
  let poster = fixture.directory.at("borrow.jpg")
  try poster.write("first poster")
  let asset = try JSON
    .parse(
      #"{"scene":"borrow","locale":"en","title":"Borrow","description":"Borrow","video":"borrow.mp4","poster":"borrow.jpg","sha256":"0123456789abcdef","durationSeconds":14}"#
    )
  let gallery = try VideoGallery(workspace: testWorkspace)
  let first = try gallery.collection("borrow", assets: [asset], mediaDirectory: fixture.directory)
  try poster.write("updated poster")
  let second = try gallery.collection("borrow", assets: [asset], mediaDirectory: fixture.directory)
  #expect(first != second)
  #expect(first.contains("borrow.mp4?v=0123456789ab"))
  #expect(second.contains("borrow.mp4?v=0123456789ab"))
  #expect(try second.contains("borrow.jpg?v=" + sha(poster).prefix(12)))
}

@Test
func `poster selection uses the configured time and rejects invalid frames`() throws {
  let asset = try JSON.parse(#"{"posterSeconds":5}"#)
  #expect(try VideoExporter.posterTime(asset: asset, timeline: .object([]), duration: 14) == 5)
  for second in [-1, 14, 20] {
    #expect(throws: (any Error).self) {
      try VideoExporter.posterTime(asset: .object([("posterSeconds", .integer(second))]), timeline: .object([]), duration: 14)
    }
  }
  #expect(throws: (any Error).self) {
    try VideoExporter.posterTime(asset: asset.merging([("posterCaptionIndex", .integer(0))]), timeline: .object([]), duration: 14)
  }
}
