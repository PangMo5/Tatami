// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation

// MARK: - AppWindowGrouping

struct AppWindowGrouping: Sendable {

  // MARK: Lifecycle

  init() {
    byBundle = [:]
  }

  init(workspace: Workspace, sharedApps: [SharedApp], sharedGroups: [StackGroup] = []) {
    let localTiled = Set(workspace.apps.filter { $0.layout == .tiled }.map(\.bundleIdentifier))
    let excluded = Set(
      workspace.apps.filter { $0.layout != .tiled }.map(\.bundleIdentifier)
        + sharedApps.filter { $0.layout != .tiled }.map(\.bundleIdentifier)
    )
    let sharedTiled = Set(sharedApps.filter { $0.layout == .tiled }.map(\.bundleIdentifier))
    var groups = [String: Group]()
    if workspace.stackAllAssignedApps {
      for bundleId in localTiled.subtracting(excluded) {
        groups[bundleId] = .allAssigned
      }
    } else {
      for group in workspace.stackGroups {
        for bundleId in group.bundleIdentifiers where localTiled.contains(bundleId) && !excluded.contains(bundleId) {
          groups[bundleId] = groups[bundleId] ?? .workspace(group.id)
        }
      }
    }
    if workspace.kind != .scratchpad {
      for group in sharedGroups {
        for bundleId in group.bundleIdentifiers where sharedTiled.contains(bundleId) && !excluded.contains(bundleId) {
          groups[bundleId] = groups[bundleId] ?? .shared(group.id)
        }
      }
    }
    byBundle = groups
  }

  // MARK: Internal

  enum Group: Hashable, Sendable {
    case allAssigned
    case workspace(StackGroup.ID)
    case shared(StackGroup.ID)
  }

  func group(for window: WindowKey) -> Group? {
    byBundle[window.bundleId]
  }

  func reconcile(_ tree: BSPNode<WindowKey>?, in area: CGRect, settings: AppSettings) -> BSPNode<WindowKey>? {
    guard let tree, !byBundle.isEmpty || tree.hasAutomaticStacks else { return tree }
    return tree.reconcilingAutomaticStacks(
      in: area,
      splitAxis: settings.layout.splitType.bspSplitAxis(),
      placement: settings.layout.windowPlacement.bspChild,
      groupForWindow: group(for:),
    )
  }

  func reconcile(_ snapshot: LayoutSnapshot, in area: CGRect, settings: AppSettings) -> LayoutSnapshot {
    guard !byBundle.isEmpty || snapshot.tree.hasAutomaticStacks else { return snapshot }
    var updated = snapshot
    updated.tree = snapshot.tree.reconcilingAutomaticStacks(
      in: area,
      splitAxis: settings.layout.splitType.bspSplitAxis(),
      placement: settings.layout.windowPlacement.bspChild,
      groupForWindow: { byBundle[$0.bundleId] },
    )
    return updated
  }

  // MARK: Private

  private let byBundle: [String: Group]

}

extension WorkspaceActivationFeature.State {
  func windowGrouping(in workspace: Workspace) -> AppWindowGrouping {
    let borrowed = compositionsByDisplay.values.contains { composition in
      composition.borrowed.contains { $0.workspace == workspace.id }
    }
    return AppWindowGrouping(
      workspace: workspace,
      sharedApps: borrowed ? [] : config.sharedApps,
      sharedGroups: borrowed ? [] : config.sharedStackGroups,
    )
  }
}

extension WorkspaceActivationFeature {
  /// A layout-only setting does not activate workspaces or touch native Spaces.
  func applyWindowGrouping(
    bundleIds: Set<String>,
    workspaceId: Workspace.ID?,
    state: inout State,
  ) -> Effect<Action> {
    if state.isActivating || state.drag.windowKey != nil {
      state.pendingWindowSyncBundleIds.formUnion(bundleIds)
      return .none
    }
    guard !state.isTilingPaused, !state.isLayoutSuspended else { return .none }

    let settings = state.config.settings
    var effects = [Effect<Action>]()
    var updatedWorkspaces = Set<Workspace.ID>()
    for id in state.layoutWorkspaceIDs where workspaceId == nil || workspaceId == id {
      guard
        state.canManageWorkspace(id),
        let workspace = state.presentedWorkspace(id)
      else { continue }

      let (_, area) = tilingContext(for: id, state: state)
      let grouping = state.windowGrouping(in: workspace)
      if let snapshot = state.pendingLayoutRestorations[id] {
        let updated = grouping.reconcile(snapshot, in: area, settings: settings)
        if updated != snapshot {
          state.pendingLayoutRestorations[id] = updated
          effects.append(.run { [store = layoutStore] _ in await store.save(id, updated) })
        }
      }
      guard
        let current = state.tilingTrees[id],
        let updated = grouping.reconcile(current, in: area, settings: settings),
        current != updated
      else { continue }

      state.tilingTrees[id] = updated
      if state.pendingLayoutRestorations[id] == nil {
        effects.append(persist(updated, fullscreenZoomed: state.fullscreenZoomed[id] ?? [], for: workspace))
      }
      if let display = state.displayShowing(id) {
        updatedWorkspaces.insert(state.compositionsByDisplay[display]?.host ?? id)
      } else {
        updatedWorkspaces.insert(id)
      }
    }
    for id in updatedWorkspaces {
      effects.append(flushLayout(workspaceId: id, state: &state, monitorsPresentationChanges: true))
    }
    if !updatedWorkspaces.isEmpty {
      effects.append(refreshMarkers(state: state))
    }
    return .merge(effects)
  }
}
