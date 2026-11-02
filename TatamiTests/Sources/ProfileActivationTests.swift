// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TatamiKit

@Suite("Profile auto-activation")
struct ProfileActivationTests {

  // MARK: Internal

  @Test
  func `contains requires listed but tolerates extras`() {
    let rule = ProfileActivation(whenConnected: .contains([ext]))
    #expect(rule.matches(connected: [builtin, ext]))
    #expect(rule.matches(connected: [ext]))
    #expect(!rule.matches(connected: [builtin]))
  }

  @Test
  func `exactly requires the exact set`() {
    let rule = ProfileActivation(whenConnected: .exactly([builtin, ext]))
    #expect(rule.matches(connected: [builtin, ext]))
    #expect(!rule.matches(connected: [builtin, ext, proj]))
    #expect(!rule.matches(connected: [builtin]))
  }

  @Test
  func `when disconnected rejects presence`() {
    let rule = ProfileActivation(whenConnected: .contains([ext]), whenDisconnected: [proj])
    #expect(rule.matches(connected: [ext]))
    #expect(!rule.matches(connected: [ext, proj]))
  }

  @Test
  func `display count constraints`() {
    #expect(ProfileActivation(displayCount: .exactly(1)).matches(connected: [builtin]))
    #expect(!ProfileActivation(displayCount: .exactly(1)).matches(connected: [builtin, ext]))
    #expect(ProfileActivation(displayCount: .atLeast(2)).matches(connected: [builtin, ext]))
    #expect(!ProfileActivation(displayCount: .atLeast(2)).matches(connected: [builtin]))
    #expect(ProfileActivation(displayCount: .atMost(1)).matches(connected: [builtin]))
  }

  @Test
  func `empty rule is A catch all that always matches`() {
    // A non-nil rule with no conditions = auto-activation on, un-narrowed.
    #expect(ProfileActivation().matches(connected: [builtin, ext]))
    #expect(ProfileActivation().matches(connected: []))
    #expect(!ProfileActivation().hasConditions)
  }

  @Test
  func `resolver prefers most specific`() {
    let loose = Profile(name: "Docked-ish", autoActivation: .init(whenConnected: .contains([ext])))
    let exact = Profile(name: "Docked", autoActivation: .init(whenConnected: .exactly([builtin, ext])))
    let config = AppConfig(profiles: [loose, exact])
    // Both match {builtin, ext}; the exact rule is more specific.
    #expect(config.autoActiveProfile(connected: [builtin, ext]) == exact.id)
    // Only the loose rule matches when a third display is present.
    #expect(config.autoActiveProfile(connected: [builtin, ext, proj]) == loose.id)
  }

  @Test
  func `resolver tie breaks to first and returns nil when none match`() {
    let first = Profile(name: "A", autoActivation: .init(displayCount: .atLeast(2)))
    let second = Profile(name: "B", autoActivation: .init(displayCount: .atLeast(2)))
    let manual = Profile(name: "Manual")
    let config = AppConfig(profiles: [first, second, manual])
    #expect(config.autoActiveProfile(connected: [builtin, ext]) == first.id)
    #expect(config.autoActiveProfile(connected: [builtin]) == nil)
  }

  @Test
  func `startup resolver keeps the last manual profile`() {
    let laptop = Profile(name: "Laptop", autoActivation: .init(displayCount: .exactly(1)))
    let manual = Profile(name: "Interview")
    let config = AppConfig(profiles: [laptop, manual])

    #expect(
      config.startupActiveProfile(
        lastUsedProfileId: manual.id,
        connected: [builtin],
      ) == manual.id
    )
  }

  @Test
  func `startup resolver falls back when the last profiles condition no longer matches`() {
    let laptop = Profile(name: "Laptop", autoActivation: .init(displayCount: .exactly(1)))
    let dual = Profile(name: "Dual", autoActivation: .init(displayCount: .exactly(2)))
    let config = AppConfig(profiles: [laptop, dual])

    #expect(
      config.startupActiveProfile(
        lastUsedProfileId: dual.id,
        connected: [builtin],
      ) == laptop.id
    )
  }

  @Test
  func `codable round trips`() throws {
    let rule = ProfileActivation(
      whenConnected: .contains([ext]),
      whenDisconnected: [proj],
      displayCount: .atLeast(2),
    )
    let data = try JSONEncoder().encode(rule)
    let decoded = try JSONDecoder().decode(ProfileActivation.self, from: data)
    #expect(decoded == rule)
  }

  @Test
  func `contains rules overlap via superset`() {
    let a = ProfileActivation(whenConnected: .contains([ext]))
    let b = ProfileActivation(whenConnected: .contains([proj]))
    // A set containing both ext and proj satisfies both.
    #expect(a.overlaps(with: b))
  }

  @Test
  func `exactly disjoint sets do not overlap`() {
    let a = ProfileActivation(whenConnected: .exactly([builtin]))
    let b = ProfileActivation(whenConnected: .exactly([ext]))
    #expect(!a.overlaps(with: b))
  }

  @Test
  func `exactly overlaps A contained subset rule`() {
    let a = ProfileActivation(whenConnected: .exactly([builtin, ext]))
    let b = ProfileActivation(whenConnected: .contains([ext]))
    #expect(a.overlaps(with: b)) // C = {builtin, ext}
  }

  @Test
  func `count only rules overlap at A shared size`() {
    let a = ProfileActivation(displayCount: .atLeast(2))
    let b = ProfileActivation(displayCount: .atLeast(3))
    #expect(a.overlaps(with: b)) // |C| >= 3 satisfies both
  }

  @Test
  func `exact count vs higher at least do not overlap`() {
    let a = ProfileActivation(displayCount: .exactly(1))
    let b = ProfileActivation(displayCount: .atLeast(2))
    #expect(!a.overlaps(with: b))
  }

  @Test
  func `catch all overlaps any satisfiable rule`() {
    let catchAll = ProfileActivation()
    let real = ProfileActivation(whenConnected: .contains([ext]))
    #expect(catchAll.overlaps(with: real))
    #expect(real.overlaps(with: catchAll))
  }

  @Test
  func `disconnected only rules overlap on bare laptop`() {
    let a = ProfileActivation(whenDisconnected: [ext])
    let b = ProfileActivation(whenDisconnected: [proj])
    #expect(a.overlaps(with: b)) // C = {} satisfies both
  }

  @Test
  func `diagnostic flags equal specificity as conflict`() {
    let p1 = Profile(name: "Dual A", autoActivation: .init(displayCount: .atLeast(2)))
    let p2 = Profile(name: "Dual B", autoActivation: .init(displayCount: .atLeast(3)))
    let config = AppConfig(profiles: [p1, p2])
    let d1 = config.autoActivationDiagnostic(for: p1.id)
    #expect(d1.hasConflict)
    #expect(d1.ambiguousWith == ["Dual B"])
  }

  @Test
  func `diagnostic reports shadowing both ways`() {
    // "exactly [builtin, ext]" is more specific than "contains [ext]"; they
    // overlap on {builtin, ext}.
    let specific = Profile(name: "Specific", autoActivation: .init(whenConnected: .exactly([builtin, ext])))
    let general = Profile(name: "General", autoActivation: .init(whenConnected: .contains([ext])))
    let config = AppConfig(profiles: [specific, general])
    let dGeneral = config.autoActivationDiagnostic(for: general.id)
    #expect(!dGeneral.hasConflict)
    #expect(dGeneral.shadowedBy == ["Specific"])
    let dSpecific = config.autoActivationDiagnostic(for: specific.id)
    #expect(dSpecific.shadows == ["General"])
  }

  @Test
  func `diagnostic empty when rules cannot both match`() {
    let laptop = Profile(name: "Laptop", autoActivation: .init(displayCount: .exactly(1)))
    let docked = Profile(name: "Docked", autoActivation: .init(displayCount: .atLeast(2)))
    let config = AppConfig(profiles: [laptop, docked])
    #expect(config.autoActivationDiagnostic(for: laptop.id).isEmpty)
    #expect(config.autoActivationDiagnostic(for: docked.id).isEmpty)
  }

  @Test
  func `manual profiles have no diagnostic`() {
    let manual = Profile(name: "Manual")
    let auto = Profile(name: "Auto", autoActivation: .init(displayCount: .atLeast(2)))
    let config = AppConfig(profiles: [manual, auto])
    #expect(config.autoActivationDiagnostic(for: manual.id).isEmpty)
    // `auto` only overlaps *enabled* rules; `manual` (nil) isn't one.
    #expect(config.autoActivationDiagnostic(for: auto.id).isEmpty)
  }

  @Test
  func `two catch all profiles conflict`() {
    // Both enabled with no conditions ("any") → both always match → order
    // alone decides. This is the any/any case that must be flagged.
    let p1 = Profile(name: "Any A", autoActivation: .init())
    let p2 = Profile(name: "Any B", autoActivation: .init())
    let config = AppConfig(profiles: [p1, p2])
    #expect(config.autoActivationDiagnostic(for: p1.id).ambiguousWith == ["Any B"])
    #expect(config.autoActivationDiagnostic(for: p2.id).hasConflict)
  }

  @Test
  func `catch all is shadowed by A specific rule`() {
    let fallback = Profile(name: "Fallback", autoActivation: .init())
    let docked = Profile(name: "Docked", autoActivation: .init(displayCount: .atLeast(2)))
    let config = AppConfig(profiles: [fallback, docked])
    let dFallback = config.autoActivationDiagnostic(for: fallback.id)
    #expect(!dFallback.hasConflict)
    #expect(dFallback.shadowedBy == ["Docked"]) // more specific wins where both match
    #expect(config.autoActivationDiagnostic(for: docked.id).shadows == ["Fallback"])
  }

  // MARK: Private

  private let builtin = DisplayName(uuid: "U1", name: "Built-in")
  private let ext = DisplayName(uuid: "U2", name: "IP1640")
  private let proj = DisplayName(uuid: "U3", name: "Projector")

}
