import ComposableArchitecture
import Foundation
import OrderedCollections

// MARK: - DisplayAssignment

/// A workspace to (re)activate on a specific display — the unit of a
/// display-reconnect restore plan (and its pending queue).
public struct DisplayAssignment: Equatable, Sendable {
  public init(display: DisplayName, workspace: Workspace.ID) {
    self.display = display
    self.workspace = workspace
  }

  public var display: DisplayName
  public var workspace: Workspace.ID
}

extension WorkspaceActivationFeature {
  /// Map persisted fullscreen-zoom slots back onto live windows via the same
  /// windowID-rank assignment `hydrate` uses (`slotToKey` over `keys`), so a
  /// specific same-app window resolves to the exact slot it was zoomed in — not
  /// just "some window of that app". Slots whose window isn't in the laid-out
  /// tree are dropped, so the layout degrades gracefully when an app has fewer
  /// windows than at save time.
  static func resolveFullscreenZoom(
    slots: [SlotID],
    keys: [WindowKey],
    among windows: [WindowKey],
  ) -> Set<WindowKey> {
    let keyForSlot = slotToKey(keys)
    let present = Set(windows)
    return Set(slots.compactMap { keyForSlot[$0] }.filter { present.contains($0) })
  }

  /// Pick the workspace to put on `display`, or nil to leave it be. Pure.
  ///
  /// - `reconnect` (a monitor just plugged in):
  ///     1. the last workspace shown here, if it's pinned here, or it's dynamic
  ///        and not currently in use on another display;
  ///     2. else the first workspace statically pinned to this display;
  ///     3. else a dynamic workspace (or one whose pinned display is absent)
  ///        not in use on another display — the most recently used one
  ///        (`workspaceMRU`), falling back to the first.
  /// - vacated (a dynamic workspace just left this display): walk the display's
  ///   MRU history newest→oldest and take the first workspace that belongs here
  ///   (dynamic, or pinned to this display) and isn't already in use elsewhere —
  ///   so the monitor falls back to what the user last had on it.
  static func chooseWorkspaceForDisplay(
    _ display: DisplayName,
    reconnect: Bool,
    byId: [Workspace.ID: Workspace],
    workspaces: [Workspace],
    assigned: [DisplayName: Workspace.ID],
    history: [DisplayName: [Workspace.ID]],
    workspaceMRU: [Workspace.ID] = [],
    connected: Set<DisplayName> = [],
  ) -> Workspace.ID? {
    func pinned(_ id: Workspace.ID) -> Bool {
      byId[id]?.displayHint?.matches(display) ?? false
    }
    func isDynamic(_ id: Workspace.ID) -> Bool {
      byId[id]?.isDynamic ?? false
    }
    /// A workspace pinned to a display that isn't currently connected has no home
    /// to return to — treat it like a free dynamic so it stays where the user
    /// last put it, rather than being evicted for the display's first pinned one.
    func homelessPin(_ id: Workspace.ID) -> Bool {
      guard let hint = byId[id]?.displayHint else { return false }
      return !connected.contains { hint.matches($0) }
    }
    func elsewhere(_ id: Workspace.ID) -> Bool {
      assigned.contains { $0.key != display && $0.value == id }
    }
    if reconnect {
      // 1. last shown here — pinned here, or a free / homeless-pinned dynamic.
      if
        let last = (history[display] ?? []).first(where: { byId[$0] != nil }),
        pinned(last) || ((isDynamic(last) || homelessPin(last)) && !elsewhere(last))
      {
        return last
      }
      // 2. first pinned to this display.
      if
        let firstPinned = workspaces.first(where: {
          $0.kind != .scratchpad && ($0.displayHint?.matches(display) ?? false)
        })
      {
        return firstPinned.id
      }
      // 3. a free dynamic: most-recently-used, else the first.
      if
        let recentDynamic = workspaceMRU.first(where: {
          byId[$0] != nil
            && (isDynamic($0) || homelessPin($0))
            && !elsewhere($0)
        })
      {
        return recentDynamic
      }
      return workspaces.first {
        $0.kind != .scratchpad
          && ($0.isDynamic || homelessPin($0.id))
          && !elsewhere($0.id)
      }?.id
    }
    return (history[display] ?? []).first {
      byId[$0] != nil && !elsewhere($0) && (isDynamic($0) || pinned($0))
    }
  }

  static func planDisplayRestore(
    connected: [DisplayName],
    newlyConnected: Set<DisplayName>,
    workspaces: [Workspace],
    active: [DisplayName: Workspace.ID],
    history: [DisplayName: [Workspace.ID]],
    workspaceMRU: [Workspace.ID] = [],
  ) -> [DisplayAssignment] {
    var byId = [Workspace.ID: Workspace]()
    for w in workspaces where w.kind != .scratchpad { byId[w.id] = w }

    // Live simulation of which workspace sits on each display as the plan grows.
    var assigned = active
    var visited = Set<DisplayName>()

    func displayShowing(_ id: Workspace.ID) -> DisplayName? {
      assigned.first { $0.value == id }?.key
    }
    func pinned(_ id: Workspace.ID, to display: DisplayName) -> Bool {
      byId[id]?.displayHint?.matches(display) ?? false
    }

    func fill(_ display: DisplayName, reconnect: Bool) {
      guard visited.insert(display).inserted else { return }
      guard
        let target = chooseWorkspaceForDisplay(
          display,
          reconnect: reconnect,
          byId: byId,
          workspaces: workspaces,
          assigned: assigned,
          history: history,
          workspaceMRU: workspaceMRU,
          connected: Set(connected),
        ), byId[target] != nil
      else { return }
      if let other = displayShowing(target), other != display {
        // Already up on another display — only pull it over if it's pinned here.
        guard pinned(target, to: display) else { return }
        assigned[other] = nil
        assigned[display] = target
        fill(other, reconnect: false)
      } else {
        assigned[display] = target
      }
    }

    for display in connected where newlyConnected.contains(display) {
      fill(display, reconnect: true)
    }
    // Re-assert every connected display's (possibly reclaimed/filled) workspace.
    return connected.compactMap { display in
      assigned[display].map { DisplayAssignment(display: display, workspace: $0) }
    }
  }

  /// Lay the tree out, trimming fullscreen-zoomed windows so the rest
  /// of the tree shapes around as if they weren't present. Parent-zoom
  /// is handled inside `tree.frames(...)` directly.
  @MainActor
  static func computeFrames(
    tree: BSPNode<WindowKey>?,
    settings: AppSettings,
    targetDisplay: DisplayName?,
    fullscreenZoomed: Set<WindowKey> = [],
    targetRect: CGRect? = nil,
  ) -> [WindowKey: CGRect] {
    guard let tree else { return [:] }
    // `targetRect` (a composition sub-rect) is already inset; only the
    // full-display path applies the outer gap.
    let workArea = targetRect ?? ScreenGeometry.workArea(for: targetDisplay).insetBy(
      dx: CGFloat(settings.layout.gapOuter),
      dy: CGFloat(settings.layout.gapOuter),
    )
    let gap = CGFloat(settings.layout.gapInner)
    let activeZoom = fullscreenZoomed.intersection(Set(tree.windows))
    if !activeZoom.isEmpty {
      let trimmed = tree.removingAll(activeZoom)
      var frames = trimmed?.frames(in: workArea, gap: gap) ?? [:]
      for key in activeZoom { frames[key] = workArea }
      return frames
    }
    return tree.frames(in: workArea, gap: gap)
  }

  /// Split a work area into (host, borrowed) sub-rects for a borrow docked
  /// to `edge`; the borrowed block sits on that edge with `fraction` share.
  static func subRects(
    workArea: CGRect,
    edge: BorrowEdge,
    fraction: CGFloat,
    gap: CGFloat,
  ) -> (host: CGRect, borrowed: CGRect) {
    let axis: BSPNode<WindowKey>.SplitAxis =
      (edge == .left || edge == .right) ? .vertical : .horizontal
    switch edge {
    case .left,
         .top:
      let (b, h) = axis.subdivide(workArea, ratio: fraction, gap: gap)
      return (host: h, borrowed: b)

    case .right,
         .bottom:
      let (h, b) = axis.subdivide(workArea, ratio: 1 - fraction, gap: gap)
      return (host: h, borrowed: b)
    }
  }

  /// SF Symbol for a borrow docked to `edge` — a filled half-rectangle on the
  /// side the borrowed block sits.
  static func borrowEdgeIcon(_ edge: BorrowEdge) -> String {
    switch edge {
    case .left: "rectangle.lefthalf.inset.filled"
    case .right: "rectangle.righthalf.inset.filled"
    case .top: "rectangle.tophalf.inset.filled"
    case .bottom: "rectangle.bottomhalf.inset.filled"
    }
  }

  /// On the display being left, identify both where focus went and which
  /// workspace now owns it. The destination display shows the regular
  /// workspace-switch HUD separately.
  func focusMovedHUDEffect(
    workspace: Workspace,
    from oldDisplay: DisplayName?,
    to targetDisplay: DisplayName?,
    state: State,
  ) -> Effect<Action> {
    guard
      state.config.settings.hud.shows(\.workspaceSwitch),
      let oldDisplay,
      let targetDisplay,
      !oldDisplay.matches(targetDisplay)
    else { return .none }
    let durationMs = state.config.settings.hud.durationMs
    let subtitle = String(localized: "\(workspace.name) is on \(targetDisplay.name)")
    return .run { [workspaceHUD] _ in
      await workspaceHUD.showOnDisplay(
        String(localized: "Focus moved"),
        "arrow.right.to.line",
        subtitle,
        durationMs,
        oldDisplay,
      )
    }
  }

  func performActivate(
    workspaceId: Workspace.ID,
    setFocus: Bool,
    displayOverride: DisplayName? = nil,
    suppressSwitchHUD: Bool = false,
    state: inout State,
  ) -> Effect<Action> {
    guard
      let profile = state.config.activeProfile,
      let workspace = profile.workspaces[id: workspaceId]
    else { return .none }
    // (Switching to a borrowed workspace fully activates it — the composition
    // is dropped as the display re-tiles. Moving focus *into* a borrowed block
    // without switching is the directional-focus path, not activation.)
    // A scratchpad is borrow-only: there's no "switch to" it. Redirect a
    // standalone activate into a borrow on the pointer display's host
    // (re-docks if it's already borrowed there).
    if workspace.kind == .scratchpad {
      debugLog.log("Activate", "scratchpad \(workspace.name) → borrow")
      let resolved = workspace.borrowEdge ?? state.config.settings.switching.borrowDefaultEdge
      if let resolved {
        // A configured default edge → dock straight there.
        return performBorrow(targetId: workspaceId, edge: resolved, state: &state)
      }
      if setFocus {
        // "Ask" via a deliberate shortcut (switch/borrow): open the direction
        // picker with nothing placed yet, like the borrow shortcut.
        return .send(.beginBorrowDirection(workspaceId: workspaceId))
      }
      // "Ask" via focusing the app: dock provisionally at the fallback edge so
      // the window never floats unplaced, then open the picker to re-steer it.
      return .merge(
        performBorrow(targetId: workspaceId, edge: .right, state: &state),
        .send(.beginBorrowDirection(workspaceId: workspaceId)),
      )
    }
    // AX callbacks continuously maintain the latest focused key. Never perform
    // a synchronous focus IPC read in the hotkey reducer: one unresponsive app
    // would stall every subsequent menu and hotkey event on the main thread.
    var recordedOutgoingFocus = false
    if
      setFocus,
      let focused = state.lastObservedFocusedWindow,
      let outgoing = state.recordFocusedWindow(
        focused,
        requireVisibleTreeMembership: true,
      )
    {
      debugLog.log(
        "FocusSnapshot",
        "before activation workspaceId=\(outgoing) "
          + "key=\(focused.bundleId)#\(focused.windowID)",
      )
      recordedOutgoingFocus = true
    }
    // Only fall back to a live AX lookup when the observer stream did not
    // already give us a valid outgoing key. Waiting on the same Electron app
    // before show/hide added its full timeout to the visible switch path under
    // CPU pressure even though MRU and insertion state were already current.
    let outgoingFrontmostApp = setFocus && !recordedOutgoingFocus
      ? windowSnapshot.frontmostApp()
      : nil
    // Latest-wins: a switch arriving mid-activation supersedes the
    // in-flight one (the effect below is `cancellable(cancelInFlight:)`)
    // instead of being dropped — dropping read as "the hotkey got
    // swallowed" whenever an activation was slow (an app still
    // launching, AX waits under load). The superseded effect stops at
    // its next cancellation check; this activation's own show/hide and
    // tile pass overwrite whatever partial state it left.
    if state.isActivating {
      debugLog.log("Activate", "supersede in-flight activation → workspaceId=\(workspaceId)")
    }
    state.isActivating = true
    state.activatingWorkspaceID = workspaceId
    let isPaused = state.isTilingPaused
    debugLog.log(
      "Activate",
      "start workspace=\(workspace.name) setFocus=\(setFocus) "
        + "paused=\(isPaused) registeredApps=\(workspace.apps.map(\.bundleIdentifier))",
    )

    // Resolve the pinned display to where it actually tiles: the connected
    // screen (UUID → name match), else the primary display as fallback.
    // Learn the UUID for a name-only hint so future matching is UUID-stable.
    let targetDisplay: DisplayName?
    if let displayOverride {
      targetDisplay = displayOverride
      if
        let hint = workspace.displayHint,
        hint.matches(displayOverride),
        hint.uuid != displayOverride.uuid
      {
        state.$config.withLock { config in
          config.mutateWorkspace(workspaceId) { $0.displayHint = displayOverride }
        }
      }
    } else if let hint = workspace.displayHint {
      let connected = displays.connected(hint)
      if let connected, hint.uuid != connected.uuid {
        state.$config.withLock { config in
          config.mutateWorkspace(workspaceId) { $0.displayHint = connected }
        }
      }
      targetDisplay = connected ?? displays.primary() ?? hint
    } else {
      // A deliberate dynamic activation follows the mouse. Background reflows
      // keep the workspace on its actual display (or the keyboard-focused one
      // before it has an owner) so a config/layout sync cannot move it merely
      // because the pointer happens to be on another monitor.
      targetDisplay =
        if setFocus {
          displays.current() ?? state.focusedDisplay
        } else {
          state.displayShowing(workspaceId) ?? state.focusedDisplay ?? displays.current()
        }
    }
    // The switch HUD shows on the display focus lands on; on a cross-monitor
    // switch a second HUD on the monitor being left says where focus went, so
    // it doesn't look like the workspace just vanished.
    let oldDisplay = state.focusedDisplay
    if setFocus, let targetDisplay {
      state.focusedDisplay = targetDisplay
    }
    // Re-tiling this display to `workspace` dismisses any live composition on
    // it — a borrow is transient and vanishes when its host re-tiles. Capture
    // the dropped borrow's name so the switch HUD can announce it; skip the
    // case where we're switching *into* the borrowed workspace (a promotion,
    // not a return).
    // Restoring the *host* of a live composition (a borrow release), as opposed
    // to switching away to a third workspace. The host never left the screen, so
    // its tree's transient (unregistered) members must survive the re-tile, and
    // the hide pass stays borrow-scoped to the managed universe so an
    // unregistered floating app summoned alongside the borrow is left alone.
    // Every other activation — a fresh switch, *and* switching to a third
    // workspace while a borrow is still up — passes an empty set → legacy full
    // hide, so nothing unmanaged lingers on the new workspace. (The earlier
    // `compositionsByDisplay[display] != nil` gate leaked the managed-only scope
    // onto third-workspace switches, stranding the unregistered app on screen.)
    let restoringHost =
      targetDisplay.flatMap { state.compositionsByDisplay[$0]?.host } == workspaceId
    var dismissedBorrowName: String?
    var clearedComposition = false
    if let targetDisplay, let comp = state.compositionsByDisplay[targetDisplay] {
      if let slot = comp.borrowed.first, slot.workspace != workspaceId {
        dismissedBorrowName = profile.workspaces[id: slot.workspace]?.name
      }
      state.borrowGenerationByDisplay[targetDisplay, default: 0] &+= 1
      state.pendingBorrowCompletionByDisplay[targetDisplay] = nil
      for slot in comp.borrowed {
        state.pendingCenterWarps[slot.workspace] = nil
      }
      state.compositionsByDisplay[targetDisplay] = nil
      clearedComposition = true
    }
    var displacedCompositionHosts = [Workspace.ID]()
    for (sourceDisplay, composition) in Array(state.compositionsByDisplay)
      where composition.host == workspaceId
      || composition.borrowed.contains(where: { $0.workspace == workspaceId })
    {
      guard targetDisplay?.matches(sourceDisplay) != true else { continue }
      state.borrowGenerationByDisplay[sourceDisplay, default: 0] &+= 1
      state.pendingBorrowCompletionByDisplay[sourceDisplay] = nil
      for slot in composition.borrowed {
        state.pendingCenterWarps[slot.workspace] = nil
      }
      state.compositionsByDisplay[sourceDisplay] = nil
      clearedComposition = true
      if composition.host != workspaceId {
        displacedCompositionHosts.append(composition.host)
      }
    }
    // "Most recently used" (no pinned focus app): restore the exact window the
    // user last had focused in this workspace. On a plain switch the target must
    // be a window that survives the switch's hide pass — a registered or shared
    // member. An unregistered app folded into the tree this session (a transient)
    // is hidden by the switch, so restoring it as the focus target would have the
    // manager *resurrect* it (unhide + raise + activate) and the post-switch sync
    // re-fold it into the tree — making it stick on every return (the symptom:
    // "an unregistered app lingers across workspaces"). The design contract is
    // that transients drop out on the next activation; MRU restoration must not
    // defeat it. Only a borrow return (`restoringHost`) keeps transients on
    // screen (managed-scoped hide), so the last-used transient is restorable
    // there — that's the borrow-return focus the manager honors.
    let mruCandidates = workspace.appToFocusBundleId == nil
      ? (state.mruWindows[workspaceId] ?? [])
      : []
    let isWorkspaceMember: (WindowKey) -> Bool = { key in
      workspace.apps.contains { $0.bundleIdentifier == key.bundleId }
        || state.config.sharedApps.contains { $0.bundleIdentifier == key.bundleId }
    }
    let mruWindow = restoringHost
      ? mruCandidates.first
      : mruCandidates.first(where: isWorkspaceMember)
    let expectedFocusBundleId = workspace.appToFocusBundleId
      ?? mruWindow?.bundleId
      ?? workspace.apps.last?.bundleIdentifier
    debugLog.log(
      "FocusTarget",
      "ws=\(workspace.name) pin=\(workspace.appToFocusBundleId ?? "nil(MRU)") "
        + "mru=\(state.mruWindows[workspaceId]?.map { "\($0.bundleId)#\($0.windowID)" } ?? []) "
        + "pick=\(mruWindow.map { "\($0.bundleId)#\($0.windowID)" } ?? "nil")",
    )
    let request = ActivationRequest(
      workspace: workspace,
      sharedApps: state.config.sharedApps,
      targetDisplay: targetDisplay,
      setFocus: setFocus,
      mouseHidesOnFocus: setFocus && state.config.settings.focus.mouseHidesOnFocus,
      windowKeyToFocus: mruWindow,
      managedBundleIds: restoringHost ? state.managedBundleIds : [],
    )
    let warpMouse = setFocus && state.config.settings.focus.mouseFollowsFocus
    // Show the HUD on a normal switch, or whenever this switch returned a
    // borrow (so the dismissal is always announced — even mid-move).
    // A profile switch shows its own HUD (profile name + activated workspace),
    // so the per-workspace switch HUD is suppressed here to avoid clobbering it.
    let showHUD = setFocus && !suppressSwitchHUD && (
      state.config.settings.hud.shows(\.workspaceSwitch)
        || (dismissedBorrowName != nil && state.config.settings.hud.shows(\.borrow))
    )

    let settings = state.config.settings
    // Tile target: this workspace's tiled apps + shared tiled apps. Floating
    // apps (per-workspace or shared) are shown by the manager but kept out of
    // the tree.
    // An app registered to the workspace AND shared appears in both lists —
    // dedupe, or its windows get discovered twice and tile twice.
    // Restoring the host after a borrow keeps its tree's transient members
    // (apps folded in this session but registered nowhere) — discover them too,
    // or `mergeTree` would drop them as stale and they'd fall out of the tiling.
    // A fresh switch passes none, so transients drop as designed.
    let transientBundles = restoringHost
      ? (state.tilingTrees[workspace.id]?.windows.map(\.bundleId) ?? [])
      : []
    let bundleIds = Array(OrderedSet(
      workspace.apps.filter { $0.layout == .tiled }.map(\.bundleIdentifier)
        + state.config.sharedApps.filter { $0.layout == .tiled }.map(\.bundleIdentifier)
        + transientBundles
    ))
    // Floating apps (per-workspace + shared) are raised above the tiles after
    // the tile pass. Unmanaged apps are neither tiled nor floated — left out
    // of both sets; the manager still shows/hides them as members.
    let floatingBundleIds = Array(OrderedSet(
      workspace.apps.filter { $0.layout == .floating }.map(\.bundleIdentifier)
        + state.config.sharedApps.filter { $0.layout == .floating }.map(\.bundleIdentifier)
    ))
    // Floating overlays and markers are process-global presentation surfaces.
    // Replacing one display must retain the other displays' visible members;
    // using only the target workspace here tore their mirrors/markers down.
    var presentationWorkspaceIDs = state.visibleWorkspaceIDs
    if
      let targetDisplay,
      let outgoing = state.activeWorkspacesByDisplay[targetDisplay]
    {
      presentationWorkspaceIDs.remove(outgoing)
    }
    presentationWorkspaceIDs.insert(workspace.id)
    let presentationFloatingBundleIds = Self.floatingBundleIds(
      state: state,
      workspaceIDs: presentationWorkspaceIDs,
    )
    let activationObservedBundleIds = Array(OrderedSet(
      bundleIds
        + presentationFloatingBundleIds
        + Self.unmanagedBundleIds(
          state: state,
          workspaceIDs: presentationWorkspaceIDs,
        )
    ))
    let sessionTree = state.tilingTrees[workspace.id]
    let sharedTiledBundleIds = Set(
      state.config.sharedApps.filter { $0.layout == .tiled }.map(\.bundleIdentifier)
    )
    let partitionsSharedWindows = state.connectedDisplays.count > 1
      || state.activeWorkspacesByDisplay.count > 1
    var protectedWindowKeys = Set<WindowKey>()
    if let targetDisplay {
      for otherId in state.visibleWorkspaceIDs where otherId != workspace.id {
        guard
          let otherDisplay = state.displayShowing(otherId),
          !otherDisplay.matches(targetDisplay)
        else { continue }
        protectedWindowKeys.formUnion(state.tilingTrees[otherId]?.windows ?? [])
      }
    }
    let existingTargetKeys = Set(sessionTree?.windows ?? [])
    let zoomed = state.fullscreenZoomed[workspace.id] ?? []
    let insertionPoint = state.insertionPoint[workspace.id]
    // A composition marker is an always-visible symbol badge. Clear it as soon
    // as activation drops the composition; waiting for the post-layout
    // floating-window pass leaves the old, 2× Borrow badge masquerading as an
    // oversized fullscreen dot on the promoted workspace.
    let clearedCompositionMarkers = clearedComposition
      ? refreshMarkers(state: state)
      : Effect<Action>.none

    let hudName = workspace.name
    let hudIcon = workspace.symbolIconName
    let hudSubtitle = dismissedBorrowName.map { String(localized: "Returned \($0)") }
    // The switch HUD shows on the display focus landed on (the target). On a
    // same-monitor switch with no resolved target it falls back to the cursor.
    let hudDisplay = targetDisplay
    let hudDurationMs = state.config.settings.hud.durationMs

    // On a cross-monitor switch, a second HUD on the monitor being left names
    // where focus went. Separate panel (the controller tracks one per screen),
    // shown alongside the switch HUD on the new monitor.
    let crossMonitorHUD = !setFocus || suppressSwitchHUD
      ? Effect<Action>.none
      : focusMovedHUDEffect(
        workspace: workspace,
        from: oldDisplay,
        to: targetDisplay,
        state: state,
      )
    var displacedCompositionEffects = [Effect<Action>]()
    for workspaceId in displacedCompositionHosts {
      displacedCompositionEffects.append(
        flushLayout(workspaceId: workspaceId, state: &state)
      )
    }
    let displacedCompositionReflow = Effect<Action>.merge(
      displacedCompositionEffects
    )

    // Floating windows need Screen Recording for their mirrors. Don't fail
    // silently ("floating just doesn't stay on top"): surface the system
    // prompt and a HUD pointing at the Settings row, once per session.
    var screenRecordingWarning = Effect<Action>.none
    if
      !floatingBundleIds.isEmpty,
      !screenRecording.isGranted(),
      !state.didWarnMissingScreenRecording
    {
      state.didWarnMissingScreenRecording = true
      screenRecordingWarning = .merge(
        .run { [screenRecording] _ in await screenRecording.requestAccess() },
        hudEffect(
          state,
          \.floating,
          "Screen Recording Needed",
          "exclamationmark.triangle.fill",
          subtitle: "Floating windows can't stay above the tiles without it — grant in Settings → General → Permissions, then relaunch",
        ),
      )
    }

    // Watchdog: `isActivating` is only ever cleared by
    // `activationCompleted` — if the activation effect wedges past every
    // AX timeout (or dies without reporting), the latch would refuse all
    // future activations and syncs for the rest of the session. Cancelled
    // by `activationCompleted` on the normal path.
    let watchdog = Effect<Action>.run { [clock] send in
      try await clock.sleep(for: .seconds(10))
      await send(.activationTimedOut)
    }
    .cancellable(id: CancelID.activationWatchdog, cancelInFlight: true)

    // High/user-initiated priority: the whole effect is the visible response to a
    // hotkey press. Under system load the default priority leaves our
    // main-actor hops queued behind everything else — exactly when the
    // switch already crawls on slow AX replies.
    return .concatenate(
      // Every frame writer targeting this display shares one cancellation
      // domain. An activation is the authoritative writer, so retire an
      // in-flight tree/composition flush before its show/hide + tile pass.
      .cancel(id: CancelID.layout(targetDisplay)),
      .cancel(id: CancelID.borrowFocus(targetDisplay)),
      .cancel(id: CancelID.borrowRender(targetDisplay)),
      .merge(
        screenRecordingWarning,
        watchdog,
        crossMonitorHUD,
        displacedCompositionReflow,
        clearedCompositionMarkers,
        // Arm tiled, floating, and unmanaged apps concurrently with activation.
        // A first-time installation emits one observation-ready reconcile, so
        // a state change racing this setup cannot fall through the cache gap.
        .run { [observer = windowObserver, activationObservedBundleIds] send in
          await observer.observe(activationObservedBundleIds)
          await send(
            .presentationObservationReady(
              bundleIds: Set(activationObservedBundleIds)
            )
          )
        },
        .run(priority: .high) { [
          mgr = workspaceManager,
          tiler = windowTiler,
          store = layoutStore,
          hud = workspaceHUD,
          mouse = mouse,
          overlay = floatingOverlay,
          snapshot = windowSnapshot,
          displays = displays,
          debugLog = debugLog,
          focus = focusManager,
        ] send in
          async let outgoingFocus: WindowKey? = {
            guard let outgoingFrontmostApp else { return nil as WindowKey? }
            return await snapshot.focusedWindowKeyOffMain(outgoingFrontmostApp)
          }()
          // Wall-clock per phase — AX round trips block on *other* apps' run
          // loops, so when a switch crawls under load this names the phase
          // (and thus the app set) that ate the time.
          let timer = ContinuousClock()
          var phaseStart = timer.now
          var phases = [(String, Duration)]()
          var coreCompletionSent = false
          func mark(_ name: String) {
            let now = timer.now
            phases.append((name, now - phaseStart))
            phaseStart = now
          }
          if showHUD {
            await hud.showOnDisplay(hudName, hudIcon, hudSubtitle, hudDurationMs, hudDisplay)
          }
          guard !Task.isCancelled else { return }
          // Tear down the outgoing workspace's mirrors in the same beat as the
          // hide pass — leaving them to the post-tile `setFloating` made the
          // floating windows visibly outlive the windows they mirror.
          await overlay.retainOnly(Set(presentationFloatingBundleIds))
          guard !Task.isCancelled else { return }
          // Resolve the outgoing window before show/hide can focus a different
          // window in the same process. Merely starting this child task first
          // does not order its AX read ahead of `mgr.activate`.
          let outgoingFocusedWindow = await outgoingFocus
          guard !Task.isCancelled else { return }
          await mgr.activate(request)
          guard !Task.isCancelled else { return }
          if let outgoingFocusedWindow {
            await send(.activationFocusSnapshotResolved(outgoingFocusedWindow))
          }
          mark("showHide")
          // Superseded by a newer switch: stop before the tile pass. `send`
          // on a cancelled effect is already a no-op, but the AX work below
          // is not — without these checks a superseded activation would keep
          // writing the *old* workspace's frames interleaved with the new
          // activation's main-actor hops.
          guard !Task.isCancelled else { return }
          if !isPaused {
            // Layouts always persist now — restore the saved template whenever
            // there's no in-memory tree yet (fresh launch / first activation).
            let persistedSnapshot: LayoutSnapshot? =
              sessionTree == nil ? await store.load(workspaceId) : nil
            guard !Task.isCancelled else { return }
            // Cache-first discovery: a warm `WindowKeyCache` entry costs zero
            // AX round trips — AX scans block on each target app's run loop
            // (measured 50 ms–1.2 s per switch), which is what made switching
            // crawl under system load. Each process has its own serialized AX
            // lane, so independent apps can resolve concurrently without one
            // slow app adding its timeout to every following bundle. Preserve
            // configured order when flattening so fresh-tree placement stays
            // deterministic.
            let discovered = await withTaskGroup(
              of: (Int, [WindowKey]).self,
              returning: [WindowKey].self,
            ) { group in
              for (index, bundleId) in bundleIds.enumerated() {
                group.addTask {
                  (index, await snapshot.stableCachedKeysOffMain([bundleId], true))
                }
              }
              var results = [(Int, [WindowKey])]()
              for await result in group { results.append(result) }
              return results.sorted { $0.0 < $1.0 }.flatMap(\.1)
            }
            guard !Task.isCancelled else { return }
            let onScreenFrames = snapshot.onScreenWindowFrames()
            let keys = await MainActor.run {
              Self.scopedWindowKeys(
                discovered,
                sharedTiledBundleIds: sharedTiledBundleIds,
                existingTargetKeys: existingTargetKeys,
                protectedKeys: protectedWindowKeys,
                partitionSharedWindows: partitionsSharedWindows,
                targetWorkArea: displays.workArea(targetDisplay),
                windowFrame: { onScreenFrames[$0.windowID] },
              )
            }
            mark("discover")
            let (tree, frames, restoredZoom, unresolvedZoomSlots) = await MainActor.run {
              () -> (
                BSPNode<WindowKey>?,
                [WindowKey: CGRect],
                Set<WindowKey>,
                Set<SlotID>
              ) in
              let workArea = displays.workArea(targetDisplay).insetBy(
                dx: CGFloat(settings.layout.gapOuter),
                dy: CGFloat(settings.layout.gapOuter),
              )
              var base = sessionTree
              var persistedZoomSlots = [SlotID]()
              if let snapshot = persistedSnapshot {
                base = BSPNode.hydrate(template: snapshot.tree, keys: keys)
                persistedZoomSlots = snapshot.fullscreenZoomedSlots
              }
              let restoredLayout = base != nil
              let merged = Self.mergeTree(
                existing: base,
                target: keys,
                focused: { outgoingFocusedWindow },
                insertionPoint: insertionPoint,
                workArea: workArea,
                settings: settings,
              )
              let axis = settings.layout.autoBalance
              // No resident tree and no persisted template (or a template with
              // zero matching windows) means the old shape is genuinely gone.
              // Initialize from the same contract as explicit Balance:
              // Auto-balance axes when enabled, canonical BSP when Off.
              let tree =
                if restoredLayout {
                  axis == .none ? merged : merged?.balanced(axis: axis)
                } else {
                  merged?.balancedForCommand(
                    autoBalance: axis,
                    in: workArea,
                    gap: CGFloat(settings.layout.gapInner),
                    splitAxis: settings.layout.splitType.bspSplitAxis(),
                  )
                }
              let resolvedZoom: Set<WindowKey> = {
                if !zoomed.isEmpty { return zoomed }
                guard let tree else { return [] }
                return Self.resolveFullscreenZoom(
                  slots: persistedZoomSlots,
                  keys: keys,
                  among: tree.windows,
                )
              }()
              let frames = Self.computeFrames(
                tree: tree,
                settings: settings,
                targetDisplay: targetDisplay,
                fullscreenZoomed: resolvedZoom,
              )
              let assignments = slotAssignment(keys)
              let resolvedSlots = Set(resolvedZoom.compactMap { assignments[$0] })
              let unresolvedZoomSlots =
                Set(persistedZoomSlots).subtracting(resolvedSlots)
              return (tree, frames, resolvedZoom, unresolvedZoomSlots)
            }
            mark("layout")
            // Cancellation can arrive while the main actor computes a large tree.
            // Do not publish or persist a superseded workspace's layout snapshot.
            guard !Task.isCancelled else { return }
            await send(.tilingTreeUpdated(workspaceId: workspaceId, tree: tree))
            if persistedSnapshot != nil, zoomed.isEmpty {
              await send(.persistedFullscreenZoomRestored(
                workspaceId: workspaceId,
                keys: restoredZoom,
                unresolvedSlots: unresolvedZoomSlots,
              ))
            }
            guard !Task.isCancelled else { return }
            if let tree {
              let slots = slotAssignment(tree.windows)
              await store.save(
                workspaceId,
                LayoutSnapshot(
                  tree: tree.mapWindows { slots[$0]! },
                  fullscreenZoomedSlots: Set(
                    restoredZoom.compactMap { slots[$0] }
                  )
                  .union(unresolvedZoomSlots)
                  .sorted { ($0.bundleId, $0.occurrence) < ($1.bundleId, $1.occurrence) },
                ),
              )
            }
            guard !Task.isCancelled else { return }
            if !frames.isEmpty {
              await tiler.apply(FrameApplication(windowFrames: frames))
            }
            mark("apply")
            guard !Task.isCancelled else { return }
            if !frames.isEmpty {
              await send(
                .presentationLayoutApplied(
                  keys: Set(frames.keys),
                  preservesPointer: false,
                )
              )
            }
            // Show/hide + the first authoritative tile pass is the visible
            // switch. Publish it now; floating overlays, markers, focus
            // validation, and pointer warp are cancellable best-effort
            // post-layout work and must not hold the activation gate.
            coreCompletionSent = true
            await send(.activationCompleted(workspaceId: workspaceId, display: targetDisplay))
            guard !Task.isCancelled else { return }
            // Mirror floating windows onto always-on-top panels (the Topit /
            // Floaty technique): a foreign window's level can't be raised without
            // SIP, so instead of trying we paint a live mirror above the tiles.
            // Passing the resolved set (possibly empty) also tears down mirrors
            // for apps that were just un-floated or belong to another workspace.
            // Same cache-first, per-bundle worker discovery as the tile pass
            // above.
            var floatingDiscovered = Set<WindowKey>()
            for bundleId in presentationFloatingBundleIds {
              guard !Task.isCancelled else { return }
              floatingDiscovered.formUnion(
                await snapshot.cachedKeysOffMain([bundleId], false)
              )
            }
            let floatingKeys = floatingDiscovered
            mark("float")
            guard !Task.isCancelled else { return }
            await overlay.setFloating(floatingKeys)
            guard !Task.isCancelled else { return }
            // Markers ride the same discovery, but reducer state owns their
            // categories. Re-derive after `activationCompleted` publishes the
            // target workspace and cancel any composition-era marker refresh.
            await send(.activationMarkerKeysResolved(Array(floatingKeys)))
            guard !Task.isCancelled else { return }
            if warpMouse {
              var fallbackFrames = [WindowKey: CGRect]()
              let liveWindowServerFrames = snapshot.onScreenWindowFrames()
              if let mruWindow, frames[mruWindow] == nil {
                if let frame = liveWindowServerFrames[mruWindow.windowID] {
                  fallbackFrames[mruWindow] = frame
                } else if let frame = await snapshot.windowFrameOffMain(mruWindow) {
                  fallbackFrames[mruWindow] = frame
                }
              }
              guard !Task.isCancelled else { return }
              // Read focus after the potentially blocking MRU geometry lookup,
              // so a user focus change during that IPC cannot leave a stale
              // "still focused" proof for the eventual pointer warp.
              var liveFocused = await snapshot.focusedWindowKeyOffMain()
              guard !Task.isCancelled else { return }
              if
                let candidateFocus = liveFocused,
                frames[candidateFocus] == nil,
                fallbackFrames[candidateFocus] == nil
              {
                if let frame = liveWindowServerFrames[candidateFocus.windowID] {
                  fallbackFrames[candidateFocus] = frame
                } else {
                  let frame = await snapshot.windowFrameOffMain(candidateFocus)
                  guard !Task.isCancelled else { return }
                  // Geometry is another suspension point. Validate focus again
                  // and accept that frame only if the same window still owns it.
                  let verifiedFocused = await snapshot.focusedWindowKeyOffMain()
                  guard !Task.isCancelled else { return }
                  if verifiedFocused == candidateFocus, let frame {
                    fallbackFrames[candidateFocus] = frame
                  }
                  liveFocused = verifiedFocused
                }
              }
              guard !Task.isCancelled else { return }
              let warp: (key: WindowKey, rect: CGRect, live: WindowKey?)? = {
                // Warp to the window this activation deliberately focused (the MRU
                // target), not a live `focusedWindowKey()` read. That read races
                // the async app activation and can return a *different* frontmost
                // window (e.g. Siri keeping front while ChatGPT is the target),
                // sending the cursor to the wrong tile — where focus-follows-mouse
                // then grabs focus to it. Fall back to the live read only when this
                // workspace has no MRU target (a pinned-app or empty workspace).
                let live = liveFocused
                if
                  let mruWindow,
                  let rect = frames[mruWindow] ?? fallbackFrames[mruWindow]
                {
                  return (mruWindow, rect, live)
                }
                // A stale MRU id is allowed to fall back to the app's live main
                // window (the focus manager does the same). Gate by the expected
                // bundle so a lagging frontmost read can never warp into the
                // outgoing workspace. AX geometry also lets MFF follow an owned
                // floating/unmanaged restore target, which has no tiled frame.
                guard
                  let live,
                  live.bundleId == expectedFocusBundleId,
                  let rect = frames[live] ?? fallbackFrames[live]
                else { return nil }
                return (live, rect, live)
              }()
              guard !Task.isCancelled else { return }
              if let warp {
                let center = CGPoint(x: warp.rect.midX, y: warp.rect.midY)
                debugLog.log(
                  "Warp",
                  "activate target=\(warp.key.bundleId)#\(warp.key.windowID) "
                    + "live=\(warp.live.map { "\($0.bundleId)#\($0.windowID)" } ?? "nil") "
                    + "→ (\(Int(center.x)),\(Int(center.y)))",
                )
                // The deliberate activation focus can be stolen mid-switch — an app
                // like Siri grabs frontmost as it unhides — leaving the keyboard
                // focus on the wrong tile while the cursor warps to the intended
                // one, so directional focus then anchors on the wrong window. When
                // the live frontmost differs from the window we're warping to,
                // re-assert the intended focus now that the layout has settled.
                if warp.live != warp.key {
                  await focus.focusWindow(warp.key)
                }
                guard !Task.isCancelled else { return }
                mouse.warp(center)
              }
            }
          }
          debugLog.log(
            "Activate",
            "phases " + phases.map { "\($0.0)=\(ms($0.1))ms" }.joined(separator: " "),
          )
          if !coreCompletionSent {
            await send(.activationCompleted(workspaceId: workspaceId, display: targetDisplay))
          }
        }
        .cancellable(id: CancelID.activation, cancelInFlight: true),
      ),
    )
  }

  func cycle(by direction: Int, state: inout State) -> Effect<Action> {
    let anchor = state.activatingWorkspaceID ?? state.primaryActiveWorkspaceID
    let workspaces = state.config.activeProfile?.workspaces
    let name = { (id: Workspace.ID?) -> String in
      id.flatMap { workspaces?[id: $0]?.name } ?? "nil"
    }
    guard let id = adjacentWorkspaceId(by: direction, state: state) else {
      debugLog.log(
        "Activate",
        "cycle \(direction > 0 ? "next" : "previous") from=\(name(anchor)): no eligible target",
      )
      return .none
    }
    debugLog.log(
      "Activate",
      "cycle \(direction > 0 ? "next" : "previous") from=\(name(anchor)) → \(name(id))",
    )
    return .send(.activate(workspaceId: id, setFocus: true))
  }

  /// The workspace `direction` steps from the active one, honoring the
  /// `loop` / `skipEmpty` switching preferences. Shared by cycling and by
  /// "move focused app to next/previous workspace". Returns `nil` when there
  /// is no eligible target (e.g. at an end with looping off).
  func adjacentWorkspaceId(
    by direction: Int,
    state: State,
    display: DisplayName? = nil,
  ) -> Workspace.ID? {
    // Scratchpads are borrow-only — never a cycle destination.
    guard
      let all = state.config.activeProfile?.workspaces
        .filter({ $0.kind != .scratchpad }),
      !all.isEmpty
    else { return nil }
    let settings = state.config.settings
    // Scope the cycle. `cycleAcrossDisplays` → every workspace. Otherwise stay
    // on the cursor's display: pinned workspaces by their display, dynamic
    // (unpinned) ones by the display they were last activated on (never-active
    // ones are included so they stay reachable).
    let workspaces: IdentifiedArrayOf<Workspace> =
      if
        !settings.switching.cycleAcrossDisplays,
        let focused = display ?? state.focusedDisplay
      {
        all.filter { ws in
          if let hint = ws.displayHint {
            // A pinned workspace belongs to the display it actually tiles on —
            // the connected screen, or the primary as fallback — so one pinned
            // to a *disconnected* display stays reachable on the primary.
            return displays.resolveOrPrimary(hint)?.matches(focused) ?? true
          }
          // Dynamic: the monitor it was last on (or include if never activated).
          if let last = state.lastActiveDisplay[ws.id] { return last.matches(focused) }
          return true
        }
      } else {
        all
      }
    guard !workspaces.isEmpty else { return nil }
    // Anchor at the in-flight activation's target when there is one, else
    // the active workspace on the focused display. `primaryActive` only
    // updates on completion, so without the in-flight anchor every press
    // during a slow switch re-resolved to the same target.
    let currentID = state.activatingWorkspaceID
      ?? (display ?? state.focusedDisplay).flatMap { state.activeWorkspacesByDisplay[$0] }
      ?? state.primaryActiveWorkspaceID
    let currentIndex = workspaces.firstIndex { $0.id == currentID } ?? -1
    let count = workspaces.count

    let runningBundleIds: Set<String> = settings.switching.skipEmpty
      ? windowSnapshot.runningBundleIds()
      : []

    var index = currentIndex
    for _ in 0 ..< count {
      let next = index + direction
      if settings.switching.loop {
        index = (next + count) % count
      } else {
        guard next >= 0, next < count else { return nil }
        index = next
      }
      let candidate = workspaces[index]
      if settings.switching.skipEmpty {
        let hasRunning = candidate.apps.contains {
          runningBundleIds.contains($0.bundleIdentifier)
        }
        if !hasRunning { continue }
      }
      return candidate.id
    }
    return nil
  }

  /// The full set of (display → workspace) activations to run when the display
  /// configuration changes. Pure so the rules + reclaim recursion are testable.
  ///
  /// It re-asserts every still-connected display's current workspace (so macOS's
  /// own window shuffle on a config change is overwritten by Tatami's layout),
  /// and fills each `newlyConnected` monitor per `chooseWorkspaceForDisplay`.
  /// When a pinned workspace is reclaimed from another display A, A is refilled
  /// by walking its history (recursively), skipping anything in use elsewhere.
  /// Per-display profile-switch HUDs: on each monitor, the profile name (title)
  /// + the workspace that lands there (subtitle). One HUD per display so a
  /// multi-monitor switch reads correctly on each screen; the per-workspace
  /// switch HUD is suppressed during the switch so these aren't clobbered.
  func profileSwitchHUDs(
    profile: Profile,
    plan: [DisplayAssignment],
    show: Bool,
    durationMs: Int,
  ) -> Effect<Action> {
    guard show else { return .none }
    let name = profile.name
    let symbol = profile.symbolIconName ?? "rectangle.stack.fill"
    let entries = plan.compactMap { assignment in
      profile.workspaces[id: assignment.workspace].map { (assignment.display, $0.name) }
    }
    guard !entries.isEmpty else { return .none }
    return .run { [workspaceHUD] _ in
      for (display, workspaceName) in entries {
        await workspaceHUD.showOnDisplay(name, symbol, workspaceName, durationMs, display)
      }
    }
  }

  /// Flush the display's composition (host + borrowed blocks) in one apply:
  /// each workspace's tree laid into its sub-rect, frames merged, applied
  /// together. No-op when the display has no active composition.
  func applyComposition(
    display: DisplayName?,
    forceAllFrames: Bool = false,
    followUp: PostLayoutFocus? = nil,
    monitorsPresentationChanges: Bool = false,
    presentationRepairKeys: Set<WindowKey> = [],
    borrowPhaseCompletion: BorrowPhase? = nil,
    state: inout State,
  ) -> Effect<Action> {
    let settings = state.config.settings
    guard
      let display,
      let comp = state.compositionsByDisplay[display],
      let slot = comp.borrowed.first,
      let hostTree = state.tilingTrees[comp.host]
    else {
      guard let phase = borrowPhaseCompletion else { return .none }
      return .send(
        .borrowCompositionLayoutCompleted(
          display: phase.display,
          workspaceId: phase.workspaceId,
          generation: phase.generation,
          composition: phase.composition,
        )
      )
    }
    let borrowedTree = state.tilingTrees[slot.workspace]
    let hostZoom = state.fullscreenZoomed[comp.host] ?? []
    let borrowedZoom = state.fullscreenZoomed[slot.workspace] ?? []
    let edge = slot.edge
    let fraction = slot.fraction
    let monitoredKeys = monitorsPresentationChanges
      ? state.armPresentationMonitoring(
        Set(hostTree.windows + (borrowedTree?.windows ?? [])),
        preservesPointer: false,
      )
      : []
    state.layoutWriteGeneration &+= 1
    let layoutGeneration = state.layoutWriteGeneration
    state.activeLayoutWriteGenerations.insert(layoutGeneration)
    let writer = Effect<Action>.run { [tiler = windowTiler, displays] send in
      let merged: [WindowKey: CGRect] = await MainActor.run {
        let workArea = displays.workArea(display).insetBy(
          dx: CGFloat(settings.layout.gapOuter),
          dy: CGFloat(settings.layout.gapOuter),
        )
        let gap = CGFloat(settings.layout.gapInner)
        let (hostRect, borrowedRect) = Self.subRects(
          workArea: workArea,
          edge: edge,
          fraction: fraction,
          gap: gap,
        )
        let hf = Self.computeFrames(
          tree: hostTree,
          settings: settings,
          targetDisplay: display,
          fullscreenZoomed: hostZoom,
          targetRect: hostRect,
        )
        let bf = Self.computeFrames(
          tree: borrowedTree,
          settings: settings,
          targetDisplay: display,
          fullscreenZoomed: borrowedZoom,
          targetRect: borrowedRect,
        )
        return hf.merging(bf) { current, _ in current }
      }
      guard !Task.isCancelled else { return }
      guard !merged.isEmpty else {
        if let phase = borrowPhaseCompletion {
          await send(
            .borrowCompositionLayoutCompleted(
              display: phase.display,
              workspaceId: phase.workspaceId,
              generation: phase.generation,
              composition: phase.composition,
            )
          )
        }
        return
      }
      await tiler.apply(
        FrameApplication(windowFrames: merged, forceAllFrames: forceAllFrames)
      )
      guard !Task.isCancelled else { return }
      if let phase = borrowPhaseCompletion {
        await send(
          .borrowCompositionLayoutCompleted(
            display: phase.display,
            workspaceId: phase.workspaceId,
            generation: phase.generation,
            composition: phase.composition,
          )
        )
      }
      if let followUp {
        await send(
          .settleFocusAfterLayout(
            windowKey: followUp.windowKey,
            workspaceId: followUp.workspaceId,
            shouldFocus: followUp.shouldFocus,
          )
        )
      }
    }
    return .concatenate(
      writer.cancellable(
        id: CancelID.layout(display),
        cancelInFlight: true,
      ),
      .send(
        .layoutWriteFinished(
          generation: layoutGeneration,
          verificationKeys: presentationRepairKeys.union(monitoredKeys),
        )
      ),
    )
  }

  /// Re-apply a borrowed block after one of its windows becomes focused.
  /// Notification clicks and app-owned window selectors can make an already
  /// tiled window restore its saved frame after the immediate AX focus event.
  /// Membership is unchanged, so the ordinary sync is intentionally a no-op.
  /// Arm the exact affected windows and let their real geometry notification
  /// drive convergence; the immediate WindowServer verification covers a
  /// restore that landed just before this focus event.
  func monitorBorrowedPresentationAfterFocus(
    bundleId: String,
    preservesPointer: Bool,
    state: State,
  ) -> Effect<Action> {
    let sharedTiled = state.config.sharedApps.contains {
      $0.bundleIdentifier == bundleId && $0.layout == .tiled
    }
    let keys = state.compositionsByDisplay.values.reduce(into: Set<WindowKey>()) {
      keys, composition in
      guard
        let slot = composition.borrowed.first,
        state.tilingTrees[slot.workspace]?.windows.contains(where: {
          $0.bundleId == bundleId
        }) == true
        || sharedTiled
        || state.config.activeProfile?.workspaces[id: slot.workspace]?
        .apps.contains(where: {
          $0.bundleIdentifier == bundleId && $0.layout == .tiled
        }) == true
      else { return }
      keys.formUnion(
        (state.tilingTrees[slot.workspace]?.windows ?? [])
          .filter { sharedTiled || $0.bundleId == bundleId }
      )
    }
    guard !keys.isEmpty else { return .none }
    return .send(
      .presentationLayoutApplied(
        keys: keys,
        preservesPointer: preservesPointer,
      )
    )
  }

  /// Borrow `targetId` into the pointer display's host workspace, docked to
  /// `edge`. Re-borrowing a target already borrowed there dismisses it when
  /// `toggleBorrowOnRepeat` is on, otherwise it re-docks to the new edge. Live:
  /// the borrowed block reuses the target's real tree, so
  /// edits persist to it. Only the borrowed workspace's *tiled* apps take part
  /// — its floating / unmanaged apps are ignored while borrowed.
  func performBorrow(
    targetId: Workspace.ID,
    edge: BorrowEdge,
    displayOverride: DisplayName? = nil,
    state: inout State,
  ) -> Effect<Action> {
    guard
      let profile = state.config.activeProfile,
      let target = profile.workspaces[id: targetId],
      let display = displayOverride ?? displays.current() ?? state.focusedDisplay
      ?? state.activeWorkspacesByDisplay.keys.first,
      let hostId = state.activeWorkspacesByDisplay[display],
      hostId != targetId,
      let hostWs = profile.workspaces[id: hostId]
    else { return .none }
    // Already borrowed here → dismiss by default. Users who want repeated
    // summons to move/refocus the block can turn the toggle behavior off.
    if
      let existing = state.compositionsByDisplay[display],
      let idx = existing.borrowed.firstIndex(where: { $0.workspace == targetId })
    {
      if state.config.settings.switching.toggleBorrowOnRepeat {
        debugLog.log("Borrow", "repeat summon \(target.name) → dismiss")
        return dismissBorrow(display: display, state: &state)
      }
      var comp = existing
      comp.borrowed[idx].edge = edge
      state.compositionsByDisplay[display] = comp
      let generation = state.borrowGenerationByDisplay[display, default: 0]
      state.pendingBorrowCompletionByDisplay[display] = .init(
        workspaceId: targetId,
        generation: generation,
      )
      debugLog.log("Borrow", "re-dock \(target.name) → \(edge)")
      // Keep an in-flight first hydration valid: re-docking changes only the
      // composition edge, and that hydration's eventual flush reads this
      // current composition. Starting neither a replacement discovery nor a
      // new generation used to strand a fast re-dock with an empty block.
      return .send(
        .flushCompositionAndFocus(
          display: display,
          workspaceId: targetId,
          generation: generation,
        )
      )
    }
    // One workspace/tree can have one physical display owner. Borrowing a
    // workspace already visible on another monitor would make two layout
    // writers fight over the same WindowKeys. Keep that monitor intact and
    // report the conflict instead of silently duplicating it.
    if
      let sourceDisplay = state.displayShowing(targetId),
      !sourceDisplay.matches(display)
    {
      debugLog.log(
        "Borrow",
        "skip \(target.name): already visible on \(sourceDisplay.name)",
      )
      return hudEffect(
        state,
        \.borrow,
        "Already visible",
        "rectangle.on.rectangle.slash",
        subtitle: "\(target.name) is on \(sourceDisplay.name)",
      )
    }
    let fraction = target.borrowFraction ?? state.config.settings.switching.borrowFraction
    let slot = BorrowedSlot(workspace: targetId, edge: edge, fraction: fraction)
    state.borrowGenerationByDisplay[display, default: 0] &+= 1
    let borrowGeneration = state.borrowGenerationByDisplay[display, default: 0]
    state.pendingBorrowCompletionByDisplay[display] = .init(
      workspaceId: targetId,
      generation: borrowGeneration,
    )
    state.compositionsByDisplay[display] = Composition(host: hostId, borrowed: [slot])
    // Only tiled apps from the borrowed workspace participate; float / unmanaged
    // are ignored while borrowed. A scratchpad forces auto-open on all of them
    // (it only ever shows when borrowed, so its apps should come up then).
    let tiledBorrowed = target.apps.filter { $0.layout == .tiled }
    let tiledBorrowedBundleIds = tiledBorrowed.map(\.bundleIdentifier)
    let borrowedApps: [AppAssignment] = target.kind == .scratchpad
      ? tiledBorrowed.map { var a = $0
        a.autoOpen = true
        return a
      }
      : tiledBorrowed
    let existingBorrowedTree = state.tilingTrees[targetId]
    let request = ActivationRequest(
      workspace: hostWs,
      sharedApps: state.config.sharedApps,
      targetDisplay: display,
      setFocus: false,
      borrowedApps: borrowedApps,
      managedBundleIds: state.managedBundleIds,
      knownWindows: Set(existingBorrowedTree?.windows ?? []),
    )
    let settings = state.config.settings
    let focusedForBorrowMerge = state.lastObservedFocusedWindow
    debugLog.log("Borrow", "borrow \(target.name) → host=\(hostWs.name) edge=\(edge)")
    let hud = hudEffect(
      state,
      \.borrow,
      "Borrowed \(target.name)",
      Self.borrowEdgeIcon(edge),
    )
    let render = Effect<Action>.run {
      [
        mgr = workspaceManager,
        observer = windowObserver,
        snapshot = windowSnapshot,
        displays,
      ] send in
      // Borrowed workspaces are visible without becoming the display's active
      // host, so the normal activation-completion observer setup never sees
      // them. Arm their apps alongside the reveal; a replacement surface that
      // appears after discovery then gets an immediate sync.
      async let observation: Void = observer.observe(tiledBorrowedBundleIds)
      await mgr.activate(request)
      // Independent app processes resolve concurrently; WindowSnapshotClient
      // still serializes every AX operation per PID. This bounds cold Borrow
      // latency by the slowest app instead of summing every app's timeout.
      let discovered = await withTaskGroup(
        of: (Int, [WindowKey]).self,
        returning: [WindowKey].self,
      ) { group in
        for (index, bundleId) in tiledBorrowedBundleIds.enumerated() {
          group.addTask {
            let keys: [WindowKey] =
              switch await snapshot.cachedKeysOnlyOffMain([bundleId], true) {
              case .hit(let cached) where !cached.isEmpty:
                // A non-empty cache hit keeps the repeated-Borrow zero-AX path.
                cached
              case .hit,
                   .miss:
                // A miss and a warm empty result each need exactly one fresh
                // post-unhide scan.
                await snapshot.discoverKeysOffMain([bundleId], true)
              }
            return (index, keys)
          }
        }
        var results = [(Int, [WindowKey])]()
        for await result in group { results.append(result) }
        return results.sorted { $0.0 < $1.0 }.flatMap(\.1)
      }
      guard !Task.isCancelled else { return }
      // Validate identity, not immediate visibility. `unhide()` returns before
      // WindowServer necessarily publishes the reused surface through
      // `.optionOnScreenOnly`; filtering there erased a live cached KakaoTalk
      // window and left the Borrow block empty until another window was opened.
      // Exact WindowServer existence still rejects a retired/reused key.
      let existingKeys = snapshot.existingWindowKeys(discovered)
      let keys = discovered.filter(existingKeys.contains)
      let tree = await MainActor.run { () -> BSPNode<WindowKey>? in
        let workArea = displays.workArea(display).insetBy(
          dx: CGFloat(settings.layout.gapOuter),
          dy: CGFloat(settings.layout.gapOuter),
        )
        return Self.mergeTree(
          existing: existingBorrowedTree,
          target: keys,
          focused: { focusedForBorrowMerge },
          insertionPoint: nil,
          workArea: workArea,
          settings: settings,
        )
      }
      await send(
        .borrowedTilingTreeHydrated(
          display: display,
          workspaceId: targetId,
          generation: borrowGeneration,
          previousTree: existingBorrowedTree,
          tree: tree,
        )
      )
      // The borrowed tree is now in state. Apply every host/borrow AX frame
      // first, then land focus + cursor on the completed block. Previously the
      // layout and focus effects raced on the main actor, which made the
      // summon visibly hitch and could wake an overlapping floating mirror.
      await send(
        .flushCompositionAndFocus(
          display: display,
          workspaceId: targetId,
          generation: borrowGeneration,
        )
      )
      // Observer readiness is not part of the visible layout/focus critical
      // path. Its synthetic create event reconciles any surface that raced the
      // snapshot, and this verification catches a frame restore that landed
      // while the AX notifications were being armed.
      _ = await observation
      await send(
        .presentationObservationReady(
          bundleIds: Set(tiledBorrowedBundleIds)
        )
      )
    }
    .cancellable(
      id: CancelID.borrowRender(display),
      cancelInFlight: true,
    )
    return .concatenate(
      .cancel(id: CancelID.borrowFocus(display)),
      .merge(render, hud),
    )
  }

  /// Land focus on a just-summoned borrowed block: the last-used window still
  /// in its tree, else the tree's first window, and — under mouse-follows-focus
  /// — warp the cursor onto it. A deliberate borrow means "work in this now", so
  /// focus + cursor should follow; the borrow itself only *unhides* the apps
  /// (`setFocus: false`) and leaves both on the host. A scratchpad seemed to
  /// land focus only by accident — force-opening its app spawns a fresh window
  /// that the new-window sync warps to — but borrowing an already-running
  /// workspace creates no window, so it never warped. This makes both
  /// consistent. No-op while the borrowed tree is still empty (a cold-launching
  /// app); the new-window sync warps once its window appears, as before.
  func focusBorrowedBlock(
    workspaceId: Workspace.ID,
    completion: BorrowPhase? = nil,
    state: inout State,
  ) -> Effect<Action> {
    guard let tree = state.tilingTrees[workspaceId] else { return .none }
    let target = (state.mruWindows[workspaceId] ?? [])
      .first { tree.windows.contains($0) } ?? tree.windows.first
    guard let target else { return .none }
    debugLog.log("Borrow", "focus borrowed block → \(target.bundleId)#\(target.windowID)")
    // Keep the two main-thread AX operations ordered. Merging focus and warp
    // let app activation win the race after the pointer had already moved,
    // producing a focused Borrow block with the cursor left on its host.
    return settleFocusAfterLayout(
      target,
      workspaceId: workspaceId,
      shouldFocus: true,
      borrowCompletion: completion,
      state: &state,
    )
  }

  /// End the borrow on `display`: drop the composition and re-activate the
  /// host alone, which hides the borrowed apps (no longer in keepVisible) and
  /// re-tiles the host to the full work area. Fire-and-forget.
  /// The recent target shared by switch / assign / borrow. The default is a
  /// strict per-display history; global mode walks workspace MRU across every
  /// display while excluding the workspace on the interaction display.
  func recentWorkspaceId(state: State, display: DisplayName? = nil) -> Workspace.ID? {
    let interactionDisplay = display ?? state.focusedDisplay
    guard let workspaces = state.config.activeProfile?.workspaces else { return nil }
    let isEligible: (Workspace.ID) -> Bool = { id in
      workspaces[id: id]?.kind == .normal
    }
    guard state.config.settings.switching.recentAcrossDisplays else {
      if let interactionDisplay {
        return state.previousWorkspacesByDisplay[interactionDisplay].flatMap {
          isEligible($0) ? $0 : nil
        }
      }
      return state.previousWorkspacesByDisplay.values.first(where: isEligible)
    }
    let current = interactionDisplay.flatMap { state.activeWorkspacesByDisplay[$0] }
      ?? state.primaryActiveWorkspaceID
    return state.workspaceMRU.first { $0 != current && isEligible($0) }
  }

  /// Transfer keyboard focus to a workspace that is already visible without
  /// re-running activation. Activation intentionally tears down the target
  /// display's Borrow composition before re-tiling its host; display focus
  /// navigation must preserve that composition and focus its existing window.
  func focusVisibleWorkspace(
    workspaceId: Workspace.ID,
    display: DisplayName,
    state: inout State,
  ) -> Effect<Action> {
    guard state.displayShowing(workspaceId)?.matches(display) == true else {
      return .none
    }
    let oldDisplay = state.focusedDisplay
    state.focusedDisplay = display
    let target = (state.mruWindows[workspaceId] ?? []).first
      ?? state.tilingTrees[workspaceId]?.windows.first
    guard let target else {
      debugLog.log(
        "Display",
        "focus visible \(workspaceId) on \(display.name): no window",
      )
      return .none
    }
    debugLog.log(
      "Display",
      "focus visible \(workspaceId) on \(display.name) "
        + "→ \(target.bundleId)#\(target.windowID)",
    )
    let focus = settleFocusAfterLayout(
      target,
      workspaceId: workspaceId,
      shouldFocus: true,
      state: &state,
    )
    guard
      let oldDisplay,
      !oldDisplay.matches(display),
      state.config.settings.hud.shows(\.workspaceSwitch),
      let workspace = state.config.activeProfile?.workspaces[id: workspaceId]
    else { return focus }
    let durationMs = state.config.settings.hud.durationMs
    let targetHUD = Effect<Action>.run { [hud = workspaceHUD] _ in
      await hud.showOnDisplay(
        workspace.name,
        workspace.symbolIconName,
        nil,
        durationMs,
        display,
      )
    }
    return .merge(
      focus,
      targetHUD,
      focusMovedHUDEffect(
        workspace: workspace,
        from: oldDisplay,
        to: display,
        state: state,
      ),
    )
  }

  func dismissBorrow(display: DisplayName?, state: inout State) -> Effect<Action> {
    // A hotkey passes nil → resolve the pointer display. Internal collapse
    // actions pass their exact owner so a background monitor stays isolated.
    let display = display ?? displays.current() ?? state.focusedDisplay
      ?? state.compositionsByDisplay.keys.first
    guard let display, let comp = state.compositionsByDisplay[display] else { return .none }
    debugLog.log("Borrow", "dismiss borrow on \(display.name) → restore host")
    state.borrowGenerationByDisplay[display, default: 0] &+= 1
    state.pendingBorrowCompletionByDisplay[display] = nil
    for slot in comp.borrowed {
      state.pendingCenterWarps[slot.workspace] = nil
    }
    // Re-activate the host on the composition's own display. A plain
    // `.activate` re-resolves a dynamic host from interaction focus/cursor and
    // could pull a background-display composition onto the wrong monitor.
    return performActivate(
      workspaceId: comp.host,
      setFocus: true,
      displayOverride: display,
      state: &state,
    )
  }

  /// Disarm the borrow direction pick: clear the target, remove the tap, and
  /// cancel the auto-timeout.
  func endBorrowCapture(state: inout State) -> Effect<Action> {
    state.borrowCapture = nil
    return .merge(
      .run { [borrowChord] _ in await borrowChord.setArmed(false) },
      .cancel(id: CancelID.borrowChordTimeout),
    )
  }

  /// Auto-cancel the borrow direction pick after a few idle seconds so a
  /// half-finished borrow can't keep the key tap swallowing keystrokes.
  func borrowChordTimeout() -> Effect<Action> {
    .run { [clock] send in
      try await clock.sleep(for: .seconds(5))
      await send(.borrowChordKey(.cancel))
    }
    .cancellable(id: CancelID.borrowChordTimeout, cancelInFlight: true)
  }

  /// HUD hint while a borrow direction pick is armed: which workspace, and
  /// that a direction key places it.
  func borrowChordHint(state: State) -> Effect<Action> {
    guard
      state.config.settings.hud.shows(\.borrow),
      let capture = state.borrowCapture,
      let name = state.config.activeProfile?.workspaces[id: capture.workspaceId]?.name
    else { return .none }
    let durationMs = max(state.config.settings.hud.durationMs, 4000)
    return .run { [workspaceHUD] _ in
      await workspaceHUD.show(
        String(localized: "Borrow \(name)"),
        "rectangle.split.2x1",
        String(localized: "press a direction · h j k l / arrows · esc"),
        durationMs,
      )
    }
  }

  /// Directional focus at a block edge crossing into the sibling composition
  /// block (host ↔ borrowed): the nearest window in the sibling toward the
  /// shared boundary, plus the geometry for a mouse warp. Nil when the
  /// direction doesn't point across the boundary or there's no sibling window.
  func crossBlockFocus(
    from key: WindowKey,
    currentId: Workspace.ID,
    currentTree: BSPNode<WindowKey>,
    currentRect: CGRect,
    direction: BSPDirection,
    state: State,
  ) -> (target: WindowKey, display: DisplayName?, tree: BSPNode<WindowKey>, rect: CGRect, zoomed: Set<WindowKey>)? {
    guard
      let display = state.displayShowing(currentId),
      let comp = state.compositionsByDisplay[display],
      let slot = comp.borrowed.first
    else { return nil }
    let dirEdge: BorrowEdge =
      switch direction {
      case .east: .right
      case .west: .left
      case .north: .top
      case .south: .bottom
      }
    // Host crosses toward the borrowed dock; borrowed crosses back (opposite).
    let siblingId: Workspace.ID
    if currentId == comp.host {
      guard dirEdge == slot.edge else { return nil }
      siblingId = slot.workspace
    } else if currentId == slot.workspace {
      guard dirEdge == slot.edge.opposite else { return nil }
      siblingId = comp.host
    } else {
      return nil
    }
    guard let siblingTree = state.tilingTrees[siblingId], !siblingTree.windows.isEmpty
    else { return nil }
    let gap = CGFloat(state.config.settings.layout.gapInner)
    let (_, siblingRect) = tilingContext(for: siblingId, state: state)
    let siblingFrames = siblingTree.frames(in: siblingRect, gap: gap)
    guard !siblingFrames.isEmpty else { return nil }
    let center: CGPoint = currentTree.frames(in: currentRect, gap: gap)[key]
      .map { CGPoint(x: $0.midX, y: $0.midY) }
      ?? CGPoint(x: currentRect.midX, y: currentRect.midY)
    let target = siblingFrames.min {
      hypot($0.value.midX - center.x, $0.value.midY - center.y)
        < hypot($1.value.midX - center.x, $1.value.midY - center.y)
    }?.key
    guard let target else { return nil }
    return (target, display, siblingTree, siblingRect, state.fullscreenZoomed[siblingId] ?? [])
  }

  /// The display + rect a workspace's tree should tile into right now: its
  /// composition sub-rect when it's a host/borrowed block, else its own
  /// display's full work area (pre-feature behavior). The single place every
  /// focus-relative BSP op resolves geometry, so composed and uncomposed
  /// paths can't drift.
  func tilingContext(for workspaceId: Workspace.ID, state: State) -> (display: DisplayName?, rect: CGRect) {
    if
      let display = state.displayShowing(workspaceId),
      let comp = state.compositionsByDisplay[display],
      let slot = comp.borrowed.first
    {
      let workArea = tilingWorkArea(for: display, settings: state.config.settings)
      let gap = CGFloat(state.config.settings.layout.gapInner)
      let (hostRect, borrowedRect) = Self.subRects(
        workArea: workArea,
        edge: slot.edge,
        fraction: slot.fraction,
        gap: gap,
      )
      if workspaceId == comp.host { return (display, hostRect) }
      if workspaceId == slot.workspace { return (display, borrowedRect) }
    }
    // Tile on the display the workspace is *actually* on — not its logical
    // home. A pinned workspace displaced off its (disconnected/other) monitor,
    // or a dynamic one moved across monitors, must lay out for the display it
    // really occupies; resolving to `displayHint`/`displays.current()` sized it
    // to the wrong monitor, leaving a gap / wrong ratio (the intermittent
    // cross-display tiling bug). `activeWorkspacesByDisplay` is the source of
    // truth for placement; fall back to the hint (fresh pinned activation) then
    // the cursor (fresh dynamic activation).
    let display = state.displayShowing(workspaceId)
      ?? state.config.activeProfile?.workspaces[id: workspaceId]?.displayHint
      ?? displays.current()
    return (display, tilingWorkArea(for: display, settings: state.config.settings))
  }
}

/// Whole milliseconds of a `Duration`, for the activation phase log.
private func ms(_ duration: Duration) -> Int64 {
  duration.components.seconds * 1000
    + duration.components.attoseconds / 1_000_000_000_000_000
}

extension SplitTypePreference {
  /// Translate the user-facing preference to the internal split axis
  /// used by `BSPNode.inserting(...)`. `.auto` returns nil so the
  /// aspect-ratio heuristic kicks in.
  func bspSplitAxis() -> BSPNode<WindowKey>.SplitAxis? {
    switch self {
    case .auto: nil
    case .horizontal: .horizontal
    case .vertical: .vertical
    }
  }
}
