// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct SceneLocalizer {
  let workspace: Workspace

  func catalog(_ file: URL) throws -> JSON {
    .object(try JSON.read(file)["strings"].object.map { key, entry in
      (key, .object(locales.map { ($0, entry["localizations"][$0]["stringUnit"]["value"]) }))
    })
  }

  func compileStrings(output: URL) throws {
    let catalog = try JSON.read(workspace.lab.at("Localization/Localizable.xcstrings"))["strings"]
    try require(!catalog.object.isEmpty, "The demo string catalog is empty or invalid")
    var rendered = [(URL, String)]()
    for locale in locales {
      var lines = ["/* Generated from Localizable.xcstrings. Do not edit. */"]
      for (key, entry) in catalog.object.sorted(by: { $0.0 < $1.0 }) {
        let translation = entry["localizations"][locale]
        try require(
          translation.object.map(\.0) == ["stringUnit"] && translation["stringUnit"]["state"].str == "translated",
          "Expected a reviewed plain string unit: \(locale) / \(key)",
        )
        guard let value = translation["stringUnit"]["value"].string else { throw ToolError("Missing string value: \(key)") }
        lines.append(JSON.quote(key) + " = " + JSON.quote(value) + ";")
      }
      rendered.append((output.at(locale + ".lproj/Localizable.strings"), lines.joined(separator: "\n") + "\n"))
    }
    for (file, text) in rendered { try file.write(text) }
    print("Compiled \(catalog.object.count) strings in \(locales.count) locales")
  }

  func outputs() throws -> [(URL, String)] {
    let app = try catalog(workspace.lab.at("Localization/Localizable.xcstrings"))
    let film = try JSON.read(workspace.lab.at("Localization/Films.json"))["strings"]
    let product = try catalog(workspace.root.at("Tatami/Resources/Localizable.xcstrings"))
    var english = [String: JSON]()
    for (key, values) in product.object { english[values["en"].str.isEmpty ? key : values["en"].str] = values }
    let names = Set(try matches(#"(?m)^name = "([^"]+)""#, workspace.lab.at("config/tatami-demo.toml.in").text())
      .map { $0[1] } + [
        "Design review",
        "Writing",
        "Conversation",
        "Quick notes",
      ])
    func translated(_ text: String, _ locale: String) throws -> String {
      let values = film[text].isNull ? app[text] : film[text]
      try require(!values[locale].str.isEmpty, "Missing \(locale) film/input text: \(text)")
      return values[locale].str
    }
    func native(_ text: String, _ locale: String) throws -> String {
      if names.contains(text) { return text }
      if let value = english[text]?[locale].string, !value.isEmpty { return value }
      for (source, values) in english.sorted(by: { $0.key < $1.key }) {
        let normalized = replacing(#"%\d+\$lld"#, in: source) { _ in "%lld" }
        if !normalized.contains("%lld") { continue }
        let pattern = NSRegularExpression.escapedPattern(for: normalized).replacingOccurrences(of: "%lld", with: #"(\d+)"#)
        guard let match = matches("^(?:" + pattern + ")$", text).first, !values[locale].str.isEmpty else { continue }
        let arguments = Array(match.dropFirst())
        var index = 0
        return try replacing(#"%(?:(\d+)\$)?lld"#, in: values[locale].str) { match in
          let position = match[1].isEmpty ? index : Int(match[1])! - 1
          index += 1
          try require(arguments.indices.contains(position), "Native translation argument out of range")
          return arguments[position]
        }
      }
      throw ToolError("Missing native AX translation \(locale): \(text)")
    }
    var rendered = [(URL, String)]()
    for locale in locales.dropFirst() {
      for asset in try workspace.assets {
        var scene = try JSON.read(workspace.lab.at("scenes/" + asset["scene"].str + ".json"))
        scene["title"] = .string(try translated(asset["title"].str, locale))
        scene["summary"] = .string(try translated(asset["description"].str, locale))
        for field in ["setup", "steps"] where !scene[field].isNull {
          var steps = scene[field].array
          for index in steps.indices {
            var step = steps[index]
            let kind = step["kind"].str
            if ["caption", "chapter"].contains(kind), !step["text"].str.isEmpty { step["text"] = .string(try translated(
              step["text"].str,
              locale,
            )) }
            if
              kind == "typeText",
              step["app"].str != "Terminal" { step["text"] = .string(try translated(step["text"].str, locale)) }
            if step["app"].str == "Tatami", !step["identifier"].isNull {
              let components = step["identifier"].str.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                .map(String.init)
              if components.count == 2, ["text", "description", "title", "help", "button", "heading"].contains(components[0]) {
                step["identifier"] = .string(try components[0] + ":" + native(components[1], locale))
                if kind == "expectValue" { step["value"] = .string(try native(step["value"].str, locale)) }
              }
            } else if kind == "expectValue", !app[step["value"].str].isNull || !film[step["value"].str].isNull {
              step["value"] = .string(try translated(step["value"].str, locale))
            } else if
              kind == "expectStory",
              ["headline", "lastTask", "lastMessage", "reviewComment"].contains(step["field"].str)
            {
              step["value"] = .string(try translated(step["value"].str, locale))
            }
            steps[index] = step
          }
          scene[field] = .array(steps)
        }
        rendered.append((workspace.lab.at("scenes/" + locale + "/" + asset["scene"].str + ".json"), try scene.rendered() + "\n"))
      }
    }
    return rendered
  }

  func build(check: Bool) throws {
    let rendered = try outputs()
    for (file, text) in rendered {
      if check { try require(try JSON.read(file) == JSON.parse(text), "Generated scene drift: \(file.path)") }
      else { try JSON.parse(text).write(file) }
    }
    print("\(check ? "Verified" : "Compiled") \(rendered.count) localized scenes")
  }
}
