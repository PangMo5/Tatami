// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import DemoAppKit
import Foundation
import System

let environment = ProcessInfo.processInfo.environment
let arguments = Array(CommandLine.arguments.dropFirst())
let event = environment["TATAMI_HOOK_EVENT"] ?? ""
guard arguments.count == 2, ["event-log", "status"].contains(arguments[0]), !event.isEmpty else {
  FileHandle.standardError.write(Data("usage: demohook event-log <log> | status <control-directory> (called by Tatami)\n".utf8))
  exit(64)
}
do {
  let target = URL(fileURLWithPath: arguments[1])
  if arguments[0] == "event-log" {
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fields = [String(Int(Date().timeIntervalSince1970)), event,
                  environment["TATAMI_PROFILE_NAME"] ?? "", environment["TATAMI_WORKSPACE_NAME"] ?? "",
                  environment["TATAMI_WORKSPACE_KIND"] ?? "", environment["TATAMI_DISPLAY_NAME"] ?? ""]
    let data = Data((fields.joined(separator: "\t") + "\n").utf8)
    let file = try FileDescriptor.open(FilePath(target.path), .writeOnly, options: [.create, .append], permissions: [.ownerRead, .ownerWrite])
    defer { try? file.close() }
    // One append write keeps concurrent display-transition records together.
    let written = try data.withUnsafeBytes { try file.write($0) }
    guard written == data.count else { throw CocoaError(.fileWriteUnknown) }
  } else {
    let value = HookActivity(event: event, profile: environment["TATAMI_PROFILE_NAME"] ?? "",
                             workspace: environment["TATAMI_WORKSPACE_NAME"] ?? "",
                             title: environment["TATAMI_HUD_TITLE"] ?? "", subtitle: environment["TATAMI_HUD_SUBTITLE"] ?? "")
    try JSONEncoder().encode(value).write(to: target.appendingPathComponent(event == "hud" ? "hud-hook.json" : "workspace-hook.json"), options: .atomic)
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("dev.PangMo5.DemoLab.hookChanged"), object: nil, userInfo: nil, deliverImmediately: true)
  }
} catch {
  FileHandle.standardError.write(Data("demohook: \(error)\n".utf8)); exit(1)
}
