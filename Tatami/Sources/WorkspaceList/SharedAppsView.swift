import ComposableArchitecture
import SwiftUI
import TatamiKit

/// Detail pane for the sidebar's "Shared Apps" pseudo-workspace: the apps
/// listed here are part of every workspace. The per-app Float toggle works
/// exactly like a workspace's — flipped on it makes the app *shared
/// floating*: untiled and kept above the tiles everywhere.
struct SharedAppsView: View {
  let store: StoreOf<SharedAppsFeature>

  var body: some View {
    Form {
      Section {
        ForEach(store.apps) { app in
          SharedAppRow(
            app: app,
            floatingBinding: Binding(
              get: { app.floating },
              set: { value in
                store.send(
                  .floatingToggled(bundleIdentifier: app.bundleIdentifier, isOn: value)
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
  }
}

private struct SharedAppRow: View {
  let app: SharedApp
  let floatingBinding: Binding<Bool>
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
      HStack(spacing: 6) {
        Text("Float")
          .font(.caption)
          .foregroundStyle(.secondary)
        Toggle("Float", isOn: floatingBinding)
          .labelsHidden()
          .toggleStyle(.switch)
      }
      .help("Keep this app untiled and floating above the tiles — in every workspace.")
      Button(role: .destructive, action: onRemove) {
        Image(systemName: "minus.circle.fill")
          .foregroundStyle(.red)
      }
      .buttonStyle(.borderless)
    }
  }
}
