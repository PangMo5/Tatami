// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Testing
@testable import TatamiKit

struct SharedMarkerTests {

  // MARK: Internal

  @Test
  func `a badge above the front window cannot expose its covered owner`() {
    let firstFrame = CGRect(x: 0, y: 0, width: 240, height: 220)
    let secondFrame = firstFrame.offsetBy(dx: 300, dy: 0)
    let firstCorner = CGRect(x: 200, y: 180, width: 24, height: 24)
    let secondCorner = firstCorner.offsetBy(dx: 300, dy: 0)
    let firstOwner = Self.surface(10, firstFrame)
    let secondOwner = Self.surface(11, secondFrame)
    let badges = [Self.surface(90, firstCorner), Self.surface(91, secondCorner)]
    // The first owner's body is partly visible but the badge's corner is not.
    let cover = Self.surface(20, CGRect(x: 160, y: 140, width: 120, height: 100))
    let hidden = MarkerWindowStack(badges + [cover, firstOwner, secondOwner])
    #expect(hidden.exposure(of: firstCorner, on: 10, ignoring: [90, 91]) == .covered(.init(pid: 20, windowID: 20, bundleId: "")))
    #expect(hidden.exposure(of: secondCorner, on: 11, ignoring: [90, 91]) == .exposed)
    let uncovered = MarkerWindowStack(badges + [firstOwner, secondOwner, cover])
    #expect(uncovered.exposure(of: firstCorner, on: 10, ignoring: [90, 91]) == .exposed)
  }

  @Test
  func `higher layers are composited above the badge without hiding its exposed owner`() {
    let frame = CGRect(x: 0, y: 0, width: 240, height: 220)
    let corner = CGRect(x: 200, y: 180, width: 24, height: 24)
    let dockCanvas = Self.surface(30, frame, layer: 20)
    let owner = Self.surface(10, frame)
    let clearCorner = MarkerWindowStack([dockCanvas, owner])
    #expect(clearCorner.exposure(of: corner, on: 10, ignoring: []) == .exposed)

    let cover = Self.surface(20, frame)
    let coveredCorner = MarkerWindowStack([dockCanvas, cover, owner])
    #expect(coveredCorner.exposure(of: corner, on: 10, ignoring: []) == .covered(.init(pid: 20, windowID: 20, bundleId: "")))
  }

  @Test
  func `a floating marker is authorized by the visible mirror rather than the covered native window`() {
    let frame = CGRect(x: 0, y: 0, width: 240, height: 220)
    let corner = CGRect(x: 200, y: 180, width: 24, height: 24)
    let invisibleCover = Self.surface(30, frame, alpha: 0)
    let stack = MarkerWindowStack([invisibleCover, Self.surface(40, frame), Self.surface(20, frame), Self.surface(10, frame)])
    #expect(stack.exposure(of: corner, on: 40, ignoring: []) == .exposed)
    #expect(stack.exposure(of: corner, on: 10, ignoring: []) == .covered(.init(pid: 40, windowID: 40, bundleId: "")))
    #expect(stack.exposure(of: corner, on: 90, ignoring: []) == .unavailable)
  }

  @Test
  func `window marker states compose without replacing one another`() throws {
    let key = WindowKey(pid: 1, windowID: 10, bundleId: "app.shared")
    let config = AppSettings.Marker()
    let target = try #require(WorkspaceActivationFeature.markerTargets(
      fullscreenZoomed: [key],
      floatingKeys: [key, key],
      borrowed: [key: "book"],
      cfg: config,
      sharedKeys: [key],
      stackedColors: [key: "#89B4FA"],
    )[key])
    #expect(target.badges == [
      WindowMarker(kind: .fullscreen, colorHex: MarkerPalette.fullscreen),
      WindowMarker(kind: .floating, colorHex: MarkerPalette.floating),
      WindowMarker(kind: .borrowed, colorHex: MarkerPalette.borrowed, symbol: "book"),
      WindowMarker(kind: .shared, colorHex: MarkerPalette.shared, symbol: "person.2.fill"),
      WindowMarker(kind: .stacked, colorHex: "#89B4FA", symbol: "rectangle.stack.fill"),
    ])
  }

  @Test
  func `automatic stacks mark only their actual members and coexist with other badges`() throws {
    let first = WindowKey(pid: 1, windowID: 10, bundleId: "app.shared")
    let second = WindowKey(pid: 2, windowID: 11, bundleId: "app.other")
    var keys = Set<WindowKey>()
    let automatic = try #require(BSPNode<WindowKey>.leaf(first).stackingAutomatically(second, on: first))
    automatic.collectAutomaticallyStackedWindows(into: &keys)
    #expect(keys == [first, second])

    let manual = BSPNode<WindowKey>.leaf(BSPLeaf(windowList: [first, second]))
    var manualKeys = Set<WindowKey>()
    manual.collectAutomaticallyStackedWindows(into: &manualKeys)
    #expect(manualKeys.isEmpty)

    var config = AppSettings.Marker()
    let badges = WorkspaceActivationFeature.markerTargets(
      fullscreenZoomed: [first],
      floatingKeys: [],
      borrowed: [:],
      cfg: config,
      sharedKeys: [first],
      stackedColors: [first: "#89B4FA", second: "#FAB387"],
    )
    #expect(badges[first]?.badges.map(\.kind) == [.fullscreen, .shared, .stacked])
    #expect(badges[first]?.badges.last?.colorHex == "#89B4FA")
    #expect(badges[second]?.badges == [
      WindowMarker(kind: .stacked, colorHex: "#FAB387", symbol: "rectangle.stack.fill")
    ])
    config.stackEnabled = false
    #expect(WorkspaceActivationFeature.markerTargets(
      fullscreenZoomed: [],
      floatingKeys: [],
      borrowed: [:],
      cfg: config,
      stackedColors: [first: "#89B4FA", second: "#FAB387"],
    ).isEmpty)
  }

  @Test
  func `shared only windows have no artificial status dot and the badge can be disabled`() throws {
    let key = WindowKey(pid: 1, windowID: 10, bundleId: "app.shared")
    var config = AppSettings.Marker()
    let shared = try #require(WorkspaceActivationFeature.markerTargets(
      fullscreenZoomed: [],
      floatingKeys: [],
      borrowed: [:],
      cfg: config,
      sharedKeys: [key],
    )[key])
    #expect(shared.badges == [
      WindowMarker(kind: .shared, colorHex: MarkerPalette.shared, symbol: "person.2.fill")
    ])
    config.sharedEnabled = false
    #expect(WorkspaceActivationFeature.markerTargets(
      fullscreenZoomed: [],
      floatingKeys: [],
      borrowed: [:],
      cfg: config,
      sharedKeys: [key],
    ).isEmpty)
  }

  @Test
  func `stored legacy defaults migrate in TOML while other marker choices survive`() throws {
    let config = try decodeTatamiConfig(Data("""
      [settings.marker]
      floatingColorHex = "#FF9500"
      fullscreenColorHex = "#007aff"
      borrowColorHex = "#AF52DE"
      sharedColorHex = "#123456"
      floatingEnabled = false
      size = 8
      corner = "bottomLeading"
      """.utf8))
    #expect(config.settings.marker.floatingColorHex == MarkerPalette.floating)
    #expect(config.settings.marker.fullscreenColorHex == MarkerPalette.fullscreen)
    #expect(config.settings.marker.borrowColorHex == MarkerPalette.borrowed)
    #expect(config.settings.marker.sharedColorHex == "#123456")
    #expect(!config.settings.marker.floatingEnabled)
    #expect(config.settings.marker.size == 8)
    #expect(config.settings.marker.corner == .bottomLeading)
  }

  @Test
  func `a deliberate legacy color survives save and reload after migration`() throws {
    var config = try decodeTatamiConfig(Data("""
      [settings.marker]
      floatingColorHex = "#FF9500"
      fullscreenColorHex = "#123456"
      """.utf8))
    #expect(config.settings.marker.floatingColorHex == MarkerPalette.floating)
    #expect(config.settings.marker.fullscreenColorHex == "#123456")
    config.settings.marker.floatingColorHex = "#FF9500"
    let reloaded = try decodeTatamiConfig(encodeTatamiConfig(config))
    #expect(reloaded.settings.marker == config.settings.marker)
  }

  @Test
  func `Mocha defaults do not overwrite saved custom marker colors`() throws {
    let decoded = try JSONDecoder().decode(AppSettings.Marker.self, from: Data("""
      {"floatingColorHex":"#ABCDEF","fullscreenColorHex":"#123456","borrowColorHex":"#654321"}
      """.utf8))
    #expect(decoded.floatingColorHex == "#ABCDEF")
    #expect(decoded.fullscreenColorHex == "#123456")
    #expect(decoded.borrowColorHex == "#654321")
    #expect(decoded.sharedEnabled)
    #expect(decoded.sharedColorHex == MarkerPalette.shared)
    let defaults = try JSONDecoder().decode(AppSettings.Marker.self, from: Data("{}".utf8))
    #expect(defaults.floatingColorHex == MarkerPalette.floating)
    #expect(defaults.fullscreenColorHex == MarkerPalette.fullscreen)
    #expect(defaults.borrowColorHex == MarkerPalette.borrowed)
  }

  // MARK: Private

  private static func surface(_ id: CGWindowID, _ frame: CGRect, layer: Int = 0, alpha: Double = 1) -> WindowServerWindow {
    WindowServerWindow(
      id: id,
      surface: WindowServerSurface(ownerPID: pid_t(id), layer: layer, frame: frame),
      title: nil,
      alpha: alpha,
    )
  }

}
