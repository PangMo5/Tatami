// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import SwiftUI
import TatamiKit

// MARK: - SharedAppsView

/// Detail pane for the sidebar's "Shared Apps" pseudo-workspace: the apps
/// listed here are part of every workspace. The per-app Float toggle works
/// exactly like a workspace's — flipped on it makes the app *shared
/// floating*: untiled and kept above the tiles everywhere.
struct SharedAppsView: View {
  @Bindable var store: StoreOf<SharedAppsFeature>

  var body: some View {
    Form {
      Section {
        ForEach(store.apps) { app in
          AppAssignmentRow(
            name: app.name,
            bundleIdentifier: app.bundleIdentifier,
            iconPath: app.iconPath,
            autoOpenBinding: Binding(
              get: { app.autoOpen },
              set: { value in
                store.send(
                  .autoOpenToggled(bundleIdentifier: app.bundleIdentifier, isOn: value)
                )
              },
            ),
            layoutBinding: Binding(
              get: { app.layout },
              set: { value in
                store.send(
                  .layoutChanged(bundleIdentifier: app.bundleIdentifier, layout: value)
                )
              },
            ),
            autoOpenHelp: "Launch this app automatically when a workspace activates, if it has no open window. Also restores it when minimized.",
            onRemove: {
              store.send(.appRemoveRequested(bundleIdentifier: app.bundleIdentifier))
            },
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
        Text(
          store.apps.isEmpty
            ? "No shared apps yet. Tap + to add one — it will tile into every workspace."
            : "Shared apps are part of every workspace: tiled into each layout, or — with Float on — untiled and kept above the tiles everywhere."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Shared Apps")
    .sheet(
      isPresented: Binding(
        get: { store.isAppPickerPresented },
        set: { if !$0 { store.send(.appPickerDismissed) } },
      )
    ) {
      AppPickerSheet(
        apps: store.availableRunningApps,
        onSelect: { app in store.send(.appPickerAppSelected(app)) },
        onChooseFile: { store.send(.chooseAppFileTapped) },
        onCancel: { store.send(.appPickerDismissed) },
      )
    }
    .persistentChangeAlert(
      $store.scope(state: \.alert, action: \.alert),
      suppressible: store.alert?.buttons.contains(where: { $0.role == .destructive }) == true,
      suppress: Binding(
        get: { store.suppressConfirmation },
        set: { store.send(.confirmationSuppressionChanged($0)) },
      ),
    )
  }
}
