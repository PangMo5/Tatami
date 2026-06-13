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

    for workspace in workspaces {
      if let key = workspace.activateShortcut {
        out.append(.init(action: .activateWorkspace(workspace.id), hotKey: key))
      }
      if let key = workspace.assignAppShortcut {
        out.append(.init(action: .assignFocusedAppToWorkspace(workspace.id), hotKey: key))
      }
    }

    func add(_ action: HotKeyAction, _ key: HotKey?) {
      if let key { out.append(.init(action: action, hotKey: key)) }
    }
    let shortcuts = settings.shortcuts
    add(.switchToNextWorkspace, shortcuts.switchToNextWorkspace)
    add(.switchToPreviousWorkspace, shortcuts.switchToPreviousWorkspace)
    add(.switchToRecentWorkspace, shortcuts.switchToRecentWorkspace)
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
