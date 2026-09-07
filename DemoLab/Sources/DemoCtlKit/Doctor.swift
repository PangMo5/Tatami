// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ApplicationServices
import CoreGraphics
import DemoAppKit
import Foundation

// MARK: - DisplayInfo

public struct DisplayInfo: Sendable {

  // MARK: Lifecycle

  public init(index: Int, displayID: CGDirectDisplayID, name: String, uuid: String?, frame: CGRect, scale: CGFloat) {
    self.index = index
    self.displayID = displayID
    self.name = name
    self.uuid = uuid
    self.frame = frame
    self.scale = scale
  }

  // MARK: Public

  /// Sorted by `(frame.minX, frame.minY)` — the same order Tatami uses for
  /// `display focus next`, so an index here means the same display there.
  public static func all() -> [DisplayInfo] {
    NSScreen.screens
      .sorted { lhs, rhs in
        lhs.frame.minX == rhs.frame.minX
          ? lhs.frame.minY < rhs.frame.minY
          : lhs.frame.minX < rhs.frame.minX
      }
      .enumerated()
      .map { index, screen in
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let displayID = CGDirectDisplayID(number?.uint32Value ?? 0)
        return DisplayInfo(
          index: index,
          displayID: displayID,
          name: screen.localizedName,
          uuid: uuidString(for: displayID),
          frame: screen.frame,
          scale: screen.backingScaleFactor
        )
      }
  }

  public let index: Int
  public let displayID: CGDirectDisplayID
  public let name: String
  public let uuid: String?
  public let frame: CGRect
  public let scale: CGFloat

  /// The exact string a `displayHint` needs. Tatami stores a display as
  /// `"<uuid>::<name>"`, splitting on the first `::`.
  public var displayHint: String {
    guard let uuid else { return name }
    return "\(uuid)::\(name)"
  }

  // MARK: Private

  private static func uuidString(for displayID: CGDirectDisplayID) -> String? {
    guard displayID != 0, let reference = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
    let value = reference.takeRetainedValue()
    return CFUUIDCreateString(nil, value) as String?
  }

}

// MARK: - CheckStatus

public enum CheckStatus: String, Sendable {
  case ok = "ok"
  case warn = "warn"
  case fail = "fail"

  // MARK: Public

  public var marker: String {
    switch self {
    case .ok: "  ok  "
    case .warn: " warn "
    case .fail: " FAIL "
    }
  }
}

// MARK: - Check

public struct Check: Sendable {

  // MARK: Lifecycle

  public init(_ status: CheckStatus, _ title: String, _ detail: String = "") {
    self.status = status
    self.title = title
    self.detail = detail
  }

  // MARK: Public

  public let status: CheckStatus
  public let title: String
  public let detail: String

}

// MARK: - Doctor

/// Everything that has to be true before a take, checked in one place.
///
/// Two of these checks exist because the corresponding failure is *invisible*
/// at run time: without an Accessibility grant Tatami's socket still accepts and
/// acknowledges every command while no window ever moves, and a recorder
/// launched down the wrong path reports "no access" without prompting.
@MainActor
public struct Doctor {

  // MARK: Lifecycle

  public init(paths: LabPaths, install: TatamiInstall?) {
    self.paths = paths
    self.install = install
  }

  // MARK: Public

  public let paths: LabPaths
  public let install: TatamiInstall?

  public func run() -> [Check] {
    var checks = [Check]()

    checks.append(Check(.ok, "package root", paths.packageRoot.path))

    if let install {
      checks.append(Check(
        .ok,
        "Tatami",
        "\(install.bundle.path) (\(install.bundleIdentifier), \(install.version ?? "unknown version"))"
      ))
      checks.append(
        FileManager.default.isExecutableFile(atPath: install.cli.path)
          ? Check(.ok, "tatami CLI", install.cli.path)
          : Check(.fail, "tatami CLI", "missing at \(install.cli.path)")
      )
    } else {
      checks.append(Check(.fail, "Tatami", "not found — pass --tatami-app or set DEMOLAB_TATAMI_APP"))
    }

    checks.append(bundlesCheck())
    checks.append(contentsOf: overlayChecks())
    checks.append(hookCheck())
    checks.append(accessibilityCheck())
    checks.append(contentsOf: screenRecordingChecks())
    checks.append(contentsOf: tatamiRuntimeChecks())
    checks.append(configCheck())
    checks.append(contentsOf: displayChecks())

    let scenes = SceneLoader.available(in: paths)
    checks.append(
      scenes.isEmpty
        ? Check(.warn, "scenes", "none found in \(paths.scenesRoot.path)")
        : Check(.ok, "scenes", scenes.joined(separator: ", "))
    )

    do {
      try CaptureGate.requireCleanDesktop()
      checks.append(Check(.ok, "capture surface", "no permission or settings window detected"))
    } catch {
      checks.append(Check(.fail, "capture surface", String(describing: error)))
    }
    return checks
  }

  // MARK: Private

  private func bundlesCheck() -> Check {
    let controller = DemoAppsController(paths: paths)
    let missing = controller.missingBundles(DemoCatalog.all)
    if missing.isEmpty {
      return Check(.ok, "demo apps", "\(DemoCatalog.all.count) bundles in \(paths.bundlesRoot.path)")
    }
    return Check(.fail, "demo apps", "missing \(missing.joined(separator: ", ")) — run `democtl build`")
  }

  /// The narration overlay, which is not part of ``DemoCatalog/all`` and so is
  /// missed by every check that walks the demo apps.
  ///
  /// Both halves are reported because they fail independently: the bundle can be
  /// missing (never built), and a built, running overlay can still be deaf if it
  /// was launched without the lab's `DEMOLAB_CONTROL_DIR`, in which case every
  /// caption in a scene lands nowhere.
  private func overlayChecks() -> [Check] {
    let overlay = OverlayController(paths: paths)
    var checks = [Check]()
    checks.append(
      overlay.bundleExists
        ? Check(.ok, "overlay bundle", "\(overlay.bundle.path) (\(DemoCatalog.overlayBundleIdentifier))")
        : Check(.fail, "overlay bundle", "missing at \(overlay.bundle.path). Run `democtl build`")
    )
    if OverlayController.isListening {
      checks.append(Check(.ok, "overlay control", "answering on \(OverlayController.socketPath)"))
    } else if OverlayController.running().isEmpty {
      checks.append(Check(.warn, "overlay control", "not running. `democtl seed` starts it"))
    } else {
      checks.append(Check(
        .fail,
        "overlay control",
        "running but silent on \(OverlayController.socketPath). It binds that socket only when it is "
          + "launched with \(LabControl.variable) set to \(paths.controlDirectory.path); "
          + "`democtl reset && democtl seed` relaunches it correctly."
      ))
    }
    return checks
  }

  private func hookCheck() -> Check {
    FileManager.default.isExecutableFile(atPath: paths.hookExecutable.path)
      ? Check(.ok, "hook executable", paths.hookExecutable.path)
      : Check(.fail, "hook executable", "not executable: \(paths.hookExecutable.path) (run tatami-tools bundle-apps)")
  }

  private func accessibilityCheck() -> Check {
    // The lab only needs its own trust for scenes that type shortcuts. Tatami
    // needs its own, separately, for every window operation.
    AXIsProcessTrusted()
      ? Check(.ok, "Accessibility (this process)", "trusted — scenes may type shortcuts")
      : Check(
        .warn,
        "Accessibility (this process)",
        "not trusted; CLI-driven scenes still work, `key`/`hold` steps will refuse to run"
      )
  }

  private func screenRecordingChecks() -> [Check] {
    var checks = [Check]()
    checks.append(
      CGPreflightScreenCaptureAccess()
        ? Check(.ok, "Screen Recording (this process)", "granted")
        : Check(.warn, "Screen Recording (this process)", "not granted (only the recorder needs it)")
    )

    let recorder = RecorderController(paths: paths)
    guard recorder.bundleExists else {
      checks.append(Check(.fail, "DemoRecorder.app", "missing — run `democtl build`"))
      return checks
    }
    if let granted = try? recorder.preflight() {
      checks.append(
        granted
          ? Check(.ok, "DemoRecorder screen access", "granted when run directly")
          : Check(
            .warn,
            "DemoRecorder screen access",
            "denied when run directly. That is expected before the one-time grant, and can also "
              + "mean the parent process owns TCC responsibility. `democtl record start` launches it "
              + "through LaunchServices, which is the path that can be granted."
          )
      )
    }
    return checks
  }

  private func tatamiRuntimeChecks() -> [Check] {
    var checks = [Check]()
    let others = TatamiProcess.running()
    if others.isEmpty {
      checks.append(Check(.warn, "Tatami process", "not running — `democtl seed` starts it"))
    } else {
      checks.append(Check(.ok, "Tatami process", "\(others.count) running"))
    }

    guard let install else { return checks }
    let client = TatamiClient(install: install, paths: paths)
    if let version = try? client.runningVersion() {
      checks.append(Check(.ok, "lab socket", "\(paths.socketPath.path) answering, Tatami \(version)"))
      if let hooks = try? client.hooks() {
        let invalid = hooks.filter { ($0["valid"] as? Bool) == false }.compactMap { $0["id"] as? String }
        checks.append(
          invalid.isEmpty
            ? Check(.ok, "hooks", "\(hooks.count) registered, all valid")
            : Check(.fail, "hooks", "invalid: \(invalid.joined(separator: ", "))")
        )
      }
    } else if !others.isEmpty {
      checks.append(Check(
        .fail,
        "lab socket",
        "\(paths.socketPath.path) is not answering, but a Tatami is running. It was probably started "
          + "without the lab's isolation flags; run `democtl reset && democtl seed`."
      ))
    }
    return checks
  }

  private func configCheck() -> Check {
    guard let text = try? String(contentsOf: paths.configFile, encoding: .utf8) else {
      return Check(.warn, "lab config", "not rendered yet — run `democtl seed`")
    }
    let report = ConfigValidator.report(text)
    if !report.problems.isEmpty {
      return Check(.fail, "lab config", report.problems.joined(separator: "; "))
    }
    if !report.warnings.isEmpty {
      return Check(.warn, "lab config", report.warnings.joined(separator: "; "))
    }
    return Check(.ok, "lab config", paths.configFile.path)
  }

  private func displayChecks() -> [Check] {
    let displays = DisplayInfo.all()
    guard !displays.isEmpty else {
      return [Check(.fail, "displays", "AppKit reports no screens")]
    }
    var checks = displays.map { display in
      Check(
        display.name.isEmpty ? .fail : .ok,
        "display \(display.index)",
        display.name.isEmpty
          // Tatami drops a screen whose localizedName is empty, and an empty
          // display set makes it skip the entire startup restore.
          ? "reports an EMPTY name; Tatami will ignore this screen entirely"
          : "\(display.displayHint) \(Int(display.frame.width))x\(Int(display.frame.height)) @\(display.scale)x"
      )
    }
    if displays.count == 1 {
      checks.append(Check(
        .warn,
        "multi-display scenes",
        "one display connected: cross-display scenes need a secondary screen. "
          + "The lab can add a guest-side CoreGraphics screen with `democtl display connect`."
      ))
    }
    return checks
  }

}
