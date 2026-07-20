import AppKit
import ComposableArchitecture
import Foundation
import OrderedCollections

extension WorkspaceActivationFeature {

  // MARK: Internal

  /// Keep one physical window in one visible workspace. Shared tiled apps may
  /// have windows on several monitors; their live frame decides which display's
  /// tree owns each window. Non-shared keys already owned by another visible
  /// display stay there instead of being duplicated into a second tree.
  static func scopedWindowKeys(
    _ keys: [WindowKey],
    sharedTiledBundleIds: Set<String>,
    existingTargetKeys: Set<WindowKey>,
    protectedKeys: Set<WindowKey>,
    partitionSharedWindows: Bool,
    targetWorkArea: CGRect,
    windowFrame: (WindowKey) -> CGRect?,
  ) -> [WindowKey] {
    keys.filter { key in
      if partitionSharedWindows, sharedTiledBundleIds.contains(key.bundleId) {
        guard let frame = windowFrame(key) else {
          return existingTargetKeys.contains(key)
        }
        return targetWorkArea.contains(CGPoint(x: frame.midX, y: frame.midY))
      }
      return !protectedKeys.contains(key)
    }
  }

  /// Incremental merge. Removes vanished windows (sibling promotes),
  /// inserts new windows at the insertion point. Fresh trees (no
  /// existing) build via `BSPNode.build` (which uses the shallowest-
  /// leaf rule for each new window).
  ///
  /// `focused` is a closure because resolving it costs a live AX round
  /// trip to the frontmost app — which can block for hundreds of ms on a
  /// busy Electron app right after it was raised. It's only consulted
  /// when there are new windows to anchor, so the common steady-state
  /// merge never pays for it.
  static func mergeTree(
    existing: BSPNode<WindowKey>?,
    target: [WindowKey],
    focused: () -> WindowKey?,
    insertionPoint: WindowKey?,
    workArea: CGRect,
    settings: AppSettings,
  ) -> BSPNode<WindowKey>? {
    guard !target.isEmpty else { return nil }
    let targetSet = Set(target)
    var tree = existing

    if var current = tree {
      let stale = current.windows.filter { !targetSet.contains($0) }
      for id in stale {
        if let next = current.removing(id) {
          current = next
        } else {
          tree = nil
          break
        }
      }
      if tree != nil { tree = current }
    }

    // `tree.windows` is a full recursive tree walk that allocates a fresh
    // array; hoist it into a Set once instead of rebuilding + linear-scanning
    // it per target window (the per-element `contains` made this O(N²)).
    let existing = Set(tree?.windows ?? [])
    let newOnes = target.filter { !existing.contains($0) }
    guard !newOnes.isEmpty else { return tree }

    let viewSplit = settings.layout.splitType.bspSplitAxis()
    let placement = settings.layout.windowPlacement.bspChild

    if tree == nil {
      // Initial tree — each insert picks the shallowest leaf, which
      // `inserting(...)` does when no anchor is supplied.
      var t: BSPNode<WindowKey>? = nil
      for key in newOnes {
        if let cur = t {
          t = cur.inserting(
            key,
            near: nil,
            in: workArea,
            viewSplitType: viewSplit,
            globalPlacement: placement,
          )
        } else {
          t = .leaf(key)
        }
      }
      return t
    }

    let focusedKey = focused()
    for id in newOnes {
      let anchor: WindowKey? = {
        if let insertionPoint, tree?.windows.contains(insertionPoint) == true {
          return insertionPoint
        }
        if let focusedKey, tree?.windows.contains(focusedKey) == true {
          return focusedKey
        }
        return nil
      }()
      tree = tree?.inserting(
        id,
        near: anchor,
        in: workArea,
        viewSplitType: viewSplit,
        globalPlacement: placement,
      ) ?? .leaf(id)
    }
    return tree
  }

  func debouncedSync(_ bundleId: String, delayMs: Int) -> Effect<Action> {
    .run { [clock] send in
      if delayMs > 0 {
        try await clock.sleep(for: .milliseconds(delayMs))
      }
      await send(.syncAppWindows(bundleId: bundleId))
    }
    .cancellable(id: CancelID.sync(bundleId), cancelInFlight: true)
  }

  /// Schedule an off-screen prune after a short delay — a hidden window is
  /// still on screen for an instant after focus moves off it, so let it
  /// settle before snapshotting the on-screen set.
  func debouncedPrune() -> Effect<Action> {
    .run { [clock] send in
      try await clock.sleep(for: .milliseconds(120))
      await send(.pruneOffscreenWindows)
    }
    .cancellable(id: CancelID.prune, cancelInFlight: true)
  }

  /// Incrementally reconcile a single app's windows into the active
  /// workspace's tree. Insert windows new to the tree (next to the
  /// insertion point), remove vanished ones, leave the rest.
  /// Unassigned visible apps are *not* folded into the tree.
  func syncAppWindows(bundleId: String, state: inout State) -> Effect<Action> {
    guard !state.isTilingPaused else {
      debugLog.log("Sync", "skip \(bundleId): tiling paused")
      return .none
    }
    // Dormant in a native fullscreen Space: re-tiling would write frames to (or
    // raise) Desktop windows and bounce the user out of fullscreen. The space-
    // change observer reconciles once they return to a normal Space.
    guard !state.isInFullscreenSpace else {
      debugLog.log("Sync", "skip \(bundleId): native fullscreen space")
      return .none
    }
    if MacApp.isTatami(bundleId) {
      return .none
    }
    // performActivate owns the tree during its async build — let it
    // finish, otherwise an incremental sync races it.
    guard !state.isActivating else {
      debugLog.log("Sync", "skip \(bundleId): activation in flight")
      return .none
    }
    // Bundle-only AX create/destroy notifications do not identify a window or
    // display. Reconcile every visible owner so a shared/multi-member app split
    // across monitors cannot leave a stale window in the background tree.
    let workspaceIds = state.workspacesForSync(bundleId: bundleId)
    guard !workspaceIds.isEmpty else {
      debugLog.log("Sync", "skip \(bundleId): no active workspace")
      return .none
    }
    var effects = [Effect<Action>]()
    for workspaceId in workspaceIds {
      effects.append(syncAppWindows(
        bundleId: bundleId,
        workspaceId: workspaceId,
        state: &state,
      ))
    }
    return .merge(effects)
  }

  /// Drop active-workspace tree windows that have left the screen without an
  /// AX destroy event. Electron apps like Discord `hide()` their window on
  /// close instead of destroying it, so no `kAXUIElementDestroyedNotification`
  /// fires and the slot lingers; the on-screen window list is the only signal.
  /// Re-tiles the survivors and, when focus was stranded, pulls it to one.
  func pruneOffscreenWindows(state: inout State) -> Effect<Action> {
    guard !state.isTilingPaused, !state.isActivating else { return .none }
    // In a native fullscreen Space the Desktop's windows are all off-screen, so
    // the on-screen list reports them "gone". Pruning then would empty the tree
    // and bounce the user out of fullscreen — stay put until they return (the
    // space-change reconcile catches up on exit).
    if state.isInFullscreenSpace {
      debugLog.log("Prune", "skip: native fullscreen space")
      return .none
    }

    // WindowServer destruction is global. Pruning only the cursor display left
    // dead slots resident on background monitors until the user switched back.
    let targetIds = Array(state.visibleWorkspaceIDs)
    guard !targetIds.isEmpty else { return .none }

    let onScreen = windowSnapshot.onScreenWindowIDs()
    let settings = state.config.settings
    let axis = settings.layout.autoBalance
    // Read focus lazily — only when a prune actually happens (the read is an
    // AX round trip to the frontmost app, and prune runs after every
    // activation).
    var focusedRead = false
    var focused: WindowKey?

    var prunedAny = false
    var effects = [Effect<Action>]()
    var postLayoutFocusEffects = [Effect<Action>]()
    var layoutRootsByDisplay = [DisplayName: Workspace.ID]()
    var displaylessLayoutRoots = Set<Workspace.ID>()
    for workspaceId in targetIds {
      guard
        let workspace = state.config.activeProfile?.workspaces[id: workspaceId],
        let tree = state.tilingTrees[workspaceId]
      else { continue }
      let gone = tree.windows.filter { !onScreen.contains($0.windowID) }
      guard !gone.isEmpty else { continue }
      windowSnapshot.invalidateWindowIDs(Set(gone.map(\.windowID)))
      if !focusedRead { focused = windowSnapshot.focusedWindowKey()
        focusedRead = true
      }

      var pruned: BSPNode<WindowKey>? = tree
      for key in gone { pruned = pruned?.removing(key) }
      let balanced = axis == .none ? pruned : pruned?.balanced(axis: axis)
      state.tilingTrees[workspaceId] = balanced
      let newWindows = Set(balanced?.windows ?? [])
      state.removeFromWindowMRU(Set(gone), workspaceId: workspaceId)
      let zoomed = state.fullscreenZoomed[workspaceId] ?? []
      prunedAny = true
      if let display = state.displayShowing(workspaceId) {
        layoutRootsByDisplay[display] = state.activeWorkspacesByDisplay[display] ?? workspaceId
      } else {
        displaylessLayoutRoots.insert(workspaceId)
      }

      debugLog.log(
        "Prune",
        "ws=\(workspace.name) removed=\(gone.map { $0.windowID }) "
          + "treeAfter=\(balanced?.windows.map { $0.windowID } ?? [])",
      )

      var postLayoutFocusEffect = Effect<Action>.none
      var willRefocus = false
      if
        settings.focus.refocusOnClose, !newWindows.isEmpty,
        focused == nil || !newWindows.contains(focused!)
      {
        // A background monitor losing a window must never steal keyboard focus.
        // Refocus when that exact focused window disappeared, or when AX has no
        // focus during a close on the reducer's currently focused display.
        let mayRefocus = focused.map(gone.contains) == true
          || (focused == nil && state.displayShowing(workspaceId) == state.focusedDisplay)
        if mayRefocus {
          let target = state.mruWindows[workspaceId]?.first { newWindows.contains($0) }
            ?? balanced?.windows.first
          if let target {
            willRefocus = true
            postLayoutFocusEffect = settleFocusAfterLayout(
              target,
              workspaceId: workspaceId,
              shouldFocus: true,
              state: &state,
            )
          }
        }
      }
      if !willRefocus, let focused, newWindows.contains(focused) {
        postLayoutFocusEffect = settleFocusAfterLayout(
          focused,
          workspaceId: workspaceId,
          shouldFocus: false,
          state: &state,
        )
      }

      effects.append(
        persist(balanced, fullscreenZoomed: zoomed, for: workspace)
      )
      postLayoutFocusEffects.append(postLayoutFocusEffect)
      // Pruning only runs when windows actually left the screen.
      effects.append(handleEmptied(workspaceId: workspaceId, state: state))
    }

    guard prunedAny else { return .none }
    // One writer per affected display. Composition roots flush every block in
    // one frame application. Focus/cursor settlement observes all applied
    // layouts, including when several monitors lost windows in the same event.
    let layoutEffects = layoutRootsByDisplay.values.map {
      flushLayout(workspaceId: $0, state: state)
    } + displaylessLayoutRoots.map {
      flushLayout(workspaceId: $0, state: state)
    }
    effects.append(.concatenate(.merge(layoutEffects), .merge(postLayoutFocusEffects)))
    effects.append(refreshMarkers(state: state))
    return .merge(effects)
  }

  /// Re-apply the dragged window's owning tree frames (no tree change), snapping
  /// it back to its slot when the drag committed nothing. Ownership, rather
  /// than focused/cursor display, keeps a background-monitor drag local.
  func retile(windowKey: WindowKey, state: State) -> Effect<Action> {
    guard
      let workspaceId = state.workspaceOwning(windowKey),
      state.tilingTrees[workspaceId] != nil
    else { return .none }
    return flushLayout(workspaceId: workspaceId, state: state)
  }

  // MARK: Private

  /// Bundle ids registered to any workspace anywhere in the config.
  /// `syncAppWindows` uses this to decide whether a window belongs to
  /// the active workspace's tree (registered here / unregistered
  /// anywhere → transient) or to some other workspace (skip).
  private static func everyAssignedBundleId(in config: AppConfig) -> Set<String> {
    var out = Set<String>()
    for profile in config.profiles {
      for ws in profile.workspaces {
        for app in ws.apps {
          out.insert(app.bundleIdentifier)
        }
      }
    }
    return out
  }

  private func syncAppWindows(
    bundleId: String,
    workspaceId: Workspace.ID,
    state: inout State,
  ) -> Effect<Action> {
    guard
      let workspace = state.config.activeProfile?
        .workspaces[id: workspaceId]
    else { return .none }

    let settings = state.config.settings
    let registeredSet = Set(workspace.apps.map(\.bundleIdentifier))
    // Floating = shown but never tiled (excluded from the tree): this
    // workspace's per-window floating apps + shared floating apps.
    let floatingSet = Set(workspace.apps.filter { $0.layout == .floating }.map(\.bundleIdentifier))
      .union(state.config.sharedApps.filter { $0.layout == .floating }.map(\.bundleIdentifier))
    // Unmanaged = member but never tiled and never mirrored — the real
    // window is left alone. Tracked so sync skips it like a floating app,
    // minus the overlay refresh.
    let unmanagedSet = Set(workspace.apps.filter { $0.layout == .unmanaged }.map(\.bundleIdentifier))
      .union(state.config.sharedApps.filter { $0.layout == .unmanaged }.map(\.bundleIdentifier))
    // Shared tiled apps tile into every workspace's layout.
    let sharedTiledSet = Set(
      state.config.sharedApps.filter { $0.layout == .tiled }.map(\.bundleIdentifier)
    )
    let assignedAnywhere = Self.everyAssignedBundleId(in: state.config)
    let existing = state.tilingTrees[workspaceId]
    let inTree = existing?.windows.contains { $0.bundleId == bundleId } ?? false

    // Floating apps never enter the tree. Instead, refresh their mirror
    // overlays so a window opening / closing on a floating app is reflected
    // on top live (not just on the next activation). Markers re-resolve in
    // the same beat — floating dots are discovered from live windows, so
    // skipping this left a quit app's dot up until the next focus change.
    if unmanagedSet.contains(bundleId) {
      // Unmanaged: never tiled, never mirrored — the window stays put. Still
      // a member, so a per-workspace unmanaged window closing can empty the
      // workspace; shared unmanaged apps aren't workspace content.
      // Still a managed member: discover it (populating the cache, which
      // feeds both the FFM hit-test and window cycling) but don't tile or
      // mirror.
      _ = windowSnapshot.discoverKeys([bundleId], false)
      return workspace.apps
        .contains { $0.layout == .unmanaged && $0.bundleIdentifier == bundleId }
        ? handleEmptied(workspaceId: workspaceId, state: state)
        : .none
    }
    if floatingSet.contains(bundleId) {
      // A *per-workspace* floating window closing can empty the workspace;
      // shared floats aren't workspace content, so their events don't bounce.
      let emptySwitch = workspace.apps
        .contains { $0.layout == .floating && $0.bundleIdentifier == bundleId }
        ? handleEmptied(workspaceId: workspaceId, state: state)
        : Effect<Action>.none
      return .merge(
        refreshFloatingPresentation(state: state),
        emptySwitch,
      )
    }
    // Eligibility:
    //   * registered in this workspace → always tile.
    //   * a shared tiled app → tiles into every workspace.
    //   * already in the tree (transient member from an earlier sync)
    //     → keep tiling so the window doesn't suddenly fall out.
    //   * unregistered anywhere → transient: gets folded into the
    //     active workspace's tree because the user just opened/raised
    //     it after activation. The next activation rebuilds the tree
    //     from the registered set alone, so the transient drops out
    //     automatically.
    //   * registered in some *other* workspace → not tiled here;
    //     followAppFocus (if enabled) jumps to its owning workspace
    //     instead.
    let isUnregisteredAnywhere = !assignedAnywhere.contains(bundleId)
    let eligibleToAdd = registeredSet.contains(bundleId)
      || sharedTiledSet.contains(bundleId)
      || inTree
      || isUnregisteredAnywhere

    let discovered = windowSnapshot.discoverKeys([bundleId], true)
    let targetDisplay = state.displayShowing(workspaceId)
    var protectedKeys = Set<WindowKey>()
    if let targetDisplay {
      for otherId in state.visibleWorkspaceIDs where otherId != workspaceId {
        guard
          let otherDisplay = state.displayShowing(otherId),
          !otherDisplay.matches(targetDisplay)
        else { continue }
        protectedKeys.formUnion(state.tilingTrees[otherId]?.windows ?? [])
      }
    }
    let existingTargetKeys = Set(existing?.windows ?? [])
    let targetWorkArea = displays.workArea(targetDisplay)
    let current = Self.scopedWindowKeys(
      discovered,
      sharedTiledBundleIds: sharedTiledSet,
      existingTargetKeys: existingTargetKeys,
      protectedKeys: protectedKeys,
      partitionSharedWindows: state.connectedDisplays.count > 1
        || state.activeWorkspacesByDisplay.count > 1,
      targetWorkArea: targetWorkArea,
      windowFrame: { windowSnapshot.windowFrame($0) },
    )
    // The block's geometry — composition sub-rect when this is a borrowed/host
    // block, else the workspace's full work area. New windows insert into it.
    let (_, workArea) = tilingContext(for: workspaceId, state: state)
    let currentSet = Set(current)
    let treeWindows = existing?.windows ?? []
    let willRemove = treeWindows.contains { $0.bundleId == bundleId && !currentSet.contains($0) }
    let willInsert = eligibleToAdd && current.contains { !treeWindows.contains($0) }
    // The focused-window read is a live AX round trip to the frontmost
    // app — the slowest call in a no-op sync (an Electron app answers AX
    // late right after being raised). Only a sync that changes the tree
    // needs it (insertion anchor + refocus); pure focus bookkeeping is
    // event-driven (`windowFocused` / `appActivated`).
    let focused: WindowKey? = (willRemove || willInsert)
      ? windowSnapshot.focusedWindowKey()
      : nil
    if let focused, existing?.windows.contains(focused) == true {
      state.insertionPoint[workspaceId] = focused
    }
    let insertionPointKey = state.insertionPoint[workspaceId]

    let treeBefore = existing?.windows.map { $0.windowID } ?? []
    debugLog.log(
      "Sync",
      "enter \(bundleId) ws=\(workspace.name) eligible=\(eligibleToAdd) "
        + "(registered=\(registeredSet.contains(bundleId)) "
        + "inTree=\(inTree) unregistered=\(isUnregisteredAnywhere)) "
        + "discovered=\(current.map { $0.windowID }) treeBefore=\(treeBefore)",
    )

    var tree = existing
    for key in (tree?.windows ?? []) where key.bundleId == bundleId && !currentSet.contains(key) {
      tree = tree?.removing(key)
    }

    // Insert new windows next to the insertion point. After each
    // insert, the new window becomes the insertion anchor — that's
    // what makes the dwindle wind instead of all-windows piling onto
    // one node.
    if eligibleToAdd {
      let viewSplit = settings.layout.splitType.bspSplitAxis()
      let placement = settings.layout.windowPlacement.bspChild
      var anchor = insertionPointKey
      for key in current {
        guard let current = tree else {
          tree = .leaf(key)
          anchor = key
          state.insertionPoint[workspaceId] = key
          continue
        }
        if current.windows.contains(key) { continue }
        let present = Set(current.windows)
        let resolved = [anchor, focused]
          .compactMap { $0 }
          .first { present.contains($0) }
        tree = current.inserting(
          key,
          near: resolved,
          in: workArea,
          viewSplitType: viewSplit,
          globalPlacement: placement,
        )
        anchor = key
        state.insertionPoint[workspaceId] = key
      }
    }

    let axis = settings.layout.autoBalance
    let balanced = axis == .none ? tree : tree?.balanced(axis: axis)
    let oldWindows = Set(existing?.windows ?? [])
    let newWindows = Set(balanced?.windows ?? [])
    let removedKeys = oldWindows.subtracting(newWindows)
    state.tilingTrees[workspaceId] = balanced
    state.removeFromWindowMRU(removedKeys, workspaceId: workspaceId)

    // A native-tab switch (Ghostty, Terminal) retires the active tab's
    // CGWindowID and surfaces a new one for the same app — so a fullscreen-zoom
    // recorded on the retired id would fall back to a half tile. Migrate the
    // zoom to the replacement (same app, newly in the tree).
    //
    // Only *migrate* — never drop a zoom key just because its window isn't in
    // the tree this pass. A window transiently absent (monitor unplug/replug
    // churn empties the tree, then the window returns with the same id) would
    // otherwise lose its zoom permanently. A key whose window is genuinely gone
    // is harmless: `computeFrames` ignores a zoom key not in the tree, so the
    // workspace un-zooms correctly on close and the stale key just lingers.
    if var zoom = state.fullscreenZoomed[workspaceId], !zoom.isEmpty {
      let addedKeys = newWindows.subtracting(oldWindows)
      var changed = false
      for stale in zoom where balanced?.pathTo(window: stale) == nil {
        guard let replacement = addedKeys.first(where: { $0.bundleId == stale.bundleId })
        else { continue }
        zoom.remove(stale)
        zoom.insert(replacement)
        changed = true
      }
      if changed { state.fullscreenZoomed[workspaceId] = zoom.isEmpty ? nil : zoom }
    }

    let added = newWindows.subtracting(oldWindows).map { $0.windowID }
    let removed = removedKeys.map { $0.windowID }
    debugLog.log(
      "Sync",
      "result \(bundleId): added=\(added) removed=\(removed) "
        + "treeAfter=\(balanced?.windows.map { $0.windowID } ?? [])",
    )

    // Shared apps included so floating ones get window events too (they're
    // in neither the tree nor the workspace's registered set).
    let observeIds = Array(OrderedSet(
      (balanced?.windows.map(\.bundleId) ?? [])
        + Array(registeredSet)
        + state.config.sharedApps.map(\.bundleIdentifier)
    ))
    let observeEffect = Effect<Action>.run { [observer = windowObserver] _ in
      await observer.observe(observeIds)
    }
    // Only a sync that actually removed windows can have emptied the
    // workspace — launch/no-op syncs must never bounce the user off a
    // deliberately empty one.
    let emptySwitch = removed.isEmpty
      ? Effect<Action>.none
      : handleEmptied(workspaceId: workspaceId, state: state)

    let treeChanged = oldWindows != newWindows
    let markerRefresh = treeChanged ? refreshMarkers(state: state) : .none
    guard treeChanged, let final = balanced else {
      return .merge(observeEffect, markerRefresh, emptySwitch)
    }

    // When a window closed and focus would otherwise be stranded on a
    // now-windowless app (the frontmost window is no longer part of this
    // workspace), pull focus to a remaining window so typing has a home.
    // Gated on the removed key actually owning focus (or AX temporarily having
    // no focus on this display), so a background monitor never steals it.
    var postLayoutFocusEffect = Effect<Action>.none
    var willRefocus = false
    let mayRefocus = focused.map(removedKeys.contains) == true
      || (focused == nil && state.displayShowing(workspaceId) == state.focusedDisplay)
    if
      settings.focus.refocusOnClose,
      !removed.isEmpty,
      mayRefocus
    {
      let target = state.mruWindows[workspaceId]?.first { newWindows.contains($0) }
        ?? final.windows.first
      if let target {
        willRefocus = true
        postLayoutFocusEffect = settleFocusAfterLayout(
          target,
          workspaceId: workspaceId,
          shouldFocus: true,
          state: &state,
        )
      }
    }

    // Mouse-follows-focus when focus moved without the mouse: a *newly opened*
    // window the OS focused, or a *close* that shifted focus to a surviving tile
    // (Tatami's refocus above didn't fire because focus landed validly on its
    // own). Warp to the tile's new center either way — on a close the surviving
    // tile expands over where the cursor sat, so "cursor already inside" is not
    // a reason to skip. Ordinary click-focus doesn't reach here (no tree edit).
    if
      !willRefocus, let focused, newWindows.contains(focused),
      newWindows.subtracting(oldWindows).contains(focused) || !removed.isEmpty
    {
      postLayoutFocusEffect = settleFocusAfterLayout(
        focused,
        workspaceId: workspaceId,
        shouldFocus: false,
        state: &state,
      )
    }

    let zoomed = state.fullscreenZoomed[workspaceId] ?? []
    let layoutThenFocus = Effect<Action>.concatenate(
      flushLayout(workspaceId: workspaceId, state: state),
      postLayoutFocusEffect,
    )
    return .merge(
      layoutThenFocus,
      observeEffect,
      persist(final, fullscreenZoomed: zoomed, for: workspace),
      markerRefresh,
      emptySwitch,
    )
  }

  /// `switchToRecentWhenEmpty`: a close left the active workspace with
  /// nothing of its own on screen — nothing tiled (registered, shared
  /// tiled, or transient) and no *per-workspace* floating window — so jump
  /// back to the recent workspace. Shared apps don't anchor: they join
  /// every workspace, and a shared float follows you to the recent one
  /// anyway. The tile-sync and prune callers gate on an actual removal;
  /// the floating-branch caller relies on the live floating re-discovery
  /// below — either way, deliberately sitting on an empty workspace never
  /// bounces you out.
  private func switchToRecentIfEmpty(
    state: State,
    workspaceId: Workspace.ID,
  ) -> Effect<Action> {
    guard
      state.config.settings.switching.switchToRecentWhenEmpty,
      !state.isActivating,
      state.primaryActiveWorkspaceID == workspaceId,
      let workspace = state.config.activeProfile?
        .workspaces[id: workspaceId],
      state.tilingTrees[workspaceId]?.windows.isEmpty ?? true
    else { return .none }
    // Recent on the display the workspace is actually shown on (resolved via
    // activeWorkspacesByDisplay first, not the cursor); falls back to any recent.
    let display = tilingContext(for: workspaceId, state: state).display
    let recent = display.flatMap { state.previousWorkspacesByDisplay[$0] }
      ?? state.previousWorkspacesByDisplay.values.first
    guard let recent, recent != workspaceId else { return .none }
    // The BSP tree can read empty *transiently* while a window's identity
    // is mid-flight — ghostty's native tabs each carry their own window id,
    // so switching tabs swaps the live window out from under the tree (the
    // old id is pruned before the new one syncs back in). Re-check the
    // workspace's own tiled apps against the live window list: a tab switch
    // leaves the app on screen, so a momentarily-stale tree must not be
    // mistaken for an empty workspace and bounce the user to the recent one.
    // Tiled *and* unmanaged apps occupy real screen space (only floating
    // ones are mirrors). A live AX re-check of those tells "tree
    // momentarily stale" (e.g. a native-tab window-id swap) apart from
    // "workspace truly empty". requireResizable=false so fixed-size
    // unmanaged windows (media players, etc.) still count.
    let onScreenIds = workspace.apps.filter { $0.layout != .floating }.map(\.bundleIdentifier)
    let hasOnScreen = !onScreenIds.isEmpty
      && !windowSnapshot.discoverKeys(onScreenIds, false).isEmpty
    guard !hasOnScreen else {
      debugLog.log(
        "Sync",
        "ws=\(workspace.name) tree empty but member apps still on screen — not switching",
      )
      return .none
    }
    // A still-open per-workspace floating window anchors the workspace.
    let floatingIds = workspace.apps.filter { $0.layout == .floating }.map(\.bundleIdentifier)
    let hasFloating = !floatingIds.isEmpty
      && !windowSnapshot.discoverKeys(floatingIds, false).isEmpty
    guard !hasFloating else { return .none }
    debugLog.log("Sync", "ws=\(workspace.name) empty → switch to recent")
    return .send(.activate(workspaceId: recent, setFocus: true))
  }

  /// Empty-block handling after a sync/prune removal: the host block falls
  /// back to `switchToRecentIfEmpty`, a borrowed block collapses its borrow so
  /// the host reclaims the full screen. Both are gated on the tree actually
  /// being empty, so a deliberately-empty block never bounces.
  private func handleEmptied(workspaceId: Workspace.ID, state: State) -> Effect<Action> {
    if state.primaryActiveWorkspaceID == workspaceId {
      return switchToRecentIfEmpty(state: state, workspaceId: workspaceId)
    }
    return collapseIfBorrowedEmpty(borrowedId: workspaceId, state: state)
  }

  /// A borrowed block lost all its windows → dismiss the borrow. Re-checks the
  /// borrowed workspace's on-screen apps first so a transient empty tree (e.g.
  /// a native-tab window-id swap) doesn't collapse the composition.
  private func collapseIfBorrowedEmpty(
    borrowedId: Workspace.ID,
    state: State,
  ) -> Effect<Action> {
    guard !state.isActivating else { return .none }
    for (display, comp) in state.compositionsByDisplay
      where comp.borrowed.contains(where: { $0.workspace == borrowedId })
    {
      guard
        state.tilingTrees[borrowedId]?.windows.isEmpty ?? true,
        let borrowedWs = state.config.activeProfile?.workspaces[id: borrowedId]
      else { return .none }
      let onScreenIds = borrowedWs.apps.filter { $0.layout != .floating }.map(\.bundleIdentifier)
      let hasOnScreen = !onScreenIds.isEmpty
        && !windowSnapshot.discoverKeys(onScreenIds, false).isEmpty
      guard !hasOnScreen else {
        debugLog.log("Borrow", "borrowed \(borrowedWs.name) tree empty but apps on screen — keep")
        return .none
      }
      debugLog.log("Borrow", "borrowed \(borrowedWs.name) empty → dismiss")
      return .send(.dismissBorrow(display: display))
    }
    return .none
  }

}
