// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation

extension WorkspaceActivationFeature {
  /// Space notifications precede or overlap AX/WindowServer visibility edges.
  /// While the read is pending, none of those snapshots authorizes pruning.
  func observeDesktopSpaces(state: inout State) -> Effect<Action> {
    state.desktops.revision &+= 1
    state.desktops.isRefreshing = true
    let revision = state.desktops.revision
    return .run { [sls] send in
      let snapshot = await sls.desktopSpaces()
      await send(.desktopSpacesResolved(snapshot, revision: revision))
    }
  }

  func updateDesktopSpaces(
    _ snapshot: DesktopSpaces?,
    adopting: DisplayName? = nil,
    state: inout State,
  ) -> Effect<Action> {
    guard !state.isLayoutSuspended else { return .none }
    var previous = state.desktops
    previous.isRefreshing = false
    let displays = state.connectedDisplays.union(state.activeWorkspacesByDisplay.keys).union(state.compositionsByDisplay.keys)
    state.desktops.observe(snapshot, displays: displays)
    if let adopting {
      state.desktops.adopt(adopting)
    }
    var effects = [Effect<Action>]()
    var changedAvailability = false
    for display in displays {
      let available = state.desktops.isAvailable(on: display)
      if
        available,
        let restore = state.deferredDesktopRestores.removeValue(forKey: display),
        state.config.activeProfile?.workspaces[id: restore.workspace] != nil
      {
        state.pendingDisplayRestores.append(restore)
        effects.append(.send(.processDisplayRestores))
      }
      guard previous.isAvailable(on: display) != available else { continue }
      changedAvailability = true
      debugLog.log("Space", "display=\(display.name) managed Desktop available=\(available)")
      let workspaceIDs = state.visibleWorkspaceIDs.filter {
        state.displayShowing($0)?.matches(display) == true
      }
      if available {
        // An off-Space 816 must not become a hide-on-close tombstone when the
        // same native surface returns. Clear only this display's identities.
        let keys = Set(workspaceIDs.flatMap { state.tilingTrees[$0]?.windows ?? [] })
        state.windowServerHiddenWindows.subtract(keys)
        for bundle in Set(keys.map(\.bundleId)) { windowSnapshot.markBundleDirty(bundle) }
      } else {
        effects.append(.cancel(id: CancelID.layout(display)))
        effects.append(.cancel(id: CancelID.borrowFocus(display)))
        state.pendingBorrowCompletionByDisplay[display] = nil
        for id in workspaceIDs {
          effects.append(.cancel(id: CancelID.warp(id)))
          state.pendingCenterWarps[id] = nil
          state.removeFromPresentationMonitoring(Set(state.tilingTrees[id]?.windows ?? []))
        }
      }
    }
    if
      changedAvailability,
      !Self.floatingBundleIds(state: state, workspaceIDs: state.visibleWorkspaceIDs).isEmpty
    {
      effects.append(refreshFloatingPresentation(state: state, onlyVisibleWindows: true))
    }
    return .merge(effects)
  }
}
