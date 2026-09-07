// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct BundleBuilder: Sendable {
  let workspace: Workspace

  func build(output: URL?) async throws {
    #if os(macOS)
    let out = output ?? ProcessInfo.processInfo.environment["DEMOLAB_OUT"].map { URL(fileURLWithPath: $0) } ?? workspace.lab
      .at(".build/DemoLab")
    let identity = ProcessInfo.processInfo.environment["CODESIGN_IDENTITY"] ?? "-"
    try out.makeDirectory()
    try await runProcess(["swift", "build", "--package-path", workspace.lab.path, "-c", "release"])
    let bin = URL(fileURLWithPath: trim(try await runProcess(
      ["swift", "build", "--package-path", workspace.lab.path, "-c", "release", "--show-bin-path"],
      capture: true,
    )))
    let catalog = try JSON.parse(await runProcess([bin.at("democtl").path, "catalog"], capture: true)).array
    try require(!catalog.isEmpty, "Demo app catalog is empty")
    try SceneLocalizer(workspace: workspace).compileStrings(output: out.at("Localization"))
    let scratch = workspace.lab.at(".build/bundle-icons-" + UUID().uuidString)
    try scratch.makeDirectory()
    defer { try? fm.removeItem(at: scratch) }
    try await runProcess([bin.at("demoicon").path, "--all", "--out", scratch.at("iconsets").path])
    for file in try scratch.at("iconsets").children() where file.pathExtension == "iconset" {
      try await runProcess(["iconutil", "-c", "icns", "-o", scratch.at(file.stem + ".icns").path, file.path])
    }
    for spec in catalog {
      let name = spec["name"].str
      let bundle = out.at(name + ".app")
      try require(fm.isExecutableFile(atPath: bin.at(name).path), "Missing executable: \(name)")
      if bundle.exists { try fm.removeItem(at: bundle) }
      let resources = bundle.at("Contents/Resources")
      try resources.makeDirectory()
      try copy(bin.at(name), bundle.at("Contents/MacOS/" + name))
      for localization in try out.at("Localization").children() where localization.pathExtension == "lproj" { try copy(
        localization,
        resources.at(localization.lastPathComponent),
      ) }
      var plist: [String: Any] = [
        "CFBundleDevelopmentRegion": "en",
        "CFBundleName": name,
        "CFBundleDisplayName": name,
        "CFBundleExecutable": name,
        "CFBundleIdentifier": spec["bundleIdentifier"].str,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "14.0",
        "LSApplicationCategoryType": spec["categoryType"].str,
        "NSPrincipalClass": "NSApplication",
        "NSHighResolutionCapable": true,
        "NSSupportsAutomaticTermination": false,
        "NSSupportsSuddenTermination": false,
      ]
      if spec["agent"].boolean { plist["LSUIElement"] = true }
      if let usage = spec["captureUsageDescription"].string { plist["NSScreenCaptureUsageDescription"] = usage }
      let icon = scratch.at(name + ".icns")
      if icon.exists { try copy(icon, resources.at(icon.lastPathComponent))
        plist["CFBundleIconFile"] = name
      } else { try require(spec["agent"].boolean, "Missing icon for \(name)") }
      let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      try data.write(to: bundle.at("Contents/Info.plist"), options: .atomic)
      try await runProcess(["codesign", "--force", "--sign", identity, "--timestamp=none", bundle.path])
      try await runProcess([
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
        "-f",
        bundle.path,
      ])
      print("Bundled \(name): \(spec["bundleIdentifier"].str)")
    }
    for tool in ["democtl", "demokey", "demohook"] { try copy(bin.at(tool), out.at("bin/" + tool)) }
    try await buildVirtualDisplay()
    let tools = workspace.lab.at(".build/tools/tatami-tools")
    let current = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    if current != tools.resolvingSymlinksInPath() { try copy(current, tools) }
    print("Bundles: \(out.path). Signed with \(identity). Ad-hoc rebuilds require renewed Screen Recording consent.")
    #else
    throw ToolError("Demo app bundling requires macOS")
    #endif
  }

  func buildVirtualDisplay() async throws {
    #if os(macOS)
    let output = workspace.lab.at(".build/tools/demodisplay")
    try output.deletingLastPathComponent().makeDirectory()
    try await runProcess([
      "clang",
      "-fobjc-arc",
      "-framework",
      "Cocoa",
      "-framework",
      "CoreGraphics",
      workspace.lab.at("Sources/demodisplay/main.m").path,
      "-o",
      output.path,
    ])
    #else
    throw ToolError("Virtual displays require macOS")
    #endif
  }

  func control(_ arguments: [String]) async throws {
    let binary = workspace.lab.at(".build/release/democtl")
    if ProcessInfo.processInfo.environment["DEMOLAB_NO_BUILD"] != "1" {
      try await runProcess(["swift", "build", "--package-path", workspace.lab.path, "-c", "release", "--product", "democtl"])
    }
    try require(fm.isExecutableFile(atPath: binary.path), "Missing democtl; build the Demo Lab first")
    try await runProcess([binary.path] + arguments, cwd: workspace.lab, environment: ["DEMOLAB_ROOT": workspace.lab.path])
  }
}
