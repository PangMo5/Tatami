import AppKit
import ComposableArchitecture
import SFSafeSymbols
import SwiftUI
import TatamiKit

struct WorkspaceDetailView: View {
  @Bindable var store: StoreOf<WorkspaceDetailFeature>
  let activationStore: StoreOf<WorkspaceActivationFeature>
  @State private var nameDraft: String = ""
  @FocusState private var nameFieldFocused: Bool
  @State private var symbolPickerPresented = false

  /// True when *this* workspace is the currently-active one on any
  /// display. Drives the toolbar Activate button's disabled state.
  private func isActive(_ workspace: Workspace) -> Bool {
    activationStore.activeWorkspacesByDisplay.values.contains(workspace.id)
  }

  var body: some View {
    if let workspace = store.workspace {
      Form {
        Section("Workspace") {
          // Icon picker — opens the SF Symbol grid on tap. Plain HStack with
          // center alignment so the label sits vertically centered against
          // the icon (LabeledContent aligns to the text baseline, which
          // floats the label above taller controls).
          HStack {
            Text("Icon")
            Spacer()
            Button {
              symbolPickerPresented = true
            } label: {
              Image(systemName: workspace.symbolIconName ?? "square.stack.3d.up")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Choose an icon for this workspace.")
            .sheet(isPresented: $symbolPickerPresented) {
              SymbolPicker(
                selected: workspace.symbolIconName,
                onSelect: { store.send(.symbolIconChanged($0)) }
              )
            }
          }

          // Name — separate row, commits on blur or Return.
          HStack {
            Text("Name")
            Spacer(minLength: 16)
            TextField("", text: $nameDraft)
              .textFieldStyle(.roundedBorder)
              .frame(maxWidth: 360)
              .focused($nameFieldFocused)
              .onSubmit { store.send(.nameSubmitted(nameDraft)) }
              .onChange(of: nameFieldFocused) { _, focused in
                if !focused { store.send(.nameSubmitted(nameDraft)) }
              }
          }
        }

        Section {
          // Centered HStack, not LabeledContent — its baseline-aligned label
          // floats above the taller recorder capsule.
          HStack {
            Text("Activate")
            Spacer(minLength: 16)
            ShortcutRecorder(
              hotKey: workspace.activateShortcut,
              conflict: { store.state.activateShortcutConflict(for: $0) },
              onRecordingChanged: { store.send(.shortcutRecordingChanged($0)) }
            ) { store.send(.activateShortcutChanged($0)) }
          }
          HStack {
            Text("Assign focused app here")
            Spacer(minLength: 16)
            ShortcutRecorder(
              hotKey: workspace.assignAppShortcut,
              conflict: { store.state.assignShortcutConflict(for: $0) },
              onRecordingChanged: { store.send(.shortcutRecordingChanged($0)) }
            ) { store.send(.assignAppShortcutChanged($0)) }
          }
        } header: {
          Text("Shortcuts")
        } footer: {
          Text("Assign adds the focused app to this workspace (keeping it in any workspace it's already in) and switches here.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        DisplayPickerSection(
          availableDisplays: store.availableDisplays,
          selectedHint: workspace.displayHint,
          onSelect: { store.send(.displayHintChanged($0)) }
        )

        Section("Tiling Memory") {
          let globalDefault = store.config.settings.layout.defaultTilingMemory
          Picker(
            selection: Binding(
              get: { workspace.tilingMemory },
              set: { store.send(.tilingMemoryChanged($0)) }
            )
          ) {
            Text("Use Global (\(globalDefault.displayName))").tag(TilingMemory?.none)
            Divider()
            ForEach(TilingMemory.allCases, id: \.self) { memory in
              Text(memory.displayName).tag(TilingMemory?.some(memory))
            }
          } label: {
            Text("Remember layout")
            Text(workspace.tilingMemory.map(memoryDescription)
              ?? "Follow the global default — \(globalDefault.displayName). Change it in Settings.")
          }
          .pickerStyle(.menu)
        }

        Section("On Activation") {
          Picker(
            selection: Binding(
              get: { workspace.appToFocusBundleId },
              set: { store.send(.appToFocusChanged($0)) }
            )
          ) {
            Text("Most recently used").tag(String?.none)
            ForEach(workspace.apps, id: \.bundleIdentifier) { app in
              Text(app.name).tag(String?.some(app.bundleIdentifier))
            }
          } label: {
            Text("Focus app")
            Text("Which assigned app gets focus when this workspace activates.")
          }
          .pickerStyle(.menu)
        }

        Section {
          ForEach(store.apps) { assignment in
            AppRow(
              assignment: assignment,
              autoOpenBinding: Binding(
                get: { assignment.autoOpen },
                set: { value in
                  store.send(
                    .autoOpenToggled(bundleIdentifier: assignment.bundleIdentifier, isOn: value)
                  )
                }
              ),
              floatingBinding: Binding(
                get: { assignment.floating },
                set: { value in
                  store.send(
                    .floatingToggled(bundleIdentifier: assignment.bundleIdentifier, isOn: value)
                  )
                }
              ),
              onRemove: {
                store.send(.appRemoveRequested(bundleIdentifier: assignment.bundleIdentifier))
              }
            )
          }
        } header: {
          HStack {
            Text("Apps")
            Spacer()
            Button {
              store.send(.addAppButtonTapped)
            } label: {
              Label("Add", systemImage: "plus.circle")
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
          }
        } footer: {
          if store.apps.isEmpty {
            Text("No apps yet. Tap + to assign one.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle(workspace.name)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          let active = isActive(workspace)
          Button {
            activationStore.send(.activate(workspaceId: workspace.id, setFocus: true))
          } label: {
            Label(
              active ? "Active" : "Activate",
              systemImage: active ? "checkmark.circle.fill" : "play.fill"
            )
          }
          .disabled(active || activationStore.isActivating)
          .help(active ? "This workspace is already active." : "Activate this workspace.")
        }
      }
      .sheet(isPresented: $store.isAppPickerPresented) {
        AppPickerSheet(
          apps: store.availableRunningApps,
          onSelect: { app in store.send(.appPickerAppSelected(app)) },
          onChooseFile: { store.send(.chooseAppFileTapped) },
          onCancel: { store.send(.appPickerDismissed) }
        )
      }
      .onChange(of: workspace.id, initial: true) { _, _ in nameDraft = workspace.name }
      // Keyed on the workspace so re-running per selection re-fetches the
      // display list (a plain `.task` only fires on first appearance, which
      // left later workspaces' pickers showing just their own pinned display).
      .task(id: workspace.id) { store.send(.onAppear) }
      // Refresh the pinned-display picker when monitors are plugged/unplugged.
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
      ) { _ in store.send(.refreshDisplays) }
    } else {
      ContentUnavailableView(
        "Workspace Unavailable",
        systemImage: "exclamationmark.triangle",
        description: Text("This workspace no longer exists.")
      )
    }
  }
}

private func memoryDescription(_ memory: TilingMemory) -> String {
  switch memory {
  case .session: "Keep split ratios while the app runs; reset on restart."
  case .persistent: "Remember the layout across app restarts."
  }
}

/// Searchable SF Symbol picker backed by SFSafeSymbols' full catalog.
private struct SymbolPicker: View {
  let selected: String?
  let onSelect: (String?) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  // Full catalog, sorted once. Some entries require a newer OS than the
  // deployment target and just render blank — harmless for a picker.
  private static let allNames: [String] =
    SFSymbol.allSymbols.map(\.rawValue).sorted()

  private var filtered: [String] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return Self.allNames }
    return Self.allNames.filter { $0.localizedCaseInsensitiveContains(trimmed) }
  }

  private let columns = [GridItem(.adaptive(minimum: 40), spacing: 8)]

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Choose Icon").font(.headline)
        Spacer()
        Button("Reset") { onSelect(nil); dismiss() }
          .buttonStyle(.borderless)
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(.horizontal, 12)
      .padding(.top, 12)

      TextField("Search symbols", text: $query)
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)

      Divider()

      ScrollView {
        LazyVGrid(columns: columns, spacing: 8) {
          ForEach(filtered, id: \.self) { name in
            Button {
              onSelect(name)
              dismiss()
            } label: {
              Image(systemName: name)
                .font(.system(size: 18))
                .frame(width: 40, height: 40)
                .background(
                  RoundedRectangle(cornerRadius: 8)
                    .fill(name == selected ? Color.accentColor.opacity(0.3) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .help(name)
          }
        }
        .padding(12)
      }
    }
    .frame(width: 420, height: 460)
  }
}

private struct DisplayPickerSection: View {
  // Plain values passed by the parent (which is `@Bindable` and observes the
  // store), so this section reliably re-renders when the display list loads.
  let availableDisplays: [DisplayName]
  let selectedHint: DisplayName?
  let onSelect: (DisplayName?) -> Void

  var body: some View {
    Section {
      Picker("Pinned display", selection: binding) {
        Text("Dynamic (follow apps)").tag(DisplayName?.none)
        ForEach(pickerItems, id: \.self) { display in
          Text(display.name).tag(DisplayName?.some(display))
        }
      }
      .pickerStyle(.menu)
    } header: {
      Text("Display")
    } footer: {
      Text("Pin this workspace to always open on one display. Dynamic instead follows your apps — it opens on whichever display you're using.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  /// Connected displays, plus the pinned display itself when it's currently
  /// disconnected — so the picker can still show the existing selection.
  private var pickerItems: [DisplayName] {
    var items = availableDisplays
    if let hint = selectedHint, !items.contains(where: { $0.matches(hint) }) {
      items.append(hint)
    }
    return items
  }

  private var binding: Binding<DisplayName?> {
    Binding(
      get: {
        guard let hint = selectedHint else { return nil }
        // Resolve the hint to the actual picker item (UUID-or-name match) so a
        // legacy / name-only hint still highlights the right display.
        return pickerItems.first { $0.matches(hint) } ?? hint
      },
      set: { onSelect($0) }
    )
  }
}

private struct AppRow: View {
  let assignment: AppAssignment
  let autoOpenBinding: Binding<Bool>
  let floatingBinding: Binding<Bool>
  let onRemove: () -> Void

  var body: some View {
    HStack {
      AppIcon(bundleIdentifier: assignment.bundleIdentifier, iconPath: assignment.iconPath)
        .frame(width: 22, height: 22)
      VStack(alignment: .leading, spacing: 2) {
        Text(assignment.name)
          .font(.body)
        Text(assignment.bundleIdentifier)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      HStack(spacing: 6) {
        Text("Float")
          .font(.caption)
          .foregroundStyle(.secondary)
        Toggle("Float", isOn: floatingBinding)
          .labelsHidden()
          .toggleStyle(.switch)
      }
      .help("Keep this app untiled and above the tiles in this workspace.")
      HStack(spacing: 6) {
        Text("Auto-open")
          .font(.caption)
          .foregroundStyle(.secondary)
        Toggle("Auto-open", isOn: autoOpenBinding)
          .labelsHidden()
          .toggleStyle(.switch)
      }
      .help("Launch this app automatically when the workspace activates, if it isn't already running.")
      Button(role: .destructive, action: onRemove) {
        Image(systemName: "minus.circle.fill")
          .foregroundStyle(.red)
      }
      .buttonStyle(.borderless)
    }
  }
}

// Shared with SharedAppsView (same target), hence not file-private.
struct AppIcon: View {
  let bundleIdentifier: String
  let iconPath: String?

  var body: some View {
    if let iconPath, let image = NSImage(contentsOfFile: iconPath) {
      Image(nsImage: image)
        .resizable()
        .scaledToFit()
    } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    {
      Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
        .resizable()
        .scaledToFit()
    } else {
      Image(systemName: "app.dashed")
        .foregroundStyle(.secondary)
    }
  }
}

// Shared with SharedAppsView (same target), hence not file-private.
struct AppPickerSheet: View {
  let apps: [MacApp]
  let onSelect: (MacApp) -> Void
  /// Pick an app from disk instead of the running list.
  let onChooseFile: () -> Void
  let onCancel: () -> Void

  @State private var query = ""

  private var filtered: [MacApp] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return apps }
    return apps.filter {
      $0.name.localizedCaseInsensitiveContains(trimmed)
        || $0.bundleIdentifier.localizedCaseInsensitiveContains(trimmed)
    }
  }

  var body: some View {
    NavigationStack {
      Group {
        if filtered.isEmpty {
          ContentUnavailableView {
            Label(apps.isEmpty ? "No Running Apps" : "No Matches", systemImage: "magnifyingglass")
          } description: {
            Text(apps.isEmpty
              ? "Use “Choose from Files…” to add an app that isn't running."
              : "No running app matches “\(query)”.")
          }
        } else {
          List(filtered, id: \.bundleIdentifier) { app in
            Button {
              onSelect(app)
            } label: {
              HStack {
                AppIcon(bundleIdentifier: app.bundleIdentifier, iconPath: app.iconPath)
                  .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                  Text(app.name)
                  Text(app.bundleIdentifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
              }
            }
            .buttonStyle(.plain)
          }
        }
      }
      .navigationTitle("Add App")
      .searchable(text: $query, prompt: "Search running apps")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: onCancel)
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            onChooseFile()
          } label: {
            Label("Choose from Files…", systemImage: "folder")
          }
          .help("Pick an app from disk that isn't currently running.")
        }
      }
    }
    .frame(width: 420, height: 480)
  }
}
