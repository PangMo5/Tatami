// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - VideoGallery

struct VideoGallery {

  // MARK: Lifecycle

  init(workspace: Workspace) throws {
    self.workspace = workspace
    interface = try JSON.read(workspace.lab.at("Localization/Interface.json"))
  }

  // MARK: Internal

  let workspace: Workspace
  let interface: JSON

  func settingsLinks(_ asset: JSON) -> String {
    let settings = asset["relatedSettings"].array
    if settings.isEmpty { return "" }
    let label = htmlEscape(interface[asset["locale"].string ?? "en"]["relatedSettings"].str)
    let links = settings
      .map { "<a href=\"./configuration.html#\(htmlEscape($0["anchor"].str))\"><code>\(htmlEscape($0["key"].str))</code></a>" }
      .joined()
    return "<nav class=\"demo-settings\" aria-label=\"\(label)\"><span>\(label)</span>\(links)</nav>"
  }

  func collection(_ section: String, assets: [JSON], mediaDirectory: URL, cacheBust: Bool = true) throws -> String {
    try require(!assets.isEmpty, "Empty video collection: \(section)")
    let locale = assets[0]["locale"].string ?? "en"
    let ui = interface[locale]
    let title = ui["sections"][section].str
    try require(!title.isEmpty, "Missing video section label: \(locale)/\(section)")
    let collectionLabel = htmlEscape(ui["collection"].str.replacingOccurrences(of: "{name}", with: title))
    let chooseLabel = htmlEscape(ui["choose"].str.replacingOccurrences(of: "{name}", with: title))
    var slides = [String]()
    var tabs = [String]()
    for (index, asset) in assets.enumerated() {
      let name = htmlEscape(asset["scene"].str)
      let title = htmlEscape(asset["title"].str)
      let suffix = cacheBust ? "?v=" + asset["sha256"].str.prefix(12) : ""
      let video = htmlEscape(asset["video"].str + suffix)
      let posterSuffix = try cacheBust ? "?v=" + sha(mediaDirectory.at(asset["scene"].str + ".jpg")).prefix(12) : ""
      let poster = htmlEscape(asset["poster"].str + posterSuffix)
      let description = htmlEscape(asset["description"].string ?? asset["title"].str)
      let duration = String(format: "%d:%02d", asset["durationSeconds"].int / 60, asset["durationSeconds"].int % 60)
      let aspect = ["dual", "dynamic-dual"].contains(asset["presentation"].str) ? "16 / 5" : "16 / 10"
      slides.append("""
        <article class="demo-slide" id="demo-\(name)" aria-labelledby="tab-\(name)">
                  <video class="demo-video" controls muted playsinline preload="none" poster="\(poster)" aria-label="\(title)" style="aspect-ratio: \(aspect)">
                    <source src="\(video)" type="video/mp4" />
                    <a href="\(video)">\(htmlEscape(ui["watch"].str.replacingOccurrences(of: "{title}", with: asset["title"].str)))</a>
                  </video>
                  <p class="demo-description">\(description)</p>
                  \(settingsLinks(asset))
                </article>
        """)
      tabs.append("""
        <button class="demo-tab" type="button" role="tab" id="tab-\(name)" aria-controls="demo-\(name)" aria-selected="\(index == 0 ? "true" : "false")" tabindex="\(index == 0 ? 0 : -1)">
                  <span class="demo-thumb"><img src="\(poster)" loading="lazy" alt="" /><span class="demo-duration">\(duration)</span></span>
                  <span class="demo-tab-title">\(title)</span>
                </button>
        """)
    }
    return """
      <!-- DEMO-COLLECTION:\(section):START -->
          <div class="demo-gallery" data-count="\(assets.count)" aria-label="\(collectionLabel)" data-play-hint="\(htmlEscape(ui["playHint"].str))">
            <div class="demo-gallery-heading"><p class="eyebrow">\(htmlEscape(ui["explore"].str))</p>
              <div class="demo-paging"><span class="demo-count" aria-live="polite">1 / \(assets.count)</span>
                <button type="button" class="demo-prev" aria-label="\(htmlEscape(ui["previous"].str))">‹</button>
                <button type="button" class="demo-next" aria-label="\(htmlEscape(ui["next"].str))">›</button>
              </div>
            </div>
            <div class="demo-stage">\(slides.joined())</div>
            <div class="demo-tabs" role="tablist" aria-label="\(chooseLabel)">\(tabs.joined())</div>
          </div>
          <!-- DEMO-COLLECTION:\(section):END -->
      """
  }

  func reviewBundle(destination: URL, records: [JSON]) throws {
    try require(!records.isEmpty, "Cannot render an empty review bundle")
    let locale = records[0]["locale"].string ?? "en"
    let ui = interface[locale]
    let groups = orderedGroups(records, by: "section")
    let sections = try groups.map { name, assets in
      try "<section id=\"\(name)\"><div class=\"wrap\"><h2>\(ui["sections"][name].string ?? name)</h2>" + collection(
        name,
        assets: assets,
        mediaDirectory: destination,
        cacheBust: false,
      ) + "</div></section>"
    }
    for name in ["style.css", "demos.js", "docs.js", "site.js"] {
      try copy(workspace.root.at("web/" + name), destination.at(name))
    }
    try destination.at("index.html")
      .write(
        "<!doctype html><html lang=\"\(locale)\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Tatami · \(htmlEscape(ui["library"].str))</title><link rel=\"stylesheet\" href=\"style.css\"></head><body><section class=\"hero\"><div class=\"wrap\"><p class=\"eyebrow\">TATAMI / DEMO LAB</p><h1>\(htmlEscape(ui["headline"].str))</h1><p class=\"sub\">\(htmlEscape(ui["intro"].str))</p></div></section>" +
          sections.joined() + "<script src=\"demos.js\" defer></script></body></html>"
      )
    let values = try JSON.read(workspace.root.at("Localization/Web.json"))
    for page in ["configuration.html", "cli.html", "releases.html"] {
      let document = try translateHTML(workspace.root.at("web/" + page).text(), TextCatalog(values: values, locale: locale), page)
      try document.walk { node in
        if node.tag == "html" { node["lang"] = locale }
        if node.tag == "a", let href = node["href"] {
          node["href"] = DocumentBuilder(workspace: workspace).localizedNoticeLink(href, locale: locale)
        }
        if let source = node["data-document-src"] {
          let name = URL(fileURLWithPath: source).lastPathComponent
          node["data-document-src"] = "./content/" + name
          try copy(workspace.root.at("docs").at(locale == "en" ? "" : locale).at(name), destination.at("content/" + name))
        }
      }
      try destination.at(page).write(document.render() + "\n")
    }
    try copy(workspace.root.at("Resources/Marketing/app-icon.png"), destination.at("icon.png"))
  }

}

func orderedGroups(_ assets: [JSON], by field: String) -> [(String, [JSON])] {
  var groups = [(String, [JSON])]()
  for asset in assets {
    let key = asset[field].str
    if let index = groups.firstIndex(where: { $0.0 == key }) { groups[index].1.append(asset) }
    else { groups.append((key, [asset])) }
  }
  return groups
}
