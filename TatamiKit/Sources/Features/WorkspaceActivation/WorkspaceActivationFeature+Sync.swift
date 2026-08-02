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

  /// Pair old/new WindowServer identities from one app while preserving the
  /// logical BSP slot. macOS native tabs are separate CGWindow surfaces: a tab
  /// switch removes one id and exposes another, but it is not a close followed
  /// by an unrelated window insertion.
  static func surfaceReplacements(
    outgoing: [WindowKey],
    incoming: [WindowKey],
    expectedFrames: [WindowKey: CGRect],
    liveFrames: [CGWindowID: CGRect],
  ) -> [WindowKey: WindowKey] {
    guard !outgoing.isEmpty, !incoming.isEmpty else { return [:] }
    var available = incoming
    var replacements = [WindowKey: WindowKey]()
    for old in outgoing {
      let sameProcess = available.indices.filter { available[$0].pid == old.pid }
      guard !sameProcess.isEmpty else { continue }
      let oldFrame = expectedFrames[old]
      let best = sameProcess.min { lhs, rhs in
        let lhsKey = available[lhs]
        let rhsKey = available[rhs]
        func distance(_ key: WindowKey) -> CGFloat {
          guard let oldFrame, let frame = liveFrames[key.windowID] else {
            return .greatestFiniteMagnitude
          }
          let dx = frame.midX - oldFrame.midX
          let dy = frame.midY - oldFrame.midY
          return dx * dx + dy * dy
        }
        let lhsDistance = distance(lhsKey)
        let rhsDistance = distance(rhsKey)
        return lhsDistance == rhsDistance
          ? lhsKey.windowID < rhsKey.windowID
          : lhsDistance < rhsDistance
      }
      guard let best else { continue }
      replacements[old] = available.remove(at: best)
    }
    return replacements
  }

  /// Pure target-rect variant of `computeFrames`. Visibility reconciliation
  /// already owns an exact display/composition rect, so it must not cross the
  /// MainActor-only NSScreen boundary merely to compare surface geometry.
  static func replacementExpectedFrames(
    tree: BSPNode<WindowKey>,
    settings: AppSettings,
    targetRect: CGRect,
    fullscreenZoomed: Set<WindowKey>,
  ) -> [WindowKey: CGRect] {
    let gap = CGFloat(settings.layout.gapInner)
    let activeZoom = fullscreenZoomed.intersection(Set(tree.windows))
    guard !activeZoom.isEmpty else {
      return tree.frames(in: targetRect, gap: gap)
    }
    let trimmed = tree.removingAll(activeZoom)
    var frames = trimmed?.frames(in: targetRect, gap: gap) ?? [:]
    for key in activeZoom { frames[key] = targetRect }
    return frames
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

  /// Enter the reducer-owned single-flight/dirty reconciliation path.
  /// No timer or cooperative scheduling guess is involved.
  func requestWindowSync(_ bundleId: String) -> Effect<Action> {
    .send(.syncAppWindows(bundleId: bundleId))
  }

  /// Capture one app's AX window set off the main actor. The reducer guarantees
  /// one in-flight request per bundle and schedules a trailing pass when any
  /// notification arrives during this scan.
  func syncAppWindows(bundleId: String, state: inout State) -> Effect<Action> {
    guard !state.isSystemSuspended else {
      debugLog.log("Sync", "skip \(bundleId): system suspended")
      return .none
    }
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
    if state.windowSyncBundleIdsInFlight.contains(bundleId) {
      state.dirtyWindowSyncBundleIds.insert(bundleId)
      debugLog.log("Sync", "dirty \(bundleId): discovery already in flight")
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

    var needsResizableDiscovery = false
    var needsMovableCache = false
    for workspaceId in workspaceIds {
      guard let workspace = state.config.activeProfile?.workspaces[id: workspaceId]
      else { continue }
      let floating = workspace.apps.contains {
        $0.bundleIdentifier == bundleId && $0.layout == .floating
      } || state.config.sharedApps.contains {
        $0.bundleIdentifier == bundleId && $0.layout == .floating
      }
      let unmanaged = workspace.apps.contains {
        $0.bundleIdentifier == bundleId && $0.layout == .unmanaged
      } || state.config.sharedApps.contains {
        $0.bundleIdentifier == bundleId && $0.layout == .unmanaged
      }
      if unmanaged {
        needsMovableCache = true
      } else if !floating {
        needsResizableDiscovery = true
      }
    }

    let snapshot = windowSnapshot
    let discoverResizable = needsResizableDiscovery
    let populateMovableCache = needsMovableCache
    state.windowSyncBundleIdsInFlight.insert(bundleId)
    return .run(priority: .high) { send in
      let resizableKeys: [WindowKey]?
      switch (discoverResizable, populateMovableCache) {
      case (true, true):
        let capabilities = await snapshot.discoverCapabilitiesOffMain([bundleId])
        resizableKeys = capabilities.resizableKeys

      case (true, false):
        resizableKeys = await snapshot.discoverKeysOffMain([bundleId], true)

      case (false, true):
        _ = await snapshot.discoverKeysOffMain([bundleId], false)
        resizableKeys = nil

      case (false, false):
        // Floating presentation owns its own all-visible-floats discovery.
        resizableKeys = nil
      }
      let frames = snapshot.onScreenWindowFrames()
      await send(.syncAppWindowsResolved(
        bundleId: bundleId,
        resizableKeys: resizableKeys,
        onScreenFrames: frames,
      ))
    }
  }

  /// Incrementally reconcile one completed worker snapshot into every visible
  /// owner. Insert new windows next to the insertion point, remove vanished
  /// ones, and leave the rest untouched.
  func applySyncedAppWindows(
    bundleId: String,
    resizableKeys: [WindowKey]?,
    onScreenFrames: [CGWindowID: CGRect],
    state: inout State,
  ) -> Effect<Action> {
    guard
      !state.isSystemSuspended,
      !state.isTilingPaused,
      !state.isInFullscreenSpace,
      !state.isActivating,
      !MacApp.isTatami(bundleId)
    else { return .none }
    let workspaceIds = state.workspacesForSync(bundleId: bundleId)
    guard !workspaceIds.isEmpty else { return .none }
    var effects = [Effect<Action>]()
    for workspaceId in workspaceIds {
      effects.append(syncAppWindows(
        bundleId: bundleId,
        workspaceId: workspaceId,
        discovered: resizableKeys,
        onScreenFrames: onScreenFrames,
        state: &state,
      ))
    }
    // Observer installation emits a synthetic create event after its AX
    // notifications are armed. Even when that reconciliation is a tree no-op,
    // verify presentation once more: the app may have restored its own frame
    // between the initial layout snapshot and observer readiness.
    if
      state.presentationConvergenceWindows.contains(where: {
        $0.bundleId == bundleId
      })
    {
      effects.append(
        .send(.presentationObservationReady(bundleIds: [bundleId]))
      )
    }
    return .merge(effects)
  }

  /// Consume a WindowServer 816 edge as an atomic surface replacement when a
  /// new layer-0 surface from the same process is already occupying the tile's
  /// display. The fast local snapshot keeps native-tab switching immediate;
  /// the normal AX sync still follows as an eligibility/cache verification.
  func replaceInvisibleWindowServerSurface(
    windowID: CGWindowID,
    state: inout State,
  ) -> Effect<Action>? {
    guard
      let workspaceId = state.visibleWorkspaceIDs.first(where: { workspaceId in
        state.tilingTrees[workspaceId]?.windows.contains(where: {
          $0.windowID == windowID
        }) == true
      }),
      let tree = state.tilingTrees[workspaceId],
      let outgoing = tree.windows.first(where: { $0.windowID == windowID })
    else { return nil }

    let surfaces = windowSnapshot.onScreenWindowSurfaces()
    let knownWindowIDs = Set(
      state.visibleWorkspaceIDs.flatMap {
        state.tilingTrees[$0]?.windows.map(\.windowID) ?? []
      }
    )
    let (_, targetRect) = tilingContext(for: workspaceId, state: state)
    let expectedFrames = Self.replacementExpectedFrames(
      tree: tree,
      settings: state.config.settings,
      targetRect: targetRect,
      fullscreenZoomed: state.fullscreenZoomed[workspaceId] ?? [],
    )
    let expectedFrame = expectedFrames[outgoing]
    let candidates = surfaces.compactMap { windowID, surface -> WindowKey? in
      guard
        surface.ownerPID == outgoing.pid,
        surface.layer == 0,
        !knownWindowIDs.contains(windowID),
        surface.frame.width > 0,
        surface.frame.height > 0,
        targetRect.contains(CGPoint(x: surface.frame.midX, y: surface.frame.midY))
      else { return nil }
      return WindowKey(
        pid: outgoing.pid,
        windowID: windowID,
        bundleId: outgoing.bundleId,
      )
    }
    let replacement = candidates.min { lhs, rhs in
      func distance(_ key: WindowKey) -> CGFloat {
        guard let expectedFrame, let frame = surfaces[key.windowID]?.frame else {
          return .greatestFiniteMagnitude
        }
        let dx = frame.midX - expectedFrame.midX
        let dy = frame.midY - expectedFrame.midY
        return dx * dx + dy * dy
      }
      let lhsDistance = distance(lhs)
      let rhsDistance = distance(rhs)
      return lhsDistance == rhsDistance
        ? lhs.windowID < rhs.windowID
        : lhsDistance < rhsDistance
    }
    guard let replacement else { return nil }

    state.windowServerHiddenWindows.insert(outgoing)
    windowSnapshot.markBundleDirty(outgoing.bundleId)
    let orderedVisible = state.config.activeProfile?.workspaces.map(\.id) ?? []
    let existingBundleKeys = orderedVisible
      .filter(state.visibleWorkspaceIDs.contains)
      .flatMap { state.tilingTrees[$0]?.windows ?? [] }
      .filter { $0.bundleId == outgoing.bundleId && $0 != outgoing }
    let discovered = Array(OrderedSet(existingBundleKeys + [replacement]))
    let frames = surfaces.mapValues(\.frame)
    debugLog.log(
      "SLS",
      "surface replacement \(outgoing.bundleId) "
        + "\(outgoing.windowID)→\(replacement.windowID)",
    )
    return .merge(
      applySyncedAppWindows(
        bundleId: outgoing.bundleId,
        resizableKeys: discovered,
        onScreenFrames: frames,
        state: &state,
      ),
      requestWindowSync(outgoing.bundleId),
    )
  }

  /// Drop active-workspace tree windows that have left the screen without an
  /// AX destroy event. Electron apps like Discord `hide()` their window on
  /// close instead of destroying it, so no `kAXUIElementDestroyedNotification`
  /// fires and the slot lingers; the on-screen window list is the only signal.
  /// Re-tiles the survivors and, when focus was stranded, pulls it to one.
  func pruneOffscreenWindows(
    knownDestroyedWindowIDs: Set<CGWindowID> = [],
    knownInvisibleWindowIDs: Set<CGWindowID> = [],
    state: inout State,
  ) -> Effect<Action> {
    guard !state.isTilingPaused, !state.isActivating else { return .none }
    if state.isSystemSuspended || state.isRecoveringSystemLayout {
      debugLog.log("Prune", "skip: system layout suspended/recovering")
      return .none
    }
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
    // Focus notifications maintain this state continuously. A prune must not
    // synchronously ask the frontmost app for focus: that is precisely the AX
    // round trip that used to block the hotkey/main event loop under load.
    let focused = state.lastObservedFocusedWindow

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
      let gone = tree.windows.filter {
        knownDestroyedWindowIDs.contains($0.windowID)
          || knownInvisibleWindowIDs.contains($0.windowID)
          || !onScreen.contains($0.windowID)
      }
      guard !gone.isEmpty else { continue }
      // A visibility edge removes the tile but not the WindowServer identity:
      // hide-on-close, minimize, and Space transitions can all bring the same
      // surface back through 815. Every other off-screen id is a real cache
      // invalidation, including explicit 804 termination.
      let invalidatedWindowIDs = Set(gone.map(\.windowID))
        .subtracting(knownInvisibleWindowIDs)
      windowSnapshot.invalidateWindowIDs(invalidatedWindowIDs)
      var pruned: BSPNode<WindowKey>? = tree
      for key in gone { pruned = pruned?.removing(key) }
      let balanced = axis == .none ? pruned : pruned?.balanced(axis: axis)
      state.tilingTrees[workspaceId] = balanced
      let newWindows = Set(balanced?.windows ?? [])
      state.removeFromWindowMRU(Set(gone), workspaceId: workspaceId)
      state.removeFromPresentationMonitoring(Set(gone))
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
        persist(
          balanced,
          fullscreenZoomed: zoomed,
          unresolvedFullscreenZoomSlots:
          state.unresolvedFullscreenZoomSlots[workspaceId] ?? [],
          for: workspace,
        )
      )
      postLayoutFocusEffects.append(postLayoutFocusEffect)
      // Pruning only runs when windows actually left the screen.
      effects.append(handleEmptied(workspaceId: workspaceId, state: state))
    }

    guard prunedAny else { return .none }
    // One writer per affected display. Composition roots flush every block in
    // one frame application. Focus/cursor settlement observes all applied
    // layouts, including when several monitors lost windows in the same event.
    var layoutEffects = [Effect<Action>]()
    for workspaceId in layoutRootsByDisplay.values {
      layoutEffects.append(
        flushLayout(
          workspaceId: workspaceId,
          state: &state,
          monitorsPresentationChanges: true,
        )
      )
    }
    for workspaceId in displaylessLayoutRoots {
      layoutEffects.append(
        flushLayout(
          workspaceId: workspaceId,
          state: &state,
          monitorsPresentationChanges: true,
        )
      )
    }
    effects.append(.concatenate(.merge(layoutEffects), .merge(postLayoutFocusEffects)))
    effects.append(refreshMarkers(state: state))
    return .merge(effects)
  }

  /// Complete one bundle from the wake reconciliation batch. If every
  /// pre-suspend WindowKey disappeared, WindowServer recycled the whole
  /// workspace and there is no live identity left from which to preserve the
  /// prior tree. Reset only that genuinely lost layout using the same
  /// Auto-balance contract as the explicit Balance command.
  func completeSystemLayoutRecovery(
    bundleId: String,
    state: inout State,
  ) -> Effect<Action> {
    guard state.isRecoveringSystemLayout else { return .none }
    state.pendingSystemLayoutBundleIds.remove(bundleId)
    guard state.pendingSystemLayoutBundleIds.isEmpty else { return .none }

    let suspendedLayouts = state.suspendedLayoutWindows
    state.isRecoveringSystemLayout = false
    state.suspendedLayoutWindows = [:]

    let settings = state.config.settings
    var effects = [Effect<Action>]()
    for (workspaceId, suspendedWindows) in suspendedLayouts {
      guard
        state.visibleWorkspaceIDs.contains(workspaceId),
        let workspace = state.config.activeProfile?.workspaces[id: workspaceId],
        let current = state.tilingTrees[workspaceId],
        !current.windows.isEmpty
      else { continue }

      let lostEveryIdentity = Set(current.windows).isDisjoint(with: suspendedWindows)
      let recovered: BSPNode<WindowKey>
      if lostEveryIdentity {
        let (_, workArea) = tilingContext(for: workspaceId, state: state)
        recovered = current.balancedForCommand(
          autoBalance: settings.layout.autoBalance,
          in: workArea,
          gap: CGFloat(settings.layout.gapInner),
          splitAxis: settings.layout.splitType.bspSplitAxis(),
        )
        state.tilingTrees[workspaceId] = recovered
        state.insertionPoint[workspaceId] = recovered.windows.first
        debugLog.log(
          "Sleep",
          "reset lost layout ws=\(workspace.name) mode=\(settings.layout.autoBalance.rawValue)",
        )
      } else {
        recovered = current
      }
      let zoomed = state.fullscreenZoomed[workspaceId] ?? []
      let save = persist(
        recovered,
        fullscreenZoomed: zoomed,
        unresolvedFullscreenZoomSlots:
        state.unresolvedFullscreenZoomSlots[workspaceId] ?? [],
        for: workspace,
      )
      effects.append(
        lostEveryIdentity
          ? .merge(
            flushLayout(workspaceId: workspaceId, state: &state),
            save,
          )
          : save
      )
    }
    return .merge(effects)
  }

  /// Re-apply the dragged window's owning tree frames (no tree change), snapping
  /// it back to its slot when the drag committed nothing. Ownership, rather
  /// than focused/cursor display, keeps a background-monitor drag local.
  func retile(windowKey: WindowKey, state: inout State) -> Effect<Action> {
    guard
      let workspaceId = state.workspaceOwning(windowKey),
      state.tilingTrees[workspaceId] != nil
    else { return .none }
    return flushPointerDrivenLayout(workspaceId: workspaceId, state: &state)
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
  func handleEmptyWorkspacePresenceResolution(
    workspaceId: Workspace.ID,
    hasOnScreenMembers: Bool,
    hasFloatingWindows: Bool,
    borrowDisplay: DisplayName?,
    borrowGeneration: UInt64?,
    borrowComposition: Composition?,
    state: State,
  ) -> Effect<Action> {
    guard
      !state.isActivating,
      state.tilingTrees[workspaceId]?.windows.isEmpty ?? true
    else { return .none }
    if let borrowDisplay, let borrowGeneration, let borrowComposition {
      // Presence discovery is AX IPC and may complete after a dismiss/reborrow.
      // Only the exact composition generation that started this scan may act
      // on its empty result.
      guard
        state.borrowGenerationByDisplay[borrowDisplay] == borrowGeneration,
        state.compositionsByDisplay[borrowDisplay] == borrowComposition,
        borrowComposition.borrowed.contains(where: {
          $0.workspace == workspaceId
        })
      else { return .none }
    } else if
      state.compositionsByDisplay.values.contains(where: {
        $0.borrowed.contains(where: { $0.workspace == workspaceId })
      })
    {
      // A non-Borrow presence scan cannot dismiss a composition that appeared
      // while its AX request was in flight.
      return .none
    }
    if state.primaryActiveWorkspaceID == workspaceId {
      guard
        state.config.settings.switching.switchToRecentWhenEmpty,
        let workspace = state.config.activeProfile?.workspaces[id: workspaceId]
      else { return .none }
      guard !hasOnScreenMembers, !hasFloatingWindows else {
        debugLog.log(
          "Sync",
          "ws=\(workspace.name) tree empty but member apps still on screen — not switching",
        )
        return .none
      }
      let display = tilingContext(for: workspaceId, state: state).display
      let recent = display.flatMap { state.previousWorkspacesByDisplay[$0] }
        ?? state.previousWorkspacesByDisplay.values.first
      guard let recent, recent != workspaceId else { return .none }
      debugLog.log("Sync", "ws=\(workspace.name) empty → switch to recent")
      return .send(.activate(workspaceId: recent, setFocus: true))
    }

    guard !hasOnScreenMembers else { return .none }
    if let borrowDisplay {
      debugLog.log("Borrow", "borrowed \(workspaceId) empty → dismiss")
      return .send(.dismissBorrow(display: borrowDisplay))
    }
    return .none
  }

  // MARK: Private

  private func syncAppWindows(
    bundleId: String,
    workspaceId: Workspace.ID,
    discovered: [WindowKey]?,
    onScreenFrames: [CGWindowID: CGRect],
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
    let managedInActiveProfile = state.managedBundleIds
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
    //   * unregistered in the active profile / Shared Apps → transient:
    //     gets folded into the
    //     active workspace's tree because the user just opened/raised
    //     it after activation. The next activation rebuilds the tree
    //     from the registered set alone, so the transient drops out
    //     automatically.
    //   * registered in some *other active-profile* workspace → not tiled here;
    //     followAppFocus (if enabled) jumps to its owning workspace
    //     instead.
    // Inactive profiles are independent configurations. An assignment there
    // must not strand the app in the current profile with no eligible owner.
    let isUnregisteredInActiveProfile = !managedInActiveProfile.contains(bundleId)
    let eligibleToAdd = registeredSet.contains(bundleId)
      || sharedTiledSet.contains(bundleId)
      || inTree
      || isUnregisteredInActiveProfile

    guard let discovered else {
      debugLog.log("Sync", "skip \(bundleId): no resizable worker snapshot")
      return .none
    }
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
    let scoped = Self.scopedWindowKeys(
      discovered,
      sharedTiledBundleIds: sharedTiledSet,
      existingTargetKeys: existingTargetKeys,
      protectedKeys: protectedKeys,
      partitionSharedWindows: state.connectedDisplays.count > 1
        || state.activeWorkspacesByDisplay.count > 1,
      targetWorkArea: targetWorkArea,
      windowFrame: { onScreenFrames[$0.windowID] },
    )
    // SLS 816 is the exact visibility edge for a surface. AX can continue to
    // return that now-hidden element for one scan (Electron hide-on-close), so
    // do not let it reassert membership. A matching 815 removes the key from
    // this set before requesting its reconciliation.
    let current = scoped.filter { !state.windowServerHiddenWindows.contains($0) }
    // The block's geometry — composition sub-rect when this is a borrowed/host
    // block, else the workspace's full work area. New windows insert into it.
    let (_, workArea) = tilingContext(for: workspaceId, state: state)
    let treeWindows = existing?.windows ?? []
    let currentSet = Set(current)
    let staleBundleKeys = treeWindows.filter {
      $0.bundleId == bundleId && !currentSet.contains($0)
    }
    let freshBundleKeys = current.filter { !treeWindows.contains($0) }
    let expectedFrames = existing.map {
      Self.replacementExpectedFrames(
        tree: $0,
        settings: settings,
        targetRect: workArea,
        fullscreenZoomed: state.fullscreenZoomed[workspaceId] ?? [],
      )
    } ?? [:]
    let replacements = Self.surfaceReplacements(
      outgoing: staleBundleKeys,
      incoming: freshBundleKeys,
      expectedFrames: expectedFrames,
      liveFrames: onScreenFrames,
    )
    let replacedOutgoing = Set(replacements.keys)
    let willRemove = treeWindows.contains { $0.bundleId == bundleId && !currentSet.contains($0) }
    let willInsert = eligibleToAdd && current.contains { !treeWindows.contains($0) }
    // The focused-window read is a live AX round trip to the frontmost
    // app — the slowest call in a no-op sync (an Electron app answers AX
    // late right after being raised). Only a sync that changes the tree
    // needs it (insertion anchor + refocus); pure focus bookkeeping is
    // event-driven (`windowFocused` / `appActivated`).
    let focused: WindowKey? = (willRemove || willInsert)
      ? state.lastObservedFocusedWindow
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
        + "inTree=\(inTree) unregistered=\(isUnregisteredInActiveProfile)) "
        + "discovered=\(current.map { $0.windowID }) treeBefore=\(treeBefore)",
    )

    var tree = existing?.mapWindows { replacements[$0] ?? $0 }
    if
      let insertionPoint = state.insertionPoint[workspaceId],
      let replacement = replacements[insertionPoint]
    {
      state.insertionPoint[workspaceId] = replacement
    }
    state.replaceInWindowMRU(replacements, workspaceId: workspaceId)
    for key in (tree?.windows ?? [])
      where key.bundleId == bundleId
      && !currentSet.contains(key)
      && !replacedOutgoing.contains(key)
    {
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
    let addedKeys = newWindows.subtracting(oldWindows)
    let removedKeys = oldWindows.subtracting(newWindows)
    state.tilingTrees[workspaceId] = balanced
    // A first focus event can precede the sync that makes an unregistered
    // transient an authoritative tree member. `windowFocused` remembers the
    // exact key but deliberately cannot put a non-member into MRU. Complete
    // that same focus transaction now that membership exists, so dismissing a
    // Scratchpad Borrow restores this window without requiring an extra
    // opt+tab focus event.
    if let focused, addedKeys.contains(focused) {
      state.recordFocusedWindow(focused)
    }
    state.removeFromWindowMRU(removedKeys, workspaceId: workspaceId)
    state.removeFromPresentationMonitoring(removedKeys)
    let reappearingKeys = addedKeys.intersection(state.windowServerHiddenWindows)
    let replacedHiddenKeys = replacedOutgoing.intersection(state.windowServerHiddenWindows)
    let replacementKeys = Set(replacedHiddenKeys.compactMap { replacements[$0] })
    let visibleRepairKeys = newWindows.intersection(
      state.pendingWindowServerPresentationWindows
    )
    let presentationRepairKeys = reappearingKeys
      .union(replacementKeys)
      .union(visibleRepairKeys)
    if !presentationRepairKeys.isEmpty {
      state.windowServerHiddenWindows.subtract(reappearingKeys)
      state.windowServerHiddenWindows.subtract(replacedHiddenKeys)
      state.pendingWindowServerPresentationWindows.subtract(visibleRepairKeys)
      state.armPresentationMonitoring(
        presentationRepairKeys,
        preservesPointer: false,
      )
      debugLog.log(
        "Sync",
        "reappeared \(bundleId): arm frame convergence "
          + "\(presentationRepairKeys.map { $0.windowID })",
      )
    }

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
      var changed = false
      for stale in zoom where balanced?.pathTo(window: stale) == nil {
        guard
          let replacement = replacements[stale]
          ?? addedKeys.first(where: { $0.bundleId == stale.bundleId })
        else { continue }
        zoom.remove(stale)
        zoom.insert(replacement)
        changed = true
      }
      if changed { state.fullscreenZoomed[workspaceId] = zoom.isEmpty ? nil : zoom }
    }

    if
      let balanced,
      var unresolved = state.unresolvedFullscreenZoomSlots[workspaceId],
      !unresolved.isEmpty
    {
      let keyForSlot = slotToKey(balanced.windows)
      let resolvedPairs = unresolved.compactMap { slot in
        keyForSlot[slot].map { (slot, $0) }
      }
      let resolvedSlots = Set(resolvedPairs.map(\.0))
      let resolvedKeys = Set(resolvedPairs.map(\.1))
      if !resolvedKeys.isEmpty {
        state.fullscreenZoomed[workspaceId, default: []].formUnion(resolvedKeys)
        unresolved.subtract(resolvedSlots)
        state.unresolvedFullscreenZoomSlots[workspaceId] =
          unresolved.isEmpty ? nil : unresolved
        debugLog.log(
          "Sync",
          "restored persisted fullscreen \(bundleId): "
            + "\(resolvedKeys.map { $0.windowID })",
        )
      }
    }

    let added = newWindows.subtracting(oldWindows).map { $0.windowID }
    let removed = removedKeys.map { $0.windowID }
    let replacementLog = replacements.map {
      "\($0.key.windowID)→\($0.value.windowID)"
    }
    debugLog.log(
      "Sync",
      "result \(bundleId): added=\(added) removed=\(removed) "
        + "replaced=\(replacementLog) "
        + "treeAfter=\(balanced?.windows.map { $0.windowID } ?? [])",
    )

    // Only a sync that actually removed windows can have emptied the
    // workspace — launch/no-op syncs must never bounce the user off a
    // deliberately empty one.
    let emptySwitch = removed.isEmpty
      ? Effect<Action>.none
      : handleEmptied(workspaceId: workspaceId, state: state)

    let treeChanged = oldWindows != newWindows
    // Observers are process-lifetime and additive. Rewalking every running app
    // after a no-op focus sync only repeated AppKit/AX setup work. A changed
    // tree may contain a newly discovered transient, so only that path expands
    // the observed set.
    let observeIds = treeChanged
      ? Array(OrderedSet(
        (balanced?.windows.map(\.bundleId) ?? [])
          + Array(registeredSet)
          + state.config.sharedApps.map(\.bundleIdentifier)
      ))
      : []
    let observeEffect: Effect<Action> = treeChanged
      ? .run { [observer = windowObserver, observeIds] _ in
        await observer.observe(observeIds)
      }
      : .none
    let markerRefresh = treeChanged ? refreshMarkers(state: state) : .none
    guard treeChanged, let final = balanced else {
      return .merge(observeEffect, markerRefresh, emptySwitch)
    }

    // A fresh Borrow owns one deliberate focus/MFF completion. Cold Electron
    // apps can publish their first reusable surface only after the initial
    // reveal snapshot has already hydrated an empty tree. Resume that exact
    // generation here instead of treating the first window as an ordinary
    // sync; long-lived Borrows with no pending completion retain the generic
    // new/replacement-window behavior and cannot steal focus.
    var pendingBorrowResume: (display: DisplayName, generation: UInt64)?
    if oldWindows.isEmpty, !newWindows.isEmpty {
      for (display, composition) in state.compositionsByDisplay
        where composition.borrowed.contains(where: {
          $0.workspace == workspaceId
        })
      {
        let generation = state.borrowGenerationByDisplay[display, default: 0]
        guard
          state.pendingBorrowCompletionByDisplay[display]
          == State.PendingBorrowCompletion(
            workspaceId: workspaceId,
            generation: generation,
          )
        else { continue }
        pendingBorrowResume = (display, generation)
        break
      }
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
    let isCompositionMember = state.compositionsByDisplay.values.contains {
      $0.host == workspaceId
        || $0.borrowed.contains(where: { $0.workspace == workspaceId })
    }
    let layoutThenFocus: Effect<Action> =
      if let pendingBorrowResume {
        .send(
          .flushCompositionAndFocus(
            display: pendingBorrowResume.display,
            workspaceId: workspaceId,
            generation: pendingBorrowResume.generation,
          )
        )
      } else {
        .concatenate(
          flushLayout(
            workspaceId: workspaceId,
            state: &state,
            // A newly visible app can briefly report the target geometry
            // before restoring its remembered frame. Window-created tiling is
            // an authoritative membership transition, so always perform the
            // first AX write instead of trusting that transient preflight.
            forceAllFrames: !addedKeys.isEmpty,
            monitorsPresentationChanges: isCompositionMember,
            presentationRepairKeys: presentationRepairKeys,
          ),
          postLayoutFocusEffect,
        )
      }
    let persistence = state.isRecoveringSystemLayout
      ? Effect<Action>.none
      : persist(
        final,
        fullscreenZoomed: zoomed,
        unresolvedFullscreenZoomSlots:
        state.unresolvedFullscreenZoomSlots[workspaceId] ?? [],
        for: workspace,
      )
    return .merge(
      layoutThenFocus,
      observeEffect,
      persistence,
      markerRefresh,
      emptySwitch,
    )
  }

  /// Re-check an empty tree's app presence on the AX worker. Native-tab apps
  /// can replace their WindowServer id between prune and sync; the live check
  /// prevents a transient empty tree from switching/collapsing, without
  /// blocking the reducer/main event loop on AX IPC.
  private func handleEmptied(workspaceId: Workspace.ID, state: State) -> Effect<Action> {
    guard
      !state.isActivating,
      state.tilingTrees[workspaceId]?.windows.isEmpty ?? true,
      let workspace = state.config.activeProfile?.workspaces[id: workspaceId]
    else { return .none }
    let onScreenIds = workspace.apps
      .filter { $0.layout != .floating }
      .map(\.bundleIdentifier)
    let floatingIds = state.primaryActiveWorkspaceID == workspaceId
      ? workspace.apps.filter { $0.layout == .floating }.map(\.bundleIdentifier)
      : []
    let borrowedContext = state.compositionsByDisplay.first(where: {
      $0.value.borrowed.contains(where: { $0.workspace == workspaceId })
    }).map { display, composition in
      (
        display: display,
        generation: state.borrowGenerationByDisplay[display, default: 0],
        composition: composition,
      )
    }
    return .run { [snapshot = windowSnapshot] send in
      let onScreenKeys = onScreenIds.isEmpty
        ? []
        : await snapshot.discoverKeysOffMain(onScreenIds, false)
      let hasOnScreenMembers = !onScreenKeys.isEmpty
      let floatingKeys = hasOnScreenMembers || floatingIds.isEmpty
        ? []
        : await snapshot.discoverKeysOffMain(floatingIds, false)
      let hasFloatingWindows = !floatingKeys.isEmpty
      await send(.emptyWorkspacePresenceResolved(
        workspaceId: workspaceId,
        hasOnScreenMembers: hasOnScreenMembers,
        hasFloatingWindows: hasFloatingWindows,
        borrowDisplay: borrowedContext?.display,
        borrowGeneration: borrowedContext?.generation,
        borrowComposition: borrowedContext?.composition,
      ))
    }
    .cancellable(
      id: CancelID.emptyWorkspacePresence(workspaceId),
      cancelInFlight: true,
    )
  }

}
