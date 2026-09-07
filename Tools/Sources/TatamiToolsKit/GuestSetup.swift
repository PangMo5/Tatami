// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

extension VMWorkflow {
  func provision() async throws {
    try await sync(build: true)
    let home = trim(try await guest(["/usr/bin/printenv", "HOME"], capture: true))
    let destination = URL(fileURLWithPath: home).at(environment["GUEST_DIR"] ?? "DemoLab")
    let forwarded = ["TATAMI_APP", "TATAMI_DMG"].compactMap { key in environment[key].map { key + "=" + $0 } }
    _ = try await guest(["/usr/bin/env"] + forwarded + [
      destination.at(".build/tools/tatami-tools").path,
      "vm-setup",
      "--root",
      destination.path,
    ])
  }
}

extension VMGuest {
  static func setup(workspace: Workspace) async throws {
    try await requireGuest()
    let installed = URL(fileURLWithPath: "/Applications/Tatami.app")
    let environment = ProcessInfo.processInfo.environment
    if installed.exists {
      let plist = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: installed.at("Contents/Info.plist")),
        format: nil,
      ) as? [String: Any]
      print("Tatami already installed: \(plist?["CFBundleShortVersionString"] as? String ?? "unknown")")
    } else if let app = environment["TATAMI_APP"], !app.isEmpty {
      try require(URL(fileURLWithPath: app).exists, "TATAMI_APP does not exist")
      try await runProcess(["ditto", app, installed.path])
    } else if let dmg = environment["TATAMI_DMG"], !dmg.isEmpty {
      try require(URL(fileURLWithPath: dmg).exists, "TATAMI_DMG does not exist")
      let mount = fm.temporaryDirectory.at("tatami-dmg-" + UUID().uuidString)
      try mount.makeDirectory()
      defer { try? fm.removeItem(at: mount) }
      try await runProcess(["hdiutil", "attach", dmg, "-nobrowse", "-quiet", "-mountpoint", mount.path])
      do { try await runProcess(["ditto", mount.at("Tatami.app").path, installed.path]) }
      catch { _ = try? await runProcess(["hdiutil", "detach", mount.path, "-quiet"])
        throw error
      }
      try await runProcess(["hdiutil", "detach", mount.path, "-quiet"])
    } else {
      throw ToolError(
        "Tatami is not installed. Provide TATAMI_APP or TATAMI_DMG as a guest-visible path; provisioning does not download the app."
      )
    }
    try await desktopDefaults()
    do { try await TakeLibrary(workspace: workspace).control(["doctor"]) }
    catch {
      print(
        "Doctor reported blockers: \(error). Grant the documented Accessibility and Screen Recording permissions in the guest GUI before recording."
      )
    }
    print(
      "Provisioning complete. Dismiss first-run notifications, grant the permissions in DemoLab/docs/PERMISSIONS.md, then snapshot the VM."
    )
  }

  static func desktopDefaults() async throws {
    try await requireGuest()
    func attempt(_ label: String, _ command: [String]) async {
      do { _ = try await runProcess(command, capture: true)
        print("ok: \(label)")
      } catch { print("skip: \(label): \(error)") }
    }
    let dock: [(String, String, String)] = [
      ("autohide", "-bool", "true"),
      ("autohide-delay", "-float", "1000"),
      ("autohide-time-modifier", "-float", "0"),
      ("show-recents", "-bool", "false"),
      ("launchanim", "-bool", "false"),
      ("mru-spaces", "-bool", "false"),
      ("workspaces-auto-swoosh", "-bool", "false"),
    ]
    for (key, type, value) in dock { await attempt(key, ["defaults", "write", "com.apple.dock", key, type, value]) }
    for corner in ["tl", "tr", "bl", "br"] { await attempt(
      "disable hot corner \(corner)",
      ["defaults", "write", "com.apple.dock", "wvous-\(corner)-corner", "-int", "0"],
    ) }
    await attempt("restart Dock", ["killall", "Dock"])
    let settings: [(String, String, String, String)] = [
      ("com.apple.finder", "CreateDesktop", "-bool", "false"),
      ("com.apple.WindowManager", "EnableStandardClickToShowDesktop", "-bool", "false"),
      ("com.apple.WindowManager", "GloballyEnabled", "-bool", "false"),
      ("NSGlobalDomain", "NSAutomaticWindowAnimationsEnabled", "-bool", "false"),
      ("NSGlobalDomain", "NSWindowResizeTime", "-float", "0.001"),
      ("NSGlobalDomain", "AppleShowScrollBars", "-string", "Always"),
      ("NSGlobalDomain", "NSQuitAlwaysKeepsWindows", "-bool", "false"),
      ("com.apple.menuextra.clock", "ShowSeconds", "-bool", "false"),
      ("com.apple.menuextra.clock", "ShowDate", "-int", "2"),
    ]
    for (domain, key, type, value) in settings { await attempt(key, ["defaults", "write", domain, key, type, value]) }
    for owner in ["Finder", "WindowManager", "SystemUIServer"] { await attempt("restart \(owner)", ["killall", owner]) }
    if (try? await runProcess(["pgrep", "-f", "caffeinate -dimsu"], capture: true)) == nil {
      // launchd owns the persistent assertion after this setup command exits.
      await attempt(
        "start caffeinate",
        ["launchctl", "submit", "-l", "dev.PangMo5.DemoLab.caffeinate", "--", "/usr/bin/caffeinate", "-dimsu"],
      )
    }
    await attempt("no screen saver", ["defaults", "-currentHost", "write", "com.apple.screensaver", "idleTime", "-int", "0"])
    if (try? await runProcess(["sudo", "-n", "true"], capture: true)) != nil {
      await attempt("no display/system sleep", ["sudo", "-n", "pmset", "-a", "displaysleep", "0", "sleep", "0", "disksleep", "0"])
      for key in ["AutomaticCheckEnabled", "AutomaticDownload", "AutomaticallyInstallMacOSUpdates"] { await attempt(
        key,
        ["sudo", "-n", "defaults", "write", "/Library/Preferences/com.apple.SoftwareUpdate", key, "-bool", "false"],
      ) }
      await attempt(
        "no App Store updates",
        ["sudo", "-n", "defaults", "write", "/Library/Preferences/com.apple.commerce", "AutoUpdate", "-bool", "false"],
      )
      await attempt("unschedule updates", ["sudo", "-n", "softwareupdate", "--schedule", "off"])
      await attempt("disable indexing", ["sudo", "-n", "mdutil", "-a", "-i", "off"])
    } else { print("skip: system sleep, software updates and indexing need sudo") }
    print(
      "Set Focus, wallpaper and screen-capture permissions in System Settings, then snapshot. Log out and back in for desktop settings to settle."
    )
  }
}
