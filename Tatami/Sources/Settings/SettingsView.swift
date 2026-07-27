import ComposableArchitecture
import Sharing
import SwiftUI
import TatamiKit

/// Edits global `AppSettings` (declarative `@Shared` config bindings) and
/// drives the system-touching bits — CLI install, Accessibility, updates —
/// through `SettingsFeature`.
///
/// System-Settings-style layout: a sidebar of panes on the left, one
/// grouped form per pane on the right.
struct SettingsView: View {
  /// A deep-link from elsewhere in the app (e.g. a workspace's derived
  /// shortcut) requesting a specific pane. Routed into `pane`, then cleared
  /// via `onSectionConsumed`.
  var pendingSection: SettingsSection? = nil
  var onSectionConsumed: () -> Void = {}
  var onStartOnboarding: () -> Void = {}

  @Shared(.tatamiConfig) var config = AppConfig()
  // Not `private`: the pane bodies live in SettingsView+Panes.swift, a
  // cross-file extension of this view.
  @State var store = Store(initialState: SettingsFeature.State()) {
    SettingsFeature()
  }
  @State private var pane: Pane? = .general

  enum Pane: String, CaseIterable, Identifiable {
    case general
    case tiling
    case workspaces
    case workspaceKeys
    case focusMouse
    case gestures
    case appearance

    var id: String { rawValue }

    var title: LocalizedStringResource {
      switch self {
      case .general: "General"
      case .tiling: "Tiling"
      case .workspaces: "Workspaces"
      case .workspaceKeys: "Workspace Keys"
      case .focusMouse: "Focus & Mouse"
      case .gestures: "Gestures"
      case .appearance: "Appearance"
      }
    }

    var icon: String {
      switch self {
      case .general: "gearshape"
      case .tiling: "rectangle.split.2x2"
      case .workspaces: "square.stack.3d.up"
      case .workspaceKeys: "keyboard"
      case .focusMouse: "cursorarrow.motionlines"
      case .gestures: "hand.draw"
      case .appearance: "paintbrush"
      }
    }
  }

  var body: some View {
    NavigationSplitView {
      // `id: \.self` so the ForEach id type matches the selection type —
      // macOS only wires the selection gesture when they line up.
      List(Pane.allCases, id: \.self, selection: $pane) { pane in
        Label(pane.title, systemImage: pane.icon)
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 180, ideal: 200)
    } detail: {
      Form {
        switch pane ?? .general {
        case .general: generalPane
        case .tiling: tilingPane
        case .workspaces: workspacesPane
        case .workspaceKeys: workspaceKeysPane
        case .focusMouse: focusMousePane
        case .gestures: gesturesPane
        case .appearance: appearancePane
        }
      }
      .formStyle(.grouped)
      .navigationTitle((pane ?? .general).title)
    }
    .alert($store.scope(state: \.alert, action: \.alert))
    .frame(minWidth: 680, minHeight: 540)
    // All side effects (status reads, permission/CLI/update streams, the AX
    // change subscription) live in the reducer — the view just starts it.
    .task { await store.send(.task).finish() }
    // Consume a deep-link into a specific pane (e.g. from a workspace's
    // derived shortcut). `initial` covers the tab already being open.
    .onChange(of: pendingSection, initial: true) { _, section in
      guard let section, let target = Pane(rawValue: section.rawValue) else { return }
      pane = target
      onSectionConsumed()
    }
  }

  // MARK: - Helpers

  /// SwiftUI `Color` binding backed by a hex-string field in settings.
  func borderColorBinding(
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
  func setting<Value>(
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
