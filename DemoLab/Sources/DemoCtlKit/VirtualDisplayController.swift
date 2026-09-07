// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CoreGraphics

@MainActor
public enum VirtualDisplayController {
  private static func hasSecondary() -> Bool {
    var ids=[CGDirectDisplayID](repeating:0,count:16);var count:UInt32=0
    guard CGGetOnlineDisplayList(16,&ids,&count) == .success else {return false}
    return ids.prefix(Int(count)).contains {CGDisplayVendorNumber($0)==0x5050 && CGDisplayModelNumber($0)==0x1001}
  }
  private static func pidFile(_ paths:LabPaths)->URL {paths.packageRoot.appendingPathComponent(".build/virtual-display.pid")}
  public static func connect(_ paths:LabPaths) throws {
    if hasSecondary() {return}
    let binary=paths.packageRoot.appendingPathComponent(".build/tools/demodisplay")
    guard FileManager.default.isExecutableFile(atPath:binary.path) else {throw DemoCtlError.usage("run tatami-tools build-virtual-display before adding a display")}
    let process=try Shell.launchDetached(binary,["3600"],log:paths.packageRoot.appendingPathComponent(".build/virtual-display.log"))
    try Data(String(process.processIdentifier).utf8).write(to:pidFile(paths),options:.atomic)
    guard Shell.wait(timeout:.seconds(12),until:{hasSecondary()}) else {
      throw DemoCtlError.usage("CoreGraphics did not create the secondary display")
    }
  }
  public static func disconnect(_ paths:LabPaths) throws {
    let file=pidFile(paths)
    guard FileManager.default.fileExists(atPath:file.path) else {
      guard !hasSecondary() else {
        throw DemoCtlError.usage("secondary display has no managed PID; close its creator first")
      }
      return
    }
    let raw=try String(contentsOf:file,encoding:.utf8)
    guard let pid=Int32(raw),pid>0 else {throw DemoCtlError.usage("invalid virtual display PID")}
    // Verify identity before signalling a potentially reused PID.
    let result=try Shell.run(URL(fileURLWithPath:"/bin/ps"),["-p",String(pid),"-o","comm="])
    if result.succeeded {
      guard result.standardOutput.contains("demodisplay") else {throw DemoCtlError.usage("virtual display PID belongs to another process")}
      kill(pid,SIGTERM)
    }
    guard Shell.wait(timeout:.seconds(12),until:{!hasSecondary()}) else {
      throw DemoCtlError.usage("secondary display did not disconnect")
    }
    try FileManager.default.removeItem(at:file)
  }
}
