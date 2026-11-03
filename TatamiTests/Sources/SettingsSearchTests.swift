// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CustomDump
import Foundation
import Testing
@testable import TatamiKit

struct SettingsSearchTests {

  // MARK: Internal

  @Test(arguments: ["", " \n\t "])
  func `empty queries have no results`(_ query: String) {
    #expect(SettingsSearch.results(for: query, in: items).isEmpty)
  }

  @Test
  func `search accepts abbreviations aliases and words across fields`() {
    expectNoDifference(SettingsSearch.results(for: "  fFm  ", in: items).map(\.id), ["focus.focusFollowsMouse"])
    expectNoDifference(SettingsSearch.results(for: "MFF cursor", in: items).map(\.id), ["focus.mouseFollowsFocus"])
    expectNoDifference(SettingsSearch.results(for: "gap windows", in: items).map(\.id), ["layout.gapInner"])
    #expect(SettingsSearch.results(for: "unknown setting", in: items).isEmpty)
  }

  @Test
  func `localized titles and English source keys both remain searchable`() {
    let localize: (LocalizedStringResource) -> String = {
      $0.key == "Inner gap" ? "창 사이 간격" : $0.key
    }
    for query in ["창 간격", "창 사이 간격".decomposedStringWithCanonicalMapping, "inner gap"] {
      expectNoDifference(SettingsSearch.results(for: query, in: items, localize: localize).map(\.id), ["layout.gapInner"])
    }
  }

  @Test
  func `exact and prefix title matches precede description matches`() {
    let items = [
      SettingsSearchItem(id: "description", pane: "general", title: "General", detail: "Focus controls"),
      SettingsSearchItem(id: "prefix", pane: "focusMouse", title: "Focus follows mouse"),
      SettingsSearchItem(id: "exact", pane: "focusMouse", title: "Focus"),
    ]
    expectNoDifference(SettingsSearch.results(for: "focus", in: items).map(\.id), ["exact", "prefix", "description"])
  }

  // MARK: Private

  private let items = [
    SettingsSearchItem(
      id: "focus.mouseFollowsFocus",
      pane: "focusMouse",
      title: "Mouse follows focus (MFF)",
      aliases: "pointer cursor",
    ),
    SettingsSearchItem(
      id: "focus.focusFollowsMouse",
      pane: "focusMouse",
      title: "Focus follows mouse (FFM)",
      detail: "Focus the window under the pointer.",
    ),
    SettingsSearchItem(id: "layout.gapInner", pane: "tiling", title: "Inner gap", detail: "Space between tiled windows."),
  ]

}
