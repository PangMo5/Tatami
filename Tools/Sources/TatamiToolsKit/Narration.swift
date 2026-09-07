// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct Narration {
  let workspace: Workspace

  static func captureContract(_ scene: JSON) -> JSON {
    var scene = scene
    scene.remove("title")
    scene.remove("summary")
    for field in ["setup", "steps"] where !scene[field].isNull {
      scene[field] = .array(scene[field].array.map { step in
        var step = step
        if ["caption", "chapter"].contains(step["kind"].str) { step["text"] = .bool(!step["text"].str.isEmpty) }
        return step
      })
    }
    return scene
  }

  static func escaped(_ text: String) -> String {
    let protected = text.replacingOccurrences(of: "{", with: "｛").replacingOccurrences(of: "}", with: "｝")
    return replacing(#"\\([Nnh])"#, in: protected) { #"\{}"# + $0[1] }
      .replacingOccurrences(of: "\r\n", with: #"\N"#).replacingOccurrences(of: "\n", with: #"\N"#).replacingOccurrences(
        of: "\r",
        with: #"\N"#,
      )
  }

  static func timestamp(_ seconds: Double) -> String {
    let total = Int((max(0, seconds) * 100).rounded(.toNearestOrEven))
    return String(format: "%d:%02d:%02d.%02d", total / 360_000, total / 6000 % 60, total / 100 % 60, total % 100)
  }

  static func reviseASS(_ original: String, timeline: JSON) throws -> String {
    var output = lines(original).filter { line in
      let fields = line.components(separatedBy: ",")
      return !(line.hasPrefix("Dialogue: ") && fields.count > 3 && ["Caption", "Chapter"].contains(fields[3]))
    }
    for event in timeline["events"].array
      where ["caption", "chapter"].contains(event["track"].str) && !event["text"].str.isEmpty
    {
      let start = event["start"].double
      let end = event["end"].double
      try require(start.isFinite && end.isFinite, "Invalid narration timestamp")
      let text = escaped(event["text"].str).replacingOccurrences(of: " | ", with: #"\N"#)
      output
        .append(
          "Dialogue: 0,\(timestamp(start)),\(timestamp(max(end, start + 0.01))),\(event["track"].str.capitalized),,0,0,0,,{\\fad(100,100)}\(text)"
        )
    }
    return output.joined(separator: "\n") + "\n"
  }

  func verifiedScenes(movie: URL, asset: JSON, record: JSON, current: URL? = nil) throws -> (JSON, JSON) {
    try require(!movie.replacingExtension("rejected.json").exists, "\(movie.path): take rejected during visual review")
    let frozen = movie.replacingExtension("scene.json")
    try require(
      try frozen.exists && sha(frozen) == record["sceneSHA256"].str,
      "\(movie.path): scene changed or frozen capture scene is missing",
    )
    let old = try JSON.read(frozen)
    let new = try JSON.read(current ?? workspace.scene(asset))
    try require(
      Self.captureContract(old) == Self.captureContract(new),
      "\(movie.path): scene changed its actions or timing; re-record before exporting",
    )
    return (old, new)
  }

  func revisedTimeline(movie: URL, asset: JSON, record: JSON, current: URL? = nil) throws -> JSON {
    let (old, new) = try verifiedScenes(movie: movie, asset: asset, record: record, current: current)
    var timeline = try JSON.read(movie.replacingExtension("timeline.json"))
    for track in ["chapter", "caption"] {
      var replacements = [String: String]()
      try require(old["steps"].array.count == new["steps"].array.count, "Changed scene step count")
      for (before, after) in zip(old["steps"].array, new["steps"].array)
        where before["kind"].str == track && !before["text"].str.isEmpty
      {
        let source = before["text"].str
        let target = after["text"].str
        try require(
          replacements[source] == nil || replacements[source] == target,
          "\(movie.path): repeated narration has ambiguous revisions",
        )
        replacements[source] = target
      }
      timeline["events"] = .array(try timeline["events"].array.map { event in
        var event = event
        if event["track"].str == track, !event["text"].str.isEmpty {
          guard let replacement = replacements[event["text"].str]
          else { throw ToolError("\(movie.path): timeline narration does not match its capture scene") }
          event["text"] = .string(replacement)
        }
        return event
      })
    }
    return timeline
  }
}
