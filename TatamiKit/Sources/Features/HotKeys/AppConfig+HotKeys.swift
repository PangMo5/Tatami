// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

extension AppConfig {
  /// Every active hotkey binding the config implies — each workspace's
  /// activate / assign shortcuts plus the global action shortcuts. The
  /// single source for both registration (`HotKeysFeature`) and recorder
  /// conflict detection (Settings / workspace detail), so the two can never
  /// disagree about what's bound.
  public var hotKeyBindings: [HotKeyBinding] {
    hotKeyBindings(for: activeProfile?.id)
  }

  /// The bindings that would be active while `profileId` is running. Workspace
  /// shortcuts are profile-scoped; profile-switch and Settings shortcuts are
  /// global and therefore appear in every projection. Passing nil represents
  /// a config with no active profile and still returns its global bindings.
  func hotKeyBindings(for profileId: Profile.ID?) -> [HotKeyBinding] {
    var out: [HotKeyBinding] = []
    let workspaces = profileId
      .flatMap { id in profiles.first(where: { $0.id == id }) }
      .map(\.workspaces) ?? []
    // Default workspace shortcuts: a global modifier combo + a workspace's
    // single `keyEquivalent`. One key drives several actions, each with its
    // own modifier combo. Skipped when the combo is empty (a bare-key global
    // hotkey would hijack normal typing).
    let switchModifiers = HotKey.carbonModifiers(from: settings.shortcuts.keyEquivalentModifiers)
    let assignModifiers = HotKey.carbonModifiers(from: settings.shortcuts.assignModifiers)
    let borrowModifiers = HotKey.carbonModifiers(from: settings.shortcuts.borrowModifiers)

    for workspace in workspaces {
      let char = workspace.keyEquivalent
      let keyCode = char.flatMap { HotKey.keyCode(forName: $0) }
      func keyEquivBinding(_ action: HotKeyAction, _ modifiers: Int) {
        guard modifiers != 0, let keyCode else { return }
        out.append(.init(action: action, hotKey: HotKey(carbonKeyCode: keyCode, carbonModifiers: modifiers)))
      }
      // Explicit per-workspace override wins; else modifier + key equivalent.
      if let key = workspace.activateShortcut {
        out.append(.init(action: .activateWorkspace(workspace.id), hotKey: key))
      } else {
        keyEquivBinding(.activateWorkspace(workspace.id), switchModifiers)
      }
      if let key = workspace.assignAppShortcut {
        out.append(.init(action: .assignFocusedAppToWorkspace(workspace.id), hotKey: key))
      } else {
        keyEquivBinding(.assignFocusedAppToWorkspace(workspace.id), assignModifiers)
      }
      if let key = workspace.borrowShortcut {
        out.append(.init(action: .borrowWorkspace(workspace.id), hotKey: key))
      } else {
        keyEquivBinding(.borrowWorkspace(workspace.id), borrowModifiers)
      }
    }

    // Each profile's own switch shortcut, registered for *every* profile (not
    // just the active one) so any profile can be activated from any other.
    for profile in profiles {
      if let key = profile.shortcut {
        out.append(.init(action: .activateProfile(profile.id), hotKey: key))
      }
    }

    func add(_ action: HotKeyAction, _ key: HotKey?) {
      if let key { out.append(.init(action: action, hotKey: key)) }
    }
    let shortcuts = settings.shortcuts
    // Each nav target's switch / assign / borrow: explicit override wins, else
    // the matching modifier + the target's key.
    func addNavAction(_ action: HotKeyAction, override explicit: HotKey?, modifiers: Int, key char: String?) {
      if let explicit {
        out.append(.init(action: action, hotKey: explicit))
      } else if modifiers != 0, let char, let keyCode = HotKey.keyCode(forName: char) {
        out.append(.init(action: action, hotKey: HotKey(carbonKeyCode: keyCode, carbonModifiers: modifiers)))
      }
    }
    addNavAction(.switchToRecentWorkspace, override: shortcuts.switchToRecentWorkspace, modifiers: switchModifiers, key: shortcuts.recentWorkspaceKey)
    addNavAction(.assignFocusedAppToRecentWorkspace, override: shortcuts.assignRecentWorkspace, modifiers: assignModifiers, key: shortcuts.recentWorkspaceKey)
    addNavAction(.borrowRecentWorkspace, override: shortcuts.borrowRecentWorkspace, modifiers: borrowModifiers, key: shortcuts.recentWorkspaceKey)
    addNavAction(.switchToNextWorkspace, override: shortcuts.switchToNextWorkspace, modifiers: switchModifiers, key: shortcuts.nextWorkspaceKey)
    addNavAction(.assignFocusedAppToNextWorkspace, override: shortcuts.assignNextWorkspace, modifiers: assignModifiers, key: shortcuts.nextWorkspaceKey)
    addNavAction(.borrowNextWorkspace, override: shortcuts.borrowNextWorkspace, modifiers: borrowModifiers, key: shortcuts.nextWorkspaceKey)
    addNavAction(.switchToPreviousWorkspace, override: shortcuts.switchToPreviousWorkspace, modifiers: switchModifiers, key: shortcuts.previousWorkspaceKey)
    addNavAction(.assignFocusedAppToPreviousWorkspace, override: shortcuts.assignPreviousWorkspace, modifiers: assignModifiers, key: shortcuts.previousWorkspaceKey)
    addNavAction(.borrowPreviousWorkspace, override: shortcuts.borrowPreviousWorkspace, modifiers: borrowModifiers, key: shortcuts.previousWorkspaceKey)
    add(.moveFocusedAppToNextWorkspace, shortcuts.moveToNextWorkspace)
    add(.moveFocusedAppToPreviousWorkspace, shortcuts.moveToPreviousWorkspace)
    add(.focusNextDisplay, shortcuts.focusNextDisplay)
    add(.focusPreviousDisplay, shortcuts.focusPreviousDisplay)
    add(.focusLeft, shortcuts.focusLeft)
    add(.focusRight, shortcuts.focusRight)
    add(.focusUp, shortcuts.focusUp)
    add(.focusDown, shortcuts.focusDown)
    add(.cycleNextWindow, shortcuts.cycleNextWindow)
    add(.cyclePreviousWindow, shortcuts.cyclePreviousWindow)
    add(.resizeGrow, shortcuts.resizeGrow)
    add(.resizeShrink, shortcuts.resizeShrink)
    add(.swapLeft, shortcuts.swapLeft)
    add(.swapRight, shortcuts.swapRight)
    add(.swapUp, shortcuts.swapUp)
    add(.swapDown, shortcuts.swapDown)
    add(.toggleOrientation, shortcuts.toggleOrientation)
    add(.toggleFullscreen, shortcuts.toggleFullscreen)
    add(.balance, shortcuts.balance)
    add(.toggleFloating, shortcuts.toggleFloating)
    add(.toggleSharedFloating, shortcuts.toggleSharedFloating)
    add(.toggleSpaceActivated, shortcuts.toggleSpaceActivated)
    add(.toggleFocusedAppInActiveWorkspace, shortcuts.toggleFocusedAppInActiveWorkspace)
    add(.toggleAppInSharedApps, shortcuts.toggleAppInSharedApps)
    add(.dismissBorrow, shortcuts.dismissBorrow)
    return out
  }

  /// The display title of an action already bound to `candidate`, or nil if
  /// the combo is free. `action` is excluded so a recorder treats its own
  /// current combo as available (re-recording the same key isn't a conflict).
  /// Workspace actions only overlap actions in their owning profile; global
  /// actions overlap the possible runtime binding set of every profile.
  public func shortcutConflict(for candidate: HotKey, excluding action: HotKeyAction) -> String? {
    if
      let workspaceId = action.workspaceId,
      let profileId = profileId(owning: workspaceId)
    {
      return shortcutConflict(for: candidate, excluding: action, in: profileId)
    }
    return shortcutConflictAcrossProfiles(for: candidate, excluding: action)
  }

  /// Conflict lookup for a workspace action edited in a specific profile.
  func shortcutConflict(
    for candidate: HotKey,
    excluding action: HotKeyAction,
    in profileId: Profile.ID
  ) -> String? {
    shortcutConflict(
      for: candidate,
      excluding: action,
      among: hotKeyBindings(for: profileId)
    )
  }

  /// Conflict lookup for a global action, which must remain available no
  /// matter which profile is active.
  func shortcutConflictAcrossProfiles(
    for candidate: HotKey,
    excluding action: HotKeyAction
  ) -> String? {
    let profileIds: [Profile.ID?] = profiles.isEmpty ? [nil] : profiles.map { $0.id }
    for profileId in profileIds {
      if let conflict = shortcutConflict(
        for: candidate,
        excluding: action,
        among: hotKeyBindings(for: profileId)
      ) {
        return conflict
      }
    }
    return nil
  }

  /// Conflict for a workspace key equivalent after applying the same
  /// explicit-override precedence used by `hotKeyBindings(for:)`. A derived
  /// activate/assign/borrow combo does not exist while that action has its own
  /// explicit shortcut, so it must not reject an otherwise valid key.
  public func workspaceKeyEquivalentConflict(
    for keyName: String,
    workspaceId: Workspace.ID
  ) -> String? {
    guard
      let workspace = workspace(id: workspaceId),
      let profileId = profileId(owning: workspaceId)
    else { return nil }
    let shortcuts = settings.shortcuts
    return keyEquivalentConflict(
      for: keyName,
      candidates: [
        .init(
          modifiers: shortcuts.keyEquivalentModifiers,
          action: .activateWorkspace(workspaceId),
          explicitOverride: workspace.activateShortcut
        ),
        .init(
          modifiers: shortcuts.assignModifiers,
          action: .assignFocusedAppToWorkspace(workspaceId),
          explicitOverride: workspace.assignAppShortcut
        ),
        .init(
          modifiers: shortcuts.borrowModifiers,
          action: .borrowWorkspace(workspaceId),
          explicitOverride: workspace.borrowShortcut
        ),
      ],
      conflict: { hotKey, action in
        shortcutConflict(for: hotKey, excluding: action, in: profileId)
      }
    )
  }

  /// Equivalent validation for the recent/next/previous key recorders. These
  /// actions are global settings, so every profile projection is checked, but
  /// only for actions that still use their derived modifier + key binding.
  public func navigationKeyEquivalentConflict(
    for keyName: String,
    switchAction: HotKeyAction,
    switchOverride: HotKey?,
    assignAction: HotKeyAction,
    assignOverride: HotKey?,
    borrowAction: HotKeyAction,
    borrowOverride: HotKey?
  ) -> String? {
    let shortcuts = settings.shortcuts
    return keyEquivalentConflict(
      for: keyName,
      candidates: [
        .init(
          modifiers: shortcuts.keyEquivalentModifiers,
          action: switchAction,
          explicitOverride: switchOverride
        ),
        .init(
          modifiers: shortcuts.assignModifiers,
          action: assignAction,
          explicitOverride: assignOverride
        ),
        .init(
          modifiers: shortcuts.borrowModifiers,
          action: borrowAction,
          explicitOverride: borrowOverride
        ),
      ],
      conflict: { hotKey, action in
        shortcutConflictAcrossProfiles(for: hotKey, excluding: action)
      }
    )
  }

  /// Validate shortcut-producing fields selected by Copy/Duplicate against
  /// the complete projected configuration. For an existing destination, a
  /// field owns only collisions that disappear when that field alone is
  /// restored from `baseline`; this avoids highlighting representation-only
  /// changes that merely happen to participate in another field's collision.
  /// A duplicated workspace has no baseline destination, so all of its
  /// collisions are new. Workspace bindings are checked only in their
  /// destination profile; global profile/settings bindings are still present
  /// in every projection. This is the same scope and precedence used by actual
  /// registration in `hotKeyBindings(for:)`.
  public func shortcutCopyConflicts(
    for selections: some Sequence<WorkspaceShortcutSelection>,
    comparedTo baseline: AppConfig? = nil
  ) -> [WorkspaceShortcutConflict] {
    let contexts = selections.compactMap { selection -> ShortcutSelectionContext? in
      guard
        workspace(id: selection.workspaceId) != nil,
        let profileId = profileId(owning: selection.workspaceId)
      else { return nil }
      return ShortcutSelectionContext(
        actions: Set(shortcutActions(
          potentiallyAffectedBy: selection.field,
          workspaceId: selection.workspaceId
        )),
        profileId: profileId,
        selection: selection
      )
    }

    // First establish the authoritative set of collision pairs introduced by
    // the full selection. Per-field attribution below may be empty for a
    // joint/redundant cause, but it must never erase this gate.
    var projectedPairs = Set<ShortcutCollisionPair>()
    var baselinePairs = Set<ShortcutCollisionPair>()
    for context in contexts {
      for action in context.actions {
        projectedPairs.formUnion(shortcutCollisionPairs(
          for: action,
          in: context.profileId
        ))
        if let baseline {
          baselinePairs.formUnion(baseline.shortcutCollisionPairs(for: action))
        }
      }
    }
    let introducedPairs = projectedPairs.subtracting(baselinePairs)

    var pairsBySelection = [WorkspaceShortcutSelection: Set<ShortcutCollisionPair>]()
    var attributedPairs = Set<ShortcutCollisionPair>()
    for context in contexts {
      let projectedForField = collisionPairs(
        for: context.actions,
        in: context.profileId
      )
      let counterfactual = baseline.flatMap { reverting(context.selection, to: $0) }
      let remainingForField = counterfactual?.collisionPairs(
        for: context.actions,
        in: context.profileId
      ) ?? []
      let causalPairs = projectedForField
        .subtracting(remainingForField)
        .intersection(introducedPairs)
      pairsBySelection[context.selection] = causalPairs
      attributedPairs.formUnion(causalPairs)
    }

    // If no single revert removes an introduced pair, the fields are a joint
    // or redundant cause (for example explicit X plus key-equivalent-derived
    // X). Attribute the still-uncovered pair to every relevant selected field
    // so Apply remains blocked until the combination is actually resolved.
    for pair in introducedPairs.subtracting(attributedPairs) {
      for context in contexts
        where context.profileId == pair.profileId
        && !context.actions.isDisjoint(with: pair.actions)
      {
        pairsBySelection[context.selection, default: []].insert(pair)
      }
    }

    var conflicts = [WorkspaceShortcutConflict]()
    var seen = Set<WorkspaceShortcutConflict>()
    for context in contexts {
      for pair in pairsBySelection[context.selection] ?? [] {
        guard let owner = collisionOwner(in: pair, for: context.actions) else { continue }
        let conflict = WorkspaceShortcutConflict(
          selection: context.selection,
          hotKey: pair.hotKey,
          owner: owner.title(in: self)
        )
        if seen.insert(conflict).inserted {
          conflicts.append(conflict)
        }
      }
    }
    return conflicts.sorted {
      let lhs = ($0.selection.workspaceId.uuidString, $0.selection.field.rawValue, $0.hotKey.displayString, $0.owner)
      let rhs = ($1.selection.workspaceId.uuidString, $1.selection.field.rawValue, $1.hotKey.displayString, $1.owner)
      return lhs < rhs
    }
  }

  private func collisionOwner(
    in pair: ShortcutCollisionPair,
    for controlledActions: Set<HotKeyAction>
  ) -> HotKeyAction? {
    let actions = pair.actions.sorted { $0.nameKey < $1.nameKey }
    guard let controlled = actions.first(where: controlledActions.contains) else { return nil }
    return actions.first { $0 != controlled }
  }

  private func collisionPairs(
    for actions: Set<HotKeyAction>,
    in profileId: Profile.ID
  ) -> Set<ShortcutCollisionPair> {
    actions.reduce(into: Set<ShortcutCollisionPair>()) { result, action in
      result.formUnion(shortcutCollisionPairs(for: action, in: profileId))
    }
  }

  /// Return the projected config with exactly one selected destination field
  /// restored to its reviewed baseline value. Nil means the destination is new
  /// (profile duplication), where there is no counterfactual old field.
  private func reverting(
    _ selection: WorkspaceShortcutSelection,
    to baseline: AppConfig
  ) -> AppConfig? {
    guard let previous = baseline.workspace(id: selection.workspaceId) else { return nil }
    var counterfactual = self
    counterfactual.mutateWorkspace(selection.workspaceId) { workspace in
      switch selection.field {
      case .keyEquivalent:
        workspace.keyEquivalent = previous.keyEquivalent
      case .activateShortcut:
        workspace.activateShortcut = previous.activateShortcut
      case .assignAppShortcut:
        workspace.assignAppShortcut = previous.assignAppShortcut
      case .borrowShortcut:
        workspace.borrowShortcut = previous.borrowShortcut
      }
    }
    return counterfactual
  }

  private func shortcutConflict(
    for candidate: HotKey,
    excluding action: HotKeyAction,
    among bindings: [HotKeyBinding]
  ) -> String? {
    bindings
      .first { $0.hotKey == candidate && $0.action != action }?
      .action.title(in: self)
  }

  /// Effective collision pairs for one workspace action in one profile scope.
  private func shortcutCollisionPairs(
    for action: HotKeyAction,
    in profileId: Profile.ID? = nil
  ) -> Set<ShortcutCollisionPair> {
    guard
      let workspaceId = action.workspaceId,
      let ownerProfileId = profileId ?? self.profileId(owning: workspaceId)
    else { return [] }
    let bindings = hotKeyBindings(for: ownerProfileId)
    guard let binding = bindings.first(where: { $0.action == action }) else { return [] }
    return Set(bindings.compactMap { other in
      guard other.action != action, other.hotKey == binding.hotKey else { return nil }
      return ShortcutCollisionPair(
        actions: [action, other.action],
        hotKey: binding.hotKey,
        profileId: ownerProfileId
      )
    })
  }

  private func keyEquivalentConflict(
    for keyName: String,
    candidates: [KeyEquivalentCandidate],
    conflict: (HotKey, HotKeyAction) -> String?
  ) -> String? {
    guard let keyCode = HotKey.keyCode(forName: keyName) else { return nil }
    for candidate in candidates where candidate.explicitOverride == nil {
      let modifiers = HotKey.carbonModifiers(from: candidate.modifiers)
      guard modifiers != 0 else { continue }
      let hotKey = HotKey(carbonKeyCode: keyCode, carbonModifiers: modifiers)
      if let owner = conflict(hotKey, candidate.action) { return owner }
    }
    return nil
  }

  private func shortcutActions(
    potentiallyAffectedBy field: WorkspaceShortcutField,
    workspaceId: Workspace.ID
  ) -> [HotKeyAction] {
    switch field {
    case .keyEquivalent:
      return [
        .activateWorkspace(workspaceId),
        .assignFocusedAppToWorkspace(workspaceId),
        .borrowWorkspace(workspaceId),
      ]

    case .activateShortcut:
      return [.activateWorkspace(workspaceId)]

    case .assignAppShortcut:
      return [.assignFocusedAppToWorkspace(workspaceId)]

    case .borrowShortcut:
      return [.borrowWorkspace(workspaceId)]
    }
  }
}

private struct KeyEquivalentCandidate {
  let modifiers: [String]
  let action: HotKeyAction
  let explicitOverride: HotKey?
}

private struct ShortcutCollisionPair: Hashable {
  let actions: Set<HotKeyAction>
  let hotKey: HotKey
  let profileId: Profile.ID
}

private struct ShortcutSelectionContext {
  let actions: Set<HotKeyAction>
  let profileId: Profile.ID
  let selection: WorkspaceShortcutSelection
}
