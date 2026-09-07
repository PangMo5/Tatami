// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct Publication {
  let workspace: Workspace

  func renderSource() throws {
    let manifest = try JSON.read(workspace.root.at("web/demo-manifest.json"))
    let gallery = try VideoGallery(workspace: workspace)
    let planned = try Dictionary(uniqueKeysWithValues: workspace.assets.map { ($0["scene"].str, $0) })
    let assets = manifest["assets"].array.filter { $0["scene"].str != "tour" }.map { asset in
      asset.merging(["title", "description", "section"].compactMap { key in planned[asset["scene"].str].map { (key, $0[key]) } })
    }
    let groups = orderedGroups(assets, by: "section")
    let page = workspace.root.at("web/index.html")
    var text = try page.text()
    for pattern in [
      #"(?s)\s*<!-- DEMO-COLLECTION:.*?:START -->.*?<!-- DEMO-COLLECTION:.*?:END -->"#,
      #"(?s)\s*<details class="more-demo">.*?</details>"#,
      #"(?s)\s*<figure class="feature-demo".*?</figure>"#,
    ] { text = replacing(pattern, in: text) { _ in "" } }
    for (section, assets) in groups {
      let regex = try NSRegularExpression(pattern: #"<section\b[^>]*\bid=""# + NSRegularExpression
        .escapedPattern(for: section) + #""[^>]*>"#)
      guard
        let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(
          match.range,
          in: text,
        ),
        let end = text.range(of: "</section>", range: range.upperBound..<text.endIndex)
      else { throw ToolError("No section for \(section)") }
      let region = String(text[range.upperBound..<end.lowerBound])
      let position: String.Index
      if
        let paragraph = try NSRegularExpression(pattern: #"(?s)<p class="sub">.*?</p>"#).firstMatch(
          in: region,
          range: NSRange(region.startIndex..., in: region),
        )
      {
        let offset = region.distance(from: region.startIndex, to: Range(paragraph.range, in: region)!.upperBound)
        position = text.index(range.upperBound, offsetBy: offset)
      } else {
        guard let div = text.range(of: "</div>", options: .backwards, range: range.upperBound..<end.lowerBound)
        else { throw ToolError("Missing collection container: \(section)") }
        position = div.lowerBound
      }
      text.insert(contentsOf: try "\n    " + gallery.collection(section, assets: assets), at: position)
    }
    if !text.contains("src=\"./demos.js\"") { text = text.replacingOccurrences(
      of: "</body>",
      with: "<script src=\"./demos.js\" defer></script>\n</body>",
    ) }
    guard let hero = manifest["assets"].array.first(where: { $0["scene"].str == "tour" }) else { throw ToolError("Missing tour") }
    text = replacing(#"(?s)<!-- DEMO-SETTINGS:tour:START -->.*?<!-- DEMO-SETTINGS:tour:END -->"#, in: text) { _ in
      "<!-- DEMO-SETTINGS:tour:START -->" + gallery.settingsLinks(hero) + "<!-- DEMO-SETTINGS:tour:END -->"
    }
    for name in [hero["video"].str, hero["poster"].str] {
      text = replacing(NSRegularExpression.escapedPattern(for: name) + #"(?:\?v=[a-f0-9]+)?"#, in: text) { _ in
        name + "?v=" + hero["sha256"].str.prefix(12)
      }
    }
    try page.write(text)
    print("Collections: " + groups.map { "\($0.0) (\($0.1.count))" }.joined(separator: ", "))
  }

  func install(bundle: URL, allLocales: Bool) throws {
    let bundles = allLocales ? locales.map(bundle.at) : [bundle]
    let validator = SiteBuilder(workspace: workspace)
    var validated = [(URL, String, JSON)]()
    for bundle in bundles {
      let manifest = try JSON.read(bundle.at("manifest.json"))
      let locale = manifest["locale"].string ?? "en"
      try require(!allLocales || bundle.lastPathComponent == locale, "Bundle directory and locale disagree")
      try validator.validatedManifest(directory: bundle, manifest: manifest, locale: locale)
      validated.append((bundle, locale, manifest))
    }
    for (bundle, locale, manifest) in validated {
      let target = workspace.root.at(locale == "en" ? "web" : "web/media/" + locale)
      for asset in manifest["assets"].array { for kind in ["video", "poster"] { try copy(
        bundle.at(asset[kind].str),
        target.at(asset[kind].str),
      ) } }
      try copy(bundle.at("manifest.json"), target.at(locale == "en" ? "demo-manifest.json" : "manifest.json"))
    }
    if validated.contains(where: { $0.1 == "en" }) { try renderSource() }
    print("Installed \(validated.count) reviewed locales locally in web/")
  }

  func merge(bundle: URL, patch: URL, archive: URL) throws {
    var base = try JSON.read(bundle.at("manifest.json"))
    let update = try JSON.read(patch.at("manifest.json"))
    try require(base["locale"] == update["locale"], "Locale mismatch")
    try require(!archive.exists, "Archive already exists")
    var byScene = Dictionary(uniqueKeysWithValues: base["assets"].array.map { ($0["scene"].str, $0) })
    let newAudit = try JSON.read(patch.at("evidence/ocr-audit.json"))
    try require(
      newAudit["status"]
        .str == "passed" && Set(newAudit["movies"].array.map { URL(fileURLWithPath: $0["movie"].str).stem }) ==
        Set(update["assets"].array.map { $0["scene"].str }),
      "Patch OCR evidence does not cover the patch",
    )
    try SiteBuilder(workspace: workspace).validatedManifest(
      directory: patch,
      manifest: update,
      locale: base["locale"].str,
      complete: false,
    )
    for asset in update["assets"].array { try require(byScene[asset["scene"].str] != nil, "Patch adds an unknown film") }
    func evidence(_ directory: URL, scene: String) throws -> [URL] {
      try directory.children().filter { $0.lastPathComponent.hasPrefix(scene + ".") || fullMatch(
        NSRegularExpression.escapedPattern(for: scene) + #"-[0-9]+\.jpg"#,
        $0.lastPathComponent,
      ) }
    }
    try archive.makeDirectory()
    try copy(bundle.at("manifest.json"), archive.at("manifest.json"))
    if bundle.at("evidence/ocr-audit.json").exists { try copy(
      bundle.at("evidence/ocr-audit.json"),
      archive.at("evidence/ocr-audit.json"),
    ) }
    for asset in update["assets"].array {
      let scene = asset["scene"].str
      let old = byScene[scene]!
      for kind in ["video", "poster"] {
        try fm.moveItem(at: bundle.at(old[kind].str), to: archive.at(old[kind].str))
        try copy(patch.at(asset[kind].str), bundle.at(asset[kind].str))
      }
      let saved = archive.at("evidence")
      try saved.makeDirectory()
      for file in try evidence(bundle.at("evidence"), scene: scene) { try fm.moveItem(
        at: file,
        to: saved.at(file.lastPathComponent),
      ) }
      for file in try evidence(patch.at("evidence"), scene: scene) { try copy(
        file,
        bundle.at("evidence/" + file.lastPathComponent),
      ) }
      byScene[scene] = asset
    }
    base["assets"] = .array(base["assets"].array.map { byScene[$0["scene"].str]! })
    try base.write(bundle.at("manifest.json"))
    let auditFile = bundle.at("evidence/ocr-audit.json")
    if auditFile.exists {
      var audit = try JSON.read(auditFile)
      let replacements = Dictionary(uniqueKeysWithValues: newAudit["movies"].array.map { movie in
        let file = URL(fileURLWithPath: movie["movie"].str)
        return (file.stem, movie.merging([("movie", .string(bundle.at(file.lastPathComponent).path))]))
      })
      audit["movies"] = .array(audit["movies"].array.map { replacements[URL(fileURLWithPath: $0["movie"].str).stem] ?? $0 })
      let passed = audit["movies"].array.allSatisfy { movie in
        !movie["captionChecks"].array.isEmpty && movie["captionChecks"].array
          .allSatisfy { $0["passed"].boolean } && movie["samples"].array.allSatisfy { $0["matches"].array.isEmpty }
      }
      audit["status"] = .string(passed ? "passed" : "failed")
      try audit.write(auditFile)
    }
    try VideoGallery(workspace: workspace).reviewBundle(destination: bundle, records: base["assets"].array)
    print("Merged \(update["assets"].array.map { $0["scene"].str }) into \(bundle.path)")
  }
}
