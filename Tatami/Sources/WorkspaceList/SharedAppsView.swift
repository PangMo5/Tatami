import ComposableArchitecture
import SwiftUI
import TatamiKit

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
          SharedAppRow(
            app: app,
            layoutBinding: Binding(
              get: { app.layout },
              set: { value in
                store.send(
                  .layoutChanged(bundleIdentifier: app.bundleIdentifier, layout: value)
                )
              }
            ),
            autoOpenBinding: Binding(
              get: { app.autoOpen },
              set: { value in
                store.send(
                  .autoOpenToggled(bundleIdentifier: app.bundleIdentifier, isOn: value)
                )
              }
            ),
            onRemove: {
              store.send(.appRemoveRequested(bundleIdentifier: app.bundleIdentifier))
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
        set: { if !$0 { store.send(.appPickerDismissed) } }
      )
    ) {
      AppPickerSheet(
        apps: store.availableRunningApps,
        onSelect: { app in store.send(.appPickerAppSelected(app)) },
        onChooseFile: { store.send(.chooseAppFileTapped) },
        onCancel: { store.send(.appPickerDismissed) }
      )
    }
    .alert($store.scope(state: \.alert, action: \.alert))
  }
}

private struct SharedAppRow: View {
  let app: SharedApp
  let layoutBinding: Binding<LayoutMode>
  let autoOpenBinding: Binding<Bool>
  let onRemove: () -> Void

  var body: some View {
    HStack {
      AppIcon(bundleIdentifier: app.bundleIdentifier, iconPath: app.iconPath)
        .frame(width: 22, height: 22)
      VStack(alignment: .leading, spacing: 2) {
        Text(app.name)
          .font(.body)
        Text(app.bundleIdentifier)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
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
      .help("Launch this app automatically when a workspace activates, if it has no open window. Also restores it when minimized.")
      Button(role: .destructive, action: onRemove) {
        Image(systemName: "minus.circle.fill")
          .foregroundStyle(.red)
      }
      .buttonStyle(.borderless)
    }
  }
}
