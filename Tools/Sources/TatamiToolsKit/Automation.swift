// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - FixtureAutomation

enum FixtureAutomation {
  static func focusSession() async throws {
    let cli = ProcessInfo.processInfo.environment["TATAMI_CLI"] ?? "tatami"
    for arguments in [["workspace", "activate", "Design"], ["layout", "balance"], ["workspace", "borrow", "from", "Notes"]] {
      try await runProcess([cli] + arguments)
    }
    print("\nFocus-session commands submitted.")
  }

  static func setSpacing(_ gap: Int) throws {
    try require((4...40).contains(gap), "gap must be 4...40")
    guard let path = ProcessInfo.processInfo.environment["DEMO_CONFIG"] else { throw ToolError("DEMO_CONFIG is required") }
    let file = URL(fileURLWithPath: path)
    let source = try file.text()
    let pattern = #"(?m)^(\s*gapInner\s*=\s*)\d+\s*$"#
    try require(matches(pattern, source).count == 1, "Expected exactly one gapInner setting")
    // A targeted source edit preserves all TOML comments and unrelated formatting.
    try file.write(replacing(pattern, in: source) { $0[1] + String(gap) })
    print("config.toml: gapInner = \(gap)\nTatami picks up the change through its normal live reload.")
  }
}

// MARK: - MarketingBuilder

struct MarketingBuilder {
  let workspace: Workspace

  func overview() async throws {
    let source = workspace.root.at("Resources/Marketing/screenshots")
    let scratch = fm.temporaryDirectory.at("tatami-overview-" + UUID().uuidString)
    try scratch.makeDirectory()
    defer { try? fm.removeItem(at: scratch) }
    func magick(_ arguments: [String], capture: Bool = false) async throws -> String {
      try await runProcess(
        ["magick"] + arguments,
        capture: capture,
      )
    }
    func dimension(_ file: URL, _ field: String) async throws -> Int {
      let raw = trim(try await magick(["identify", "-format", field, file.path], capture: true))
      guard let value = Int(raw), value > 0 else { throw ToolError("Invalid image dimensions") }
      return value
    }
    for (name, output) in [("workspaces", "ws"), ("borrow", "bw")] {
      _ = try await magick([
        source.at(name + ".png").path,
        "-resize",
        "x1000",
        "-depth",
        "8",
        "-strip",
        scratch.at("flat.png").path,
      ])
      let width = try await dimension(scratch.at("flat.png"), "%w")
      _ = try await magick([
        "-size",
        "\(width)x1000",
        "xc:black",
        "-fill",
        "white",
        "-draw",
        "roundrectangle 0,0,\(width - 1),999,24,24",
        "-alpha",
        "off",
        scratch.at("mask.png").path,
      ])
      _ = try await magick([
        scratch.at("flat.png").path,
        scratch.at("mask.png").path,
        "-alpha",
        "off",
        "-compose",
        "CopyOpacity",
        "-composite",
        scratch.at("round.png").path,
      ])
      _ = try await magick([
        scratch.at("round.png").path,
        "(",
        "+clone",
        "-background",
        "black",
        "-shadow",
        "45x26+0+14",
        ")",
        "+swap",
        "-background",
        "none",
        "-layers",
        "merge",
        "+repage",
        scratch.at(output + ".png").path,
      ])
    }
    let width = try await dimension(scratch.at("ws.png"), "%w")
    let height = try await dimension(scratch.at("ws.png"), "%h")
    _ = try await magick([
      source.at("guided-setup.png").path,
      "-trim",
      "+repage",
      "-resize",
      "\(width)x",
      "-depth",
      "8",
      "-strip",
      scratch.at("guide.png").path,
    ])
    let guideHeight = try await dimension(scratch.at("guide.png"), "%h")
    _ = try await magick([
      "-size",
      "\(width + 280)x\(1240 + height + guideHeight + 60)",
      "xc:none",
      scratch.at("bw.png").path,
      "-geometry",
      "+0+0",
      "-composite",
      scratch.at("ws.png").path,
      "-geometry",
      "+110+620",
      "-composite",
      scratch.at("guide.png").path,
      "-geometry",
      "+220+1240",
      "-composite",
      "-trim",
      "+repage",
      "-bordercolor",
      "none",
      "-border",
      "20",
      "-define",
      "png:compression-level=9",
      source.at("overview.png").path,
    ])
    _ = try await magick(["identify", "-format", "Built %f  %wx%h  %B bytes\n", source.at("overview.png").path])
  }
}
