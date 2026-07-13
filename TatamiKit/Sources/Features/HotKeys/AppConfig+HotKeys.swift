import Foundation

extension AppConfig {
  /// Every active hotkey binding the config implies — each workspace's
  /// activate / assign shortcuts plus the global action shortcuts. The
  /// single source for both registration (`HotKeysFeature`) and recorder
  /// conflict detection (Settings / workspace detail), so the two can never
  /// disagree about what's bound.
  public var hotKeyBindings: [HotKeyBinding] {
    var out: [HotKeyBinding] = []
    let workspaces = activeProfile?.workspaces ?? []
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
  public func shortcutConflict(for candidate: HotKey, excluding action: HotKeyAction) -> String? {
    hotKeyBindings
      .first { $0.hotKey == candidate && $0.action != action }?
      .action.title(in: self)
  }
}
