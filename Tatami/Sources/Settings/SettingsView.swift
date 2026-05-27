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

      Section("Updates") {
        Toggle(isOn: setting(\.checkForUpdatesAutomatically)) {
          Text("Check for updates automatically")
          Text("Periodically check for new Tatami releases.")
        }
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 440, minHeight: 420)
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
