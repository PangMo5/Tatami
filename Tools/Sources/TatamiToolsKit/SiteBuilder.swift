// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct SiteBuilder {
  static let pages = ["index.html", "cli.html", "configuration.html", "releases.html"]

  let workspace: Workspace

  func validatedManifest(directory: URL, manifest: JSON, locale: String, complete: Bool = true) throws {
    try require(
      (manifest["locale"].string ?? "en") == locale && locales.contains(locale),
      "Wrong media locale: \(directory.path)",
    )
    let expected = Set(try workspace.assets.map { $0["scene"].str })
    let assets = manifest["assets"].array
    let actual = Set(assets.map { $0["scene"].str })
    try require(
      actual.count == assets.count && (complete ? actual == expected : actual.isSubset(of: expected)),
      "Incomplete or duplicate media collection: \(locale)",
    )
    for asset in assets {
      for (kind, suffix) in [("video", ".mp4"), ("poster", ".jpg")] {
        try require(
          asset[kind].str == asset["scene"].str + suffix && directory.at(asset[kind].str).exists,
          "Missing media: \(locale)/\(asset[kind].str)",
        )
      }
      try require(
        try sha(directory.at(asset["video"].str)) == asset["sha256"].str,
        "Media hash mismatch: \(locale)/\(asset["scene"].str)",
      )
      try require(
        try sha(workspace.scene(asset.merging([("locale", .string(locale))]))) == asset["sceneSHA256"].str,
        "Stale scene in published media: \(locale)/\(asset["scene"].str)",
      )
    }
  }

  func localeManifest(_ locale: String) throws -> (URL, JSON) {
    let directory = workspace.root.at(locale == "en" ? "web" : "web/media/" + locale)
    let manifest = try JSON.read(directory.at(locale == "en" ? "demo-manifest.json" : "manifest.json"))
    try validatedManifest(directory: directory, manifest: manifest, locale: locale)
    return (directory, manifest)
  }

  func mediaURL(_ asset: JSON, kind: String, locale: String) -> String {
    (locale == "en" ? "" : "../media/" + locale + "/") + asset[kind].str
  }

  func pageLink(_ page: String, locale: String, from: String) -> String {
    (from == "en" ? "./" : "../") + (locale == "en" ? "" : locale + "/") + page
  }

  func generatedPages(version: String, selectedLocales: [String], manifests: [String: JSON]) throws -> [(String, String)] {
    let values = try JSON.read(workspace.root.at("Localization/Web.json"))
    let gallery = try VideoGallery(workspace: workspace)
    var output = [(String, String)]()
    for locale in selectedLocales {
      guard let manifest = manifests[locale] else { throw ToolError("Missing manifest: \(locale)") }
      let assets = manifest["assets"].array
      let groups = orderedGroups(assets.filter { $0["scene"].str != "tour" }.map { asset in
        asset.merging([
          ("locale", .string(locale)),
          ("video", .string(mediaURL(asset, kind: "video", locale: locale))),
          ("poster", .string(mediaURL(asset, kind: "poster", locale: locale))),
        ])
      }, by: "section")
      for page in Self.pages {
        var source = try workspace.root.at("web/" + page).text()
        source = replacing(#"(?s)<!-- DEMO-COLLECTION:([^:]+):START -->.*?<!-- DEMO-COLLECTION:\1:END -->"#, in: source) {
          "<div data-collection=\"\($0[1])\"></div>"
        }
        let catalog = TextCatalog(values: values, locale: locale)
        let document = try translateHTML(source, catalog, "web/" + page)
        func walk(_ node: HTMLNode) throws {
          if node.tag == "html" { node["lang"] = locale }
          if node.tag == "video", let poster = node["poster"] {
            let name = URL(fileURLWithPath: URLComponents(string: poster)?.path ?? poster).stem
            guard let asset = assets.first(where: { $0["scene"].str == name })
            else { throw ToolError("Missing hero asset: \(name)") }
            node["poster"] = mediaURL(asset, kind: "poster", locale: locale) + "?v=" + asset["sha256"].str.prefix(12)
          }
          if node.tag == "source", node["type"] == "video/mp4", let source = node["src"] {
            let name = URL(fileURLWithPath: URLComponents(string: source)?.path ?? source).stem
            guard let asset = assets.first(where: { $0["scene"].str == name })
            else { throw ToolError("Missing hero asset: \(name)") }
            node["src"] = mediaURL(asset, kind: "video", locale: locale) + "?v=" + asset["sha256"].str.prefix(12)
          }
          for attribute in ["src", "href"] {
            let value = node[attribute] ?? ""
            let parts = URLComponents(string: value)
            let name = URL(fileURLWithPath: parts?.path ?? value).lastPathComponent
            if ["style.css", "demos.js", "docs.js", "site.js", "icon.png"].contains(name), parts?.scheme == nil {
              let token = try sha(workspace.root.at(name == "icon.png" ? "Resources/Marketing/app-icon.png" : "web/" + name))
              node[attribute] = (locale == "en" ? "./" : "../") + name + "?v=" + token.prefix(12)
            }
          }
          if let source = node["data-document-src"] {
            let name = URL(fileURLWithPath: source).lastPathComponent
            node["data-document-src"] = (locale == "en" ? "./" : "../") + "content/" + locale + "/" + name
            if locale != "en" { node["data-source-url"] = node["data-source-url"]?.replacingOccurrences(
              of: "/docs/",
              with: "/docs/" + locale + "/",
            ) }
          }
          if
            node.tag == "a", let href = node["href"],
            ["/docs/CLI.md", "/docs/CONFIGURATION.md"].contains(where: { href.hasSuffix($0) })
          {
            node["href"] = (locale == "en" ? "./" : "../") + "content/" + locale + "/" + URL(fileURLWithPath: href)
              .lastPathComponent
          }
          if node.tag == "a", locale != "en" {
            for notice in ["NOTICE", "THIRD_PARTY_NOTICES"] {
              if
                let href = node["href"],
                href.hasSuffix("/" + notice + ".md") { node["href"] = String(href.dropLast(3)) + "." + locale + ".md" }
            }
          }
          for child in node.children { if let child = child.node { try walk(child) } }
          if node.tag == "div", node["class"] == "nav-inner" {
            let picker = HTMLNode(
              "select",
              [
                ("data-language-picker", ""),
                ("aria-label", try catalog.text("Language", "language picker")),
                ("class", "language-picker"),
              ],
            )
            for code in locales {
              var attrs: [(String, String?)] = [("value", pageLink(page, locale: code, from: locale))]
              if code == locale { attrs.append(("selected", nil)) }
              picker.children.append(.node(HTMLNode("option", attrs, [.text(languageNames[code]!)])))
            }
            node.children.append(.node(picker))
          }
          if node.tag == "div", node["class"] == "footer-inner" {
            let links = HTMLNode(
              "nav",
              [("class", "language-links"), ("aria-label", try catalog.text("Language", "language links"))],
            )
            for code in locales {
              var attrs: [(String, String?)] = [("href", pageLink(page, locale: code, from: locale)), ("data-language-link", "")]
              if code == locale { attrs.append(("aria-current", "page")) }
              links.children.append(.node(HTMLNode("a", attrs, [.text(languageNames[code]!)])))
            }
            node.children.append(.node(links))
          }
          if node.tag == "head" {
            for code in locales {
              let url = "https://pangmo5.dev/Tatami/" + (code == "en" ? "" : code + "/") + (page == "index.html" ? "" : page)
              node.children.append(.node(HTMLNode("link", [("rel", "alternate"), ("hreflang", code), ("href", url)])))
            }
            let url = "https://pangmo5.dev/Tatami/" + (locale == "en" ? "" : locale + "/") + (page == "index.html" ? "" : page)
            node.children.append(.node(HTMLNode("link", [("rel", "canonical"), ("href", url)])))
          }
        }
        try walk(document)
        var text = document.render().replacingOccurrences(of: "__VERSION__", with: version)
        text = try replacing(#"<div data-collection="([^"]+)"></div>"#, in: text) { match in
          guard let assets = groups.first(where: { $0.0 == match[1] })?.1
          else { throw ToolError("Missing collection: \(match[1])") }
          return try gallery.collection(match[1], assets: assets)
        }
        output.append(((locale == "en" ? "" : locale + "/") + page, text + "\n"))
      }
    }
    return output
  }

  func build(output: URL, version: String?, selectedLocales: [String]) throws {
    try require(!selectedLocales.isEmpty && selectedLocales.allSatisfy(locales.contains), "Unsupported site locale")
    let version = try version ?? matches(#"let appVersion = "([^"]+)""#, workspace.root.at("Project.swift").text(
    )).first?[1] ?? ""
    try require(fullMatch(#"[0-9]+\.[0-9]+\.[0-9]+(?:[.-][A-Za-z0-9.-]+)?"#, version), "Invalid version")
    var manifests = [String: JSON]()
    var directories = [String: URL]()
    for locale in selectedLocales { let (directory, manifest) = try localeManifest(locale)
      directories[locale] = directory
      manifests[locale] = manifest
    }
    let generated = try generatedPages(version: version, selectedLocales: selectedLocales, manifests: manifests)
    for locale in selectedLocales { for name in ["CLI.md", "CONFIGURATION.md"] { try require(
      workspace.root.at("docs").at(locale == "en"
        ? ""
        : locale).at(name).exists,
      "Missing localized document: \(locale)/\(name)",
    ) } }
    try output.makeDirectory()
    for file in try workspace.root.at("web").children() where ["css", "js"].contains(file.pathExtension) { try copy(
      file,
      output.at(file.lastPathComponent),
    ) }
    try copy(workspace.root.at("Resources/Marketing/app-icon.png"), output.at("icon.png"))
    for locale in selectedLocales {
      let directory = directories[locale]!
      let manifest = manifests[locale]!
      let target = locale == "en" ? output : output.at("media/" + locale)
      for asset in manifest["assets"].array { for kind in ["video", "poster"] { try copy(
        directory.at(asset[kind].str),
        target.at(asset[kind].str),
      ) } }
      try manifest.write(target.at(locale == "en" ? "demo-manifest.json" : "manifest.json"))
      for name in ["CLI.md", "CONFIGURATION.md"] { try copy(
        workspace.root.at("docs").at(locale == "en" ? "" : locale).at(name),
        output.at("content/" + locale + "/" + name),
      ) }
    }
    for (path, text) in generated { try output.at(path).write(text) }
    print("Built \(generated.count) pages, \(selectedLocales.count) languages: \(output.path)")
  }
}
