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

    func add(_ action: HotKeyAction, _ key: HotKey?) {
      if let key { out.append(.init(action: action, hotKey: key)) }
    }
    let shortcuts = settings.shortcuts
    // Key-equivalent default with explicit override: an explicit shortcut
    // wins; otherwise switch-modifier + the single-char key equivalent (when
    // the modifier combo is non-empty).
    func addKeyEquiv(_ action: HotKeyAction, override explicit: HotKey?, key char: String?) {
      if let explicit {
        out.append(.init(action: action, hotKey: explicit))
      } else if switchModifiers != 0,
                let char, let keyCode = HotKey.keyCode(forName: char) {
        out.append(.init(
          action: action,
          hotKey: HotKey(carbonKeyCode: keyCode, carbonModifiers: switchModifiers)
        ))
      }
    }
    addKeyEquiv(.switchToNextWorkspace, override: shortcuts.switchToNextWorkspace, key: shortcuts.nextWorkspaceKey)
    addKeyEquiv(.switchToPreviousWorkspace, override: shortcuts.switchToPreviousWorkspace, key: shortcuts.previousWorkspaceKey)
    addKeyEquiv(.switchToRecentWorkspace, override: shortcuts.switchToRecentWorkspace, key: shortcuts.recentWorkspaceKey)
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
