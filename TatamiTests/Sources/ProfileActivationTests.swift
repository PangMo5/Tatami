// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TatamiKit

@Suite("Profile auto-activation")
struct ProfileActivationTests {
  let builtin = DisplayName(uuid: "U1", name: "Built-in")
  let ext = DisplayName(uuid: "U2", name: "IP1640")
  let proj = DisplayName(uuid: "U3", name: "Projector")

  @Test
  func containsRequiresListedButToleratesExtras() {
    let rule = ProfileActivation(whenConnected: .contains([ext]))
    #expect(rule.matches(connected: [builtin, ext]))
    #expect(rule.matches(connected: [ext]))
    #expect(!rule.matches(connected: [builtin]))
  }

  @Test
  func exactlyRequiresTheExactSet() {
    let rule = ProfileActivation(whenConnected: .exactly([builtin, ext]))
    #expect(rule.matches(connected: [builtin, ext]))
    #expect(!rule.matches(connected: [builtin, ext, proj]))
    #expect(!rule.matches(connected: [builtin]))
  }

  @Test
  func whenDisconnectedRejectsPresence() {
    let rule = ProfileActivation(whenConnected: .contains([ext]), whenDisconnected: [proj])
    #expect(rule.matches(connected: [ext]))
    #expect(!rule.matches(connected: [ext, proj]))
  }

  @Test
  func displayCountConstraints() {
    #expect(ProfileActivation(displayCount: .exactly(1)).matches(connected: [builtin]))
    #expect(!ProfileActivation(displayCount: .exactly(1)).matches(connected: [builtin, ext]))
    #expect(ProfileActivation(displayCount: .atLeast(2)).matches(connected: [builtin, ext]))
    #expect(!ProfileActivation(displayCount: .atLeast(2)).matches(connected: [builtin]))
    #expect(ProfileActivation(displayCount: .atMost(1)).matches(connected: [builtin]))
  }

  @Test
  func emptyRuleIsACatchAllThatAlwaysMatches() {
    // A non-nil rule with no conditions = auto-activation on, un-narrowed.
    #expect(ProfileActivation().matches(connected: [builtin, ext]))
    #expect(ProfileActivation().matches(connected: []))
    #expect(!ProfileActivation().hasConditions)
  }

  @Test
  func resolverPrefersMostSpecific() {
    let loose = Profile(name: "Docked-ish", autoActivation: .init(whenConnected: .contains([ext])))
    let exact = Profile(name: "Docked", autoActivation: .init(whenConnected: .exactly([builtin, ext])))
    let config = AppConfig(profiles: [loose, exact])
    // Both match {builtin, ext}; the exact rule is more specific.
    #expect(config.autoActiveProfile(connected: [builtin, ext]) == exact.id)
    // Only the loose rule matches when a third display is present.
    #expect(config.autoActiveProfile(connected: [builtin, ext, proj]) == loose.id)
  }

  @Test
  func resolverTieBreaksToFirstAndReturnsNilWhenNoneMatch() {
    let first = Profile(name: "A", autoActivation: .init(displayCount: .atLeast(2)))
    let second = Profile(name: "B", autoActivation: .init(displayCount: .atLeast(2)))
    let manual = Profile(name: "Manual")
    let config = AppConfig(profiles: [first, second, manual])
    #expect(config.autoActiveProfile(connected: [builtin, ext]) == first.id)
    #expect(config.autoActiveProfile(connected: [builtin]) == nil)
  }

  @Test
  func startupResolverKeepsTheLastManualProfile() {
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
  func startupResolverFallsBackWhenTheLastProfilesConditionNoLongerMatches() {
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
  func codableRoundTrips() throws {
    let rule = ProfileActivation(
      whenConnected: .contains([ext]),
      whenDisconnected: [proj],
      displayCount: .atLeast(2)
    )
    let data = try JSONEncoder().encode(rule)
    let decoded = try JSONDecoder().decode(ProfileActivation.self, from: data)
    #expect(decoded == rule)
  }

  // MARK: - Overlap

  @Test
  func containsRulesOverlapViaSuperset() {
    let a = ProfileActivation(whenConnected: .contains([ext]))
    let b = ProfileActivation(whenConnected: .contains([proj]))
    // A set containing both ext and proj satisfies both.
    #expect(a.overlaps(with: b))
  }

  @Test
  func exactlyDisjointSetsDoNotOverlap() {
    let a = ProfileActivation(whenConnected: .exactly([builtin]))
    let b = ProfileActivation(whenConnected: .exactly([ext]))
    #expect(!a.overlaps(with: b))
  }

  @Test
  func exactlyOverlapsAContainedSubsetRule() {
    let a = ProfileActivation(whenConnected: .exactly([builtin, ext]))
    let b = ProfileActivation(whenConnected: .contains([ext]))
    #expect(a.overlaps(with: b)) // C = {builtin, ext}
  }

  @Test
  func countOnlyRulesOverlapAtASharedSize() {
    let a = ProfileActivation(displayCount: .atLeast(2))
    let b = ProfileActivation(displayCount: .atLeast(3))
    #expect(a.overlaps(with: b)) // |C| >= 3 satisfies both
  }

  @Test
  func exactCountVsHigherAtLeastDoNotOverlap() {
    let a = ProfileActivation(displayCount: .exactly(1))
    let b = ProfileActivation(displayCount: .atLeast(2))
    #expect(!a.overlaps(with: b))
  }

  @Test
  func catchAllOverlapsAnySatisfiableRule() {
    let catchAll = ProfileActivation()
    let real = ProfileActivation(whenConnected: .contains([ext]))
    #expect(catchAll.overlaps(with: real))
    #expect(real.overlaps(with: catchAll))
  }

  @Test
  func disconnectedOnlyRulesOverlapOnBareLaptop() {
    let a = ProfileActivation(whenDisconnected: [ext])
    let b = ProfileActivation(whenDisconnected: [proj])
    #expect(a.overlaps(with: b)) // C = {} satisfies both
  }

  // MARK: - Diagnostic

  @Test
  func diagnosticFlagsEqualSpecificityAsConflict() {
    let p1 = Profile(name: "Dual A", autoActivation: .init(displayCount: .atLeast(2)))
    let p2 = Profile(name: "Dual B", autoActivation: .init(displayCount: .atLeast(3)))
    let config = AppConfig(profiles: [p1, p2])
    let d1 = config.autoActivationDiagnostic(for: p1.id)
    #expect(d1.hasConflict)
    #expect(d1.ambiguousWith == ["Dual B"])
  }

  @Test
  func diagnosticReportsShadowingBothWays() {
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
  func diagnosticEmptyWhenRulesCannotBothMatch() {
    let laptop = Profile(name: "Laptop", autoActivation: .init(displayCount: .exactly(1)))
    let docked = Profile(name: "Docked", autoActivation: .init(displayCount: .atLeast(2)))
    let config = AppConfig(profiles: [laptop, docked])
    #expect(config.autoActivationDiagnostic(for: laptop.id).isEmpty)
    #expect(config.autoActivationDiagnostic(for: docked.id).isEmpty)
  }

  @Test
  func manualProfilesHaveNoDiagnostic() {
    let manual = Profile(name: "Manual")
    let auto = Profile(name: "Auto", autoActivation: .init(displayCount: .atLeast(2)))
    let config = AppConfig(profiles: [manual, auto])
    #expect(config.autoActivationDiagnostic(for: manual.id).isEmpty)
    // `auto` only overlaps *enabled* rules; `manual` (nil) isn't one.
    #expect(config.autoActivationDiagnostic(for: auto.id).isEmpty)
  }

  @Test
  func twoCatchAllProfilesConflict() {
    // Both enabled with no conditions ("any") → both always match → order
    // alone decides. This is the any/any case that must be flagged.
    let p1 = Profile(name: "Any A", autoActivation: .init())
    let p2 = Profile(name: "Any B", autoActivation: .init())
    let config = AppConfig(profiles: [p1, p2])
    #expect(config.autoActivationDiagnostic(for: p1.id).ambiguousWith == ["Any B"])
    #expect(config.autoActivationDiagnostic(for: p2.id).hasConflict)
  }

  @Test
  func catchAllIsShadowedByASpecificRule() {
    let fallback = Profile(name: "Fallback", autoActivation: .init())
    let docked = Profile(name: "Docked", autoActivation: .init(displayCount: .atLeast(2)))
    let config = AppConfig(profiles: [fallback, docked])
    let dFallback = config.autoActivationDiagnostic(for: fallback.id)
    #expect(!dFallback.hasConflict)
    #expect(dFallback.shadowedBy == ["Docked"]) // more specific wins where both match
    #expect(config.autoActivationDiagnostic(for: docked.id).shadows == ["Fallback"])
  }
}
