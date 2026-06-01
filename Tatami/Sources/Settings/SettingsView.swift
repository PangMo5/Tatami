import ComposableArchitecture
import KeyboardShortcuts
import Sharing
import SwiftUI
import TatamiKit

/// Edits global `AppSettings` (declarative `@Shared` config bindings) and
/// drives the system-touching bits — CLI install, Accessibility, updates —
/// through `SettingsFeature`.
struct SettingsView: View {
  @Shared(.tatamiConfig) private var config = AppConfig()
  @State private var store = Store(initialState: SettingsFeature.State()) {
    SettingsFeature()
  }

  var body: some View {
    Form {
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
        if !store.hasAXPermission {
          HStack {
            Text("macOS only applies a new grant after a relaunch.")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Button("Relaunch Tatami") { store.send(.relaunchTapped) }
          }
        }
      }

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

      Section("Mouse & Focus") {
        Toggle(isOn: setting(\.focus.mouseFollowsFocus)) {
          Text("Mouse follows focus")
          Text("Move the cursor to the focused window when you switch workspaces.")
        }
        Toggle(isOn: setting(\.focus.mouseHidesOnFocus)) {
          Text("Hide cursor on focus")
          Text("Hide the cursor on a workspace switch until you move the mouse.")
        }
        Toggle(isOn: setting(\.focus.focusFollowsMouse)) {
          Text("Focus follows mouse")
          Text("Focus whatever window sits under the cursor as it moves.")
        }
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
        shortcut("Toggle orientation", .toggleOrientation, \.toggleOrientation)
        shortcut("Toggle fullscreen", .toggleFullscreen, \.toggleFullscreen)
        shortcut("Balance", .balance, \.balance)
      }

      Section("Windows & Workspaces") {
        shortcut("Cycle next window", .cycleNextWindow, \.cycleNextWindow)
        shortcut("Cycle previous window", .cyclePreviousWindow, \.cyclePreviousWindow)
        shortcut("Next workspace", .switchToNextWorkspace, \.switchToNextWorkspace)
        shortcut("Previous workspace", .switchToPreviousWorkspace, \.switchToPreviousWorkspace)
        shortcut("Recent workspace", .switchToRecentWorkspace, \.switchToRecentWorkspace)
        shortcut("Move app to next workspace", .moveFocusedAppToNextWorkspace, \.moveToNextWorkspace)
        shortcut(
          "Move app to previous workspace",
          .moveFocusedAppToPreviousWorkspace,
          \.moveToPreviousWorkspace
        )
        shortcut("Focus next display", .focusNextDisplay, \.focusNextDisplay)
        shortcut("Focus previous display", .focusPreviousDisplay, \.focusPreviousDisplay)
      }

      Section("Toggles") {
        shortcut("Toggle floating", .toggleFloating, \.toggleFloating)
        shortcut("Toggle tiling (pause)", .toggleSpaceActivated, \.toggleSpaceActivated)
        shortcut(
          "Toggle app in workspace",
          .toggleFocusedAppInActiveWorkspace,
          \.toggleFocusedAppInActiveWorkspace
        )
      }

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
          // Sensitivity is the inverse of the swipe-distance threshold:
          // higher sensitivity = shorter swipe needed. Map 0.1...0.8
          // threshold to a 0–100% display.
          let sensitivity = 0.9 - config.settings.gestures.threshold
          HStack {
            Text("Sensitivity")
            Spacer()
            Text("\(Int((sensitivity / 0.8 * 100).rounded()))%")
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
          Slider(
            value: Binding(
              get: { sensitivity },
              set: { v in $config.withLock { $0.settings.gestures.threshold = 0.9 - v } }
            ),
            in: 0.1 ... 0.8
          ) {
            Text("Sensitivity")
          } minimumValueLabel: {
            Text("Low")
          } maximumValueLabel: {
            Text("High")
          }
          Text("How far you must swipe to switch — higher sensitivity needs a shorter swipe.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .disabled(!config.settings.gestures.enabled)
      }

      Section("Menu Bar") {
        Toggle(isOn: setting(\.menuBar.showWorkspaceName)) {
          Text("Show workspace name")
          Text("Display the active workspace's name next to its icon in the menu bar.")
        }
      }

      Section("Overlay") {
        Toggle(isOn: setting(\.hud.enabled)) {
          Text("Show workspace HUD")
          Text("Display a brief overlay with the workspace name when switching.")
        }
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
          Text("Show a small color dot on windows of apps in your floating list.")
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
    .formStyle(.grouped)
    .frame(minWidth: 460, minHeight: 520)
    // All side effects (status reads, permission/CLI/update streams, the AX
    // change subscription) live in the reducer — the view just starts it.
    .task { await store.send(.task).finish() }
  }

  /// One-line status describing where the CLI is (or would be) installed.
  private var cliStatusDetail: String {
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

  /// A recorder row bound to a global `HotKeyAction`. The recorder edits
  /// the shared KeyboardShortcuts slot directly (so the live handler
  /// updates immediately); the callback also mirrors it into the config's
  /// `shortcuts` group so it persists.
  private func shortcut(
    _ title: String,
    _ action: HotKeyAction,
    _ keyPath: WritableKeyPath<AppSettings.Shortcuts, HotKey?>
  ) -> some View {
    KeyboardShortcuts.Recorder(title, name: action.keyboardShortcutName) { shortcut in
      $config.withLock { $0.settings.shortcuts[keyPath: keyPath] = shortcut.map(HotKey.init) }
    }
  }

  /// SwiftUI `Color` binding backed by a hex-string field in settings.
  private func borderColorBinding(
    _ keyPath: WritableKeyPath<AppSettings, String>
  ) -> Binding<Color> {
    Binding(
      get: { Color(hex: config.settings[keyPath: keyPath]) ?? .blue },
      set: { newColor in
        guard let hex = newColor.toHex() else { return }
        $config.withLock { $0.settings[keyPath: keyPath] = hex }
      }
    )
  }

  /// Two-way binding for a single `AppSettings` field, persisted through
  /// the shared config's lock.
  private func setting<Value>(
    _ keyPath: WritableKeyPath<AppSettings, Value>
  ) -> Binding<Value> {
    Binding(
      get: { config.settings[keyPath: keyPath] },
      set: { newValue in
        $config.withLock { $0.settings[keyPath: keyPath] = newValue }
      }
    )
  }

}

/// A `Stepper` whose value lives in local `@State`, committed to the shared
/// config on a short debounce. Binding a `Stepper` directly to the observed
/// `@Shared` config made a single click run away: each step wrote the config,
/// which synchronously re-rendered the whole `SettingsView` (its label also
/// reads the config), and that re-render churned the Stepper's press tracking
/// so it auto-repeated to the range bound. Stepping local `@State` keeps the
/// press loop free of the observed store; the debounced `commit` persists once
/// the user stops.
private struct DebouncedStepper<V: Strideable>: View {
  let external: V
  let range: ClosedRange<V>
  let step: V.Stride
  let detail: String?
  let label: (V) -> String
  let commit: (V) -> Void
  @State private var local: V

  init(
    external: V,
    range: ClosedRange<V>,
    step: V.Stride = 1,
    detail: String? = nil,
    label: @escaping (V) -> String,
    commit: @escaping (V) -> Void
  ) {
    self.external = external
    self.range = range
    self.step = step
    self.detail = detail
    self.label = label
    self.commit = commit
    _local = State(initialValue: external)
  }

  var body: some View {
    Stepper(value: $local, in: range, step: step) {
      Text(label(local))
      if let detail { Text(detail) }
    }
    // Persist after the user stops stepping. `.task(id:)` cancels the prior
    // run whenever `local` changes, so rapid steps coalesce into one write.
    .task(id: local) {
      guard local != external else { return }
      try? await Task.sleep(for: .milliseconds(120))
      guard !Task.isCancelled else { return }
      commit(local)
    }
    // Reflect external changes (config edited elsewhere) back into the value.
    .onChange(of: external) { _, newValue in
      if newValue != local { local = newValue }
    }
  }
}

extension FocusFollowsMouseModifier {
  var displayName: String {
    switch self {
    case .none: "None"
    case .option: "Option (⌥)"
    case .command: "Command (⌘)"
    case .control: "Control (⌃)"
    case .shift: "Shift (⇧)"
    }
  }
}
