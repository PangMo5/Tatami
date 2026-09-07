// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - DemoAppID

/// Every app the Demo Lab ships. The raw value is the executable *and* bundle
/// name, so one identifier drives the SwiftPM target, the `.app` bundle, the
/// bundle identifier, and the Tatami config.
///
/// The names say what each app *is*, not what it is branded. A viewer reads a
/// window title and the menu-bar workspace name in about a second, and
/// "Terminal" costs them none of it while an invented product name costs them
/// the whole second. Each name also matches the workspace it belongs to, so the
/// menu bar and the screen say the same word.
public enum DemoAppID: String, CaseIterable, Sendable, Codable {
  case canvas = "Canvas"
  case editor = "Editor"
  case terminal = "Terminal"
  case review = "Review"
  case docs = "Docs"
  case chat = "Chat"
  case notes = "Notes"
  case monitor = "Monitor"
}

// MARK: - DemoAppSpec

/// The single source of truth for one demo app. `democtl`, the bundler, the
/// icon renderer, and the Tatami config template all read this, so a new app
/// is added in exactly one place.
public struct DemoAppSpec: Sendable, Equatable {

  // MARK: Lifecycle

  public init(
    id: DemoAppID,
    role: String,
    symbolName: String,
    accent: DemoAccent,
    defaultWindowCount: Int,
    windowSize: CGSize,
    windowTitles: [LocalizedStringResource],
    categoryType: String
  ) {
    self.id = id
    self.role = role
    self.symbolName = symbolName
    self.accent = accent
    self.defaultWindowCount = defaultWindowCount
    self.windowSize = windowSize
    self.windowTitles = windowTitles
    self.categoryType = categoryType
  }

  // MARK: Public

  public let id: DemoAppID
  /// One line describing what the app stands in for, used in `--help` and docs.
  public let role: String
  public let symbolName: String
  public let accent: DemoAccent
  /// Windows opened at launch when no `--windows` override is given. Fixed so
  /// every take starts with the same window count.
  public let defaultWindowCount: Int
  /// The **content** size, excluding the title bar. ``DemoAppHost`` converts it
  /// to a frame rect before placing the window.
  public let windowSize: CGSize
  /// One title per content variant, in the same order the app's view picks its
  /// fixtures, and never a date, a counter that survives across launches, or
  /// anything else that drifts between takes. A title array shorter than the
  /// view's fixture list would name a window after something it is not showing.
  public let windowTitles: [LocalizedStringResource]
  /// LaunchServices category used by the app bundler.
  public let categoryType: String

  public var name: String { id.rawValue }

  /// Deliberately **not** under `dev.PangMo5.Tatami.` — `MacApp.isTatami`
  /// treats that exact prefix as Tatami itself, and a demo app must never be
  /// mistaken for the window manager driving it.
  public var bundleIdentifier: String { "dev.PangMo5.DemoLab.\(id.rawValue)" }


  public func windowTitle(at index: Int) -> String {
    guard !windowTitles.isEmpty else { return name }
    // The same wrap every view uses to pick its fixture (`index % fixtures`),
    // so a title always names what its window is actually showing.
    let base = String(localized: windowTitles[index % windowTitles.count])
    guard index >= windowTitles.count else { return base }
    // Extra windows opened live on camera stay identifiable and stable: the
    // suffix keeps them distinct from the titles they wrap onto.
    return "\(base) \(index + 1)"
  }

}

// MARK: - DemoAccent

/// A small, fixed palette. Values are sRGB components so the icon renderer and
/// the SwiftUI views agree without a shared asset catalog.
public struct DemoAccent: Sendable, Equatable {

  // MARK: Lifecycle

  public init(red: Double, green: Double, blue: Double) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  // MARK: Public

  public static let blue = DemoAccent(red: 0.20, green: 0.47, blue: 0.96)
  public static let purple = DemoAccent(red: 0.51, green: 0.36, blue: 0.85)
  public static let teal = DemoAccent(red: 0.13, green: 0.55, blue: 0.58)
  public static let indigo = DemoAccent(red: 0.35, green: 0.40, blue: 0.78)
  public static let green = DemoAccent(red: 0.18, green: 0.55, blue: 0.34)
  public static let orange = DemoAccent(red: 0.85, green: 0.48, blue: 0.13)
  public static let graphite = DemoAccent(red: 0.36, green: 0.40, blue: 0.45)
  /// Selection fill for source lists.
  ///
  /// Deliberately a fixed color rather than `Color.accentColor`: the system
  /// accent is a per-machine preference, so a selected row would be pink on one
  /// recording machine and blue on the next. This is macOS's own default accent
  /// blue, so the apps still look stock while every take matches.
  public static let selection = DemoAccent(red: 0.00, green: 0.48, blue: 1.00)

  public let red: Double
  public let green: Double
  public let blue: Double

}

// MARK: - DemoCatalog

public enum DemoCatalog {

  // MARK: Public

  public static let all: [DemoAppSpec] = [
    DemoAppSpec(id: .canvas, role: "Design preview of the saved draft", symbolName: "square.stack.3d.up", accent: .purple,
      defaultWindowCount: 1, windowSize: CGSize(width: 1100, height: 800), windowTitles: ["Launch page — canvas", "Launch page — alternate"], categoryType: "public.app-category.graphics-design"),
    DemoAppSpec(
      id: .editor,
      role: "Draft editor: edit and save the launch page",
      symbolName: "doc.text",
      accent: .blue,
      defaultWindowCount: 1,
      windowSize: CGSize(width: 980, height: 640),
      windowTitles: ["Launch page", "Launch page — alternate"],
      categoryType: "public.app-category.developer-tools"
    ),
    DemoAppSpec(
      id: .terminal,
      role: "Terminal: run checks against the saved draft",
      symbolName: "terminal",
      accent: .graphite,
      defaultWindowCount: 1,
      windowSize: CGSize(width: 860, height: 520),
      windowTitles: ["Launch checks", "Launch checks — second session"],
      categoryType: "public.app-category.developer-tools"
    ),
    DemoAppSpec(
      id: .review,
      role: "Copy review: validate the saved draft and approve it",
      symbolName: "checkmark.bubble",
      accent: .purple,
      defaultWindowCount: 1,
      windowSize: CGSize(width: 1100, height: 700),
      windowTitles: ["Launch copy — review", "Launch copy — second review"],
      categoryType: "public.app-category.developer-tools"
    ),
    DemoAppSpec(
      id: .docs,
      role: "Documentation and reference",
      symbolName: "book.closed",
      accent: .teal,
      defaultWindowCount: 1,
      windowSize: CGSize(width: 900, height: 660),
      windowTitles: ["Launch brief", "Content direction"],
      categoryType: "public.app-category.reference"
    ),
    DemoAppSpec(
      id: .chat,
      role: "Team conversation",
      symbolName: "bubble.left.and.bubble.right",
      accent: .indigo,
      defaultWindowCount: 1,
      windowSize: CGSize(width: 960, height: 660),
      windowTitles: ["#launch", "#team"],
      categoryType: "public.app-category.social-networking"
    ),
    DemoAppSpec(
      id: .notes,
      role: "Checklist: capture and complete the next small task",
      symbolName: "square.and.pencil",
      accent: .orange,
      defaultWindowCount: 1,
      windowSize: CGSize(width: 560, height: 620),
      windowTitles: ["Launch checklist"],
      categoryType: "public.app-category.productivity"
    ),
    DemoAppSpec(
      id: .monitor,
      role: "Small utility: the natural Always on Top and Leave As Is subject",
      symbolName: "waveform.path.ecg",
      accent: .green,
      defaultWindowCount: 1,
      windowSize: CGSize(width: 400, height: 310),
      windowTitles: ["Launch status"],
      categoryType: "public.app-category.developer-tools"
    ),
  ]

  /// The caption and keystroke overlay. Not a demo app: it is never assigned to
  /// a workspace and never tiled, so it stays out of ``all`` and is registered in
  /// Tatami's `settings.visibility.overlayAwareApps` instead.
  public static let overlayBundleIdentifier = "dev.PangMo5.DemoLab.Overlay"

  public static func spec(_ id: DemoAppID) -> DemoAppSpec {
    // Every case is present in `all`; a missing one is a programming error we
    // want to see immediately rather than paper over with a default app.
    guard let match = all.first(where: { $0.id == id }) else {
      fatalError("DemoCatalog is missing a spec for \(id.rawValue)")
    }
    return match
  }

  public static func spec(named name: String) -> DemoAppSpec? {
    all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
  }

}
