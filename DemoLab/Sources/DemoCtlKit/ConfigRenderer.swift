// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - SeedOptions

public struct SeedOptions: Sendable, Equatable {

  // MARK: Lifecycle

  public init(
    pulseLayout: String = "floating",
    borrowEdge: String = "right",
    focusFollowsMouse: Bool = false,
    mouseFollowsFocus: Bool = true,
    debugLogging: Bool = false
  ) {
    self.pulseLayout = pulseLayout
    self.borrowEdge = borrowEdge
    self.focusFollowsMouse = focusFollowsMouse
    self.mouseFollowsFocus = mouseFollowsFocus
    self.debugLogging = debugLogging
  }

  // MARK: Public

  public static let pulseLayouts = ["floating", "unmanaged", "tiled"]
  public static let borrowEdges = ["top", "bottom", "left", "right"]

  /// `floating` = Always on Top (needs Screen Recording, because the always-on-top
  /// window is a ScreenCaptureKit mirror). `unmanaged` = Leave As Is (needs no
  /// permission at all). `tiled` folds Pulse into every layout.
  public var pulseLayout: String
  public var borrowEdge: String
  public var focusFollowsMouse: Bool
  public var mouseFollowsFocus: Bool
  public var debugLogging: Bool

  public func validated() throws -> SeedOptions {
    var problems = [String]()
    if !Self.pulseLayouts.contains(pulseLayout) {
      problems.append("--pulse must be one of \(Self.pulseLayouts.joined(separator: ", "))")
    }
    if !Self.borrowEdges.contains(borrowEdge) {
      problems.append("--borrow-edge must be one of \(Self.borrowEdges.joined(separator: ", "))")
    }
    guard problems.isEmpty else { throw DemoCtlError.usage(problems.joined(separator: "\n")) }
    return self
  }

}

// MARK: - ConfigRenderer

/// Turns `config/tatami-demo.toml.in` into the config file the lab's Tatami
/// instance reads.
public struct ConfigRenderer: Sendable {

  // MARK: Lifecycle

  public init(paths: LabPaths) {
    self.paths = paths
  }

  // MARK: Public

  public let paths: LabPaths

  public func render(_ options: SeedOptions) throws -> String {
    guard let template = try? String(contentsOf: paths.templateFile, encoding: .utf8) else {
      throw DemoCtlError.templateMissing(paths.templateFile.path)
    }

    let substitutions = [
      "@STATUS_HOOK@": paths.packageRoot.appendingPathComponent("config/hooks/status-hook").path,
      "@STATUS_BINARY@": paths.bundlesRoot.appendingPathComponent("bin/demohook").path,
      "@CONTROL_DIR@": paths.controlDirectory.path,
      "@HOOK@": paths.hookScript.path,
      "@EVENT_LOG@": paths.eventLog.path,
      "@PULSE_LAYOUT@": options.pulseLayout,
      "@BORROW_EDGE@": options.borrowEdge,
      "@FOCUS_FOLLOWS_MOUSE@": options.focusFollowsMouse ? "true" : "false",
      "@MOUSE_FOLLOWS_FOCUS@": options.mouseFollowsFocus ? "true" : "false",
      "@DEBUG_LOGGING@": options.debugLogging ? "true" : "false",
    ]

    var rendered = template
    for (placeholder, value) in substitutions {
      rendered = rendered.replacingOccurrences(of: placeholder, with: value)
    }

    // A leftover placeholder would reach Tatami as a plain string and be
    // silently accepted or silently defaulted. Catch it here instead.
    let leftovers = Self.placeholders(in: rendered)
    guard leftovers.isEmpty else { throw DemoCtlError.unresolvedPlaceholders(leftovers) }

    return rendered
  }

  /// Writes the rendered config atomically.
  ///
  /// `Data.write(options: .atomic)` is a temporary file plus a rename, which is
  /// exactly the write pattern Tatami documents for external writers and which
  /// its file watcher picks up. Writing in place through a long-lived file
  /// descriptor is the one pattern that does *not* work.
  @discardableResult
  public func write(_ options: SeedOptions) throws -> String {
    let rendered = try render(options)
    try paths.ensureRuntimeDirectories()
    let problems = ConfigValidator.problems(in: rendered)
    guard problems.isEmpty else { throw DemoCtlError.configInvalid(problems) }
    try Data(rendered.utf8).write(to: paths.configFile, options: .atomic)
    return rendered
  }

  // MARK: Private

  private static let placeholderPattern = try? NSRegularExpression(pattern: "@[A-Z][A-Z0-9_]*@")

  private static func placeholders(in text: String) -> [String] {
    guard let placeholderPattern else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    let matches = placeholderPattern.matches(in: text, range: range)
    let names = matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    return Set(names).sorted()
  }

}
