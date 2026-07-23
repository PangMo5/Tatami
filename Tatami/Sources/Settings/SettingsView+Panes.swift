import ComposableArchitecture
import SwiftUI
import TatamiKit

/// The settings panes, one `@ViewBuilder` per sidebar entry — split out of
/// `SettingsView.swift` so the shell (sidebar + helpers) and the form content
/// stay separately navigable.
extension SettingsView {
  @ViewBuilder
  var generalPane: some View {
    Section("General") {
      Toggle(isOn: setting(\.general.launchAtLogin)) {
        Text("Launch at login")
        Text("Start Tatami automatically when you log in.")
      }
    }

    Section("Guided Setup") {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("Review Tatami's Core Workflow")
          Text("Practice with this Mac's apps and displays, then apply any changes together.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Run Guided Setup…", action: onStartOnboarding)
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
      Text(
        "Symlinks `tatami` into /usr/local/bin so you can script Tatami from the terminal — e.g. `tatami activate <workspace>`, `tatami list-workspaces`."
      )
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

  @ViewBuilder
  var tilingPane: some View {
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
    }

    Section("Gaps") {
      DebouncedStepper(
        external: config.settings.layout.gapInner,
        range: 0 ... 100,
        detail: "Space between adjacent tiled windows.",
        label: { "Inner gap: \($0) px" },
        commit: { v in $config.withLock { $0.settings.layout.gapInner = v } },
      )
      DebouncedStepper(
        external: config.settings.layout.gapOuter,
        range: 0 ... 100,
        detail: "Space between the tiles and the screen edge.",
        label: { "Outer gap: \($0) px" },
        commit: { v in $config.withLock { $0.settings.layout.gapOuter = v } },
      )
    }

    Section("Move & Resize") {
      shortcut("Swap left", .swapLeft, \.swapLeft)
      shortcut("Swap right", .swapRight, \.swapRight)
      shortcut("Swap up", .swapUp, \.swapUp)
      shortcut("Swap down", .swapDown, \.swapDown)
      shortcut("Grow", .resizeGrow, \.resizeGrow)
      shortcut("Shrink", .resizeShrink, \.resizeShrink)
      shortcut(
        "Toggle orientation",
        .toggleOrientation,
        \.toggleOrientation,
        description: "Flip the split between the focused window and its neighbour (side-by-side ↔ stacked).",
      )
      shortcut(
        "Toggle fullscreen",
        .toggleFullscreen,
        \.toggleFullscreen,
        description: "Zoom the focused window to fill the workspace. Tatami can keep several windows zoomed at once.",
      )
      shortcut(
        "Balance",
        .balance,
        \.balance,
        description: "Reset every split in the layout to equal sizes.",
      )
    }

    Section("Toggles") {
      shortcut(
        "Toggle floating",
        .toggleFloating,
        \.toggleFloating,
        description: "Float the focused app in the active workspace (added here as floating if it wasn't assigned); toggle again to re-tile it.",
      )
      shortcut(
        "Toggle shared floating",
        .toggleSharedFloating,
        \.toggleSharedFloating,
        description: "Float the focused app everywhere — joins Shared Apps as floating if it isn't shared yet. Toggling off flips it to shared tiled; leaving Shared Apps is the membership toggle in Workspaces.",
      )
      shortcut(
        "Toggle tiling (pause)",
        .toggleSpaceActivated,
        \.toggleSpaceActivated,
        description: "Pause or resume tiling for the active workspace. While paused, windows keep their current frames.",
      )
    }
  }

  @ViewBuilder
  var focusMousePane: some View {
    Section("Focus") {
      Toggle(isOn: setting(\.focus.mouseFollowsFocus)) {
        Text("Mouse follows focus (MFF)")
        Text(
          "Keep the pointer attached to the window Tatami focuses. It moves after directional focus, app/window cycling, workspace changes, open/close refocus, or a Swap that relocates the focused tile. Floating and Ignore-mode cycle targets use their live window frame. Clicking a window preserves the click position."
        )
      }
      Toggle(isOn: setting(\.focus.mouseHidesOnFocus)) {
        Text("Hide cursor on focus")
        Text("Hide the cursor on a workspace switch until you move the mouse.")
      }
      Toggle(isOn: setting(\.focus.refocusOnClose)) {
        Text("Refocus when a window closes")
        Text(
          "Move focus to a remaining window in the workspace when the focused one closes — so closing a chat window hands focus back to your editor instead of stranding it."
        )
      }
    }

    Section("Focus Follows Mouse (FFM)") {
      Toggle(isOn: setting(\.focus.focusFollowsMouse)) {
        Text("Focus follows mouse (FFM)")
        Text("When the pointer moves over a managed window, give that window keyboard focus.")
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

    Section("Directional Focus") {
      shortcut("Focus left", .focusLeft, \.focusLeft)
      shortcut("Focus right", .focusRight, \.focusRight)
      shortcut("Focus up", .focusUp, \.focusUp)
      shortcut("Focus down", .focusDown, \.focusDown)
    }
  }

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
      Toggle(isOn: setting(\.switching.recentAcrossDisplays)) {
        Text("Recent workspace crosses displays")
        Text(
          "Recent actions combine every display's workspace history into one global MRU. Off only uses the current display's recent workspace."
        )
      }
      Toggle(isOn: setting(\.switching.switchToRecentWhenEmpty)) {
        Text("Back to recent when empty")
        Text(
          "When the last window in the active workspace closes, switch to the recent workspace. Shared apps don't count — they join every workspace anyway."
        )
      }
    }

    Section("Window Cycling") {
      Toggle(isOn: setting(\.switching.cycleSameAppWindows)) {
        Text("Cycle through every window")
        Text(
          "Step through each window individually, including multiple windows of the same app. Off cycles app-by-app and recalls each app's most-recent window inside the visible Tatami context."
        )
      }
      shortcut(
        "Cycle next window",
        .cycleNextWindow,
        \.cycleNextWindow,
        description: "Move focus to the next app or window in the visible Tatami context, including Floating and Ignore-mode members. A borrowed tiled block joins its host's cycle until dismissed. Unlike ⌘Tab, unrelated running apps stay out; unlike ⌘`, Tatami can cross between apps. With “Cycle through every window” off, it steps app-by-app and recalls each app's most-recent window.",
      )
      shortcut(
        "Cycle previous window",
        .cyclePreviousWindow,
        \.cyclePreviousWindow,
        description: "Move focus to the previous app or window in the visible Tatami context, including Floating and Ignore-mode members. A borrowed tiled block joins its host's cycle until dismissed. Unlike ⌘Tab, unrelated running apps stay out; unlike ⌘`, Tatami can cross between apps. With “Cycle through every window” off, it steps app-by-app and recalls each app's most-recent window.",
      )
    }

    Section("Move App & Displays") {
      shortcut(
        "Move app to next workspace",
        .moveFocusedAppToNextWorkspace,
        \.moveToNextWorkspace,
        description: "Move the focused app to the next workspace and follow it there.",
      )
      shortcut(
        "Move app to previous workspace",
        .moveFocusedAppToPreviousWorkspace,
        \.moveToPreviousWorkspace,
        description: "Move the focused app to the previous workspace and follow it there.",
      )
      shortcut(
        "Focus next display",
        .focusNextDisplay,
        \.focusNextDisplay,
        description: "Focus the active workspace on the next display (loops around).",
      )
      shortcut(
        "Focus previous display",
        .focusPreviousDisplay,
        \.focusPreviousDisplay,
        description: "Focus the active workspace on the previous display (loops around).",
      )
      shortcut(
        "Toggle app in workspace",
        .toggleFocusedAppInActiveWorkspace,
        \.toggleFocusedAppInActiveWorkspace,
        description: "Add the focused app to the active workspace, or remove it if it's already assigned.",
      )
      shortcut(
        "Toggle app in Shared Apps",
        .toggleAppInSharedApps,
        \.toggleAppInSharedApps,
        description: "Add the focused app to Shared Apps (tiled into every workspace), or remove it if it's already shared.",
      )
    }

    Section("Borrow") {
      Toggle(isOn: setting(\.switching.toggleBorrowOnRepeat)) {
        Text("Dismiss when summoned again")
        Text("Calling the same workspace already borrowed on this display returns it and restores the host workspace.")
      }
      Picker(
        selection: Binding(
          get: { config.settings.switching.borrowDefaultEdge },
          set: { e in $config.withLock { $0.settings.switching.borrowDefaultEdge = e } },
        )
      ) {
        Text("Ask (pick a direction)").tag(BorrowEdge?.none)
        Divider()
        ForEach(BorrowEdge.allCases, id: \.self) { edge in
          Text(edge.rawValue.capitalized).tag(BorrowEdge?.some(edge))
        }
      } label: {
        Text("Default direction")
        Text(
          "Where a borrow docks. “Ask” means press a direction (h/j/k/l or arrows) after the borrow combo. A workspace can override this."
        )
      }
      .pickerStyle(.menu)
      Picker(
        selection: Binding(
          get: { config.settings.switching.borrowFraction },
          set: { f in $config.withLock { $0.settings.switching.borrowFraction = f } },
        )
      ) {
        ForEach([0.3, 0.4, 0.5, 0.6, 0.7], id: \.self) { f in
          Text("\(Int((f * 100).rounded()))%").tag(f)
        }
      } label: {
        Text("Default size")
        Text("The borrowed workspace's share of the screen. A workspace can override this.")
      }
      .pickerStyle(.menu)
      shortcut(
        "Dismiss borrow",
        .dismissBorrow,
        \.dismissBorrow,
        description: "Return the borrowed workspace and restore the current one to full screen.",
      )
    }
  }

  @ViewBuilder
  var workspaceKeysPane: some View {
    Section {
      modifierToggleRow(
        "Switch modifier",
        \.keyEquivalentModifiers,
        description: "Held with a key equivalent to switch workspaces. Each workspace's key is set in its own settings; the built-in targets below cover recent / next / previous. Clear it to disable key-equivalent switching.",
      )
      modifierToggleRow(
        "Assign modifier",
        \.assignModifiers,
        description: "Held with a workspace's key equivalent to assign the focused app to it.",
      )
      modifierToggleRow(
        "Borrow modifier",
        \.borrowModifiers,
        description: "Held with a workspace's key equivalent to borrow it into the current screen — then a direction key places it.",
      )
    } header: {
      Text("Modifiers")
    } footer: {
      Text("These combine with each workspace's own key equivalent to switch, assign, or borrow it.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    Section {
      navTarget(
        "Recent workspace",
        description: "The previously active workspace.",
        key: \.recentWorkspaceKey,
        switchAction: .switchToRecentWorkspace,
        switchOverride: \.switchToRecentWorkspace,
        assignAction: .assignFocusedAppToRecentWorkspace,
        assignOverride: \.assignRecentWorkspace,
        borrowAction: .borrowRecentWorkspace,
        borrowOverride: \.borrowRecentWorkspace,
      )
      navTarget(
        "Next workspace",
        description: "The next workspace in the cycle.",
        key: \.nextWorkspaceKey,
        switchAction: .switchToNextWorkspace,
        switchOverride: \.switchToNextWorkspace,
        assignAction: .assignFocusedAppToNextWorkspace,
        assignOverride: \.assignNextWorkspace,
        borrowAction: .borrowNextWorkspace,
        borrowOverride: \.borrowNextWorkspace,
      )
      navTarget(
        "Previous workspace",
        description: "The previous workspace in the cycle.",
        key: \.previousWorkspaceKey,
        switchAction: .switchToPreviousWorkspace,
        switchOverride: \.switchToPreviousWorkspace,
        assignAction: .assignFocusedAppToPreviousWorkspace,
        assignOverride: \.assignPreviousWorkspace,
        borrowAction: .borrowPreviousWorkspace,
        borrowOverride: \.borrowPreviousWorkspace,
      )
    } header: {
      Text("Built-in Targets")
    } footer: {
      Text(
        "Recent / next / previous behave like workspaces: one key each, combined with the modifiers above. Record an explicit shortcut to override any of them."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  var gesturesPane: some View {
    Section("Trackpad") {
      Toggle(isOn: setting(\.gestures.enabled)) {
        Text("Enable trackpad gestures")
        Text("Run a Tatami action when a configured three- or four-finger swipe is recognized.")
      }

      // `Gestures.sensitivity` owns the threshold ↔ sensitivity mapping
      // (inverse of the swipe distance: higher = shorter swipe). Debounced so
      // a drag doesn't write the @Shared config — and re-render the whole
      // Form — on every tick (same rationale as DebouncedStepper).
      DebouncedSlider(
        title: "Sensitivity",
        external: config.settings.gestures.sensitivity,
        range: 0 ... 1,
        step: 0.0125,
        minLabel: "Low",
        maxLabel: "High",
        detail: "How far you must swipe to switch — higher sensitivity needs a shorter swipe.",
        readout: { "\(Int(($0 * 100).rounded()))%" },
        commit: { setting(\.gestures.sensitivity).wrappedValue = $0 },
      )
      .disabled(!config.settings.gestures.enabled)
    }

    GestureBindingsSection(
      title: "Three-Finger Swipes",
      bindings: setting(\.gestures.threeFinger),
      isEnabled: config.settings.gestures.enabled,
      config: config,
    )

    GestureBindingsSection(
      title: "Four-Finger Swipes",
      bindings: setting(\.gestures.fourFinger),
      isEnabled: config.settings.gestures.enabled,
      config: config,
    )
  }

  @ViewBuilder
  var appearancePane: some View {
    Section {
      Toggle(isOn: setting(\.menuBar.showWorkspaceIcon)) {
        Text("Show workspace icon")
        Text("Display the active workspace's icon in the menu bar.")
      }
      Toggle(isOn: setting(\.menuBar.showWorkspaceName)) {
        Text("Show workspace name")
        Text("Display the active workspace's name in the menu bar.")
      }
      Toggle(isOn: setting(\.menuBar.showProfileIcon)) {
        Text("Show profile icon")
        Text("Display the active profile's icon — only when you have more than one profile.")
      }
      Toggle(isOn: setting(\.menuBar.showProfileName)) {
        Text("Show profile name")
        Text("Display the active profile's name — only when you have more than one profile.")
      }
    } header: {
      Text("Menu Bar")
    } footer: {
      Text("What the menu bar item shows. With everything off it falls back to a single icon.")
        .font(.caption).foregroundStyle(.secondary)
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
        Toggle(isOn: setting(\.hud.windowCycle)) {
          Text("Window cycling")
          Text(
            "A compact app or window switcher while cycling. Use the shortcut or arrow keys, Return, Escape, modifier release, or the pointer."
          )
        }
        Toggle(isOn: setting(\.hud.profileSwitch)) {
          Text("Profile switch")
          Text("The profile's name when you switch profiles (manual or auto).")
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
          commit: { v in $config.withLock { $0.settings.hud.durationMs = v } },
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
        supportsOpacity: false,
      )
      .disabled(!config.settings.marker.fullscreenEnabled)

      Toggle(isOn: setting(\.marker.floatingEnabled)) {
        Text("Mark floating windows")
        Text("Show a small color dot on floating windows (per-workspace or shared), so a mirror reads as floating at a glance.")
      }
      ColorPicker(
        "Floating color",
        selection: borderColorBinding(\.marker.floatingColorHex),
        supportsOpacity: false,
      )
      .disabled(!config.settings.marker.floatingEnabled)

      Toggle(isOn: setting(\.marker.borrowEnabled)) {
        Text("Mark borrowed windows")
        Text("Badge the windows of a borrowed block with the borrowed workspace's icon, so what's on loan is clear at a glance.")
      }
      ColorPicker(
        "Borrow color",
        selection: borderColorBinding(\.marker.borrowColorHex),
        supportsOpacity: false,
      )
      .disabled(!config.settings.marker.borrowEnabled)

      DebouncedStepper(
        external: config.settings.marker.size,
        range: 8 ... 28,
        label: { "Dot size: \(Int($0)) pt" },
        commit: { v in $config.withLock { $0.settings.marker.size = v } },
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

  /// A navigation target (recent / next / previous) shown like a workspace:
  /// one key equivalent plus a Switch / Assign / Borrow row, each combining
  /// that key with its global modifier and overridable by an explicit shortcut.
  @ViewBuilder
  func navTarget(
    _ title: String,
    description: String,
    key keyKP: WritableKeyPath<AppSettings.Shortcuts, String?>,
    switchAction: HotKeyAction,
    switchOverride: WritableKeyPath<AppSettings.Shortcuts, HotKey?>,
    assignAction: HotKeyAction,
    assignOverride: WritableKeyPath<AppSettings.Shortcuts, HotKey?>,
    borrowAction: HotKeyAction,
    borrowOverride: WritableKeyPath<AppSettings.Shortcuts, HotKey?>,
  ) -> some View {
    let shortcuts = config.settings.shortcuts
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
          Text(description).font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 12)
        Text("Key equivalent").font(.caption).foregroundStyle(.secondary)
        KeyEquivalentRecorder(
          key: shortcuts[keyPath: keyKP],
          modifierSymbols: "",
          conflict: { keyEquivalentConflict($0, switch: switchAction, assign: assignAction, borrow: borrowAction) },
          onRecordingChanged: { store.send(.shortcutRecordingChanged($0)) },
        ) { newKey in $config.withLock { $0.settings.shortcuts[keyPath: keyKP] = newKey } }
      }
      navDerivedRow("Switch", \.keyEquivalentModifiers, keyKP, switchOverride, switchAction)
      navDerivedRow("Assign", \.assignModifiers, keyKP, assignOverride, assignAction)
      navDerivedRow("Borrow", \.borrowModifiers, keyKP, borrowOverride, borrowAction)
    }
  }

  /// One action row under a nav target: the derived combo (its modifier + the
  /// target's key) and an explicit-shortcut override beside it.
  @ViewBuilder
  func navDerivedRow(
    _ label: String,
    _ modifiersKP: WritableKeyPath<AppSettings.Shortcuts, [String]>,
    _ keyKP: WritableKeyPath<AppSettings.Shortcuts, String?>,
    _ overrideKP: WritableKeyPath<AppSettings.Shortcuts, HotKey?>,
    _ action: HotKeyAction,
  ) -> some View {
    let shortcuts = config.settings.shortcuts
    let mods = HotKey.modifierSymbols(from: shortcuts[keyPath: modifiersKP])
    let key = shortcuts[keyPath: keyKP]
    let combo = (key?.isEmpty == false) && !mods.isEmpty ? mods + HotKey.keySymbol(forName: key ?? "") : ""
    let hasOverride = shortcuts[keyPath: overrideKP] != nil
    HStack(spacing: 10) {
      Text(label)
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(width: 56, alignment: .leading)
      ComboCapsule(text: combo, dimmed: hasOverride)
      Text("or").font(.caption).foregroundStyle(.tertiary)
      ShortcutRecorder(
        hotKey: shortcuts[keyPath: overrideKP],
        conflict: { config.shortcutConflict(for: $0, excluding: action) },
        onRecordingChanged: { store.send(.shortcutRecordingChanged($0)) },
      ) { hotKey in $config.withLock { $0.settings.shortcuts[keyPath: overrideKP] = hotKey } }
      Spacer()
    }
    .padding(.leading, 12)
  }

  /// Conflict title for a candidate key equivalent. The key generates three
  /// combos — switch / assign / borrow modifier + key — each checked against
  /// every other binding (excluding this target's matching action). Nil when
  /// all three are free / unbound.
  func keyEquivalentConflict(
    _ char: String,
    switch switchAction: HotKeyAction,
    assign assignAction: HotKeyAction,
    borrow borrowAction: HotKeyAction,
  ) -> String? {
    guard let code = HotKey.keyCode(forName: char) else { return nil }
    let s = config.settings.shortcuts
    func check(_ tokens: [String], _ exclude: HotKeyAction) -> String? {
      let mods = HotKey.carbonModifiers(from: tokens)
      guard mods != 0 else { return nil }
      return config.shortcutConflict(
        for: HotKey(carbonKeyCode: code, carbonModifiers: mods),
        excluding: exclude,
      )
    }
    return check(s.keyEquivalentModifiers, switchAction)
      ?? check(s.assignModifiers, assignAction)
      ?? check(s.borrowModifiers, borrowAction)
  }

  /// A labeled row of modifier toggle buttons (⌃⌥⇧⌘) editing one modifier
  /// list (e.g. switch vs assign).
  func modifierToggleRow(
    _ title: String,
    _ keyPath: WritableKeyPath<AppSettings.Shortcuts, [String]>,
    description: String,
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
  func modifierToggle(
    _ symbol: String,
    _ token: String,
    _ keyPath: WritableKeyPath<AppSettings.Shortcuts, [String]>,
  ) -> some View {
    Toggle(symbol, isOn: Binding(
      get: { config.settings.shortcuts[keyPath: keyPath].contains(token) },
      set: { on in
        $config.withLock { c in
          var mods = c.settings.shortcuts[keyPath: keyPath].filter { $0 != token }
          if on { mods.append(token) }
          c.settings.shortcuts[keyPath: keyPath] = mods
        }
      },
    ))
    .toggleStyle(.button)
  }

  @ViewBuilder
  func shortcut(
    _ title: String,
    _ action: HotKeyAction,
    _ keyPath: WritableKeyPath<AppSettings.Shortcuts, HotKey?>,
    description: String? = nil,
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
        onRecordingChanged: { store.send(.shortcutRecordingChanged($0)) },
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

// MARK: - GestureBindingsSection

private struct GestureBindingsSection: View {
  let title: LocalizedStringResource
  @Binding var bindings: AppSettings.GestureBindings

  let isEnabled: Bool
  let config: AppConfig

  var body: some View {
    Section(title) {
      GestureBindingPicker(
        direction: .left,
        selection: $bindings.left,
        config: config,
      )
      GestureBindingPicker(
        direction: .right,
        selection: $bindings.right,
        config: config,
      )
      GestureBindingPicker(
        direction: .up,
        selection: $bindings.up,
        config: config,
      )
      GestureBindingPicker(
        direction: .down,
        selection: $bindings.down,
        config: config,
      )
    }
    .disabled(!isEnabled)
  }
}

// MARK: - GestureBindingPicker

private struct GestureBindingPicker: View {

  // MARK: Internal

  let direction: GestureDirection
  @Binding var selection: GestureAction

  let config: AppConfig

  var body: some View {
    LabeledContent {
      Menu {
        ForEach(GestureAction.Category.allCases) { category in
          if !category.actions.isEmpty {
            Section(category.title) {
              ForEach(category.actions) { action in
                actionButton(action)
              }
            }
          }
        }
        if !config.profiles.isEmpty {
          Section("Profiles & Workspaces") {
            ForEach(config.profiles) { profile in
              Menu(profile.name) {
                actionButton(.activateProfile(profile.id))
                if !profile.workspaces.isEmpty {
                  Divider()
                  ForEach(profile.workspaces) { workspace in
                    Menu(workspace.name) {
                      actionButton(.activateWorkspace(workspace.id))
                      actionButton(.assignAppToWorkspace(workspace.id))
                      if profile.id == config.activeProfile?.id {
                        actionButton(.borrowWorkspace(workspace.id))
                      }
                    }
                  }
                }
              }
            }
          }
        }
        if !selection.isAvailable(in: config) {
          Section("Unavailable") {
            actionButton(selection)
          }
        }
      } label: {
        Text(selection.title(in: config))
      }
      .menuStyle(.borderlessButton)
      .fixedSize(horizontal: true, vertical: false)
    } label: {
      Label {
        Text(direction.title)
      } icon: {
        Image(systemName: direction.symbolName)
      }
    }
  }

  // MARK: Private

  private func actionButton(_ action: GestureAction) -> some View {
    Button {
      selection = action
    } label: {
      if action == selection {
        Label {
          Text(action.title(in: config))
        } icon: {
          Image(systemName: "checkmark")
        }
      } else {
        Text(action.title(in: config))
      }
    }
  }

}
