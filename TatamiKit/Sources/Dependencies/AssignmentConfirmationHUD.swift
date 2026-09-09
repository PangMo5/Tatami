// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import SwiftUI

// MARK: - AssignmentOperation

enum AssignmentOperation: Equatable, Sendable {
  case assign
  case move
  case addWorkspace
  case removeWorkspace
  case addShared
  case removeShared
  case floating
  case tiled
  case addFloating
  case addSharedFloating

  // MARK: Internal

  var title: LocalizedStringResource {
    switch self {
    case .assign: "Assign this app?"
    case .move: "Move this app?"
    case .addWorkspace,
         .addShared: "Add this app?"
    case .removeWorkspace,
         .removeShared: "Remove this app?"
    case .floating,
         .addFloating,
         .addSharedFloating: "Keep this app always on top?"
    case .tiled: "Tile this app?"
    }
  }

  var explanation: LocalizedStringResource {
    switch self {
    case .assign: "Keep existing workspace memberships, add this app to the destination, and switch there."
    case .move: "Remove this app from other workspaces in this profile, move it to the destination, and switch there. Shared Apps and other profiles are unchanged."
    case .addWorkspace: "Remove this app from other workspaces in this profile and register it in this workspace with default settings."
    case .removeWorkspace: "Remove this app and its saved assignment settings from this workspace."
    case .addShared: "Add this app to Shared Apps so it is tiled in every workspace."
    case .removeShared: "Remove this app and its saved settings from Shared Apps. Explicit workspace assignments are unchanged."
    case .floating: "Save Always on Top for this app in the destination. Its membership is unchanged."
    case .tiled: "Save Tiled for this app in the destination. Its membership is unchanged."
    case .addFloating: "Register this app in this workspace as Always on Top. Existing memberships are kept."
    case .addSharedFloating: "Add this app to Shared Apps as Always on Top in every workspace."
    }
  }

  var buttonTitle: LocalizedStringResource {
    switch self {
    case .assign: "Add and Switch"
    case .move: "Move and Switch"
    case .addWorkspace,
         .addShared,
         .addFloating,
         .addSharedFloating: "Add"
    case .removeWorkspace,
         .removeShared: "Remove"
    case .floating,
         .tiled: "Change"
    }
  }

  func confirmationKind(shared: Bool) -> ConfirmationKind {
    switch self {
    case .assign,
         .addWorkspace: .addWorkspaceApp
    case .move: .moveWorkspaceApp
    case .removeWorkspace: .removeWorkspaceApp
    case .addShared: .addSharedApp
    case .removeShared: .removeSharedApp
    case .addFloating: .floatWorkspaceApp
    case .addSharedFloating: .floatSharedApp
    case .floating: shared ? .floatSharedApp : .floatWorkspaceApp
    case .tiled: shared ? .tileSharedApp : .tileWorkspaceApp
    }
  }
}

// MARK: - AssignmentConfirmationRequest

struct AssignmentConfirmationRequest: Equatable, Sendable {
  let id: UUID
  let appName: String
  let workspaceName: String
  let profileName: String?
  let sourcePID: pid_t
  let operation: AssignmentOperation
  let moveDirection: Int
  let position: HUDPosition
  let display: DisplayName?
  var size = HUDSize.standard

  var confirmationKind: ConfirmationKind {
    operation.confirmationKind(shared: profileName == nil)
  }

  var symbol: String {
    switch operation {
    case .assign,
         .addWorkspace,
         .addShared: "plus.rectangle.on.rectangle"
    case .move: moveDirection < 0 ? "arrow.left.square" : "arrow.right.square"
    case .removeWorkspace,
         .removeShared: "minus.circle"
    case .floating,
         .addFloating,
         .addSharedFloating: "rectangle.dashed"
    case .tiled: "square.stack.3d.up.fill"
    }
  }
}

// MARK: - ActionConfirmationResult

struct ActionConfirmationResult: Equatable, Sendable {
  static let cancelled = Self(confirmed: false)

  var confirmed: Bool
  var suppressFuture = false
}

// MARK: - AssignmentConfirmationControls

/// The content of the shared action HUD. The controller owns the panel and
/// presentation phase across feedback and confirmation requests.
struct AssignmentConfirmationControls: View {
  let request: AssignmentConfirmationRequest
  @Binding var suppressFuture: Bool

  let confirm: () -> Void
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label { Text(request.operation.title) } icon: { Image(systemName: request.symbol) }
        .font(.headline)
      VStack(alignment: .leading, spacing: 5) {
        Text(verbatim: request.appName).font(.title3.weight(.semibold))
        if let profile = request.profileName {
          Text("Destination: \(profile) / \(request.workspaceName)").foregroundStyle(.secondary)
        } else {
          Text("Destination: \(request.workspaceName)").foregroundStyle(.secondary)
        }
      }
      Text(request.operation.explanation).font(.callout).foregroundStyle(.secondary)
      Toggle("Don't ask again", isOn: $suppressFuture)
        .toggleStyle(.checkbox)
        .font(.callout)
        .help("Turn off confirmation for this action only. You can enable it again in Settings.")
      HStack {
        Spacer(minLength: 0)
        Button("Cancel", action: cancel)
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("cancel-assignment")
        Button(action: confirm) { Text(request.operation.buttonTitle) }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("confirm-assignment")
      }
    }
    .padding(20)
    .fixedSize(horizontal: false, vertical: true)
  }
}
