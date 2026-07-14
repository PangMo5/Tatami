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
  func emptyRuleNeverMatches() {
    #expect(!ProfileActivation().matches(connected: [builtin, ext]))
    #expect(!ProfileActivation().matches(connected: []))
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
}
