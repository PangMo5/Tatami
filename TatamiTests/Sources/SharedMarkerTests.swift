// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TatamiKit

struct SharedMarkerTests {
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
}
