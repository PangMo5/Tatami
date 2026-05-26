import AppKit
import ComposableArchitecture
import SwiftUI
import TatamiKit

struct WorkspaceDetailView: View {
  @Bindable var store: StoreOf<WorkspaceDetailFeature>
  @State private var nameDraft: String = ""

  var body: some View {
    if let workspace = store.workspace {
      Form {
        Section("Workspace") {
          HStack {
            Image(systemName: workspace.symbolIconName ?? "square.stack.3d.up")
              .font(.title2)
              .foregroundStyle(.tint)
            TextField("Name", text: $nameDraft)
              .textFieldStyle(.plain)
              .onSubmit { store.send(.nameSubmitted(nameDraft)) }
          }
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
      .sheet(isPresented: $store.isAppPickerPresented) {
        AppPickerSheet(
          apps: store.availableRunningApps,
          onSelect: { app in store.send(.appPickerAppSelected(app)) },
          onCancel: { store.send(.appPickerDismissed) }
        )
      }
      .onAppear { nameDraft = workspace.name }
      .onChange(of: workspace.id) { _, _ in nameDraft = workspace.name }
    } else {
      ContentUnavailableView(
        "Workspace Unavailable",
        systemImage: "exclamationmark.triangle",
        description: Text("This workspace no longer exists.")
      )
    }
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
      Toggle("Auto-open", isOn: autoOpenBinding)
        .toggleStyle(.switch)
        .labelsHidden()
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
