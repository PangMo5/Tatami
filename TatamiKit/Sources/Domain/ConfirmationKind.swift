// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - ConfirmationKind

/// Stable opt-out scope shared by the settings row, native alert, and HUD.
public enum ConfirmationKind: String, CaseIterable, CodingKey, Identifiable, Sendable {
  case addWorkspaceApp
  case moveWorkspaceApp
  case removeWorkspaceApp
  case floatWorkspaceApp
  case tileWorkspaceApp
  case unmanageWorkspaceApp
  case addSharedApp
  case removeSharedApp
  case floatSharedApp
  case tileSharedApp
  case unmanageSharedApp
  case deleteWorkspace
  case deleteProfile
  case deleteWorkspaceChain
  case deleteHook
  case removeOverlayException
  case copyWorkspace
  case copyProfile
  case resetSetup
  case reloadSetup
  case applySetup
  case applySetupRecommendation
  case deleteSetupWorkspace
  case deleteSetupProfile
  case uninstallCLI

  // MARK: Public

  public enum Group: String, CaseIterable, Identifiable, Sendable {
    case workspaceApps
    case sharedApps
    case deletion
    case copy
    case setup
    case commandLine

    public var id: String {
      rawValue
    }

    public var title: LocalizedStringResource {
      switch self {
      case .workspaceApps: "Workspace Apps"
      case .sharedApps: "Shared Apps"
      case .deletion: "Deletions"
      case .copy: "Copy"
      case .setup: "Guided Setup"
      case .commandLine: "Command Line"
      }
    }

    public var actions: [ConfirmationKind] {
      ConfirmationKind.allCases.filter { $0.group == self }
    }
  }

  public var id: String {
    rawValue
  }

  public var title: LocalizedStringResource {
    switch self {
    case .addWorkspaceApp: "Add apps to workspaces"
    case .moveWorkspaceApp: "Move apps between workspaces"
    case .removeWorkspaceApp: "Remove apps from workspaces"
    case .floatWorkspaceApp: "Keep workspace apps always on top"
    case .tileWorkspaceApp: "Tile workspace apps"
    case .unmanageWorkspaceApp: "Leave workspace apps as is"
    case .addSharedApp: "Add Shared Apps"
    case .removeSharedApp: "Remove Shared Apps"
    case .floatSharedApp: "Keep Shared Apps always on top"
    case .tileSharedApp: "Tile Shared Apps"
    case .unmanageSharedApp: "Leave Shared Apps as is"
    case .deleteWorkspace: "Delete workspaces"
    case .deleteProfile: "Delete profiles"
    case .deleteWorkspaceChain: "Delete workspace chains"
    case .deleteHook: "Delete hooks"
    case .removeOverlayException: "Remove overlay exceptions"
    case .copyWorkspace: "Copy workspace settings"
    case .copyProfile: "Copy profile settings"
    case .resetSetup: "Start Guided Setup over"
    case .reloadSetup: "Reload the Guided Setup draft"
    case .applySetup: "Apply the Guided Setup draft"
    case .applySetupRecommendation: "Apply a setup recommendation"
    case .deleteSetupWorkspace: "Delete workspaces from the setup draft"
    case .deleteSetupProfile: "Delete profiles from the setup draft"
    case .uninstallCLI: "Uninstall the CLI"
    }
  }

  public var group: Group {
    switch self {
    case .addWorkspaceApp,
         .moveWorkspaceApp,
         .removeWorkspaceApp,
         .floatWorkspaceApp,
         .tileWorkspaceApp,
         .unmanageWorkspaceApp: .workspaceApps
    case .addSharedApp,
         .removeSharedApp,
         .floatSharedApp,
         .tileSharedApp,
         .unmanageSharedApp: .sharedApps
    case .deleteWorkspace,
         .deleteProfile,
         .deleteWorkspaceChain,
         .deleteHook,
         .removeOverlayException: .deletion
    case .copyWorkspace,
         .copyProfile: .copy
    case .resetSetup,
         .reloadSetup,
         .applySetup,
         .applySetupRecommendation,
         .deleteSetupWorkspace,
         .deleteSetupProfile: .setup
    case .uninstallCLI: .commandLine
    }
  }

  // MARK: Internal

  static func layout(_ layout: LayoutMode, shared: Bool) -> Self {
    switch (layout, shared) {
    case (.floating, false): .floatWorkspaceApp
    case (.tiled, false): .tileWorkspaceApp
    case (.unmanaged, false): .unmanageWorkspaceApp
    case (.floating, true): .floatSharedApp
    case (.tiled, true): .tileSharedApp
    case (.unmanaged, true): .unmanageSharedApp
    }
  }
}

// MARK: - AppSettings.Confirmations

extension AppSettings {
  public struct Confirmations: Hashable, Sendable, Codable {

    // MARK: Lifecycle

    public init(enabled: Bool = true) {
      disabled = enabled ? [] : Set(ConfirmationKind.allCases)
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: ConfirmationKind.self)
      disabled = Set(ConfirmationKind.allCases.filter { !container.decode($0, default: true) })
    }

    // MARK: Public

    public func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: ConfirmationKind.self)
      for kind in ConfirmationKind.allCases { try container.encode(self[kind], forKey: kind) }
    }

    public subscript(_ kind: ConfirmationKind) -> Bool {
      get { !disabled.contains(kind) }
      set {
        if newValue { disabled.remove(kind) } else { disabled.insert(kind) }
      }
    }

    // MARK: Private

    private var disabled: Set<ConfirmationKind>

  }
}
