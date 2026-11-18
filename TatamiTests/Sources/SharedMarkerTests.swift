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
    #expect(!hidden.exposes(firstCorner, on: 10, ignoring: [90, 91]))
    #expect(hidden.exposes(secondCorner, on: 11, ignoring: [90, 91]))
    let uncovered = MarkerWindowStack(badges + [firstOwner, secondOwner, cover])
    #expect(uncovered.exposes(firstCorner, on: 10, ignoring: [90, 91]))
  }

  @Test
  func `higher layers are composited above the badge without hiding its exposed owner`() {
    let frame = CGRect(x: 0, y: 0, width: 240, height: 220)
    let corner = CGRect(x: 200, y: 180, width: 24, height: 24)
    let dockCanvas = Self.surface(30, frame, layer: 20)
    let owner = Self.surface(10, frame)
    let clearCorner = MarkerWindowStack([dockCanvas, owner])
    #expect(clearCorner.exposes(corner, on: 10, ignoring: []))

    let cover = Self.surface(20, frame)
    let coveredCorner = MarkerWindowStack([dockCanvas, cover, owner])
    #expect(!coveredCorner.exposes(corner, on: 10, ignoring: []))
  }

  @Test
  func `a floating marker is authorized by the visible mirror rather than the covered native window`() {
    let frame = CGRect(x: 0, y: 0, width: 240, height: 220)
    let corner = CGRect(x: 200, y: 180, width: 24, height: 24)
    let invisibleCover = Self.surface(30, frame, alpha: 0)
    let stack = MarkerWindowStack([invisibleCover, Self.surface(40, frame), Self.surface(20, frame), Self.surface(10, frame)])
    #expect(stack.exposes(corner, on: 40, ignoring: []))
    #expect(!stack.exposes(corner, on: 10, ignoring: []))
    #expect(!stack.exposes(corner, on: 90, ignoring: []))
  }

  @Test
  func `a shared badge coexists with borrowed or zoom status without replacing it`() throws {
    let key = WindowKey(pid: 1, windowID: 10, bundleId: "app.shared")
    let config = AppSettings.Marker()
    let borrowed = try #require(WorkspaceActivationFeature.markerTargets(
      fullscreenZoomed: [key],
      floatingKeys: [],
      borrowed: [key: "book"],
      cfg: config,
      sharedKeys: [key],
    )[key])
    #expect(borrowed.colorHex == MarkerPalette.borrowed)
    #expect(borrowed.symbol == "book")
    #expect(borrowed.sharedColorHex == MarkerPalette.shared)
    let zoomed = try #require(WorkspaceActivationFeature.markerTargets(
      fullscreenZoomed: [key],
      floatingKeys: [],
      borrowed: [:],
      cfg: config,
      sharedKeys: [key],
    )[key])
    #expect(!zoomed.alwaysVisible)
    #expect(zoomed.colorHex == MarkerPalette.fullscreen)
    #expect(zoomed.sharedColorHex == MarkerPalette.shared)
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
    #expect(shared.colorHex == nil)
    #expect(shared.sharedColorHex == MarkerPalette.shared)
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
