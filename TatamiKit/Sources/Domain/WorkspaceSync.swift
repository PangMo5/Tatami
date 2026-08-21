// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// One app-assignment change between two workspaces' app lists — the unit the
/// sync preview shows and lets the user include / exclude.
public struct AppChange: Equatable, Identifiable, Sendable {
  public enum Kind: Equatable, Sendable {
    /// In the source, absent from the target — will be added.
    case add(AppAssignment)
    /// In the target, absent from the source — will be removed.
    case remove(AppAssignment)
    /// In both, but `layout` / `autoOpen` differ — will be updated.
    case modify(before: AppAssignment, after: AppAssignment)
  }

  public var kind: Kind
  /// The app's bundle id — unique within a workspace, so it keys the change.
  public var bundleId: String
  public var id: String { bundleId }

  public init(kind: Kind, bundleId: String) {
    self.kind = kind
    self.bundleId = bundleId
  }

  public var appName: String {
    switch kind {
    case .add(let a), .remove(let a), .modify(_, let a): a.name
    }
  }
}

/// A change to one of a workspace's non-app fields — includes the display pin
/// (`displayHint`); the sync preview shows it like any other change and the
/// user unchecks what they want to keep.
public enum WorkspaceFieldChange: Equatable, Identifiable, Sendable {
  case icon(before: String?, after: String?)
  case keyEquivalent(before: String?, after: String?)
  case kind(before: WorkspaceKind, after: WorkspaceKind)
  case appToFocus(before: String?, after: String?)
  case displayHint(before: DisplayName?, after: DisplayName?)
  case borrowEdge(before: BorrowEdge?, after: BorrowEdge?)
  case borrowFraction(before: Double?, after: Double?)
  case activateShortcut(before: HotKey?, after: HotKey?)
  case assignAppShortcut(before: HotKey?, after: HotKey?)
  case borrowShortcut(before: HotKey?, after: HotKey?)

  public var id: String {
    switch self {
    case .icon: "icon"
    case .keyEquivalent: "keyEquivalent"
    case .kind: "kind"
    case .appToFocus: "appToFocus"
    case .displayHint: "displayHint"
    case .borrowEdge: "borrowEdge"
    case .borrowFraction: "borrowFraction"
    case .activateShortcut: "activateShortcut"
    case .assignAppShortcut: "assignAppShortcut"
    case .borrowShortcut: "borrowShortcut"
    }
  }

  public var label: LocalizedStringResource {
    switch self {
    case .icon: "Icon"
    case .keyEquivalent: "Key equivalent"
    case .kind: "Kind"
    case .appToFocus: "Focus app"
    case .displayHint: "Display"
    case .borrowEdge: "Borrow direction"
    case .borrowFraction: "Borrow size"
    case .activateShortcut: "Activate shortcut"
    case .assignAppShortcut: "Assign shortcut"
    case .borrowShortcut: "Borrow shortcut"
    }
  }

  public var beforeText: String { Self.text(before: true, self) }
  public var afterText: String { Self.text(before: false, self) }

  private static func text(before: Bool, _ change: WorkspaceFieldChange) -> String {
    func pick<T>(_ b: T, _ a: T) -> T { before ? b : a }
    switch change {
    case let .icon(b, a): return pick(b, a) ?? "Default"
    case let .keyEquivalent(b, a): return pick(b, a).map { "“\($0)”" } ?? "—"
    case let .kind(b, a): return String(localized: pick(b, a).displayName)
    case let .appToFocus(b, a): return pick(b, a) ?? "Most recent"
    case let .displayHint(b, a): return pick(b, a)?.name ?? "Dynamic"
    case let .borrowEdge(b, a):
      return pick(b, a).map { String(localized: $0.displayName) } ?? String(localized: "Global")
    case let .borrowFraction(b, a):
      guard let v = pick(b, a) else { return "Global" }
      return "\(Int((v * 100).rounded()))%"
    case let .activateShortcut(b, a), let .assignAppShortcut(b, a), let .borrowShortcut(b, a):
      return pick(b, a)?.symbols ?? "—"
    }
  }
}

/// Pure diff + apply for copying one workspace's apps / settings onto another.
/// The direction is always "make the target look like the source" — changes
/// transform the target toward the source, and the caller applies only the
/// ones the user kept selected (by excluding the rest).
public enum WorkspaceSync {
  /// App changes that would transform `target`'s apps toward `source`'s. Adds
  /// and modifies follow the source's order (stable); removes trail. `modify`
  /// fires only on a `layout` / `autoOpen` difference (name / iconPath ignored).
  public static func appChanges(from source: [AppAssignment], to target: [AppAssignment]) -> [AppChange] {
    let targetById = Dictionary(target.map { ($0.bundleIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
    let sourceIds = Set(source.map(\.bundleIdentifier))
    var changes: [AppChange] = []
    for s in source {
      if let t = targetById[s.bundleIdentifier] {
        if t.layout != s.layout || t.autoOpen != s.autoOpen {
          changes.append(AppChange(kind: .modify(before: t, after: s), bundleId: s.bundleIdentifier))
        }
      } else {
        changes.append(AppChange(kind: .add(s), bundleId: s.bundleIdentifier))
      }
    }
    for t in target where !sourceIds.contains(t.bundleIdentifier) {
      changes.append(AppChange(kind: .remove(t), bundleId: t.bundleIdentifier))
    }
    return changes
  }

  /// Apply the app changes whose bundle id isn't in `excluded` onto `target`.
  public static func apply(
    _ changes: [AppChange], to target: [AppAssignment], excluding excluded: Set<String>
  ) -> [AppAssignment] {
    var result = target
    for change in changes where !excluded.contains(change.bundleId) {
      switch change.kind {
      case .add(let app):
        if !result.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) { result.append(app) }
      case .remove(let app):
        result.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
      case .modify(_, let after):
        if let i = result.firstIndex(where: { $0.bundleIdentifier == after.bundleIdentifier }) { result[i] = after }
      }
    }
    return result
  }

  /// Field changes that would transform `target` toward `source`, including the
  /// display pin (the caller / user decides whether to apply it).
  public static func fieldChanges(from source: Workspace, to target: Workspace) -> [WorkspaceFieldChange] {
    var out: [WorkspaceFieldChange] = []
    if target.symbolIconName != source.symbolIconName {
      out.append(.icon(before: target.symbolIconName, after: source.symbolIconName))
    }
    if target.keyEquivalent != source.keyEquivalent {
      out.append(.keyEquivalent(before: target.keyEquivalent, after: source.keyEquivalent))
    }
    if target.kind != source.kind {
      out.append(.kind(before: target.kind, after: source.kind))
    }
    if target.appToFocusBundleId != source.appToFocusBundleId {
      out.append(.appToFocus(before: target.appToFocusBundleId, after: source.appToFocusBundleId))
    }
    if target.displayHint != source.displayHint {
      out.append(.displayHint(before: target.displayHint, after: source.displayHint))
    }
    if target.borrowEdge != source.borrowEdge {
      out.append(.borrowEdge(before: target.borrowEdge, after: source.borrowEdge))
    }
    if target.borrowFraction != source.borrowFraction {
      out.append(.borrowFraction(before: target.borrowFraction, after: source.borrowFraction))
    }
    if target.activateShortcut != source.activateShortcut {
      out.append(.activateShortcut(before: target.activateShortcut, after: source.activateShortcut))
    }
    if target.assignAppShortcut != source.assignAppShortcut {
      out.append(.assignAppShortcut(before: target.assignAppShortcut, after: source.assignAppShortcut))
    }
    if target.borrowShortcut != source.borrowShortcut {
      out.append(.borrowShortcut(before: target.borrowShortcut, after: source.borrowShortcut))
    }
    return out
  }

  /// Apply the field changes whose id isn't in `excluded` onto `workspace`.
  public static func apply(
    _ changes: [WorkspaceFieldChange], to workspace: inout Workspace, excluding excluded: Set<String>
  ) {
    for change in changes where !excluded.contains(change.id) {
      switch change {
      case .icon(_, let after): workspace.symbolIconName = after
      case .keyEquivalent(_, let after): workspace.keyEquivalent = after
      case .kind(_, let after): workspace.kind = after
      case .appToFocus(_, let after): workspace.appToFocusBundleId = after
      case .displayHint(_, let after): workspace.displayHint = after
      case .borrowEdge(_, let after): workspace.borrowEdge = after
      case .borrowFraction(_, let after): workspace.borrowFraction = after
      case .activateShortcut(_, let after): workspace.activateShortcut = after
      case .assignAppShortcut(_, let after): workspace.assignAppShortcut = after
      case .borrowShortcut(_, let after): workspace.borrowShortcut = after
      }
    }
  }
}
