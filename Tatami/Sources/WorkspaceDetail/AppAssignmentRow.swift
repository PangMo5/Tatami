// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TatamiKit

// MARK: - AppAssignmentRow

/// Shared presentation for workspace and Shared Apps assignments. Intrinsic
/// controls move below the app identity when a sidebar leaves little width.
struct AppAssignmentRow: View {

  // MARK: Internal

  let name: String
  let bundleIdentifier: String
  let iconPath: String?
  let autoOpenBinding: Binding<Bool>
  let layoutBinding: Binding<LayoutMode>
  var showLayoutOptions = true
  let autoOpenHelp: LocalizedStringResource
  let onRemove: () -> Void

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 16) {
        identity.fixedSize(horizontal: true, vertical: false)
        Spacer(minLength: 12)
        if showLayoutOptions { horizontalControls }
        actions
      }
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
          identity
          Spacer(minLength: 8)
          actions
        }
        if showLayoutOptions {
          ViewThatFits(in: .horizontal) {
            horizontalControls
            VStack(alignment: .leading, spacing: 10) {
              layoutPicker
              autoOpenToggle
            }
          }
          .padding(.leading, 44)
        }
      }
    }
    .padding(.vertical, 6)
  }

  // MARK: Private

  private var identity: some View {
    HStack(spacing: 12) {
      AppIcon(bundleIdentifier: bundleIdentifier, iconPath: iconPath)
        .frame(width: 32, height: 32)
      VStack(alignment: .leading, spacing: 3) {
        Text(verbatim: name)
          .font(.body.weight(.medium))
          .lineLimit(1)
          .truncationMode(.middle)
        Text(verbatim: bundleIdentifier)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .help(bundleIdentifier)
  }

  private var horizontalControls: some View {
    HStack(spacing: 16) {
      layoutPicker
      autoOpenToggle
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var layoutPicker: some View {
    Picker("Layout", selection: layoutBinding) {
      ForEach(LayoutMode.allCases, id: \.self) { mode in
        Label { Text(mode.displayName) } icon: { Image(systemName: mode.assignmentSymbol) }
          .tag(mode)
      }
    }
    .pickerStyle(.menu)
    .labelsHidden()
    .controlSize(.small)
    .fixedSize()
    .help(Text(layoutBinding.wrappedValue.assignmentDescription))
    .accessibilityIdentifier("assignment-layout-\(bundleIdentifier)")
  }

  private var autoOpenToggle: some View {
    HStack(spacing: 6) {
      Text("Auto-open")
        .font(.caption)
        .foregroundStyle(.secondary)
      Toggle("Auto-open", isOn: autoOpenBinding)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .accessibilityIdentifier("assignment-auto-open-\(bundleIdentifier)")
    }
    .fixedSize()
    .help(Text(autoOpenHelp))
  }

  private var actions: some View {
    Menu {
      Button("Remove App", role: .destructive, action: onRemove)
    } label: {
      Image(systemName: "ellipsis")
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel("App actions")
    .accessibilityIdentifier("assignment-actions-\(bundleIdentifier)")
    .help("App actions")
  }

}

extension LayoutMode {
  var assignmentSymbol: String {
    switch self {
    case .tiled: "rectangle.split.2x2"
    case .floating: "square.on.square"
    case .unmanaged: "rectangle.dashed"
    }
  }

  var assignmentDescription: LocalizedStringResource {
    switch self {
    case .tiled: "Arrange windows automatically with the workspace layout."
    case .floating: "Keep windows above the tiled layout."
    case .unmanaged: "Keep window positions and sizes unchanged."
    }
  }
}
