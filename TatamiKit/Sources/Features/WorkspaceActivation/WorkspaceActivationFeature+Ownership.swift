// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation

extension WorkspaceActivationFeature.State {
  /// Explicit workspace selection owns non-shared apps. Registration remains
  /// unchanged, so selecting a previous workspace can bring its apps back.
  func appOwner(_ bundleId: String) -> Workspace.ID? {
    guard
      !config.sharedApps.contains(where: { $0.bundleIdentifier == bundleId }),
      let owner = appWorkspaceOwners[bundleId],
      config.activeProfile?.workspaces[id: owner]?.apps.contains(where: {
        $0.bundleIdentifier == bundleId
      }) == true
    else { return nil }
    return owner
  }

  func ownsApp(_ bundleId: String, in workspaceId: Workspace.ID) -> Bool {
    appOwner(bundleId).map { $0 == workspaceId } ?? true
  }

  func presentedWorkspace(_ id: Workspace.ID) -> Workspace? {
    guard var workspace = config.activeProfile?.workspaces[id: id] else { return nil }
    workspace.apps.removeAll { !ownsApp($0.bundleIdentifier, in: id) }
    if let focus = workspace.appToFocusBundleId, !ownsApp(focus, in: id) {
      workspace.appToFocusBundleId = nil
    }
    return workspace
  }
}

extension WorkspaceActivationFeature {
  func retainedApps(onOtherDisplaysThan target: DisplayName?, state: State) -> Set<String> {
    guard let target else { return [] }
    var bundles = Set<String>()
    for id in state.visibleWorkspaceIDs {
      guard let display = state.displayShowing(id), !display.matches(target) else { continue }
      bundles.formUnion(state.presentedWorkspace(id)?.apps.map(\.bundleIdentifier) ?? [])
      bundles.formUnion((state.tilingTrees[id]?.windows ?? []).filter {
        state.ownsApp($0.bundleId, in: id)
      }.map(\.bundleId))
    }
    for assignment in state.pendingDisplayRestores where !assignment.display.matches(target) {
      bundles.formUnion(state.presentedWorkspace(assignment.workspace)?.apps.map(\.bundleIdentifier) ?? [])
    }
    return bundles
  }

  /// Called only for a deliberate selection, never for a background reflow,
  /// display refill, or AX notification. Those paths must not take an app back.
  @discardableResult
  func claimWorkspaceApps(_ id: Workspace.ID, state: inout State) -> Bool {
    guard let workspace = state.config.activeProfile?.workspaces[id: id] else { return false }
    let shared = Set(state.config.sharedApps.map(\.bundleIdentifier))
    let claimed = Set(workspace.apps.map(\.bundleIdentifier)).subtracting(shared)
    let previousOwners = Dictionary(uniqueKeysWithValues: claimed.compactMap { bundleId in
      state.appOwner(bundleId).map { (bundleId, $0) }
    })
    state.appOwnershipGeneration &+= 1
    var transferred = false
    for bundleId in claimed {
      transferred = (state.appOwner(bundleId).map { $0 != id } ?? false) || transferred
      state.appWorkspaceOwners[bundleId] = id
    }
    for source in state.visibleWorkspaceIDs where source != id {
      let lostApps = state.tilingTrees[source]?.windows.contains(where: {
        claimed.contains($0.bundleId)
      }) == true || state.config.activeProfile?.workspaces[id: source]?.apps.contains {
        claimed.contains($0.bundleIdentifier)
          && (previousOwners[$0.bundleIdentifier].map { $0 == source } ?? true)
      } == true
      guard lostApps else { continue }
      transferred = true
      if let tree = state.tilingTrees[source] {
        let removed = Set(tree.windows.filter { claimed.contains($0.bundleId) })
        if !removed.isEmpty {
          rememberLayoutForRestoration(workspaceId: source, tree: tree, state: &state)
          state.tilingTrees[source] = tree.removingAll(removed)
          state.fullscreenZoomed[source]?.subtract(removed)
          state.removeFromWindowMRU(removed, workspaceId: source)
          state.removeFromPresentationMonitoring(removed)
          state.pendingCenterWarps[source] = nil
        }
      }
      state.displacedAppWorkspaces.insert(source)
      debugLog.log("Ownership", "workspace=\(source) yielded apps to \(id)")
    }
    if transferred {
      state.pendingAppClaims.insert(id)
    }
    return transferred || state.pendingAppClaims.contains(id)
  }

  func reconcileDisplacedAppWorkspaces(state: inout State) -> Effect<Action> {
    guard
      !state.isActivating,
      !state.isLayoutSuspended,
      !state.isRecoveringSystemLayout,
      !state.isInFullscreenSpace
    else { return .none }
    let sources = state.displacedAppWorkspaces
    debugLog.log("Ownership", "reconcile sources=\(sources) activating=\(state.isActivating)")
    let generation = state.appOwnershipGeneration
    let profileID = state.config.activeProfile?.id
    var effects = [Effect<Action>]()
    for id in sources {
      guard let display = state.displayShowing(id), let workspace = state.presentedWorkspace(id) else {
        state.displacedAppWorkspaces.remove(id)
        continue
      }
      if let saved = state.pendingLayoutRestorations[id] {
        effects.append(.run { [layoutStore] _ in await layoutStore.save(id, saved) })
      }
      if !state.isTilingPaused {
        effects.append(flushLayout(workspaceId: id, state: &state))
      }
      guard state.tilingTrees[id]?.windows.isEmpty ?? true else {
        state.displacedAppWorkspaces.remove(id)
        continue
      }
      let bundles = workspace.apps.map(\.bundleIdentifier)
      effects.append(.run { [windowSnapshot] send in
        let keys = bundles.isEmpty ? [] : await windowSnapshot.discoverKeysOffMain(bundles, false)
        guard !Task.isCancelled else { return }
        await send(.displacedAppWorkspaceResolved(
          workspaceId: id,
          display: display,
          hasWindows: !keys.isEmpty,
          generation: generation,
          profileID: profileID,
        ))
      })
    }
    return .merge(effects)
  }

  func refillDisplacedAppWorkspace(
    _ id: Workspace.ID,
    display: DisplayName,
    state: inout State,
  ) -> Effect<Action> {
    guard let profile = state.config.activeProfile else { return .none }
    if state.compositionsByDisplay[display]?.borrowed.contains(where: { $0.workspace == id }) == true {
      return dismissBorrow(display: display, setFocus: false, claimsApps: false, state: &state)
    }
    // A live borrowed block still gives this display content even when its
    // host lent its last app to that block. Do not dismiss a user's summon.
    if let composition = state.compositionsByDisplay[display], composition.host == id, !composition.borrowed.isEmpty {
      return .none
    }
    guard state.activeWorkspace(on: display) == id else { return .none }
    state.activeWorkspacesByDisplay = state.activeWorkspacesByDisplay.filter {
      !$0.key.matches(display)
    }
    let candidates = profile.workspaces.elements.filter { $0.id != id && $0.kind != .scratchpad }
    let byId = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
    let next = Self.chooseWorkspaceForDisplay(
      display,
      reconnect: false,
      byId: byId,
      workspaces: candidates,
      assigned: state.activeWorkspacesByDisplay,
      history: state.displayWorkspaceHistory,
      connected: state.connectedDisplays,
    )
    debugLog.log("Ownership", "vacated \(display.name) workspace=\(id) refill=\(String(describing: next))")
    guard let next else { return .none }
    // A refill is availability repair, not another user selection. Its app
    // list is filtered through the existing claims and it never takes focus.
    state.pendingDisplayRestores.append(DisplayAssignment(display: display, workspace: next))
    return state.activeActivationGeneration == nil ? .send(.processDisplayRestores) : .none
  }
}
