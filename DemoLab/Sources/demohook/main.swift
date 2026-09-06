// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import DemoAppKit
import Foundation
let env=ProcessInfo.processInfo.environment
let event=env["TATAMI_HOOK_EVENT"] ?? ""
guard let root=CommandLine.arguments.dropFirst().first, !event.isEmpty else {
  FileHandle.standardError.write(Data("usage: demohook <control-directory> (called by Tatami)\n".utf8));exit(64)
}
do {
  let value=HookActivity(event:event,profile:env["TATAMI_PROFILE_NAME"] ?? "",workspace:env["TATAMI_WORKSPACE_NAME"] ?? "",title:env["TATAMI_HUD_TITLE"] ?? "",subtitle:env["TATAMI_HUD_SUBTITLE"] ?? "")
  let file=URL(fileURLWithPath:root).appendingPathComponent(event == "hud" ? "hud-hook.json" : "workspace-hook.json")
  try JSONEncoder().encode(value).write(to:file,options:.atomic)
  DistributedNotificationCenter.default().postNotificationName(Notification.Name("dev.PangMo5.DemoLab.hookChanged"),object:nil,userInfo:nil,deliverImmediately:true)
} catch {FileHandle.standardError.write(Data("demohook: \(error)\n".utf8));exit(1)}
