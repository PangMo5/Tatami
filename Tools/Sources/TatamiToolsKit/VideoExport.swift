// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - VideoExporter

struct VideoExporter {
  let workspace: Workspace

  var narration: Narration {
    Narration(workspace: workspace)
  }

  static func acceptedFrames(_ record: JSON) -> Bool {
    record["frames"].double > 0 && record["droppedFrames"].double >= 0 && record["droppedFrames"].double / record["frames"]
      .double <= 0.01
  }

  func probe(_ movie: URL) async throws -> JSON {
    try JSON.parse(await runProcess(
      ["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", movie.path],
      capture: true,
    ))
  }

  func validateTake(movie: URL, asset: JSON, info: JSON? = nil) async throws -> (JSON, Double) {
    let record = try JSON.read(movie.replacingExtension("take.json"))
    try require(
      record["schemaVersion"].int == 2 && record["status"].str == "passed",
      "\(movie.path): a passed v2 take is required",
    )
    try require(
      record["scene"].str == asset["scene"].str && record["overlay"].str == "off",
      "\(movie.path): wrong scene or live overlay already burned in",
    )
    try require((record["locale"].string ?? "en") == (asset["locale"].string ?? "en"), "\(movie.path): wrong recording language")
    _ = try narration.verifiedScenes(movie: movie, asset: asset, record: record)
    try require(Self.acceptedFrames(record), "\(movie.path): missing frames or more than 1% capture drops")
    let timeline = try JSON.read(movie.replacingExtension("timeline.json"))
    let mediaInfo: JSON = if let info { info } else { try await probe(movie) }
    let info = mediaInfo
    let duration = info["format"]["duration"].double
    guard let video = info["streams"].array.first(where: { $0["codec_type"].str == "video" })
    else { throw ToolError("Missing video stream: \(movie.path)") }
    let dual = ["dual", "dynamic-dual"].contains(asset["presentation"].str)
    try require(
      video["width"].int == (dual ? 3840 : 1920) && video["height"].int == 1200,
      "\(movie.path): publishing canvas expects 1920x1200 capture",
    )
    try require(duration > 1 && duration <= asset["maxSeconds"].double, "\(movie.path): \(duration)s exceeds editorial budget")
    try require(
      abs(duration - timeline["durationSeconds"].double) <= 0.35,
      "\(movie.path): capture clock and narration differ by more than 350ms",
    )
    guard
      let opening = timeline["events"].array.first(where: { $0["track"].str == "caption" && !$0["text"].str.isEmpty }),
      opening["start"].double <= 0.35
    else { throw ToolError("\(movie.path): opening narration is late or missing") }
    return (record, duration)
  }

  func export(movie: URL, asset: JSON, destination: URL) async throws -> JSON {
    let (record, duration) = try await validateTake(movie: movie, asset: asset)
    let timeline = try narration.revisedTimeline(movie: movie, asset: asset, record: record)
    let target = destination.at(asset["scene"].str + ".mp4")
    try require(!target.exists, "\(target.path) exists; choose a new output folder")
    let scratch = fm.temporaryDirectory.at("tatami-export-" + UUID().uuidString)
    try scratch.makeDirectory()
    defer { try? fm.removeItem(at: scratch) }
    let intermediate = scratch.at("encoded.mp4")
    let styled = scratch.at("film.ass")
    let dual = ["dual", "dynamic-dual"].contains(asset["presentation"].str)
    var subtitles = try FilmPresentation(workspace: workspace).restyle(
      Narration.reviseASS(movie.replacingExtension("ass").text(), timeline: timeline),
      locale: asset["locale"].string ?? "en",
      dual: dual,
    )
    if dual { subtitles = subtitles.replacingOccurrences(of: "PlayResY: 1200", with: "PlayResY: 600") }
    try styled.write(subtitles)
    let geometry = dual ? "scale=1920:600:flags=lanczos" : "scale=1920:1200:flags=lanczos"
    try await runProcess([
      "mpv",
      "--no-config",
      movie.path,
      "--no-audio",
      "--sub-auto=no",
      "--sub-file=" + styled.path,
      "--sub-visibility=yes",
      "--sub-ass-override=no",
      "--vf=lavfi=[fps=30,\(geometry),format=yuv420p],sub",
      "--ovc=libx264",
      "--ovcopts=crf=21,preset=medium,threads=2",
      "--of=mp4",
      "--o=" + intermediate.path,
      "--msg-level=all=warn",
    ])
    try await runProcess([
      "ffmpeg",
      "-hide_banner",
      "-loglevel",
      "error",
      "-i",
      intermediate.path,
      "-map",
      "0:v:0",
      "-c",
      "copy",
      "-movflags",
      "+faststart",
      target.path,
    ])
    let info = try await probe(target)
    guard let video = info["streams"].array.first(where: { $0["codec_type"].str == "video" })
    else { throw ToolError("Export has no video stream") }
    try require(
      video["codec_name"].str == "h264" && video["pix_fmt"].str == "yuv420p",
      "\(target.path): incompatible web encoding",
    )
    try require(abs(info["format"]["duration"].double - duration) <= 0.15, "\(target.path): duration changed during encoding")
    let bytes = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize!
    try require(Double(bytes) <= asset["maxMB"].double * 1_048_576, "\(target.path): exceeds MB budget")
    try await runProcess(["ffmpeg", "-v", "error", "-xerror", "-i", target.path, "-f", "null", "-"])
    let poster = target.replacingExtension("jpg")
    let captions = timeline["events"].array.filter { $0["track"].str == "caption" && !$0["text"].str.isEmpty }
    var posterTime = 0.5
    if !asset["posterCaptionIndex"].isNull {
      let index = asset["posterCaptionIndex"].int
      try require(captions.indices.contains(index), "Poster caption index out of range")
      posterTime = captions[index]["start"].double + 0.3
    }
    try await runProcess([
      "ffmpeg",
      "-v",
      "error",
      "-ss",
      String(posterTime),
      "-i",
      target.path,
      "-frames:v",
      "1",
      "-q:v",
      "2",
      poster.path,
    ])
    let evidence = destination.at("evidence")
    try evidence.makeDirectory()
    let chapterSamples = timeline["events"].array
      .filter { $0["track"].str == "chapter" && !$0["text"].str.isEmpty && $0["end"].double - $0["start"].double > 0.2 }
      .map { min(
        $0["end"].double - 0.1,
        $0["start"].double + 3,
      ) }
    let sampleTimes = Set([0, 0.5, 2, duration * 0.25, duration * 0.5, duration * 0.75, duration - 0.2] + chapterSamples).sorted()
    for (index, second) in sampleTimes.enumerated() {
      try await runProcess([
        "ffmpeg",
        "-v",
        "error",
        "-ss",
        String(max(0, second)),
        "-i",
        target.path,
        "-frames:v",
        "1",
        "-q:v",
        "3",
        evidence.at(asset["scene"].str + "-\(index).jpg").path,
      ])
    }
    for suffix in ["ass", "timeline.json", "take.json", "scene.json"] { try copy(
      movie.replacingExtension(suffix),
      evidence.at(asset["scene"].str + "." + suffix),
    ) }
    try evidence.at(asset["scene"].str + ".ass").write(subtitles)
    try timeline.write(evidence.at(asset["scene"].str + ".edited.timeline.json"))
    try copy(workspace.scene(asset), evidence.at(asset["scene"].str + ".edited.scene.json"))
    return try asset.merging([
      ("durationSeconds", .decimal((duration * 100).rounded(.toNearestOrEven) / 100)),
      ("bytes", .integer(bytes)),
      ("sha256", .string(sha(target))),
      ("sourceSHA256", .string(sha(movie))),
      (
        "sceneSHA256",
        .string(sha(workspace.scene(asset))),
      ),
      ("capturedSceneSHA256", record["sceneSHA256"]),
      ("tatamiVersion", record["tatamiVersion"]),
      ("video", .string(target.lastPathComponent)),
      ("poster", .string(poster.lastPathComponent)),
    ])
  }

  func exportBatch(takes: URL, output: URL, locale: String, scenes: [String]) async throws {
    try require(locales.contains(locale), "Unsupported export locale")
    try require(!output.exists, "Export output already exists")
    let film = try JSON.read(workspace.lab.at("Localization/Films.json"))["strings"]
    let assets = try selectedAssets(workspace: workspace, scenes: scenes).map { asset in
      try require(
        !film[asset["title"].str][locale].str.isEmpty && !film[asset["description"].str][locale].str.isEmpty,
        "Missing film title/description",
      )
      return asset.merging([
        ("locale", .string(locale)),
        ("title", film[asset["title"].str][locale]),
        ("description", film[asset["description"].str][locale]),
      ])
    }
    for asset in assets
      where ["dual", "dynamic-dual"].contains(asset["presentation"].str) && !takes.at(asset["scene"].str + ".mkv").exists
    {
      try await compose(directory: takes, scene: asset["scene"].str, hotplug: asset["presentation"].str == "dynamic-dual")
    }
    func movie(_ asset: JSON) -> URL {
      takes.at(asset["scene"].str + (["dual", "dynamic-dual"].contains(asset["presentation"].str)
          ? ".mkv"
          : ".mov"))
    }
    for asset in assets { _ = try await validateTake(movie: movie(asset), asset: asset) }
    for asset in assets {
      let movie = movie(asset)
      let record = try JSON.read(movie.replacingExtension("take.json"))
      let timeline = try narration.revisedTimeline(movie: movie, asset: asset, record: record)
      try await FilmPresentation.requireFont(
        locale,
        texts: timeline["events"].array.filter { ["caption", "chapter"].contains($0["track"].str) }.map { $0["text"].str },
      )
    }
    try output.makeDirectory()
    var records = [JSON]()
    for asset in assets { print("Exporting \(asset["scene"].str)")
      records.append(try await export(movie: movie(asset), asset: asset, destination: output))
    }
    try FilmPresentation(workspace: workspace).json.write(output.at("theme.json"))
    try JSON.object([("schemaVersion", .integer(1)), ("locale", .string(locale)), ("assets", .array(records))])
      .write(output.at("manifest.json"))
    try VideoGallery(workspace: workspace).reviewBundle(destination: output, records: records)
    print("Review: \(output.at("index.html").path)")
  }

  func compose(directory: URL, scene: String, hotplug: Bool) async throws {
    try require(fullMatch("[A-Za-z0-9_-]+", scene), "Invalid scene name")
    let output = directory.at(scene + ".mkv")
    try require(!output.exists, "Composite already exists")
    if hotplug {
      let main = directory.at(scene + ".mov")
      let secondary = directory.at(scene + ".secondary.mov")
      let metadata = try JSON.read(secondary.replacingExtension("json"))
      var record = try JSON.read(main.replacingExtension("take.json"))
      let start = metadata["start"].double
      let end = metadata["end"].double
      let duration = try await probe(main)["format"]["duration"].double
      try require(0 <= start && start < end && end <= duration + 0.1, "Secondary capture is outside the primary clock")
      try require(Self.acceptedFrames(metadata), "Secondary capture failed quality checks")
      let filters = "[0:v]setpts=PTS-STARTPTS,fps=30[main];[1:v]setpts=PTS-STARTPTS,trim=duration=\(end - start),setpts=PTS+\(start)/TB[secondary];color=c=0x1D1D1F:s=1920x1200:r=30:d=\(duration)[absent];[absent][secondary]overlay=eof_action=pass:repeatlast=0:enable='between(t,\(start),\(end))'[right];[main][right]hstack=inputs=2:shortest=1[out]"
      try await runProcess([
        "ffmpeg",
        "-v",
        "error",
        "-i",
        main.path,
        "-i",
        secondary.path,
        "-filter_complex",
        filters,
        "-map",
        "[out]",
        "-c:v",
        "ffv1",
        "-threads",
        "4",
        "-level",
        "3",
        output.path,
      ])
      try record.write(main.replacingExtension("primary.take.json"))
      record["compositeSources"] = try .array([
        .object([("file", .string(main.lastPathComponent)), ("sha256", .string(sha(main))), ("capture", record["capture"])]),
        .object([("file", .string(secondary.lastPathComponent)), ("sha256", .string(sha(secondary))), ("capture", metadata)]),
      ])
      record["frames"] = .integer(record["frames"].int + metadata["frames"].int)
      record["droppedFrames"] = .integer(record["droppedFrames"].int + metadata["droppedFrames"].int)
      try record.write(main.replacingExtension("take.json"))
    } else {
      let files = try directory.children().filter { fullMatch(
        NSRegularExpression.escapedPattern(for: scene) + #"-[0-9]\.mov"#,
        $0.lastPathComponent,
      ) }
      try require(files.count == 2, "Expected exactly two display recordings")
      let items = try files.map { ($0, try JSON.read($0.replacingExtension("take.json"))) }.sorted { (
        $0.1["capture"]["x"].double,
        $0.1["capture"]["y"].double,
      ) < ($1.1["capture"]["x"].double, $1.1["capture"]["y"].double) }
      try require(
        items.allSatisfy { $0.1["status"].str == "passed" && Self.acceptedFrames($0.1) },
        "A display failed capture acceptance",
      )
      try require(Set(items.map { $0.1["sceneSHA256"].str }).count == 1, "Different scenes in one composite")
      let duration = items.map { $0.1["durationSeconds"].double }.min()!
      var filters = items.enumerated().map { index, item in
        "[\(index):v]setpts=PTS-STARTPTS,tpad=start_duration=\(item.1["capture"]["captureOffsetSeconds"].double):start_mode=clone,trim=duration=\(duration),fps=60[v\(index)]"
      }
      filters.append("[v0][v1]hstack=inputs=2[out]")
      try await runProcess(["ffmpeg", "-v", "error"] + items.flatMap { ["-i", $0.0.path] } + [
        "-filter_complex",
        filters.joined(separator: ";"),
        "-map",
        "[out]",
        "-c:v",
        "ffv1",
        "-level",
        "3",
        output.path,
      ])
      for suffix in ["ass", "timeline.json", "scene.json"] { try copy(
        items[0].0.replacingExtension(suffix),
        output.replacingExtension(suffix),
      ) }
      var record = items[0].1
      record["frames"] = .integer(items.map { $0.1["frames"].int }.min()!)
      record["droppedFrames"] = .integer(items.map { $0.1["droppedFrames"].int }.max()!)
      record["compositeSources"] = .array(try items.map { file, record in
        try .object([("file", .string(file.lastPathComponent)), ("sha256", .string(sha(file))), ("capture", record["capture"])])
      })
      try record.write(output.replacingExtension("take.json"))
    }
    print(output.path)
  }
}

func selectedAssets(workspace: Workspace, scenes: [String]) throws -> [JSON] {
  let assets = try workspace.assets
  let known = Set(assets.map { $0["scene"].str })
  try require(Set(scenes).isSubset(of: known), "Unknown scenes: \(Set(scenes).subtracting(known).sorted())")
  return assets.filter { scenes.isEmpty || scenes.contains($0["scene"].str) }
}
