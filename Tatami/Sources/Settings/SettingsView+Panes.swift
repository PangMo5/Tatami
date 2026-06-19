import ComposableArchitecture
import SwiftUI
import TatamiKit

/// The six settings panes, one `@ViewBuilder` per sidebar entry — split
/// out of `SettingsView.swift` so the shell (sidebar + helpers) and the
/// form content stay separately navigable.
extension SettingsView {
  // MARK: - General

  @ViewBuilder
  var generalPane: some View {
    Section("General") {
      Toggle(isOn: setting(\.general.launchAtLogin)) {
        Text("Launch at login")
        Text("Start Tatami automatically when you log in.")
      }
    }

    Section("Permissions") {
      HStack {
        Image(systemName: store.hasAXPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
          .foregroundStyle(store.hasAXPermission ? .green : .orange)
        VStack(alignment: .leading) {
          Text("Accessibility")
          Text(store.hasAXPermission
            ? "Granted — Tatami can move, resize, and focus windows."
            : "Required for tiling. Enable it in System Settings, then relaunch.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if store.hasAXPermission {
          Button("Open System Settings") { store.send(.openAccessibilitySettingsTapped) }
        } else {
          Button("Grant…") { store.send(.grantAccessibilityTapped) }
        }
      }
      HStack {
        Image(systemName: store.hasScreenRecordingPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
          .foregroundStyle(store.hasScreenRecordingPermission ? .green : .orange)
        VStack(alignment: .leading) {
          Text("Screen Recording")
          Text(store.hasScreenRecordingPermission
            ? "Granted — floating windows can be mirrored above the tiles."
            : "Needed only for floating windows: their always-on-top mirrors are screen captures.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if store.hasScreenRecordingPermission {
          Button("Open System Settings") { store.send(.openScreenRecordingSettingsTapped) }
        } else {
          Button("Grant…") { store.send(.grantScreenRecordingTapped) }
        }
      }
      if !store.hasAXPermission || !store.hasScreenRecordingPermission {
        HStack {
          Text("macOS only applies a new grant after a relaunch.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button("Relaunch Tatami") { store.send(.relaunchTapped) }
        }
      }
    }

    Section("Updates") {
      Toggle(isOn: setting(\.general.checkForUpdatesAutomatically)) {
        Text("Check for updates automatically")
        Text("Periodically check for new Tatami releases.")
      }
      Picker(selection: setting(\.general.checkInterval)) {
        ForEach(UpdateCheckInterval.allCases) { interval in
          Text(interval.displayName).tag(interval)
        }
      } label: {
        Text("Check frequency")
      }
      .disabled(!config.settings.general.checkForUpdatesAutomatically)
      Button("Check for Updates…") {
        store.send(.checkForUpdatesTapped)
      }
    }

    Section("Command Line") {
      HStack {
        Image(systemName: store.cli.isInstalled ? "checkmark.circle.fill" : "terminal")
          .foregroundStyle(store.cli.isInstalled ? .green : .secondary)
        VStack(alignment: .leading) {
          Text("tatami CLI")
          Text(cliStatusDetail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if store.cli.viaHomebrew {
          Text("Homebrew").foregroundStyle(.secondary)
        } else if store.cli.isInstalled {
          Button("Uninstall") { store.send(.uninstallCLITapped) }
        } else {
          Button("Install…") { store.send(.installCLITapped) }
            .disabled(!store.cli.isBundled)
        }
      }
      Text("Symlinks `tatami` into /usr/local/bin so you can script Tatami from the terminal — e.g. `tatami activate <workspace>`, `tatami list-workspaces`.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    Section("Debug") {
      Toggle(isOn: setting(\.general.debugLogging)) {
        Text("Debug logging")
        Text("Append diagnostic events to ~/.config/tatami/tatami.log. Off by default.")
      }
      if config.settings.general.debugLogging {
        HStack {
          Text("Log file")
            .foregroundStyle(.secondary)
          Spacer()
          Button("Reveal in Finder") {
            let url = ConfigLocation.directory
              .appendingPathComponent("tatami.log", isDirectory: false)
            NSWorkspace.shared.activateFileViewerSelecting([url])
          }
        }
      }
    }
  }

  // MARK: - Tiling

  @ViewBuilder
  var tilingPane: some View {
    Section("Gaps") {
      DebouncedStepper(
        external: config.settings.layout.gapInner,
        range: 0 ... 100,
        detail: "Space between adjacent tiled windows.",
        label: { "Inner gap: \($0) px" },
        commit: { v in $config.withLock { $0.settings.layout.gapInner = v } }
      )
      DebouncedStepper(
        external: config.settings.layout.gapOuter,
        range: 0 ... 100,
        detail: "Space between the tiles and the screen edge.",
        label: { "Outer gap: \($0) px" },
        commit: { v in $config.withLock { $0.settings.layout.gapOuter = v } }
      )
    }

    Section("Layout") {
      Picker(selection: setting(\.layout.autoBalance)) {
        ForEach(AutoBalanceMode.allCases) { mode in
          Text(mode.displayName).tag(mode)
        }
      } label: {
        Text("Auto-balance")
        Text("Equalize every split whenever a window is added or removed.")
      }
      Picker(selection: setting(\.layout.splitType)) {
        ForEach(SplitTypePreference.allCases) { type in
          Text(type.displayName).tag(type)
        }
      } label: {
        Text("Split direction")
        Text("Default axis when a new window splits an existing tile.")
      }
      Picker(selection: setting(\.layout.windowPlacement)) {
        ForEach(WindowPlacement.allCases) { place in
          Text(place.displayName).tag(place)
        }
      } label: {
        Text("New window placement")
        Text("Which side of the new split holds the inserted window.")
      }
      Picker(selection: setting(\.layout.defaultTilingMemory)) {
        ForEach(TilingMemory.allCases, id: \.self) { memory in
          Text(memory.displayName).tag(memory)
        }
      } label: {
        Text("Default tiling memory")
        Text("How workspaces remember their layout unless they override it.")
      }
    }
  }

  // MARK: - Focus & Mouse

  @ViewBuilder
  var focusMousePane: some View {
    Section("Focus") {
      Toggle(isOn: setting(\.focus.mouseFollowsFocus)) {
        Text("Mouse follows focus")
        Text("Move the cursor to the focused window when you switch workspaces.")
      }
      Toggle(isOn: setting(\.focus.mouseHidesOnFocus)) {
        Text("Hide cursor on focus")
        Text("Hide the cursor on a workspace switch until you move the mouse.")
      }
      Toggle(isOn: setting(\.focus.refocusOnClose)) {
        Text("Refocus when a window closes")
        Text("Move focus to a remaining window in the workspace when the focused one closes — so closing a chat window hands focus back to your editor instead of stranding it.")
      }
    }

    Section("Focus Follows Mouse") {
      Toggle(isOn: setting(\.focus.focusFollowsMouse)) {
        Text("Focus follows mouse")
        Text("Focus whatever window sits under the cursor as it moves.")
      }
      Toggle(isOn: setting(\.focus.focusFollowsMouseIgnoreFullscreen)) {
        Text("Ignore full-screen windows")
        Text("Don't shift focus to a window that fills the whole display as the cursor passes over it.")
      }
      .disabled(!config.settings.focus.focusFollowsMouse)
      Picker(selection: setting(\.focus.focusFollowsMouseDisableHotkey)) {
        ForEach(FocusFollowsMouseModifier.allCases, id: \.self) { modifier in
          Text(modifier.displayName).tag(modifier)
        }
      } label: {
        Text("Suspend with modifier")
        Text("Hold this key to temporarily pause focus-follows-mouse.")
      }
      .disabled(!config.settings.focus.focusFollowsMouse)
    }
  }

  // MARK: - Workspaces

  @ViewBuilder
  var workspacesPane: some View {
    Section("Workspace Switching") {
      Toggle(isOn: setting(\.switching.loop)) {
        Text("Loop around")
        Text("Wrap from the last workspace back to the first (and vice versa).")
      }
      Toggle(isOn: setting(\.switching.skipEmpty)) {
        Text("Skip empty workspaces")
        Text("Ignore workspaces with no running apps when cycling next/previous.")
      }
      Toggle(isOn: setting(\.switching.followAppFocus)) {
        Text("Follow app focus")
        Text("Switching to an app activates the workspace it belongs to.")
      }
      Toggle(isOn: setting(\.switching.cycleAcrossDisplays)) {
        Text("Cycle across all displays")
        Text("Next/previous workspace cycles through every display's workspaces instead of just the one under the cursor.")
      }
      Toggle(isOn: setting(\.switching.switchToRecentWhenEmpty)) {
        Text("Back to recent when empty")
        Text("When the last window in the active workspace closes, switch to the recent workspace. Shared apps don't count — they join every workspace anyway.")
      }
      Toggle(isOn: setting(\.switching.cycleSameAppWindows)) {
        Text("Cycle through every window")
        Text("Step through each window individually, including multiple windows of the same app, instead of cycling app-by-app.")
      }
    }

    Section("Gestures") {
      Toggle(isOn: setting(\.gestures.enabled)) {
        Text("Swipe to switch workspaces")
        Text("Swipe left/right on the trackpad to move to the next/previous workspace.")
      }
      Picker(selection: setting(\.gestures.fingerCount)) {
        Text("Three fingers").tag(3)
        Text("Four fingers").tag(4)
      } label: {
        Text("Fingers")
        Text("Number of fingers for the swipe gesture.")
      }
      .disabled(!config.settings.gestures.enabled)

      VStack(alignment: .leading, spacing: 4) {
        // `Gestures.sensitivity` owns the threshold ↔ sensitivity mapping
        // (inverse of the swipe distance: higher = shorter swipe).
        let sensitivity = config.settings.gestures.sensitivity
        HStack {
          Text("Sensitivity")
          Spacer()
          Text("\(Int((sensitivity * 100).rounded()))%")
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        Slider(
          value: setting(\.gestures.sensitivity),
          in: 0 ... 1,
          step: 0.0125
        ) {
          // Hidden — the HStack above is the visible label; leaving this in
          // place made the grouped Form render "Sensitivity" twice.
          Text("Sensitivity")
        } minimumValueLabel: {
          Text("Low")
        } maximumValueLabel: {
          Text("High")
        }
        .labelsHidden()
        Text("How far you must swipe to switch — higher sensitivity needs a shorter swipe.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .disabled(!config.settings.gestures.enabled)
    }
  }

  // MARK: - Shortcuts

  @ViewBuilder
  var shortcutsPane: some View {
    Section("Focus") {
      shortcut("Focus left", .focusLeft, \.focusLeft)
      shortcut("Focus right", .focusRight, \.focusRight)
      shortcut("Focus up", .focusUp, \.focusUp)
      shortcut("Focus down", .focusDown, \.focusDown)
    }

    Section("Move / Swap") {
      shortcut("Swap left", .swapLeft, \.swapLeft)
      shortcut("Swap right", .swapRight, \.swapRight)
      shortcut("Swap up", .swapUp, \.swapUp)
      shortcut("Swap down", .swapDown, \.swapDown)
    }

    Section("Resize & Layout") {
      shortcut("Grow", .resizeGrow, \.resizeGrow)
      shortcut("Shrink", .resizeShrink, \.resizeShrink)
      shortcut(
        "Toggle orientation", .toggleOrientation, \.toggleOrientation,
        description: "Flip the split between the focused window and its neighbour (side-by-side ↔ stacked)."
      )
      shortcut(
        "Toggle fullscreen", .toggleFullscreen, \.toggleFullscreen,
        description: "Zoom the focused window to fill the workspace. Tatami can keep several windows zoomed at once."
      )
      shortcut(
        "Balance", .balance, \.balance,
        description: "Reset every split in the layout to equal sizes."
      )
    }

    Section {
      modifierToggleRow(
        "Switch modifier", \.keyEquivalentModifiers,
        description: "Held with a key equivalent to switch workspaces. Each workspace's key is set in its own settings; the keys below cover recent / next / previous. Clear it to disable key-equivalent switching."
      )
      modifierToggleRow(
        "Assign modifier", \.assignModifiers,
        description: "Held with a workspace's key equivalent to assign the focused app to it. Distinct from the switch modifier, so one key does both."
      )
      keyEquivalentShortcut(
        "Recent workspace", .switchToRecentWorkspace,
        key: \.recentWorkspaceKey, override: \.switchToRecentWorkspace,
        description: "Switch back to the previously active workspace."
      )
      keyEquivalentShortcut(
        "Next workspace", .switchToNextWorkspace,
        key: \.nextWorkspaceKey, override: \.switchToNextWorkspace,
        description: "Cycle to the next workspace."
      )
      keyEquivalentShortcut(
        "Previous workspace", .switchToPreviousWorkspace,
        key: \.previousWorkspaceKey, override: \.switchToPreviousWorkspace,
        description: "Cycle to the previous workspace."
      )
    } header: {
      Text("Workspace Switching")
    } footer: {
      Text("Set a single-letter key, or record an explicit shortcut to override the modifier+key default.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    Section("Windows & Displays") {
      shortcut(
        "Cycle next window", .cycleNextWindow, \.cycleNextWindow,
        description: "Move focus to the next window in the active workspace."
      )
      shortcut(
        "Cycle previous window", .cyclePreviousWindow, \.cyclePreviousWindow,
        description: "Move focus to the previous window in the active workspace."
      )
      shortcut(
        "Move app to next workspace", .moveFocusedAppToNextWorkspace, \.moveToNextWorkspace,
        description: "Move the focused app to the next workspace and follow it there."
      )
      shortcut(
        "Move app to previous workspace",
        .moveFocusedAppToPreviousWorkspace,
        \.moveToPreviousWorkspace,
        description: "Move the focused app to the previous workspace and follow it there."
      )
      shortcut(
        "Focus next display", .focusNextDisplay, \.focusNextDisplay,
        description: "Focus the active workspace on the next display (loops around)."
      )
      shortcut(
        "Focus previous display", .focusPreviousDisplay, \.focusPreviousDisplay,
        description: "Focus the active workspace on the previous display (loops around)."
      )
    }

    Section("Borrow") {
      shortcut(
        "Borrow mode", .enterBorrowMode, \.enterBorrowMode,
        description: "Enter borrow mode, then a direction (h/j/k/l or arrows) + a workspace's key summons it side by side. Backtick = recent, Esc cancels."
      )
      shortcut(
        "Borrow recent (left)", .borrowRecentLeft, \.borrowRecentLeft,
        description: "Borrow the recent workspace into the left, side by side (press again to dismiss)."
      )
      shortcut(
        "Borrow recent (right)", .borrowRecentRight, \.borrowRecentRight,
        description: "Borrow the recent workspace into the right, side by side (press again to dismiss)."
      )
      shortcut(
        "Borrow recent (up)", .borrowRecentUp, \.borrowRecentUp,
        description: "Borrow the recent workspace into the top, stacked (press again to dismiss)."
      )
      shortcut(
        "Borrow recent (down)", .borrowRecentDown, \.borrowRecentDown,
        description: "Borrow the recent workspace into the bottom, stacked (press again to dismiss)."
      )
      shortcut(
        "Grow borrowed block", .borrowGrow, \.borrowGrow,
        description: "Give the borrowed workspace a larger share of the screen."
      )
      shortcut(
        "Shrink borrowed block", .borrowShrink, \.borrowShrink,
        description: "Give the borrowed workspace a smaller share of the screen."
      )
      shortcut(
        "Dismiss borrow", .dismissBorrow, \.dismissBorrow,
        description: "Return the borrowed workspace and restore the current one to full screen."
      )
    }

    Section("Toggles") {
      shortcut(
        "Toggle floating", .toggleFloating, \.toggleFloating,
        description: "Float the focused app in the active workspace (added here as floating if it wasn't assigned); toggle again to re-tile it."
      )
      shortcut(
        "Toggle shared floating", .toggleSharedFloating, \.toggleSharedFloating,
        description: "Float the focused app everywhere — joins Shared Apps as floating if it isn't shared yet. Toggling off flips it to shared tiled; leaving Shared Apps is the membership toggle below."
      )
      shortcut(
        "Toggle tiling (pause)", .toggleSpaceActivated, \.toggleSpaceActivated,
        description: "Pause or resume tiling for the active workspace. While paused, windows keep their current frames."
      )
      shortcut(
        "Toggle app in workspace",
        .toggleFocusedAppInActiveWorkspace,
        \.toggleFocusedAppInActiveWorkspace,
        description: "Add the focused app to the active workspace, or remove it if it's already assigned."
      )
      shortcut(
        "Toggle app in Shared Apps",
        .toggleAppInSharedApps,
        \.toggleAppInSharedApps,
        description: "Add the focused app to Shared Apps (tiled into every workspace), or remove it if it's already shared."
      )
    }
  }

  // MARK: - Appearance

  @ViewBuilder
  var appearancePane: some View {
    Section("Menu Bar") {
      Toggle(isOn: setting(\.menuBar.showWorkspaceName)) {
        Text("Show workspace name")
        Text("Display the active workspace's name next to its icon in the menu bar.")
      }
    }

    Section("Overlay") {
      Toggle(isOn: setting(\.hud.enabled)) {
        Text("Show HUD")
        Text("Brief on-screen overlay confirming actions. The toggles below pick which.")
      }
      Group {
        Toggle(isOn: setting(\.hud.workspaceSwitch)) {
          Text("Workspace switch")
          Text("The workspace's name when you switch to it.")
        }
        Toggle(isOn: setting(\.hud.floating)) {
          Text("Floating changes")
          Text("Floated / tiled — per-workspace and shared.")
        }
        Toggle(isOn: setting(\.hud.appMembership)) {
          Text("App membership")
          Text("App added to or removed from a workspace or Shared Apps.")
        }
        Toggle(isOn: setting(\.hud.tilingPaused)) {
          Text("Tiling pause")
          Text("Tiling paused / resumed.")
        }
        Toggle(isOn: setting(\.hud.fullscreen)) {
          Text("Fullscreen zoom")
          Text("A window zoomed to the workspace, or back.")
        }
        Toggle(isOn: setting(\.hud.layout)) {
          Text("Layout commands")
          Text("Commands without a visual cue of their own (balance).")
        }
        Toggle(isOn: setting(\.hud.borrow)) {
          Text("Borrow")
          Text("Borrowing a workspace in beside another, or returning it.")
        }
        DebouncedStepper(
          external: config.settings.hud.durationMs,
          range: 300 ... 3000,
          step: 100,
          detail: "How long the overlay stays up. HUDs with a follow-up hint stay twice as long.",
          label: { "Duration: \($0) ms" },
          commit: { v in $config.withLock { $0.settings.hud.durationMs = v } }
        )
      }
      .disabled(!config.settings.hud.enabled)
      .padding(.leading, 12)
    }

    Section("Window Markers") {
      Toggle(isOn: setting(\.marker.fullscreenEnabled)) {
        Text("Mark fullscreen window")
        Text("Show a small color dot on the workspace's zoomed window.")
      }
      ColorPicker(
        "Fullscreen color",
        selection: borderColorBinding(\.marker.fullscreenColorHex),
        supportsOpacity: false
      )
      .disabled(!config.settings.marker.fullscreenEnabled)

      Toggle(isOn: setting(\.marker.floatingEnabled)) {
        Text("Mark floating windows")
        Text("Show a small color dot on floating windows (per-workspace or shared), so a mirror reads as floating at a glance.")
      }
      ColorPicker(
        "Floating color",
        selection: borderColorBinding(\.marker.floatingColorHex),
        supportsOpacity: false
      )
      .disabled(!config.settings.marker.floatingEnabled)

      DebouncedStepper(
        external: config.settings.marker.size,
        range: 8 ... 28,
        label: { "Dot size: \(Int($0)) pt" },
        commit: { v in $config.withLock { $0.settings.marker.size = v } }
      )

      Picker(selection: setting(\.marker.corner)) {
        ForEach(MarkerCorner.allCases) { corner in
          Text(corner.displayName).tag(corner)
        }
      } label: {
        Text("Dot position")
        Text("Window corner where the dot is anchored.")
      }
      Toggle(isOn: setting(\.marker.hideOnHover)) {
        Text("Fade on hover")
        Text("Hide the dot while the cursor is over it.")
      }
    }
  }

  /// One-line status describing where the CLI is (or would be) installed.
  var cliStatusDetail: String {
    let cli = store.cli
    if cli.viaHomebrew {
      return "Installed via Homebrew at \(cli.homebrewPath)"
    } else if cli.isInstalled {
      return "Installed at \(cli.symlinkPath)"
    } else if cli.isBundled {
      return "Not installed — will symlink to \(cli.symlinkPath)"
    } else {
      return "Not bundled with this build"
    }
  }

  /// A recorder row bound to a global `HotKeyAction`. The config's
  /// `shortcuts` group is the single source of truth: the recorder reads the
  /// current combo from it and writes edits straight back, and the live
  /// `HotKeysFeature` re-registers on the change. Conflicts are detected
  /// against every other binding (`AppConfig.shortcutConflict`).
  /// A navigation shortcut driven by a single-char key equivalent (switch
  /// modifier + key) with an optional explicit-shortcut override. The key cap
  /// dims when an override is set, since the override wins.
  @ViewBuilder
  func keyEquivalentShortcut(
    _ title: String,
    _ action: HotKeyAction,
    key keyKP: WritableKeyPath<AppSettings.Shortcuts, String?>,
    override overrideKP: WritableKeyPath<AppSettings.Shortcuts, HotKey?>,
    description: String
  ) -> some View {
    let shortcuts = config.settings.shortcuts
    let modSymbols = HotKey.modifierSymbols(from: shortcuts.keyEquivalentModifiers)
    let hasOverride = shortcuts[keyPath: overrideKP] != nil
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
          Text(description)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 12)
        KeyEquivalentRecorder(
          key: shortcuts[keyPath: keyKP],
          modifierSymbols: modSymbols,
          conflict: { keyEquivalentConflict($0, excluding: action) },
          onRecordingChanged: { store.send(.shortcutRecordingChanged($0)) }
        ) { newKey in
          $config.withLock { $0.settings.shortcuts[keyPath: keyKP] = newKey }
        }
        .opacity(hasOverride ? 0.35 : 1)
        .disabled(hasOverride)
        Text("or")
          .font(.caption)
          .foregroundStyle(.tertiary)
        ShortcutRecorder(
          hotKey: shortcuts[keyPath: overrideKP],
          conflict: { config.shortcutConflict(for: $0, excluding: action) },
          onRecordingChanged: { store.send(.shortcutRecordingChanged($0)) }
        ) { hotKey in
          $config.withLock { $0.settings.shortcuts[keyPath: overrideKP] = hotKey }
        }
      }
    }
  }

  /// Conflict title for a candidate key equivalent: the switch modifier + key
  /// resolved against every other binding, or nil when free / unbound.
  func keyEquivalentConflict(_ char: String, excluding action: HotKeyAction) -> String? {
    let mods = HotKey.carbonModifiers(from: config.settings.shortcuts.keyEquivalentModifiers)
    guard mods != 0, let code = HotKey.keyCode(forName: char) else { return nil }
    return config.shortcutConflict(
      for: HotKey(carbonKeyCode: code, carbonModifiers: mods), excluding: action
    )
  }

  /// A labeled row of modifier toggle buttons (⌃⌥⇧⌘) editing one modifier
  /// list (e.g. switch vs assign).
  @ViewBuilder
  func modifierToggleRow(
    _ title: String,
    _ keyPath: WritableKeyPath<AppSettings.Shortcuts, [String]>,
    description: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title)
        Spacer(minLength: 16)
        modifierToggle("⌃", "ctrl", keyPath)
        modifierToggle("⌥", "alt", keyPath)
        modifierToggle("⇧", "shift", keyPath)
        modifierToggle("⌘", "cmd", keyPath)
      }
      Text(description)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// One compact toggle button for a modifier token (e.g. `"ctrl"`),
  /// reflecting / editing membership in the given modifier list.
  @ViewBuilder
  func modifierToggle(
    _ symbol: String,
    _ token: String,
    _ keyPath: WritableKeyPath<AppSettings.Shortcuts, [String]>
  ) -> some View {
    Toggle(symbol, isOn: Binding(
      get: { config.settings.shortcuts[keyPath: keyPath].contains(token) },
      set: { on in
        $config.withLock { c in
          var mods = c.settings.shortcuts[keyPath: keyPath].filter { $0 != token }
          if on { mods.append(token) }
          c.settings.shortcuts[keyPath: keyPath] = mods
        }
      }
    ))
    .toggleStyle(.button)
  }

  @ViewBuilder
  func shortcut(
    _ title: String,
    _ action: HotKeyAction,
    _ keyPath: WritableKeyPath<AppSettings.Shortcuts, HotKey?>,
    description: String? = nil
  ) -> some View {
    // Plain centered HStack rather than LabeledContent: the latter aligns
    // its label to the text baseline, which floats the title above the
    // taller (24pt) recorder capsule.
    let recorder = HStack {
      Text(title)
      Spacer(minLength: 16)
      ShortcutRecorder(
        hotKey: config.settings.shortcuts[keyPath: keyPath],
        conflict: { config.shortcutConflict(for: $0, excluding: action) },
        onRecordingChanged: { store.send(.shortcutRecordingChanged($0)) }
      ) { hotKey in
        $config.withLock { $0.settings.shortcuts[keyPath: keyPath] = hotKey }
      }
    }
    // Non-obvious actions get a caption below the recorder, matching the
    // toggle/picker rows; self-explanatory directional ones pass none.
    if let description {
      VStack(alignment: .leading, spacing: 4) {
        recorder
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    } else {
      recorder
    }
  }
}
