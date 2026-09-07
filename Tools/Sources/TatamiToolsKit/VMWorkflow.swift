// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - VMWorkflow

struct VMWorkflow: Sendable {

  // MARK: Lifecycle

  init(workspace: Workspace) {
    self.workspace = workspace
    name = ProcessInfo.processInfo.environment["VM_NAME"] ?? "tatami-demo"
  }

  // MARK: Internal

  let workspace: Workspace
  let name: String
  let environment = ProcessInfo.processInfo.environment

  func guest(_ arguments: [String], capture: Bool = false) async throws -> String {
    try await runProcess(["tart", "exec", name] + arguments, capture: capture)
  }

  func bootstrap() async throws {
    #if os(macOS) && arch(arm64)
    try require(!workspace.lab.path.contains(":"), "Tart cannot share a path containing ':'")
    let help = try await runProcess(["tart", "--help"], capture: true)
    try require(!matches(#"(?m)^\s+exec\b"#, help).isEmpty, "This Tart build has no exec command; upgrade Tart")
    let listing = try JSON.parse(await runProcess(["tart", "list", "--format", "json"], capture: true))
    if !listing.array.contains(where: { $0["Name"].str == name }) { try await runProcess([
      "tart",
      "clone",
      environment["BASE_IMAGE"] ?? "ghcr.io/cirruslabs/macos-sequoia-base:latest",
      name,
    ]) }
    let current = try JSON.parse(await runProcess(["tart", "list", "--format", "json"], capture: true))
    guard let entry = current.array.first(where: { $0["Name"].str == name }) else { throw ToolError("Cannot determine VM state") }
    let running: Bool
    if !entry["Running"].isNull { running = entry["Running"].boolean }
    else if ["running", "stopped"].contains(entry["State"].str) { running = entry["State"].str == "running" }
    else { throw ToolError("Tart did not report a readable VM state; refusing to change hardware") }
    if running {
      try require(
        !["DISPLAY_SIZE", "CPUS", "MEMORY_MB", "DISK_GB"].contains(where: { environment[$0] != nil }),
        "Hardware cannot be applied to a running VM; stop it first",
      )
      print("\(name) is already running; its current hardware is unchanged")
    } else {
      try await runProcess([
        "tart",
        "set",
        name,
        "--display",
        environment["DISPLAY_SIZE"] ?? "1920x1200px",
        "--no-display-refit",
        "--cpu",
        environment["CPUS"] ?? "6",
        "--memory",
        environment["MEMORY_MB"] ?? "10240",
      ])
      try await runProcess(["tart", "set", name, "--disk-size", environment["DISK_GB"] ?? "120"])
      // A VM intentionally outlives the invoking command, like a background preview.
      let logURL = workspace.lab.at(".sync/tart-\(name).log")
      try logURL.write("")
      let log = try FileHandle(forWritingTo: logURL)
      defer { try? log.close() }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = ["tart", "run", name, "--dir=demolab:" + workspace.lab.path]
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = log
      process.standardError = log
      try process.run()
      print("Started \(name); log: \(logURL.path)")
    }
    print(try await runProcess(["tart", "get", name, "--format", "json"], capture: true))
    let ip = trim(try await runProcess(["tart", "ip", name, "--wait", "300"], capture: true))
    let deadline = ContinuousClock.now.advanced(by: .seconds(300))
    while true {
      do { _ = try await guest(["/usr/bin/true"], capture: true)
        break
      } catch { try require(ContinuousClock.now < deadline, "The guest agent never answered")
        try await Task.sleep(for: .seconds(2))
      }
    }
    _ = try await guest(["/usr/bin/sw_vers"])
    print("Guest ready: \(ip). Run tatami-tools vm-sync, then grant the documented permissions in the guest GUI.")
    #else
    throw ToolError("Tart macOS VMs require an Apple silicon Mac")
    #endif
  }

  func sync(build: Bool) async throws {
    _ = try await guest(["/usr/bin/true"], capture: true)
    try FilmPresentation(workspace: workspace).writeSwift(workspace: workspace)
    let home = trim(try await guest(["/usr/bin/printenv", "HOME"], capture: true))
    let guestDirectory = environment["GUEST_DIR"] ?? "DemoLab"
    try require(
      !guestDirectory.hasPrefix("/") && !guestDirectory.split(separator: "/").contains(".."),
      "GUEST_DIR must be relative to the guest home",
    )
    let destination = URL(fileURLWithPath: home).at(guestDirectory)
    let nonce = UUID().uuidString
    let sync = workspace.lab.at(".sync")
    let stage = fm.temporaryDirectory.at("tatami-sync-" + nonce)
    try sync.makeDirectory()
    try stage.makeDirectory()
    let archive = sync.at("lab-\(nonce).tgz")
    let helper = sync.at("tatami-tools-\(nonce)")
    defer { try? fm.removeItem(at: stage)
      try? fm.removeItem(at: archive)
      try? fm.removeItem(at: helper)
    }
    for entry in VMGuest.managed {
      let source = workspace.lab.at(entry)
      if source.exists { try copy(source, stage.at(entry)) } else { try stage.at(entry).makeDirectory() }
    }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    try copy(executable, helper)
    try copy(executable, stage.at("tatami-tools"))
    try await runProcess(["tar", "czf", archive.path, "-C", stage.path] + VMGuest.managed + ["tatami-tools"])
    let digest = try sha(archive)
    let share = URL(fileURLWithPath: environment["SHARE"] ?? "/Volumes/My Shared Files/demolab")
    _ = try await guest([
      share.at(".sync/" + helper.lastPathComponent).path,
      "vm-import",
      "--archive",
      share.at(".sync/" + archive.lastPathComponent).path,
      "--destination",
      destination.path,
      "--sha256",
      digest,
    ] + (build
      ? ["--build"]
      : []))
    print("Synced \(name):\(destination.path), archive SHA256 \(digest)")
  }

  func fetch(destination: URL) async throws {
    try require(!destination.exists, "Destination already exists")
    let nonce = UUID().uuidString
    let sync = workspace.lab.at(".sync")
    try sync.makeDirectory()
    let archive = sync.at("fetch-\(nonce).tar")
    let marker = sync.at("fetch-\(nonce).marker")
    let helper = sync.at("tatami-tools-\(nonce)")
    defer { try? fm.removeItem(at: archive)
      try? fm.removeItem(at: marker)
      try? fm.removeItem(at: helper)
    }
    try marker.write(nonce)
    try copy(URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath(), helper)
    let share = URL(fileURLWithPath: environment["GUEST_SHARE"] ?? "/Volumes/My Shared Files/demolab")
    let home = trim(try await guest(["/usr/bin/printenv", "HOME"], capture: true))
    let batch = environment["GUEST_DIR"] ?? "DemoLab/recordings"
    try require(
      !batch.hasPrefix("/") && !batch.split(separator: "/").contains(".."),
      "GUEST_DIR must be relative to the guest home",
    )
    let remoteHash = trim(try await guest(
      [
        share.at(".sync/" + helper.lastPathComponent).path,
        "vm-export",
        "--batch",
        URL(fileURLWithPath: home).at(batch).path,
        "--archive",
        share.at(".sync/" + archive.lastPathComponent).path,
        "--marker",
        share.at(".sync/" + marker.lastPathComponent).path,
        "--nonce",
        nonce,
      ],
      capture: true,
    ))
    let localHash = try sha(archive)
    try require(remoteHash == localHash, "Guest/host archive hashes differ")
    try destination.makeDirectory()
    try await runProcess(["tar", "xf", archive.path, "-C", destination.path])
    print("Fetched \(batch) into \(destination.path) (archive SHA256 \(localHash))")
  }

}

// MARK: - VMGuest

enum VMGuest {
  static let managed = [
    "Package.swift",
    "publication.json",
    "Sources",
    "Tests",
    "Localization",
    "config",
    "scenes",
    "scripts",
    "bin",
    "vm",
    "docs",
    "README.md",
  ]

  static func requireGuest() async throws {
    #if os(macOS)
    let virtual = trim(try await runProcess(["sysctl", "-n", "kern.hv_vmm_present"], capture: true))
    try require(virtual == "1", "This command only runs inside the recording VM")
    #else
    throw ToolError("Recording guest operations require macOS")
    #endif
  }

  static func importArchive(archive: URL, destination: URL, digest: String, build: Bool) async throws {
    try await requireGuest()
    try require(try sha(archive) == digest, "Source archive changed across the shared mount")
    let home = fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
    try require(destination.standardizedFileURL.path.hasPrefix(home.path + "/"), "Destination must be inside the guest home")
    let stage = fm.temporaryDirectory.at("tatami-import-" + UUID().uuidString)
    try stage.makeDirectory()
    defer { try? fm.removeItem(at: stage) }
    try await runProcess(["tar", "xzf", archive.path, "-C", stage.path])
    try require(
      stage.at("Sources/DemoAppKit").exists && stage.at("Package.swift").exists,
      "Archive is not a Demo Lab source bundle",
    )
    try destination.makeDirectory()
    for entry in managed { try copy(stage.at(entry), destination.at(entry)) }
    try copy(stage.at("tatami-tools"), destination.at(".build/tools/tatami-tools"))
    if build { try await BundleBuilder(workspace: Workspace(
      root: destination.deletingLastPathComponent(),
      labOverride: destination,
    )).build(output: nil) }
  }

  static func exportArchive(batch: URL, archive: URL, marker: URL, nonce: String) async throws {
    try await requireGuest()
    try require(try marker.text() == nonce, "Shared filesystem freshness marker does not match")
    let files = try batch.children().filter { file in
      [".mov", ".ass", ".timeline.json", ".take.json", ".scene.json", ".secondary.json", ".rejected.json"]
        .contains { file.lastPathComponent.hasSuffix($0) } || file.lastPathComponent == "capture-report.json"
    }
    try require(files.contains { $0.pathExtension == "mov" }, "No movies in \(batch.path)")
    try require(!archive.exists, "Archive already exists")
    try await runProcess(["tar", "cf", archive.path, "-C", batch.path, "--"] + files.map(\.lastPathComponent))
    print(try sha(archive))
  }
}
