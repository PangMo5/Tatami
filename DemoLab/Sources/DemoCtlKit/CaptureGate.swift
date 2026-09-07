// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ApplicationServices
import CoreGraphics
import DemoAppKit
import Foundation

/// Recording acceptance checks use visible windows, not a launch acknowledgement.
@MainActor
public enum CaptureGate {
  static func windows() throws -> [[String: Any]] {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0)
      as? [[String: Any]] else {
      throw DemoCtlError.usage("cannot inspect visible windows before recording")
    }
    return windows
  }

  public static func requireCleanDesktop() throws {
    var problems: [String] = []
    for window in try windows() {
      let owner = window[kCGWindowOwnerName as String] as? String ?? ""
      let title = window[kCGWindowName as String] as? String ?? ""
      let normalized = title.lowercased()
      let permission = ["screen recording", "screen capture", "화면 기록", "화면 녹화", "accessibility", "permissions needed"]
        .contains { normalized.contains($0) }
      let systemDialog = ["UserNotificationCenter", "SecurityAgent", "System Settings", "Software Update", "universalAccessAuthWarn"]
        .contains(owner)
      // Notification Center also owns permanent desktop widgets and a
      // transparent full-screen host. Inspect actual notification text;
      // the existence of that host window alone does not mean a banner exists.
      if ["NotificationCenter", "Notification Center"].contains(owner),
         (window[kCGWindowLayer as String] as? Int ?? 0) > 0,
         let pid = window[kCGWindowOwnerPID as String] as? Int32 {
        problems += notificationTitles(pid: pid, windowTitle: title).map { "Notification: \($0)" }
      }
      let updateDialog = ["software update", "소프트웨어 업데이트", "ソフトウェアアップデート", "软件更新", "軟體更新"].contains(normalized)
      if permission || systemDialog || updateDialog { problems.append("\(owner): \(title)") }
    }
    guard problems.isEmpty else {
      throw DemoCtlError.usage("capture blocked by visible system UI: \(problems.joined(separator: "; ")). "
        + "Resolve it before recording. Recorder access does not prove Tatami has Screen Recording access.")
    }
  }

  private static func notificationTitles(pid: Int32, windowTitle: String) -> [String] {
    func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
      var value: CFTypeRef?
      guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
      return value
    }
    var titles: [String] = []
    func walk(_ element: AXUIElement, depth: Int) {
      guard depth < 12 else { return }
      if attribute(element, kAXIdentifierAttribute) as? String == "title",
         let text = attribute(element, kAXValueAttribute) as? String, !text.isEmpty {
        titles.append(text)
      }
      for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        walk(child, depth: depth + 1)
      }
    }
    let app = AXUIElementCreateApplication(pid)
    for window in attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
      where attribute(window, kAXTitleAttribute) as? String == windowTitle {
      walk(window, depth: 0)
    }
    return titles
  }

  public static func requireOpening(_ names: [String]) throws {
    let expected = try names.map { name -> String in
      guard let spec = DemoCatalog.spec(named: name) else { throw DemoCtlError.usage("unknown opening app \(name)") }
      return spec.bundleIdentifier
    }.sorted()
    let actual = try demoFrames().keys.map { String($0.split(separator: ":")[0]) }.sorted()
    guard expected == actual else {
      throw DemoCtlError.usage("opening window set differs: expected \(expected), found \(actual). Re-seed before recording.")
    }
  }

  public static func waitForApps(_ names: [String], timeout: Duration) throws {
    let specs = try names.map { name -> DemoAppSpec in
      guard let spec = DemoCatalog.spec(named: name) else {
        throw DemoCtlError.usage("unknown opening app \(name)")
      }
      return spec
    }
    var last: [String: CGRect] = [:]
    var stableSince = ContinuousClock.now
    let ready = try Shell.wait(timeout: timeout, poll: .milliseconds(100)) {
      try requireCleanDesktop()
      let frames = try demoFrames()
      let visible = specs.allSatisfy { spec in frames.keys.contains { $0.hasPrefix(spec.bundleIdentifier + ":") } }
      if !visible || !matches(frames, last) { stableSince = .now }
      last = frames
      return visible && ContinuousClock.now - stableSince >= .milliseconds(400)
    }
    guard ready else {
      throw DemoCtlError.usage("expected apps did not reach a stable visible layout: \(names.joined(separator: ", "))")
    }
  }

  static func demoFrames() throws -> [String: CGRect] {
    let identifiers = Dictionary(uniqueKeysWithValues: DemoCatalog.all.flatMap { spec in
      NSRunningApplication.runningApplications(withBundleIdentifier: spec.bundleIdentifier)
        .map { ($0.processIdentifier, spec.bundleIdentifier) }
    })
    var result: [String: CGRect] = [:]
    for window in try windows() {
      guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
            let id = identifiers[pid],
            window[kCGWindowLayer as String] as? Int == 0,
            let number = window[kCGWindowNumber as String] as? Int,
            let bounds = window[kCGWindowBounds as String] as? NSDictionary,
            let frame = CGRect(dictionaryRepresentation: bounds), frame.width > 80, frame.height > 80
      else { continue }
      result["\(id):\(number)"] = frame
    }
    return result
  }

  public static func matches(_ actual: [String: CGRect], _ expected: [String: CGRect], tolerance: CGFloat = 4) -> Bool {
    guard actual.keys.sorted() == expected.keys.sorted() else { return false }
    return expected.allSatisfy { key, value in
      guard let frame = actual[key] else { return false }
      return abs(frame.minX - value.minX) <= tolerance && abs(frame.minY - value.minY) <= tolerance
        && abs(frame.width - value.width) <= tolerance && abs(frame.height - value.height) <= tolerance
    }
  }
}
