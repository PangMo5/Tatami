// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
#if os(macOS)
import AppKit
#endif

// MARK: - ProductBuilder

/// SwiftPM owns compilation; this command owns the macOS distribution bundle.
struct ProductBuilder {
  let workspace: Workspace

  var version: String {
    get throws {
      let source = try workspace.root.at("TatamiCLIProtocol/Sources/TatamiVersion.swift").text()
      let versions = matches(#"public static let current = "([^"]+)""#, source)
      try require(versions.count == 1, "Expected one TatamiVersion.current declaration")
      let version = versions[0][1]
      try require(fullMatch(#"[0-9]+\.[0-9]+\.[0-9]+(?:[.-][A-Za-z0-9.-]+)?"#, version), "Invalid product version")
      return version
    }
  }

  func build(
    configuration: String,
    architectures: [String],
    output: URL?,
    identity: String?,
    unsigned: Bool,
  ) async throws -> URL {
    #if os(macOS)
    try require(["debug", "release"].contains(configuration), "Configuration must be debug or release")
    try require(architectures.allSatisfy { ["arm64", "x86_64"].contains($0) }, "Unsupported macOS architecture")
    let release = configuration == "release"
    let environment = ProcessInfo.processInfo.environment
    let identity = identity ?? environment["CODESIGN_IDENTITY"] ?? (release ? "Developer ID Application" : "Apple Development")
    let publicKey = environment["SPARKLE_PUBLIC_ED_KEY"] ?? ""
    if release, !unsigned {
      try require(identity.hasPrefix("Developer ID Application"), "Release signing requires a Developer ID Application identity")
      try require(!publicKey.isEmpty, "SPARKLE_PUBLIC_ED_KEY is required for a signed release")
    }
    let signingIdentity = unsigned ? nil : try await ProductSigningIdentity.resolve(
      identity,
      team: environment["DEVELOPMENT_TEAM"],
    )
    let version = try version
    let buildNumber = environment["BUILD_NUMBER"] ?? "1"
    try require(fullMatch(#"[0-9]+(?:\.[0-9]+){0,2}"#, buildNumber), "Invalid BUILD_NUMBER")
    let metadata = try await ProductBuildMetadata.load(workspace: workspace, version: version, buildNumber: buildNumber)
    let sdkPath = metadata.sdkPath
    let sdkVersion = metadata.sdkVersion
    let minimumVersion = metadata.minimumVersion
    let cliInfoFile = try metadata.writeCLIInfo(workspace: workspace)
    // Keep the linked SDK distinct from the deployment target. AppKit uses the
    // Mach-O SDK version to select modern UI behavior, including Liquid Glass.
    let arguments = [
      "swift",
      "build",
      "--package-path",
      workspace.root.path,
      "--disable-automatic-resolution",
      "--sdk",
      sdkPath,
      "-c",
      configuration,
    ]
      + architectures.flatMap { ["--arch", $0] }
    let localization = workspace.root.at(".build/localization")
    for module in ["Tatami", "TatamiKit"] { try localization.at(module).makeDirectory() }
    // Extraction is for the development catalog workflow. Universal builds must
    // not have two compiler architectures writing the same stringsdata files.
    let extraction = !release && architectures.count < 2 ? ["TATAMI_LOCALIZATION_OUTPUT": localization.path] : [:]
    let productEnvironment = extraction.merging([
      "TATAMI_LINK_SDK_VERSION": sdkVersion,
      "TATAMI_CLI_INFO_PLIST": cliInfoFile.path,
    ]) { _, new in new }
    try await runProcess(arguments, environment: productEnvironment)
    let bin = URL(fileURLWithPath: trim(try await runProcess(
      arguments + ["--show-bin-path"],
      environment: productEnvironment,
      capture: true,
    )))
    let destination = output ?? workspace.root.at(".build/app/\(configuration)/Tatami.app")
    try require(destination.pathExtension == "app", "Output must be an .app path")
    let scratch = workspace.root.at(".build/packaging/" + UUID().uuidString)
    let bundle = scratch.at("Tatami.app")
    try scratch.makeDirectory()
    defer { try? fm.removeItem(at: scratch) }
    let resources = bundle.at("Contents/Resources")
    try resources.makeDirectory()
    try copy(bin.at("TatamiApp"), bundle.at("Contents/MacOS/Tatami"))
    try copy(bin.at("tatami"), resources.at("tatami"))
    let icon = release ? "AppIcon" : "AppIcon-Debug"
    try await runProcess([
      "xcrun",
      "actool",
      "--compile",
      resources.path,
      "--platform",
      "macosx",
      "--minimum-deployment-target",
      minimumVersion,
      "--app-icon",
      icon,
      "--output-partial-info-plist",
      scratch.at("assets.plist").path,
      workspace.root.at("Tatami/Resources/Assets.xcassets").path,
    ])
    try await runProcess([
      "xcrun",
      "xcstringstool",
      "compile",
      workspace.root.at("Tatami/Resources/Localizable.xcstrings").path,
      "--output-directory",
      resources.path,
    ])
    for source in [
      "CHANGELOG.md",
      "docs/CLI.md",
      "NOTICE.md",
      "Localization/ThirdPartyNotice.md",
      "LICENSE",
      "THIRD_PARTY_NOTICES.md",
    ] {
      let file = workspace.root.at(source)
      try copy(file, resources.at(file.lastPathComponent))
    }
    for locale in locales.dropFirst() {
      try copy(workspace.root.at("docs/" + locale), resources.at(locale))
    }
    // Dependency privacy manifests and resources must travel with the product.
    for file in try bin.children() where file.pathExtension == "bundle" {
      try copy(file, resources.at(file.lastPathComponent))
    }
    let framework = bundle.at("Contents/Frameworks/Sparkle.framework")
    try framework.deletingLastPathComponent().makeDirectory()
    try await runProcess([
      "ditto",
      workspace.root.at(".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework").path,
      framework.path,
    ])
    let runtimeLibraries = try await ProductRuntime.prepare(bundle)
    guard var plist = try PropertyListSerialization.propertyList(
      from: Data(contentsOf: scratch.at("assets.plist")),
      options: [],
      format: nil,
    ) as? [String: Any] else { throw ToolError("Asset compiler output is not a property list dictionary") }
    let name = release ? "Tatami" : "Tatami Dev"
    plist.merge(metadata.info(
      identifier: release ? "dev.PangMo5.Tatami" : "dev.PangMo5.Tatami.debug",
      executable: "Tatami",
      name: name,
    )) { _, new in new }
    plist.merge([
      "CFBundleLocalizations": locales,
      "CFBundleDisplayName": name,
      "CFBundlePackageType": "APPL",
      "LSApplicationCategoryType": "public.app-category.productivity",
      "LSUIElement": true,
      "NSPrincipalClass": "NSApplication",
      "NSHighResolutionCapable": true,
      "SUFeedURL": "https://tatami.pangmo5.dev/appcast.xml",
      "SUEnableAutomaticChecks": true,
      "SUPublicEDKey": publicKey,
    ]) { _, new in new }
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: bundle.at("Contents/Info.plist"), options: .atomic)
    try Data("APPL????".utf8).write(to: bundle.at("Contents/PkgInfo"), options: .atomic)
    try await runProcess(["plutil", "-lint", bundle.at("Contents/Info.plist").path])
    for locale in locales {
      try require(resources.at(locale + ".lproj/Localizable.strings").exists, "Missing compiled localization: \(locale)")
    }
    if let signingIdentity {
      guard let sourceEntitlements = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: workspace.root.at("Tatami/Tatami.entitlements")),
        options: [],
        format: nil,
      ) as? [String: Any] else { throw ToolError("Invalid app entitlements") }
      let appEntitlements = try signingIdentity.entitlements(source: sourceEntitlements, release: release)
      let cliEntitlements = try signingIdentity.entitlements(source: [:], release: release, cli: true)
      let appFile = scratch.at("app-entitlements.plist")
      let cliFile = scratch.at("cli-entitlements.plist")
      for (file, values) in [(appFile, appEntitlements), (cliFile, cliEntitlements)] {
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: file, options: .atomic)
      }
      let signing = signingIdentity.command(release: release)
      for path in ["XPCServices/Installer.xpc", "XPCServices/Downloader.xpc", "Autoupdate", "Updater.app"] {
        try await runProcess(signing + ["--preserve-metadata=entitlements", framework.at("Versions/Current/" + path).path])
      }
      try await runProcess(signing + [framework.path])
      for library in runtimeLibraries { try await runProcess(signing + [library.path]) }
      try await runProcess(signing + [
        "--identifier",
        "dev.PangMo5.tatami.cli",
        "--entitlements",
        cliFile.path,
        resources.at("tatami").path,
      ])
      try await runProcess(signing + ["--entitlements", appFile.path, bundle.path])
      try await runProcess(["codesign", "--verify", "--deep", "--strict", "--verbose=2", bundle.path])
      try signingIdentity.validate(bundle, entitlements: appEntitlements, release: release)
      try signingIdentity.validate(resources.at("tatami"), entitlements: cliEntitlements, release: release)
      for library in runtimeLibraries { try signingIdentity.validate(library, entitlements: [:], release: release) }
    } else {
      // Mach-O relocation invalidates the linker's ad-hoc signature. Seal
      // certificate-free builds again so they remain executable on Apple silicon.
      let signing = ["codesign", "--force", "--sign", "-", "--timestamp=none"]
      for executable in [resources.at("tatami")] + runtimeLibraries { try await runProcess(signing + [executable.path]) }
      try await runProcess(signing + [bundle.path])
      try await runProcess(["codesign", "--verify", "--deep", "--strict", bundle.path])
    }
    for executable in [bundle.at("Contents/MacOS/Tatami"), resources.at("tatami")] {
      let slices = try await metadata.validateExecutable(executable, architectures: architectures)
      if executable.lastPathComponent == "tatami" {
        try metadata.validateCLIInfo(executable, slices: slices)
      }
    }
    let cliVersion = trim(try await runProcess([resources.at("tatami").path, "--version"], capture: true))
    try require(cliVersion == version, "Bundled CLI version differs from the app")
    try destination.deletingLastPathComponent().makeDirectory()
    if destination.exists {
      try require(
        Bundle(url: destination)?.bundleIdentifier == plist["CFBundleIdentifier"] as? String,
        "Refusing to replace a different app at \(destination.path)",
      )
      _ = try fm.replaceItemAt(destination, withItemAt: bundle)
    } else {
      try fm.moveItem(at: bundle, to: destination)
    }
    print("Built \(name) \(version) (\(buildNumber)): \(destination.path)")
    return destination
    #else
    throw ToolError("Product bundling requires macOS")
    #endif
  }

  @MainActor
  func launch(_ bundle: URL) async throws {
    #if os(macOS)
    guard
      let info = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: bundle.at("Contents/Info.plist")),
        options: [],
        format: nil,
      ) as? [String: Any],
      let identifier = info["CFBundleIdentifier"] as? String
    else { throw ToolError("App bundle has no valid identifier") }
    let configuration = NSWorkspace.OpenConfiguration()
    let environment = ProcessInfo.processInfo.environment
    for (key, flag) in [("XDG_CONFIG_HOME", "--tatami-config-home"), ("TATAMI_SOCKET_PATH", "--tatami-socket-path")] {
      if let path = environment[key] {
        try require(path.hasPrefix("/"), "\(key) must be an absolute path")
        configuration.arguments += [flag, path]
      }
    }
    let isolated = environment["XDG_CONFIG_HOME"] != nil && environment["TATAMI_SOCKET_PATH"] != nil
    let running = NSWorkspace.shared.runningApplications.filter { app in
      if isolated {
        return app.bundleURL?.resolvingSymlinksInPath() == bundle.resolvingSymlinksInPath()
      }
      // The ordinary dev loop replaces the installed window manager, as the
      // previous make target did. Two managers must not own the same desktop.
      return ["dev.PangMo5.Tatami", "dev.PangMo5.Tatami.debug"].contains(app.bundleIdentifier ?? "")
    }
    for app in running {
      try require(app.terminate(), "Could not quit \(identifier). Quit it before running the new build.")
    }
    // Wait for actual termination before launching, so Launch Services cannot
    // reactivate the old process. The timeout bounds an unresponsive app's quit.
    let deadline = ContinuousClock.now + .seconds(5)
    while running.contains(where: { !$0.isTerminated }), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    try require(running.allSatisfy(\.isTerminated), "Timed out quitting \(identifier)")
    _ = try await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
    #else
    throw ToolError("Launching the product requires macOS")
    #endif
  }
}
