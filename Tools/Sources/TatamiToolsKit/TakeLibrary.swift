// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct TakeLibrary: Sendable {
  struct Candidate: Sendable {
    let folder: URL
    let bases: [String]
    let loss: Double
  }

  static let sidecars = ["mov", "ass", "timeline.json", "take.json", "scene.json"]

  let workspace: Workspace

  func candidate(folder: URL, asset: JSON, locale: String, enforceBudget: Bool) throws -> Candidate? {
    let name = asset["scene"].str
    let dual = asset["presentation"].str == "dual"
    let pattern = NSRegularExpression.escapedPattern(for: name) + (dual ? #"-[0-9]\.take\.json"# : #"\.take\.json"#)
    let files = try folder.children().filter { fullMatch(pattern, $0.lastPathComponent) }
    if files.count != (dual ? 2 : 1) { return nil }
    let records = try files.map(JSON.read)
    guard
      records
        .allSatisfy({
          $0["locale"].str == locale && $0["status"].str == "passed" && VideoExporter
            .acceptedFrames($0) && (!enforceBudget || $0["durationSeconds"].double <= asset["maxSeconds"].double) })
    else { return nil }
    let localized = asset.merging([("locale", .string(locale))])
    let bases = files.map { String($0.lastPathComponent.dropLast(".take.json".count)) }
    do {
      for (base, record) in zip(bases, records) {
        _ = try Narration(workspace: workspace).verifiedScenes(movie: folder.at(base + ".mov"), asset: localized, record: record)
        for suffix in Self.sidecars { try require(
          folder.at(base + "." + suffix).exists,
          "Missing original/sidecar: \(base).\(suffix)",
        ) }
      }
      if asset["presentation"].str == "dynamic-dual" {
        let metadata = try JSON.read(folder.at(name + ".secondary.json"))
        try require(
          VideoExporter.acceptedFrames(metadata) && folder.at(name + ".secondary.mov").exists,
          "Missing or failed secondary capture",
        )
      }
    } catch {
      // A rejected/stale candidate remains evidence; another explicitly supplied
      // batch may contain the accepted take. Selection fails if none qualifies.
      print("Rejected candidate \(locale)/\(name) in \(folder.lastPathComponent): \(error)")
      return nil
    }
    return Candidate(folder: folder, bases: bases, loss: records.map { $0["droppedFrames"].double / $0["frames"].double }.max()!)
  }

  func select(output: URL, batches: [URL], selectedLocales: [String]) throws {
    try require(!output.exists, "Selection output already exists")
    let assets = try workspace.assets
    var selected = [(String, [(JSON, Candidate)])]()
    for locale in selectedLocales {
      var scenes = [(JSON, Candidate)]()
      for asset in assets {
        let candidates = try batches.compactMap { try candidate(folder: $0, asset: asset, locale: locale, enforceBudget: true) }
        guard let best = candidates.min(by: { ($0.loss, $0.folder.path) < ($1.loss, $1.folder.path) })
        else { throw ToolError("No current accepted take: \(locale)/\(asset["scene"].str)") }
        scenes.append((asset, best))
      }
      selected.append((locale, scenes))
    }
    try output.makeDirectory()
    var report = [(String, JSON)]()
    for (locale, scenes) in selected {
      var values = [(String, JSON)]()
      for (asset, selection) in scenes {
        for base in selection.bases {
          let extras = asset["presentation"].str == "dynamic-dual" ? ["secondary.mov", "secondary.json"] : []
          for suffix in Self.sidecars + extras { try copy(
            selection.folder.at(base + "." + suffix),
            output.at(locale + "/" + base + "." + suffix),
          ) }
        }
        values.append((
          asset["scene"].str,
          .object([("batch", .string(selection.folder.path)), ("files", .array(selection.bases.map(JSON.string)))]),
        ))
      }
      report.append((locale, .object(values)))
    }
    try JSON.object(report).write(output.at("selection.json"))
    print("Selected \(selected.reduce(0) { $0 + $1.1.count }) current passed films")
  }

  func control(_ arguments: [String], locale: String = "en") async throws {
    let start = ContinuousClock.now
    defer { print("PHASE \(arguments[0]) \(start.duration(to: .now))") }
    let binary = workspace.lab.at(".build/DemoLab/bin/democtl")
    try require(fm.isExecutableFile(atPath: binary.path), "Run tatami-tools bundle-apps before recording")
    try await runProcess(
      [binary.path] + arguments,
      cwd: workspace.lab,
      environment: [
        "DEMOLAB_ROOT": workspace.lab.path,
        "DEMOLAB_NO_BUILD": "1",
        "DEMOLAB_LOCALE": locale,
        "DEMOLAB_LOCALIZATION_DIR": workspace.lab.at(".build/DemoLab/Localization").path,
      ],
    )
  }

  func capture(output: URL, scenes: [String], fps: Int, locale: String, continueOnError: Bool) async throws {
    try require([30, 60].contains(fps), "FPS must be 30 or 60")
    let assets = try selectedAssets(workspace: workspace, scenes: scenes)
    try output.makeDirectory()
    let existing = try output.children().map(\.lastPathComponent)
    for asset in assets {
      let name = NSRegularExpression.escapedPattern(for: asset["scene"].str)
      try require(
        !existing.contains { fullMatch(name + #"(?:\..*|-[0-9]\..*)"#, $0) },
        "Existing take: \(asset["scene"].str); use a new output directory",
      )
    }
    var results = [JSON]()
    var fatalError: (any Error)?
    do {
      for asset in assets {
        let name = asset["scene"].str
        print("CAPTURE \(name)")
        do {
          try await control(["reset"], locale: locale)
          try await control(["display", "disconnect"], locale: locale)
          if asset["presentation"].str == "dual" { try await control(["display", "connect"], locale: locale) }
          try await control(["seed"] + asset["seedOptions"].array.map(\.str), locale: locale)
          try await control(
            [
              "take",
              name,
              "--fps",
              String(fps),
              "--display",
              asset["presentation"].str == "dual" ? "all" : "main",
              "--output",
              output.at(name + ".mov").path,
            ],
            locale: locale,
          )
          let files = try output.children()
            .filter { $0.lastPathComponent.hasPrefix(name) && $0.lastPathComponent.hasSuffix(".take.json") }
          try require(files.count == (asset["presentation"].str == "dual" ? 2 : 1), "Missing capture manifests")
          for file in files { let record = try JSON.read(file)
            try require(
              record["status"].str == "passed" && VideoExporter.acceptedFrames(record),
              "Capture quality failed: \(file.lastPathComponent)",
            )
          }
          results.append(.object([("scene", .string(name)), ("status", .string("passed"))]))
        } catch {
          results.append(.object([
            ("scene", .string(name)),
            ("status", .string("failed")),
            ("error", .string(String(describing: error))),
          ]))
          print("CAPTURE FAILED: \(name): \(error)")
          try JSON.array(results).write(output.at("capture-report.json"))
          if !continueOnError || Task.isCancelled { throw error }
        }
        try JSON.array(results).write(output.at("capture-report.json"))
      }
    } catch { fatalError = error }
    // Cleanup must run even after cancellation to restore the VM's display state.
    let cleanupErrors = await Task {
      var errors = [String]()
      for command in [["quit"], ["display", "disconnect"]] {
        do { try await control(command, locale: locale) } catch { errors.append(String(describing: error)) }
      }
      return errors
    }.value
    let failures = results.filter { $0["status"].str != "passed" }
    print("Capture result: \(results.count - failures.count) passed, \(failures.count) failed. \(output.path)")
    try require(cleanupErrors.isEmpty, "Capture cleanup failed: \(cleanupErrors.joined(separator: "; "))")
    if let fatalError { throw fatalError }
    try require(failures.isEmpty, "Capture batch contains failed takes")
  }

  func recordMissing(round: Int, selectedLocales: [String]) async throws {
    let assets = try workspace.assets
    let batches = try workspace.lab.at("recordings").children().filter { fullMatch("v[0-9].*", $0.lastPathComponent) }
    var summary = [JSON]()
    for locale in selectedLocales {
      let missing = try assets.filter { asset in
        try !batches.contains { try candidate(folder: $0, asset: asset, locale: locale, enforceBudget: false) != nil }
      }.map { $0["scene"].str }
      print("LOCALE \(locale): \(assets.count - missing.count) accepted, \(missing.count) to record")
      if missing.isEmpty { continue }
      let output = workspace.lab.at("recordings/v6-library-\(locale)-\(round)")
      do {
        try await capture(output: output, scenes: missing, fps: 30, locale: locale, continueOnError: true)
        summary.append(.object([("locale", .string(locale)), ("output", .string(output.path)), ("exitCode", .integer(0))]))
      } catch {
        summary.append(.object([
          ("locale", .string(locale)),
          ("output", .string(output.path)),
          ("exitCode", .integer(1)),
          ("error", .string(String(describing: error))),
        ]))
        if Task.isCancelled { break }
      }
    }
    print(try JSON.array(summary).rendered())
    try require(summary.allSatisfy { $0["exitCode"].int == 0 }, "Some locale recordings failed")
  }
}
