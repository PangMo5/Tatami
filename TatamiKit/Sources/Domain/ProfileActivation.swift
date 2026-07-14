import Foundation

/// How the connected-display set must look for a profile to auto-activate.
/// `exactly` is fully-specified (nothing else connected); `contains` requires
/// these but tolerates extras. Only `contains` has a meaningful "disconnected"
/// analogue (`ProfileActivation.whenDisconnected`) — an open-ended "exactly
/// absent" set has no bounded universe.
public enum DisplaySetRule: Hashable, Sendable {
  case exactly([DisplayName])
  case contains([DisplayName])

  public var displays: [DisplayName] {
    switch self {
    case .exactly(let d), .contains(let d): d
    }
  }
}

/// A constraint on the number of connected displays.
public enum CountRule: Hashable, Sendable {
  case exactly(Int)
  case atLeast(Int)
  case atMost(Int)

  func satisfied(by count: Int) -> Bool {
    switch self {
    case .exactly(let n): count == n
    case .atLeast(let n): count >= n
    case .atMost(let n): count <= n
    }
  }

  /// Compact, human-editable TOML form: `"==1"`, `">=2"`, `"<=1"`.
  var encoded: String {
    switch self {
    case .exactly(let n): "==\(n)"
    case .atLeast(let n): ">=\(n)"
    case .atMost(let n): "<=\(n)"
    }
  }

  init?(parsing raw: String) {
    let s = raw.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("=="), let n = Int(s.dropFirst(2).trimmingCharacters(in: .whitespaces)) {
      self = .exactly(n)
    } else if s.hasPrefix(">="), let n = Int(s.dropFirst(2).trimmingCharacters(in: .whitespaces)) {
      self = .atLeast(n)
    } else if s.hasPrefix("<="), let n = Int(s.dropFirst(2).trimmingCharacters(in: .whitespaces)) {
      self = .atMost(n)
    } else if let n = Int(s) {
      self = .exactly(n)
    } else {
      return nil
    }
  }
}

/// Rule that auto-activates a profile when the connected displays match. Every
/// stated condition must hold (AND); an unset field means "don't care". A
/// profile with no `autoActivation` (nil) is manual only. A non-nil rule with
/// no stated conditions is a catch-all that matches *any* configuration — i.e.
/// auto-activation is enabled but not narrowed (a fallback profile).
public struct ProfileActivation: Hashable, Sendable {
  /// The connected set must equal (`exactly`) or include (`contains`) these.
  public var whenConnected: DisplaySetRule?
  /// None of these may be connected.
  public var whenDisconnected: [DisplayName]
  /// Constraint on the number of connected displays.
  public var displayCount: CountRule?

  public init(
    whenConnected: DisplaySetRule? = nil,
    whenDisconnected: [DisplayName] = [],
    displayCount: CountRule? = nil
  ) {
    self.whenConnected = whenConnected
    self.whenDisconnected = whenDisconnected
    self.displayCount = displayCount
  }

  /// Whether the rule holds for the current `connected` set. Uses
  /// `DisplayName.matches` (uuid-preferred, name fallback) so a rule authored
  /// with just a name still matches. A rule with no stated conditions is a
  /// catch-all that matches any configuration.
  public func matches(connected: Set<DisplayName>) -> Bool {
    func present(_ d: DisplayName) -> Bool { connected.contains { $0.matches(d) } }
    if let whenConnected, !whenConnected.displays.isEmpty {
      let required = whenConnected.displays
      guard required.allSatisfy(present) else { return false }
      if case .exactly = whenConnected, connected.count != required.count { return false }
    }
    if whenDisconnected.contains(where: present) { return false }
    if let displayCount, !displayCount.satisfied(by: connected.count) { return false }
    // No stated condition ⇒ a catch-all that matches every configuration.
    return true
  }

  /// Higher = more specific, so it wins when several profiles match. `exactly`
  /// outranks `contains`; more pinned displays and more conditions rank higher.
  public var specificity: Int {
    var score = 0
    switch whenConnected {
    case .exactly(let d): score += 1000 + d.count
    case .contains(let d): score += 100 + d.count
    case nil: break
    }
    score += whenDisconnected.count
    if displayCount != nil { score += 1 }
    return score
  }

  /// True when the rule states at least one condition (vs. a catch-all that
  /// matches every configuration).
  public var hasConditions: Bool {
    (whenConnected.map { !$0.displays.isEmpty } ?? false)
      || !whenDisconnected.isEmpty
      || displayCount != nil
  }

  /// Whether some connected-display set satisfies BOTH rules — i.e. they can
  /// fire on the same configuration, so the resolver has to break the tie by
  /// specificity/order. Probed over every subset of the displays the two rules
  /// name, each padded with 0…N anonymous "some other display" entries to
  /// exercise `contains` / count rules. A catch-all (no conditions) matches
  /// everything, so it overlaps any satisfiable rule.
  public func overlaps(with other: ProfileActivation) -> Bool {
    var universe: [DisplayName] = []
    var seen = Set<DisplayName>()
    for d in displaysReferenced + other.displaysReferenced where seen.insert(d).inserted {
      universe.append(d)
    }
    // Realistic rules name a handful of displays; bail conservatively (assume a
    // clash) rather than enumerate an unreasonable number of subsets.
    guard universe.count <= 10 else { return true }

    let pad = min(6, Swift.max(countCeiling, other.countCeiling))
    let n = universe.count
    for mask in 0 ..< (1 << n) {
      var base = Set<DisplayName>()
      for i in 0 ..< n where mask & (1 << i) != 0 { base.insert(universe[i]) }
      for extra in 0 ... pad {
        var connected = base
        for k in 0 ..< extra { connected.insert(DisplayName(name: "\u{1}anon\(k)")) }
        if matches(connected: connected), other.matches(connected: connected) { return true }
      }
    }
    return false
  }

  /// Every display this rule names (connected + disconnected conditions).
  private var displaysReferenced: [DisplayName] {
    (whenConnected?.displays ?? []) + whenDisconnected
  }

  /// The largest display count the rule could demand — how far to pad the
  /// probe with anonymous displays so `contains` / `atLeast` can be satisfied.
  private var countCeiling: Int {
    var ceiling = whenConnected?.displays.count ?? 0
    switch displayCount {
    case .exactly(let n), .atLeast(let n): ceiling = Swift.max(ceiling, n)
    case .atMost, nil: break
    }
    return ceiling
  }
}

// MARK: - Diagnostic

/// How a profile's auto-activation rule overlaps other profiles', for the UI.
/// `ambiguousWith` is a real conflict (equal specificity → order alone decides,
/// includes identical rules); `shadowedBy` / `shadows` are intended precedence
/// (different specificity) surfaced as information.
public struct ProfileActivationDiagnostic: Equatable, Sendable {
  /// Profiles matching the same configuration at the *same* specificity — the
  /// resolver falls back to profile order, so one silently shadows the other.
  public var ambiguousWith: [String] = []
  /// More-specific profiles that win wherever both match (this one loses there).
  public var shadowedBy: [String] = []
  /// Less-specific profiles this one wins over wherever both match.
  public var shadows: [String] = []

  public init() {}

  /// A genuine conflict the user should resolve (vs. informational shadowing).
  public var hasConflict: Bool { !ambiguousWith.isEmpty }
  public var isEmpty: Bool { ambiguousWith.isEmpty && shadowedBy.isEmpty && shadows.isEmpty }
}

// MARK: - Codable (legible, flat TOML keys)

extension ProfileActivation: Codable {
  private enum CodingKeys: String, CodingKey {
    case whenConnectedMatch, whenConnected, whenDisconnected, displayCount
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    if let displays = try? c.decode([DisplayName].self, forKey: .whenConnected) {
      let match = (try? c.decode(String.self, forKey: .whenConnectedMatch)) ?? "contains"
      self.whenConnected = match == "exactly" ? .exactly(displays) : .contains(displays)
    } else {
      self.whenConnected = nil
    }
    self.whenDisconnected = (try? c.decode([DisplayName].self, forKey: .whenDisconnected)) ?? []
    if let countStr = try? c.decode(String.self, forKey: .displayCount) {
      self.displayCount = CountRule(parsing: countStr)
    } else {
      self.displayCount = nil
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch whenConnected {
    case .exactly(let d):
      try c.encode("exactly", forKey: .whenConnectedMatch)
      try c.encode(d, forKey: .whenConnected)
    case .contains(let d):
      try c.encode("contains", forKey: .whenConnectedMatch)
      try c.encode(d, forKey: .whenConnected)
    case nil:
      break
    }
    if !whenDisconnected.isEmpty { try c.encode(whenDisconnected, forKey: .whenDisconnected) }
    if let displayCount { try c.encode(displayCount.encoded, forKey: .displayCount) }
  }
}
