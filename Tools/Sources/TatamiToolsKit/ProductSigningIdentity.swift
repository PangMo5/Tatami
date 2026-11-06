// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
#if os(macOS)
import CryptoKit
import Security
#endif

// MARK: - ProductSigningIdentity

struct ProductSigningIdentity: Sendable {
  let fingerprint: String
  let team: String

  static func resolve(_ name: String, team: String?) async throws -> Self {
    #if os(macOS)
    let output = try await runProcess(["security", "find-identity", "-v", "-p", "codesigning"], capture: true)
    let identities = matches(#"(?m)^\s*[0-9]+\)\s+([0-9A-Fa-f]+)\s+"([^"]+)""#, output)
    var eligible = Set(identities.filter {
      $0[1] == name || $0[2] == name || $0[2].hasPrefix(name + ":")
    }.map { $0[1] })
    // The common-name suffix identifies the developer, not the team. Match
    // the certificate subject's organizational unit, as Xcode does.
    let query = [kSecClass: kSecClassCertificate, kSecMatchLimit: kSecMatchLimitAll, kSecReturnRef: true] as CFDictionary
    var result: CFTypeRef?
    try require(SecItemCopyMatching(query, &result) == errSecSuccess, "Could not read signing certificates")
    guard let certificates = result as? [SecCertificate] else { throw ToolError("Unexpected signing certificate query result") }
    var teams = [String: String]()
    for certificate in certificates {
      let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1SubjectName] as CFArray, nil) as? [CFString: Any]
      let subject = values?[kSecOIDX509V1SubjectName] as? [CFString: Any]
      let fields = subject?[kSecPropertyKeyValue] as? [[CFString: Any]] ?? []
      guard let unit = fields.first(where: {
        $0[kSecPropertyKeyLabel] as? String == kSecOIDOrganizationalUnitName as String
      })?[kSecPropertyKeyValue] as? String else { continue }
      let hash = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
        .map { String(format: "%02X", $0) }.joined()
      teams[hash] = unit
    }
    if let team, !team.isEmpty {
      eligible = eligible.filter { teams[$0] == team }
    }
    try require(
      eligible.count == 1,
      "Expected one signing identity for \(name). Set CODESIGN_IDENTITY or DEVELOPMENT_TEAM in .mise.local.toml.",
    )
    let fingerprint = eligible.first!
    guard let team = teams[fingerprint] else { throw ToolError("Signing certificate has no team identifier") }
    return Self(fingerprint: fingerprint, team: team)
    #else
    throw ToolError("Code signing requires macOS")
    #endif
  }

  func command(release: Bool) -> [String] {
    ["codesign", "--force", "--sign", fingerprint] + (release
      ? ["--options", "runtime", "--timestamp"]
      : ["--timestamp=none"])
  }

  func entitlements(source: [String: Any], release: Bool, cli: Bool = false) throws -> [String: Any] {
    var result = source
    if cli {
      result["com.apple.application-identifier"] = team + ".dev.PangMo5.tatami.cli"
    }
    if release {
      try require(result["com.apple.security.get-task-allow"] as? Bool != true, "Release entitlements permit debugger attachment")
    } else {
      // Preserve Xcode's development-only debugger and test service access.
      result["com.apple.security.get-task-allow"] = true
      result["com.apple.security.temporary-exception.files.absolute-path.read-only"] = ["/"]
      result["com.apple.security.temporary-exception.mach-lookup.global-name"] = [
        "com.apple.testmanagerd",
        "com.apple.dt.testmanagerd.runner",
        "com.apple.coresymbolicationd",
      ]
    }
    return result
  }

  func validate(_ executable: URL, entitlements: [String: Any], release: Bool) throws {
    #if os(macOS)
    var code: SecStaticCode?
    try require(
      SecStaticCodeCreateWithPath(executable as CFURL, SecCSFlags(), &code) == errSecSuccess,
      "Could not inspect signed code: \(executable.path)",
    )
    guard let code else { throw ToolError("Missing signed code object") }
    var result: CFDictionary?
    try require(
      SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &result) == errSecSuccess,
      "Could not read code signature",
    )
    guard
      let info = result as? [CFString: Any],
      let flags = info[kSecCodeInfoFlags] as? NSNumber
    else { throw ToolError("Incomplete code signature metadata") }
    let actual = info[kSecCodeInfoEntitlementsDict] as? [String: Any] ?? [:]
    try require(info[kSecCodeInfoTeamIdentifier] as? String == team, "Signed team differs from the selected identity")
    try require(
      NSDictionary(dictionary: actual).isEqual(to: entitlements),
      "Signed entitlements differ from the build configuration",
    )
    // CS_RUNTIME is the stable Mach-O code directory flag used by codesign.
    try require((flags.uint32Value & 0x10000 != 0) == release, "Hardened Runtime differs from the build configuration")
    #else
    throw ToolError("Code signature validation requires macOS")
    #endif
  }
}
