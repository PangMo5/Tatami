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

/// Optional rule that auto-activates a profile when the connected displays
/// match. Every stated condition must hold (AND); an unset field means "don't
/// care". A profile with no `autoActivation` (or an all-empty one) is manual
/// only — it never auto-activates.
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
  /// with just a name still matches. An all-empty rule never matches — a
  /// profile must state at least one condition to auto-activate.
  public func matches(connected: Set<DisplayName>) -> Bool {
    func present(_ d: DisplayName) -> Bool { connected.contains { $0.matches(d) } }
    var stated = false
    // An empty display list is "in progress" (picked the mode, no displays yet)
    // — treat it as no condition so it doesn't match everything.
    if let whenConnected, !whenConnected.displays.isEmpty {
      stated = true
      let required = whenConnected.displays
      guard required.allSatisfy(present) else { return false }
      if case .exactly = whenConnected, connected.count != required.count { return false }
    }
    if !whenDisconnected.isEmpty {
      stated = true
      if whenDisconnected.contains(where: present) { return false }
    }
    if let displayCount {
      stated = true
      guard displayCount.satisfied(by: connected.count) else { return false }
    }
    return stated
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
