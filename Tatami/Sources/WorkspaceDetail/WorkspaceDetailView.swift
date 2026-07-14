import AppKit
import ComposableArchitecture
import SFSafeSymbols
import SwiftUI
import TatamiKit

/// The sibling activation store's per-workspace slice, mirrored into the layout
/// reducer. Equatable so `.onChange` only fires on real changes.
private struct ActivationSlice: Equatable {
  var liveTree: BSPNode<WindowKey>?
  var liveZoomed: Set<WindowKey>
  var isActive: Bool
}

struct WorkspaceDetailView: View {
  @Bindable var store: StoreOf<WorkspaceDetailFeature>
  let activationStore: StoreOf<WorkspaceActivationFeature>
  @State private var nameDraft: String = ""
  @FocusState private var nameFieldFocused: Bool
  @State private var symbolPickerPresented = false
  /// App row briefly tinted after a "Configure in Apps" jump, so the user's eye
  /// lands on the right row.
  @State private var highlightedApp: String?
  private let highlightFlash: Duration = .seconds(1.6)

  /// True when *this* workspace is the currently-active one on any
  /// display. Drives the toolbar Activate button's disabled state.
  private func isActive(_ workspace: Workspace) -> Bool {
    activationStore.activeWorkspacesByDisplay.values.contains(workspace.id)
  }

  private func activationSlice(_ id: Workspace.ID) -> ActivationSlice {
    ActivationSlice(
      liveTree: activationStore.tilingTrees[id],
      liveZoomed: activationStore.fullscreenZoomed[id] ?? [],
      isActive: activationStore.activeWorkspacesByDisplay.values.contains(id)
    )
  }

  /// Conflict title for a candidate key equivalent on this workspace. The one
  /// key generates three combos — switch+key (activate), assign+key, borrow+key
  /// — so each is checked against every other binding (excluding this
  /// workspace's matching action). Nil when all three are free / unbound.
  private func keyEquivalentConflict(_ char: String) -> String? {
    guard let code = HotKey.keyCode(forName: char) else { return nil }
    let s = store.config.settings.shortcuts
    func combo(_ tokens: [String]) -> HotKey? {
      let mods = HotKey.carbonModifiers(from: tokens)
      return mods == 0 ? nil : HotKey(carbonKeyCode: code, carbonModifiers: mods)
    }
    if let hk = combo(s.keyEquivalentModifiers),
       let owner = store.state.activateShortcutConflict(for: hk) { return owner }
    if let hk = combo(s.assignModifiers),
       let owner = store.state.assignShortcutConflict(for: hk) { return owner }
    if let hk = combo(s.borrowModifiers),
       let owner = store.state.borrowShortcutConflict(for: hk) { return owner }
    return nil
  }

  /// A shortcut row whose default is "modifier + the workspace key equivalent"
  /// (shown read-only in a capsule) with an explicit-shortcut override beside.
  @ViewBuilder
  private func derivedShortcutRow(
    _ title: String,
    modifiers: [String],
    key: String?,
    override: HotKey?,
    conflict: @escaping (HotKey) -> String?,
    onOverride: @escaping (HotKey?) -> Void
  ) -> some View {
    HStack(spacing: 10) {
      Text(title)
      Spacer(minLength: 12)
      let mods = HotKey.modifierSymbols(from: modifiers)
      let combo = (key?.isEmpty == false) && !mods.isEmpty ? mods + HotKey.keySymbol(forName: key ?? "") : ""
      ComboCapsule(text: combo, dimmed: override != nil)
      Text("or")
        .font(.caption)
        .foregroundStyle(.tertiary)
      ShortcutRecorder(
        hotKey: override,
        conflict: conflict,
        onRecordingChanged: { store.send(.shortcutRecordingChanged($0)) }
      ) { onOverride($0) }
    }
  }

  var body: some View {
    if let workspace = store.workspace {
      ScrollViewReader { proxy in
      Form {
        Section {
          WorkspaceLayoutPreview(store: store.scope(state: \.layout, action: \.layout))
        } header: {
          Text("Layout")
        }

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

          // Key equivalent — the workspace's single key. Combined with the
          // switch / assign / borrow modifiers below for those actions.
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
              Text("Key equivalent")
              Spacer(minLength: 12)
              KeyEquivalentRecorder(
                key: workspace.keyEquivalent,
                modifierSymbols: "",
                conflict: { keyEquivalentConflict($0) },
                onRecordingChanged: { store.send(.shortcutRecordingChanged($0)) }
              ) { store.send(.keyEquivalentChanged($0)) }
            }
            Text("One key for this workspace — hold it with the switch / assign / borrow modifier (Settings → Workspace Keys) to run each action.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          }

          // Kind — normal vs scratchpad.
          Picker(
            selection: Binding(
              get: { workspace.kind },
              set: { store.send(.kindChanged($0)) }
            )
          ) {
            ForEach(WorkspaceKind.allCases, id: \.self) { kind in
              Text(kind.displayName).tag(kind)
            }
          } label: {
            Text("Kind")
            Text(workspace.kind == .scratchpad
              ? "Borrow-only: excluded from cycling and never activated on its own — pull it in beside another workspace with a borrow."
              : "A normal workspace you switch to and cycle through. Borrow mode summons it by this key (h/j/k/l steer direction, so a workspace keyed to one isn't borrow-summonable).")
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
              layoutBinding: Binding(
                get: { assignment.layout },
                set: { value in
                  store.send(
                    .layoutChanged(bundleIdentifier: assignment.bundleIdentifier, layout: value)
                  )
                }
              ),
              showLayoutOptions: workspace.kind != .scratchpad,
              onRemove: {
                store.send(.appRemoveRequested(bundleIdentifier: assignment.bundleIdentifier))
              }
            )
            .id("app-\(assignment.bundleIdentifier)")
            .listRowBackground(
              highlightedApp == assignment.bundleIdentifier
                ? Color.accentColor.opacity(0.18) : nil
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

        Section {
          // Each action derives from the workspace key (its modifier in
          // Settings → Workspace Keys); the recorder beside it overrides that.
          // Activate / Assign are meaningless for a borrow-only scratchpad.
          if workspace.kind != .scratchpad {
            derivedShortcutRow(
              "Activate",
              modifiers: store.config.settings.shortcuts.keyEquivalentModifiers,
              key: workspace.keyEquivalent,
              override: workspace.activateShortcut,
              conflict: { store.state.activateShortcutConflict(for: $0) },
              onOverride: { store.send(.activateShortcutChanged($0)) }
            )
            derivedShortcutRow(
              "Assign focused app here",
              modifiers: store.config.settings.shortcuts.assignModifiers,
              key: workspace.keyEquivalent,
              override: workspace.assignAppShortcut,
              conflict: { store.state.assignShortcutConflict(for: $0) },
              onOverride: { store.send(.assignAppShortcutChanged($0)) }
            )
          }
          derivedShortcutRow(
            "Borrow",
            modifiers: store.config.settings.shortcuts.borrowModifiers,
            key: workspace.keyEquivalent,
            override: workspace.borrowShortcut,
            conflict: { store.state.borrowShortcutConflict(for: $0) },
            onOverride: { store.send(.borrowShortcutChanged($0)) }
          )
        } header: {
          HStack {
            Text("Shortcuts")
            Spacer()
            Button {
              store.send(.openWorkspaceKeysTapped)
            } label: {
              Label("Workspace Keys", systemImage: "keyboard")
                .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Edit the switch / assign / borrow modifiers these combine with, in Settings → Workspace Keys.")
          }
        } footer: {
          Text("Each uses its modifier (Settings → Workspace Keys) + this workspace's key equivalent; record a shortcut to override. Borrow pulls this workspace in beside the current one — then a direction key places it unless a default is set below.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section("Borrow Placement") {
          let globalEdge = store.config.settings.switching.borrowDefaultEdge
          let globalEdgeLabel = globalEdge?.rawValue.capitalized ?? "Ask"
          let globalFraction = store.config.settings.switching.borrowFraction
          Picker(
            selection: Binding(
              get: { workspace.borrowEdge },
              set: { store.send(.borrowEdgeChanged($0)) }
            )
          ) {
            Text("Use Global (\(globalEdgeLabel))").tag(BorrowEdge?.none)
            Divider()
            ForEach(BorrowEdge.allCases, id: \.self) { edge in
              Text(edge.rawValue.capitalized).tag(BorrowEdge?.some(edge))
            }
          } label: {
            Text("Direction")
            Text("Where this workspace docks when borrowed. Change the global default in Settings.")
          }
          .pickerStyle(.menu)
          Picker(
            selection: Binding(
              get: { workspace.borrowFraction },
              set: { store.send(.borrowFractionChanged($0)) }
            )
          ) {
            Text("Use Global (\(Int((globalFraction * 100).rounded()))%)").tag(Double?.none)
            Divider()
            ForEach([0.3, 0.4, 0.5, 0.6, 0.7], id: \.self) { f in
              Text("\(Int((f * 100).rounded()))%").tag(Double?.some(f))
            }
          } label: {
            Text("Size")
            Text("This workspace's share of the screen when borrowed.")
          }
          .pickerStyle(.menu)
        }

        if workspace.kind != .scratchpad {
          DisplayPickerSection(
            availableDisplays: store.availableDisplays,
            selectedHint: workspace.displayHint,
            onSelect: { store.send(.displayHintChanged($0)) }
          )
        }

        if workspace.kind != .scratchpad {
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
      // Mirror the sibling activation store's slice for this workspace into the
      // layout reducer (it can't read the activation subtree directly). The
      // Equatable gate fires only on real changes to this workspace's tree /
      // zoom / active state.
      .onChange(of: activationSlice(workspace.id), initial: true) { _, slice in
        store.send(.layout(.activationObserved(
          liveTree: slice.liveTree, liveZoomed: slice.liveZoomed, isActive: slice.isActive
        )))
      }
      // Refresh the pinned-display picker when monitors are plugged/unplugged.
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
      ) { _ in store.send(.refreshDisplays) }
      .alert($store.scope(state: \.alert, action: \.alert))
      // A "Configure in Apps" jump: scroll the Apps section to the row and
      // flash it. Keyed on the request token so repeat jumps refire.
      .task(id: store.appScrollRequest?.token) {
        guard let request = store.appScrollRequest else { return }
        withAnimation { proxy.scrollTo("app-\(request.bundleId)", anchor: .center) }
        withAnimation { highlightedApp = request.bundleId }
        try? await Task.sleep(for: highlightFlash)
        withAnimation { highlightedApp = nil }
      }
      } // ScrollViewReader
    } else {
      ContentUnavailableView(
        "Workspace Unavailable",
        systemImage: "exclamationmark.triangle",
        description: Text("This workspace no longer exists.")
      )
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
  let layoutBinding: Binding<LayoutMode>
  /// Layout + auto-open are meaningless for a borrow-only scratchpad (only
  /// tiled apps take part when borrowed, and it never activates), so hide them.
  var showLayoutOptions: Bool = true
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
      if showLayoutOptions {
        Picker("Layout", selection: layoutBinding) {
          Text("Tiled").tag(LayoutMode.tiled)
          Text("Float").tag(LayoutMode.floating)
          Text("Ignore").tag(LayoutMode.unmanaged)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
        .help("Tiled: laid out in the BSP tree. Float: mirrored above the tiles. Ignore: left where it is — still a member (focus, FFM, cycling), no Screen Recording.")
        HStack(spacing: 6) {
          Text("Auto-open")
            .font(.caption)
            .foregroundStyle(.secondary)
          Toggle("Auto-open", isOn: autoOpenBinding)
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .help("Launch this app automatically when the workspace activates, if it isn't already running.")
      }
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
    if let image = Self.resolvedIcon(bundleIdentifier: bundleIdentifier, iconPath: iconPath) {
      Image(nsImage: image)
        .resizable()
        .scaledToFit()
    } else {
      Image(systemName: "app.dashed")
        .foregroundStyle(.secondary)
    }
  }

  /// Decoding an icon from disk (`NSImage(contentsOfFile:)`) or resolving it
  /// via `NSWorkspace` ran on every `body` pass — in the app lists each row
  /// re-decoded its icon on every keystroke/scroll. Memoize by icon path
  /// (else bundle id) so a given icon is decoded once.
  private static let cache = NSCache<NSString, NSImage>()

  private static func resolvedIcon(bundleIdentifier: String, iconPath: String?) -> NSImage? {
    let key = (iconPath ?? bundleIdentifier) as NSString
    if let hit = cache.object(forKey: key) { return hit }
    let image: NSImage? =
      if let iconPath, let fromFile = NSImage(contentsOfFile: iconPath) {
        fromFile
      } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
        NSWorkspace.shared.icon(forFile: url.path)
      } else {
        nil
      }
    if let image { cache.setObject(image, forKey: key) }
    return image
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
      // Always a List so the title + search bar stay anchored at the top; the
      // empty state overlays it centered (a bare ContentUnavailableView shrank
      // the content and let the navigation title float to the middle).
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
      .overlay {
        if filtered.isEmpty {
          ContentUnavailableView {
            Label(apps.isEmpty ? "No Running Apps" : "No Matches", systemImage: "magnifyingglass")
          } description: {
            Text(apps.isEmpty
              ? "Use “Choose from Files…” to add an app that isn't running."
              : "No running app matches “\(query)”.")
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
