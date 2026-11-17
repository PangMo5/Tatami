// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation

extension WorkspaceActivationFeature {

  // MARK: Internal

  func deliberateActivation(
    workspaceId: Workspace.ID,
    setFocus: Bool,
    targetDisplayOverride: DisplayName? = nil,
    interactionDisplayOverride: DisplayName? = nil,
    followsCursor: Bool = false,
    continuesCLIActivation: Bool = false,
    returnsToManagedDesktop: Bool = true,
    state: inout State,
  ) -> Effect<Action> {
    guard returnsToManagedDesktop else {
      guard state.pendingManagedDesktopActivation == nil else { return .none }
      return activateOnManagedDesktop(
        workspaceId: workspaceId,
        setFocus: setFocus,
        targetDisplayOverride: targetDisplayOverride,
        interactionDisplayOverride: interactionDisplayOverride,
        followsCursor: followsCursor,
        continuesCLIActivation: continuesCLIActivation,
        state: &state,
      )
    }
    guard let profile = state.config.activeProfile, let workspace = profile.workspaces[id: workspaceId] else {
      return continuesCLIActivation
        ? completeCLIActivation(error: "The requested workspace no longer exists", state: &state)
        : .none
    }
    let target = targetDisplayOverride ?? deliberateActivationDisplay(
      for: workspace,
      interactionDisplay: interactionDisplayOverride,
      state: state,
    )
    let cancellation = cancelManagedDesktopPreparation(state: &state)
    guard !state.isLayoutSuspended else { return cancellation }
    let row = target.flatMap { state.desktops.snapshot?.space(on: $0) }
    let hasOtherSpaces = row.map { !$0.fullscreenWindows.isEmpty || $0.userDesktops.count > 1 } ?? false
    guard
      let target,
      !state.desktops.isAvailable(on: target) || hasOtherSpaces
    else {
      return .concatenate(cancellation, activateOnManagedDesktop(
        workspaceId: workspaceId,
        setFocus: setFocus,
        targetDisplayOverride: targetDisplayOverride,
        interactionDisplayOverride: interactionDisplayOverride,
        followsCursor: followsCursor,
        continuesCLIActivation: continuesCLIActivation,
        state: &state,
      ))
    }
    // Native preparation is the new explicit request, even before ordinary
    // activation can begin. Invalidate old completions and stop their writers.
    state.isActivating = false
    state.activatingWorkspaceID = nil
    state.activatingDisplay = nil
    state.activeActivationGeneration = nil
    state.pendingCLIActivationBinding = nil
    let outgoing = Effect<Action>.merge(
      supersedePendingFocus(state: &state),
      .cancel(id: CancelID.activation),
      .cancel(id: CancelID.activationWatchdog),
      .cancel(id: CancelID.activationHUD),
      .cancel(id: CancelID.layout(target)),
      .cancel(id: CancelID.borrowRender(target)),
    )
    let superseded = continuesCLIActivation ? Effect<Action>.none : supersedePendingCLIActivation(state: &state)
    state.pendingManagedDesktopActivation = ManagedDesktopActivation(
      id: UUID(),
      workspace: workspace,
      profileID: profile.id,
      display: target,
      setFocus: setFocus,
      interactionDisplay: interactionDisplayOverride ?? interactionDisplay(state: state),
      followsCursor: followsCursor,
      continuesCLIActivation: continuesCLIActivation,
      cliRequestID: continuesCLIActivation ? state.pendingCLIActivation?.id : nil,
      requestedAtUptime: ProcessInfo.processInfo.systemUptime,
      wasAway: !state.desktops.isAvailable(on: target),
    )
    // A coherent native read owns the next phase. Existing in-flight reads
    // resume it through updateDesktopSpaces without a second polling loop.
    let observation = state.desktops.isRefreshing ? Effect<Action>.none : observeDesktopSpaces(state: &state)
    return .concatenate(cancellation, outgoing, superseded, observation)
  }

  func resumeManagedDesktopPreparation(state: inout State) -> Effect<Action> {
    guard var request = state.pendingManagedDesktopActivation, !request.isPreparing else { return .none }
    guard
      managedDesktopRequestIsCurrent(request, state: state),
      let home = state.desktops.resolveHomeForExplicitActivation(on: request.display)
    else {
      return completeManagedDesktopPreparation(
        id: request.id,
        spaces: nil,
        error: "The managed macOS Desktop is unavailable",
        cancelled: false,
        state: &state,
      )
    }
    debugLog.log(
      "Space",
      "prepare workspace=\(request.workspace.name) display=\(request.display.name) home=\(home) request=\(request.id)",
    )
    request.isPreparing = true
    state.pendingManagedDesktopActivation = request
    let capturedRequest = request
    let bundles = Set(request.workspace.apps.map(\.bundleIdentifier) + state.config.sharedApps.map(\.bundleIdentifier))
    let preparation = ManagedDesktopPreparation(
      id: request.id,
      display: request.display,
      home: home,
      bundleIDs: bundles,
      requestedAtUptime: request.requestedAtUptime,
    )
    return .run { [managedDesktop] send in
      let result = await managedDesktop.prepare(preparation)
      switch result {
      case .prepared(let spaces, let requiresReconciliation):
        await send(.managedDesktopPrepared(
          id: capturedRequest.id,
          spaces: spaces,
          error: nil,
          cancelled: false,
          requiresReconciliation: requiresReconciliation,
        ))

      case .failed(let error):
        await send(.managedDesktopPrepared(id: capturedRequest.id, spaces: nil, error: error, cancelled: false))

      case .cancelled:
        await send(.managedDesktopPrepared(id: capturedRequest.id, spaces: nil, error: nil, cancelled: true))
      }
    }
    .cancellable(id: CancelID.managedDesktopActivation, cancelInFlight: true)
  }

  func completeManagedDesktopPreparation(
    id: UUID,
    spaces: DesktopSpaces?,
    error: String?,
    cancelled: Bool,
    requiresReconciliation: Bool = true,
    state: inout State,
  ) -> Effect<Action> {
    guard let request = state.pendingManagedDesktopActivation, request.id == id else { return .none }
    let isCurrent = managedDesktopRequestIsCurrent(request, state: state)
    // Apply the verified snapshot while this display is still gated, so an
    // old automatic restore cannot run ahead of the explicit selection.
    let update = spaces.map { updateDesktopSpaces($0, state: &state) } ?? .none
    state.pendingManagedDesktopActivation = nil
    let available = state.desktops.isAvailable(on: request.display)
    if cancelled || error != nil || !isCurrent || !available {
      let message = error ?? (cancelled
        ? "Workspace activation was superseded by user input"
        : "Workspace activation context changed")
      debugLog.log("Space", "managed Desktop preparation stopped: \(message)")
      let completion = request.cliRequestID == state.pendingCLIActivation?.id
        ? completeCLIActivation(error: message, state: &state)
        : .none
      let warning: Effect<Action> = cancelled
        ? .none
        : hudEffect(
          state,
          \.workspaceSwitch,
          "Couldn't Switch Workspace",
          "exclamationmark.triangle.fill",
          subtitle: "Return to this display's Tatami Desktop and try again. Check the log for details.",
          display: request.display,
          priority: .warning,
        )
      return .merge(update, completion, warning, observeDesktopSpaces(state: &state))
    }
    debugLog.log("Space", "prepared workspace=\(request.workspace.name) display=\(request.display.name) request=\(request.id)")
    state.pendingAppFocusDesktopRequest = nil
    for bundle in request.workspace.apps.map(\.bundleIdentifier) { windowSnapshot.markBundleDirty(bundle) }
    return .concatenate(update, activateOnManagedDesktop(
      workspaceId: request.workspace.id,
      setFocus: request.setFocus,
      targetDisplayOverride: request.display,
      interactionDisplayOverride: request.interactionDisplay,
      followsCursor: request.followsCursor,
      continuesCLIActivation: request.continuesCLIActivation,
      requiresReconciliation: request.wasAway || requiresReconciliation,
      state: &state,
    ))
  }

  func cancelManagedDesktopPreparation(error: String? = nil, state: inout State) -> Effect<Action> {
    guard let request = state.pendingManagedDesktopActivation else { return .none }
    state.pendingManagedDesktopActivation = nil
    let completion = error != nil && request.cliRequestID == state.pendingCLIActivation?.id
      ? completeCLIActivation(error: error, state: &state)
      : .none
    let restore: Effect<Action> = state.desktops.snapshot.map {
      .send(.desktopSpacesObserved($0, revision: state.desktops.revision))
    } ?? .none
    return .merge(.cancel(id: CancelID.managedDesktopActivation), completion, restore)
  }

  // MARK: Private

  private func managedDesktopRequestIsCurrent(_ request: ManagedDesktopActivation, state: State) -> Bool {
    state.config.activeProfile?.id == request.profileID
      && state.config.activeProfile?.workspaces[id: request.workspace.id] == request.workspace
      && state.connectedDisplays.contains(where: { $0.matches(request.display) })
      && !state.isLayoutSuspended
      && (!request.continuesCLIActivation || state.pendingCLIActivation?.id == request.cliRequestID)
  }

}
