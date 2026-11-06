// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum ProductRuntime {

  // MARK: Internal

  static func prepare(_ bundle: URL) async throws -> [URL] {
    let frameworks = bundle.at("Contents/Frameworks")
    let executables = [bundle.at("Contents/MacOS/Tatami"), bundle.at("Contents/Resources/tatami")]
    let scan = executables.flatMap { ["--scan-executable", $0.path] }
      + ["--scan-folder", frameworks.path, "--platform", "macosx"]
    let required = try await runProcess(["xcrun", "swift-stdlib-tool", "--print"] + scan, capture: true)
      .split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    try await runProcess(["xcrun", "swift-stdlib-tool", "--copy"] + scan + ["--destination", frameworks.path])
    for source in required {
      try require(frameworks.at(source.lastPathComponent).exists, "Missing bundled Swift runtime: \(source.lastPathComponent)")
    }
    let libraries = try frameworks.children().filter { $0.pathExtension == "dylib" }
    for executable in executables + libraries {
      let commands = try await runProcess(["otool", "-l", executable.path], capture: true)
      let paths = Set(matches(#"cmd LC_RPATH\s+cmdsize [0-9]+\s+path ([^\n]+) \(offset [0-9]+\)"#, commands).map { $0[1] })
      for path in paths where path.hasPrefix("/") && !isSystemPath(path) {
        // SwiftPM links products for its build tree. A distributed app must
        // resolve dependencies inside its bundle, never from that build tree.
        try await runProcess(["xcrun", "install_name_tool", "-delete_rpath", path, executable.path])
      }
      let dependencies = try await runProcess(["otool", "-L", executable.path], capture: true)
      for line in dependencies.split(separator: "\n") where line.hasPrefix("\t") {
        let name = trim(String(line).components(separatedBy: " (compatibility")[0])
        if name.hasPrefix("@rpath/") {
          let relative = String(name.dropFirst("@rpath/".count))
          // OS Swift ABI libraries can live in the dyld shared cache. The
          // standard-library tool decides which compatibility libraries ship.
          let systemSwift = relative.hasPrefix("libswift") && !relative.contains("/")
          try require(frameworks.at(relative).exists || systemSwift, "Unbundled runtime dependency: \(name)")
        } else if name.hasPrefix("/") {
          try require(isSystemPath(name), "Non-relocatable runtime dependency: \(name)")
        } else {
          throw ToolError("Unexpected runtime dependency: \(name)")
        }
      }
    }
    return libraries
  }

  // MARK: Private

  private static func isSystemPath(_ path: String) -> Bool {
    path.hasPrefix("/usr/lib/") || path.hasPrefix("/System/Library/")
  }

}
