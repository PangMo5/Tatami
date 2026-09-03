// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TatamiKit

/// Compact second-line relationship preview for workspace sidebar rows. Native
/// menu-bar items preserve only one title and image, so the richer peer-symbol
/// treatment intentionally stays in this full SwiftUI surface.
struct WorkspaceChainPeerIcons: View {

  // MARK: Internal

  let profile: Profile
  let workspaceID: Workspace.ID

  var body: some View {
    if chain != nil, !peerWorkspaces.isEmpty {
      HStack(spacing: 5) {
        Image(systemName: "link")
          .font(.caption2.weight(.medium))
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)

        HStack(spacing: -2) {
          ForEach(visiblePeers) { workspace in
            Image(systemName: workspace.symbolIconName ?? "square.stack.3d.up")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(.secondary)
              .frame(width: 14, height: 16)
              .accessibilityHidden(true)
          }
        }

        if hiddenPeerCount > 0 {
          Text(verbatim: "+\(hiddenPeerCount)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Color.secondary.opacity(0.1), in: Capsule())
      .fixedSize(horizontal: true, vertical: false)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Linked workspaces: \(peerNames)")
      .help(helpText)
    }
  }

  // MARK: Private

  private var chain: WorkspaceChain? {
    profile.validWorkspaceChain(containing: workspaceID)
  }

  private var peerWorkspaces: [Workspace] {
    guard let chain else { return [] }
    return chain.workspaceIDs.compactMap { workspaceID in
      guard workspaceID != self.workspaceID else { return nil }
      return profile.workspaces[id: workspaceID]
    }
  }

  private var visiblePeers: ArraySlice<Workspace> {
    peerWorkspaces.prefix(3)
  }

  private var hiddenPeerCount: Int {
    max(0, peerWorkspaces.count - visiblePeers.count)
  }

  private var peerNames: String {
    peerWorkspaces.map(\.name).formatted()
  }

  private var helpText: String {
    let title = chain?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
    let chainName =
      if let title, !title.isEmpty {
        title
      } else {
        String(localized: "Workspace Chain")
      }
    return String(localized: "\(chainName): \(peerNames)")
  }

}
