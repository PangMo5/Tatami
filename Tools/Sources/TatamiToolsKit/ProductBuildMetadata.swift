// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
#if os(macOS)
import Security
#endif

// MARK: - ProductBuildMetadata

struct ProductBuildMetadata: Sendable {
  let sdkPath: String
  let sdkVersion: String
  let minimumVersion: String
  let fields: [String: String]

  var cliInfo: [String: Any] {
    info(identifier: "dev.PangMo5.tatami.cli", executable: "tatami", name: "tatami")
  }

  static func load(workspace: Workspace, version: String, buildNumber: String) async throws -> Self {
    let sdkPath = trim(try await runProcess(["xcrun", "--sdk", "macosx", "--show-sdk-path"], capture: true))
    let sdk = try JSON.read(URL(fileURLWithPath: sdkPath).at("SDKSettings.json"))
    let sdkVersion = sdk["Version"].str
    try require(fullMatch(#"[0-9]+(?:\.[0-9]+){1,2}"#, sdkVersion), "Selected SDK has no valid version")
    let manifest = try JSON.parse(await runProcess(
      ["swift", "package", "--package-path", workspace.root.path, "dump-package"],
      capture: true,
    ))
    let minimum = manifest["platforms"].array.first { $0["platformName"].str == "macos" }?["version"].str ?? ""
    try require(fullMatch(#"[0-9]+(?:\.[0-9]+){1,2}"#, minimum), "Package.swift has no macOS deployment target")
    let sdkBuild = trim(try await runProcess(["xcrun", "--sdk", "macosx", "--show-sdk-build-version"], capture: true))
    let xcode = try await runProcess(["xcodebuild", "-version"], capture: true)
    let xcodeVersion = matches(#"(?m)^Xcode ([0-9]+)\.([0-9]+)(?:\.([0-9]+))?"#, xcode)
    let xcodeBuild = matches(#"(?m)^Build version (\S+)"#, xcode)
    try require(xcodeVersion.count == 1 && xcodeBuild.count == 1 && !sdkBuild.isEmpty, "Could not read Xcode build metadata")
    let components = xcodeVersion[0]
    let xcodeNumber = Int(components[1])! * 100 + Int(components[2])! * 10 + (Int(components[3]) ?? 0)
    let fields = [
      "CFBundleDevelopmentRegion": "en",
      "CFBundleInfoDictionaryVersion": "6.0",
      "CFBundleShortVersionString": version,
      "CFBundleVersion": buildNumber,
      "LSMinimumSystemVersion": minimum,
      "NSHumanReadableCopyright": "© 2026 PangMo5. Released under AGPL-3.0-only.",
      "DTCompiler": sdk["DefaultProperties"]["DEFAULT_COMPILER"].str,
      "DTPlatformName": "macosx",
      "DTPlatformVersion": sdkVersion,
      "DTPlatformBuild": sdkBuild,
      "DTSDKName": sdk["CanonicalName"].str,
      "DTSDKBuild": sdkBuild,
      "DTXcode": String(xcodeNumber),
      "DTXcodeBuild": xcodeBuild[0][1],
      "BuildMachineOSBuild": trim(try await runProcess(["sw_vers", "-buildVersion"], capture: true)),
    ]
    try require(fields.values.allSatisfy { !$0.isEmpty }, "Incomplete Xcode build metadata")
    return Self(sdkPath: sdkPath, sdkVersion: sdkVersion, minimumVersion: minimum, fields: fields)
  }

  func info(identifier: String, executable: String, name: String) -> [String: Any] {
    var info = fields.mapValues { $0 as Any }
    info["CFBundleIdentifier"] = identifier
    info["CFBundleExecutable"] = executable
    info["CFBundleName"] = name
    info["CFBundleSupportedPlatforms"] = ["MacOSX"]
    return info
  }

  func writeCLIInfo(workspace: Workspace) throws -> URL {
    let data = try PropertyListSerialization.data(fromPropertyList: cliInfo, format: .xml, options: 0)
    // A content-addressed input makes every version/build/SDK change an
    // explicit linker dependency, even when the Swift sources stay unchanged.
    let file = workspace.root.at(".build/metadata/cli-" + sha(data) + ".plist")
    try file.deletingLastPathComponent().makeDirectory()
    if !file.exists {
      try data.write(to: file, options: .atomic)
    }
    return file
  }

  func validateExecutable(_ executable: URL, architectures: [String]) async throws -> Set<String> {
    let output = try await runProcess(["lipo", "-archs", executable.path], capture: true)
    let actual = Set(output.split(whereSeparator: \.isWhitespace).map(String.init))
    try require(!actual.isEmpty, "Missing architectures in \(executable.lastPathComponent)")
    if !architectures.isEmpty {
      try require(actual == Set(architectures), "Unexpected architectures in \(executable.lastPathComponent): \(output)")
    }
    let commands = try await runProcess(["xcrun", "vtool", "-show-build", executable.path], capture: true)
    let sdks = matches(#"(?m)^\s*sdk\s+([0-9.]+)\s*$"#, commands).map { $0[1] }
    let minimums = matches(#"(?m)^\s*minos\s+([0-9.]+)\s*$"#, commands).map { $0[1] }
    try require(
      sdks.count == actual.count && sdks.allSatisfy { $0 == sdkVersion },
      "Linked SDK differs from the selected SDK in \(executable.lastPathComponent)",
    )
    try require(
      minimums.count == actual.count && minimums.allSatisfy { $0 == minimumVersion },
      "Linked deployment target differs from Package.swift in \(executable.lastPathComponent)",
    )
    return actual
  }

  func validateCLIInfo(_ executable: URL, slices: Set<String>) throws {
    #if os(macOS)
    for architecture in slices {
      let attributes = [kSecCodeAttributeArchitecture: architecture] as CFDictionary
      var code: SecStaticCode?
      try require(
        SecStaticCodeCreateWithPathAndAttributes(executable as CFURL, SecCSFlags(), attributes, &code) == errSecSuccess,
        "Could not inspect CLI architecture: \(architecture)",
      )
      guard let code else { throw ToolError("Missing CLI code object") }
      var result: CFDictionary?
      try require(
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &result) == errSecSuccess,
        "Could not read CLI signing metadata",
      )
      guard let info = result as? [CFString: Any], let actual = info[kSecCodeInfoPList] as? [String: Any]
      else { throw ToolError("CLI has no embedded Info.plist: \(architecture)") }
      try require(NSDictionary(dictionary: actual).isEqual(to: cliInfo), "CLI embedded metadata differs from the app build")
    }
    #else
    throw ToolError("CLI metadata validation requires macOS")
    #endif
  }
}
