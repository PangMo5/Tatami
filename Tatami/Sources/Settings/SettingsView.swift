import KeyboardShortcuts
import Sharing
import SwiftUI
import TatamiKit

/// Edits global `AppSettings` backed directly by the shared TOML config.
/// Writes go through `$config.withLock` so they persist immediately.
struct SettingsView: View {
  @Shared(.tatamiConfig) private var config = AppConfig()

  var body: some View {
    Form {
      Section("Gaps") {
        Stepper(value: setting(\.gapInner), in: 0 ... 100) {
          Text("Inner gap: \(config.settings.gapInner) px")
          Text("Space between adjacent tiled windows.")
        }
        Stepper(value: setting(\.gapOuter), in: 0 ... 100) {
          Text("Outer gap: \(config.settings.gapOuter) px")
          Text("Space between the tiles and the screen edge.")
        }
      }

      Section("Layout") {
        Toggle(isOn: setting(\.autoBalance)) {
          Text("Auto-balance")
          Text("Equalize every split whenever a window is added or removed.")
        }
        Picker(selection: setting(\.defaultTilingMemory)) {
          ForEach(TilingMemory.allCases, id: \.self) { memory in
            Text(memory.displayName).tag(memory)
          }
        } label: {
          Text("Default tiling memory")
          Text("How workspaces remember their layout unless they override it.")
        }
      }

      Section("Mouse & Focus") {
        Toggle(isOn: setting(\.mouseFollowsFocus)) {
          Text("Mouse follows focus")
          Text("Move the cursor to the focused window when you switch workspaces.")
        }
        Toggle(isOn: setting(\.mouseHidesOnFocus)) {
          Text("Hide cursor on focus")
          Text("Hide the cursor on a workspace switch until you move the mouse.")
        }
        Toggle(isOn: setting(\.focusFollowsMouse)) {
          Text("Focus follows mouse")
          Text("Focus whatever window sits under the cursor as it moves.")
        }
        Picker(selection: setting(\.focusFollowsMouseDisableHotkey)) {
          ForEach(FocusFollowsMouseModifier.allCases, id: \.self) { modifier in
            Text(modifier.displayName).tag(modifier)
          }
        } label: {
          Text("Suspend with modifier")
          Text("Hold this key to temporarily pause focus-follows-mouse.")
        }
        .disabled(!config.settings.focusFollowsMouse)
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
      }

      Section("Windows & Workspaces") {
        shortcut("Cycle next window", .cycleNextWindow, \.cycleNextWindow)
        shortcut("Cycle previous window", .cyclePreviousWindow, \.cyclePreviousWindow)
        shortcut("Next workspace", .switchToNextWorkspace, \.switchToNextWorkspace)
        shortcut("Previous workspace", .switchToPreviousWorkspace, \.switchToPreviousWorkspace)
        shortcut("Recent workspace", .switchToRecentWorkspace, \.switchToRecentWorkspace)
      }

      Section("Toggles") {
        shortcut("Toggle floating", .toggleFloating, \.toggleFloating)
        shortcut("Toggle tiling (pause)", .toggleSpaceActivated, \.toggleSpaceActivated)
      }

      Section("Gestures") {
        Toggle(isOn: setting(\.swipeGesturesEnabled)) {
          Text("Swipe to switch workspaces")
          Text("Swipe left/right on the trackpad to move to the next/previous workspace. (Restart to apply.)")
        }
        Picker(selection: setting(\.swipeFingerCount)) {
          Text("Three fingers").tag(3)
          Text("Four fingers").tag(4)
        } label: {
          Text("Fingers")
          Text("Number of fingers for the swipe gesture.")
        }
        .disabled(!config.settings.swipeGesturesEnabled)

        VStack(alignment: .leading, spacing: 4) {
          // Sensitivity is the inverse of the swipe-distance threshold:
          // higher sensitivity = shorter swipe needed. Map 0.1...0.8
          // threshold to a 0–100% display.
          let sensitivity = 0.9 - config.settings.swipeThreshold
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
              set: { v in $config.withLock { $0.settings.swipeThreshold = 0.9 - v } }
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
        .disabled(!config.settings.swipeGesturesEnabled)
      }

      Section("Updates") {
        Toggle(isOn: setting(\.checkForUpdatesAutomatically)) {
          Text("Check for updates automatically")
          Text("Periodically check for new Tatami releases.")
        }
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 460, minHeight: 520)
  }

  /// A recorder row bound to a global `HotKeyAction`. The recorder edits
  /// the shared KeyboardShortcuts slot directly (so the live handler
  /// updates immediately); `onChange` also mirrors it into the config so
  /// it persists.
  private func shortcut(
    _ title: String,
    _ action: HotKeyAction,
    _ keyPath: WritableKeyPath<AppSettings, HotKey?>
  ) -> some View {
    KeyboardShortcuts.Recorder(title, name: action.keyboardShortcutName) { shortcut in
      $config.withLock { $0.settings[keyPath: keyPath] = shortcut.map(HotKey.init) }
    }
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
