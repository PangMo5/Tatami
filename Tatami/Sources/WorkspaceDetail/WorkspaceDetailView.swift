import AppKit
import ComposableArchitecture
import KeyboardShortcuts
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
          // Icon picker — opens the SF Symbol grid on tap.
          LabeledContent("Icon") {
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
          LabeledContent("Name") {
            TextField("", text: $nameDraft)
              .textFieldStyle(.roundedBorder)
              .focused($nameFieldFocused)
              .onSubmit { store.send(.nameSubmitted(nameDraft)) }
              .onChange(of: nameFieldFocused) { _, focused in
                if !focused { store.send(.nameSubmitted(nameDraft)) }
              }
          }
        }

        Section("Activation Shortcut") {
          KeyboardShortcuts.Recorder(
            for: KeyboardShortcuts.Name("tatami.workspace.\(workspace.id.uuidString)")
          ) { shortcut in
            store.send(.activateShortcutChanged(shortcut.map(HotKey.init)))
          }
        }

        DisplayPickerSection(store: store, workspace: workspace)

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
          onCancel: { store.send(.appPickerDismissed) }
        )
      }
      .onAppear { nameDraft = workspace.name }
      .onChange(of: workspace.id) { _, _ in nameDraft = workspace.name }
      .task { store.send(.onAppear) }
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

extension TilingMemory {
  var displayName: String {
    switch self {
    case .session: "Session"
    case .persistent: "Persistent"
    }
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
  let store: StoreOf<WorkspaceDetailFeature>
  let workspace: Workspace

  var body: some View {
    Section("Display") {
      Picker("Pinned display", selection: binding) {
        Text("Dynamic (follow apps)").tag(DisplayName?.none)
        ForEach(store.availableDisplays, id: \.self) { display in
          Text(display.rawValue).tag(DisplayName?.some(display))
        }
      }
      .pickerStyle(.menu)
    }
  }

  private var binding: Binding<DisplayName?> {
    Binding(
      get: { workspace.displayHint },
      set: { store.send(.displayHintChanged($0)) }
    )
  }
}

private struct AppRow: View {
  let assignment: AppAssignment
  let autoOpenBinding: Binding<Bool>
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

private struct AppIcon: View {
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

private struct AppPickerSheet: View {
  let apps: [MacApp]
  let onSelect: (MacApp) -> Void
  let onCancel: () -> Void

  var body: some View {
    NavigationStack {
      List(apps, id: \.bundleIdentifier) { app in
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
      .navigationTitle("Add Running App")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: onCancel)
        }
      }
    }
    .frame(width: 420, height: 480)
  }
}
