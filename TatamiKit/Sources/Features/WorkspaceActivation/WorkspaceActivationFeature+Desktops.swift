// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation

extension WorkspaceActivationFeature {

  // MARK: Internal

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
    state: inout State,
  ) -> Effect<Action> {
    guard !state.isLayoutSuspended else { return .none }
    var previous = state.desktops
    previous.isRefreshing = false
    let displays = state.connectedDisplays.union(state.activeWorkspacesByDisplay.keys).union(state.compositionsByDisplay.keys)
    state.desktops.observe(snapshot, displays: displays)
    var effects = [Effect<Action>]()
    var changedAvailability = false
    for display in displays {
      let available = state.desktops.isAvailable(on: display)
      if
        available,
        state.pendingManagedDesktopActivation?.display.matches(display) != true,
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
    effects.append(resumeManagedDesktopPreparation(state: &state))
    return .merge(effects)
  }

  /// App activation belongs to the native keyboard-focus display. Explicit
  /// workspace commands keep their captured pointer placement; an app event
  /// must not move to a fullscreen monitor merely because the pointer is there.
  func resumeFollowingAppFocus(state: inout State) -> Effect<Action> {
    guard var request = state.pendingAppFocusDesktopRequest else { return .none }
    guard state.pendingManagedDesktopActivation == nil else { return .none }
    guard isAppFocusDesktopRequestCurrent(request, state: state) else {
      state.pendingAppFocusDesktopRequest = nil
      return .cancel(id: CancelID.appFocusDesktop)
    }
    // A native Space transition owns the snapshot until its result arrives.
    // Keep this input and resume from desktopSpacesResolved, without a timer
    // or a speculative retry against the previous Space's cached focus.
    guard !state.desktops.isRefreshing else { return .none }
    if request.isReading, request.desktopRevision == state.desktops.revision {
      return .none
    }
    state.appFocusDesktopRequestID &+= 1
    request.id = state.appFocusDesktopRequestID
    request.desktopRevision = state.desktops.revision
    request.isReading = true
    state.pendingAppFocusDesktopRequest = request
    return .run { [sls, request] send in
      let spaces = await sls.desktopSpaces()
      guard !Task.isCancelled else { return }
      await send(.appFocusDesktopResolved(request, spaces))
    }
    .cancellable(id: CancelID.appFocusDesktop, cancelInFlight: true)
  }

  func completeFollowingAppFocus(
    _ request: AppFocusDesktopRequest,
    spaces: DesktopSpaces?,
    state: inout State,
  ) -> Effect<Action> {
    guard state.pendingAppFocusDesktopRequest?.id == request.id else { return .none }
    state.pendingAppFocusDesktopRequest?.isReading = false
    guard isAppFocusDesktopRequestCurrent(request, state: state) else {
      state.pendingAppFocusDesktopRequest = nil
      return .none
    }
    guard request.desktopRevision == state.desktops.revision, !state.desktops.isRefreshing else {
      return resumeFollowingAppFocus(state: &state)
    }
    state.pendingAppFocusDesktopRequest = nil
    let update = updateDesktopSpaces(spaces, state: &state)
    guard let spaces, let workspace = state.config.activeProfile?.workspaces[id: request.workspaceID]
    else { return update }
    let origin: DisplayName?
    if let uuid = spaces.focusedDisplayUUID, uuid != "Main" {
      let reference = DisplayName(uuid: uuid, name: "")
      guard let display = state.connectedDisplays.first(where: { $0.uuid == uuid }) ?? displays.connected(reference)
      else {
        debugLog.log("Activate", "skip followAppFocus: focused display is not connected")
        return update
      }
      origin = display
    } else if spaces.displays.count == 1, spaces.displays.first?.uuid == "Main" {
      // In shared-Spaces mode every monitor has the same native Desktop gate.
      origin = request.interactionDisplay ?? state.focusedDisplay ?? state.desktops.homes.keys.first
    } else {
      debugLog.log("Activate", "skip followAppFocus: keyboard-focus display unavailable")
      return update
    }
    let target = deliberateActivationDisplay(
      for: workspace,
      interactionDisplay: origin,
      state: state,
    )
    guard state.desktops.isAvailable(on: origin), state.desktops.isAvailable(on: target)
    else { return update }
    debugLog.log("Activate", "followAppFocus jump: verified native focus → ws=\(workspace.name)")
    return .merge(
      update,
      .concatenate(
        .cancel(id: CancelID.workspaceChainCleanup),
        deliberateActivation(
          workspaceId: request.workspaceID,
          setFocus: false,
          interactionDisplayOverride: origin,
          followsCursor: true,
          returnsToManagedDesktop: false,
          state: &state,
        ),
      ),
    )
  }

  // MARK: Private

  private func isAppFocusDesktopRequestCurrent(_ request: AppFocusDesktopRequest, state: State) -> Bool {
    guard
      request.activationGeneration == state.activationGeneration,
      request.profileID == state.config.activeProfile?.id,
      request.followAppFocus == state.config.settings.switching.followAppFocus,
      !state.isLayoutSuspended,
      let workspace = state.config.activeProfile?.workspaces[id: request.workspaceID]
    else { return false }
    if let expected = request.frontmostApp {
      guard
        let current = windowSnapshot.frontmostApp(),
        current.pid == expected.pid,
        current.bundleId == expected.bundleId,
        !overlayAwareness.isBackgroundedProcess(current.pid),
        workspace.apps.contains(where: { $0.bundleIdentifier == current.bundleId }),
        state.ownsApp(current.bundleId, in: workspace.id)
      else { return false }
    }
    return true
  }

}
