// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TatamiKit

// MARK: - ConfirmationSettingsSection

struct ConfirmationSettingsSection: View {

  // MARK: Internal

  @Binding var settings: AppSettings.Confirmations

  var body: some View {
    Section {
      ForEach(ConfirmationKind.Group.allCases) { group in
        Button {
          selectedGroup = group
        } label: {
          HStack(spacing: 12) {
            Image(systemName: group.settingsSymbol)
              .font(.system(size: 17, weight: .medium))
              .foregroundStyle(.tint)
              .frame(width: 36, height: 36)
              .background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
              Text(group.title).font(.body.weight(.medium))
              Text(group.settingsDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Text(status(for: group))
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize()
            Image(systemName: "chevron.right")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.tertiary)
          }
          .padding(.vertical, 5)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("confirmation-category-\(group.rawValue)")
      }
    } header: {
      VStack(alignment: .leading, spacing: 6) {
        Text("Confirm Before Changes")
        Text("Choose when Tatami asks before saving a change. Actions with confirmation turned off run immediately.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .textCase(nil)
    } footer: {
      Text("Don't ask again turns off only that action. You can turn it back on here anytime.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .sheet(item: $selectedGroup) { group in
      ConfirmationCategorySheet(group: group, settings: $settings)
    }
  }

  // MARK: Private

  @State private var selectedGroup: ConfirmationKind.Group?

  private func status(for group: ConfirmationKind.Group) -> LocalizedStringResource {
    let enabled = group.actions.count { settings[$0] }
    if enabled == group.actions.count { return "Ask for all" }
    if enabled == 0 { return "Run immediately" }
    return "Ask for \(enabled) actions"
  }

}

// MARK: - ConfirmationCategorySheet

private struct ConfirmationCategorySheet: View {

  // MARK: Internal

  let group: ConfirmationKind.Group

  @Binding var settings: AppSettings.Confirmations

  var body: some View {
    NavigationStack {
      Form {
        Section {
          ForEach(group.actions) { kind in
            Toggle(isOn: Binding(
              get: { settings[kind] },
              set: { settings[kind] = $0 },
            )) {
              VStack(alignment: .leading, spacing: 5) {
                Text(kind.settingsTitle).font(.body.weight(.medium))
                Text(kind.settingsDescription)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              .padding(.vertical, 4)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityIdentifier("confirmation-option-\(kind.rawValue)")
          }
        } header: {
          Text(group.settingsDescription)
            .textCase(nil)
        } footer: {
          Text("On asks before the change. Off applies it immediately. These preferences take effect as you change them.")
        }
      }
      .formStyle(.grouped)
      .navigationTitle(group.title)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .keyboardShortcut(.defaultAction)
        }
      }
    }
    .frame(width: 520, height: min(640, 190 + CGFloat(group.actions.count) * 76))
  }

  // MARK: Private

  @Environment(\.dismiss) private var dismiss

}

extension ConfirmationKind.Group {
  fileprivate var settingsSymbol: String {
    switch self {
    case .workspaceApps: "rectangle.3.group"
    case .sharedApps: "square.on.square"
    case .deletion: "trash"
    case .copy: "doc.on.doc"
    case .setup: "wand.and.stars"
    case .commandLine: "terminal"
    }
  }

  fileprivate var settingsDescription: LocalizedStringResource {
    switch self {
    case .workspaceApps: "App assignments, moves, and window layout changes."
    case .sharedApps: "Apps and window layouts shared across every workspace."
    case .deletion: "Remove saved workspaces, profiles, hooks, and exceptions."
    case .copy: "Replace saved assignments and settings with reviewed changes."
    case .setup: "Reset, replace, or apply your Guided Setup draft."
    case .commandLine: "Remove the installed command-line tool."
    }
  }
}

extension ConfirmationKind {
  fileprivate var settingsTitle: LocalizedStringResource {
    switch self {
    case .addWorkspaceApp: "Assign Apps"
    case .moveWorkspaceApp: "Move Apps"
    case .removeWorkspaceApp,
         .removeSharedApp: "Remove Apps"
    case .addSharedApp: "Add Apps"
    case .floatWorkspaceApp,
         .floatSharedApp: LayoutMode.floating.displayName
    case .tileWorkspaceApp,
         .tileSharedApp: LayoutMode.tiled.displayName
    case .unmanageWorkspaceApp,
         .unmanageSharedApp: LayoutMode.unmanaged.displayName
    case .deleteWorkspace: "Workspaces"
    case .deleteProfile: "Profiles"
    case .deleteWorkspaceChain: "Workspace Chains"
    case .deleteHook: "Hooks"
    case .removeOverlayException: "Window Visibility Exceptions"
    case .copyWorkspace: "Workspace Settings"
    case .copyProfile: "Profile Settings"
    case .resetSetup: "Start Over"
    case .reloadSetup: "Reload Draft"
    case .applySetup: "Apply Setup"
    case .applySetupRecommendation: "Apply Recommendation"
    case .deleteSetupWorkspace: "Delete Draft Workspaces"
    case .deleteSetupProfile: "Delete Draft Profiles"
    case .uninstallCLI: "Uninstall CLI"
    }
  }

  fileprivate var settingsDescription: LocalizedStringResource {
    switch self {
    case .addWorkspaceApp: "Add an app to a workspace from a shortcut or command."
    case .moveWorkspaceApp: "Move an app out of other workspaces in the current profile."
    case .removeWorkspaceApp: "Remove an app and its saved assignment from a workspace."
    case .addSharedApp: "Make an app available in every workspace."
    case .removeSharedApp: "Remove an app from Shared Apps and delete its saved shared settings."
    case .floatWorkspaceApp,
         .floatSharedApp: "Keep windows above the tiled layout."
    case .tileWorkspaceApp,
         .tileSharedApp: "Arrange windows automatically with the workspace layout."
    case .unmanageWorkspaceApp,
         .unmanageSharedApp: "Keep window positions and sizes unchanged."
    case .deleteWorkspace: "Delete a workspace, its app assignments, and its saved layout."
    case .deleteProfile: "Delete a profile and the workspaces it contains."
    case .deleteWorkspaceChain: "Remove the rule that switches linked workspaces together."
    case .deleteHook: "Delete a saved automation hook."
    case .removeOverlayException: "Restore the normal visibility rules for an app."
    case .copyWorkspace,
         .copyProfile: "Apply selected changes that replace or remove existing assignments and settings."
    case .resetSetup: "Discard the saved setup draft and its progress."
    case .reloadSetup: "Discard the setup draft and load the latest saved configuration."
    case .applySetup: "Replace the live configuration with the reviewed setup draft."
    case .applySetupRecommendation: "Replace the draft's workspace map with a recommendation."
    case .deleteSetupWorkspace: "Delete a workspace from the draft without changing the live configuration."
    case .deleteSetupProfile: "Delete a profile from the draft without changing the live configuration."
    case .uninstallCLI: "Remove the tatami command from /usr/local/bin."
    }
  }
}
