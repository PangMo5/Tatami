import AppKit
import ApplicationServices
import ComposableArchitecture
import Foundation
import OrderedCollections

extension WorkspaceActivationFeature {
  // MARK: - Activation

  func performActivate(
    workspaceId: Workspace.ID,
    setFocus: Bool,
    state: inout State
  ) -> Effect<Action> {
    guard let profile = state.config.activeProfile,
          let workspace = profile.workspaces[id: workspaceId]
    else { return .none }
    // (Switching to a borrowed workspace fully activates it — the composition
    // is dropped as the display re-tiles. Moving focus *into* a borrowed block
    // without switching is the directional-focus path, not activation.)
    // A scratchpad is borrow-only: there's no "switch to" it. Redirect a
    // standalone activate into a borrow on the focused display's host
    // (re-docks if it's already borrowed there).
    if workspace.kind == .scratchpad {
      debugLog.log("Activate", "scratchpad \(workspace.name) → borrow")
      return performBorrow(targetId: workspaceId, edge: .right, state: &state)
    }
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
        + "paused=\(isPaused) registeredApps=\(workspace.apps.map(\.bundleIdentifier))"
    )

    // Resolve the pinned display to where it actually tiles: the connected
    // screen (UUID → name match), else the primary display as fallback.
    // Learn the UUID for a name-only hint so future matching is UUID-stable.
    let targetDisplay: DisplayName?
    if let hint = workspace.displayHint {
      let connected = displays.connected(hint)
      if let connected, hint.uuid != connected.uuid {
        state.$config.withLock { config in
          config.mutateWorkspace(workspaceId) { $0.displayHint = connected }
        }
      }
      targetDisplay = connected ?? displays.primary() ?? hint
    } else {
      targetDisplay = displays.current()
    }
    // Re-tiling this display to `workspace` dismisses any live composition on
    // it — a borrow is transient and vanishes when its host re-tiles. Capture
    // the dropped borrow's name so the switch HUD can announce it; skip the
    // case where we're switching *into* the borrowed workspace (a promotion,
    // not a return).
    var dismissedBorrowName: String?
    if let targetDisplay, let comp = state.compositionsByDisplay[targetDisplay] {
      if let slot = comp.borrowed.first, slot.workspace != workspaceId {
        dismissedBorrowName = profile.workspaces[id: slot.workspace]?.name
      }
      state.compositionsByDisplay[targetDisplay] = nil
    }
    // "Most recently used" (no pinned focus app): restore the exact
    // window the user last had focused in this workspace.
    let mruWindow = workspace.appToFocusBundleId == nil
      ? state.mruWindows[workspaceId]?.first
      : nil
    let request = ActivationRequest(
      workspace: workspace,
      sharedApps: state.config.sharedApps,
      targetDisplay: targetDisplay,
      setFocus: setFocus,
      mouseHidesOnFocus: setFocus && state.config.settings.focus.mouseHidesOnFocus,
      windowKeyToFocus: mruWindow
    )
    let warpMouse = setFocus && state.config.settings.focus.mouseFollowsFocus
    // Show the HUD on a normal switch, or whenever this switch returned a
    // borrow (so the dismissal is always announced — even mid-move).
    let showHUD = setFocus && (
      state.config.settings.hud.shows(\.workspaceSwitch)
        || (dismissedBorrowName != nil && state.config.settings.hud.shows(\.borrow))
    )

    let settings = state.config.settings
    // Tile target: this workspace's tiled apps + shared tiled apps. Floating
    // apps (per-workspace or shared) are shown by the manager but kept out of
    // the tree.
    // An app registered to the workspace AND shared appears in both lists —
    // dedupe, or its windows get discovered twice and tile twice.
    let bundleIds = Array(OrderedSet(
      workspace.apps.filter { $0.layout == .tiled }.map(\.bundleIdentifier)
        + state.config.sharedApps.filter { $0.layout == .tiled }.map(\.bundleIdentifier)
    ))
    // Floating apps (per-workspace + shared) are raised above the tiles after
    // the tile pass. Unmanaged apps are neither tiled nor floated — left out
    // of both sets; the manager still shows/hides them as members.
    let floatingBundleIds = Array(OrderedSet(
      workspace.apps.filter { $0.layout == .floating }.map(\.bundleIdentifier)
        + state.config.sharedApps.filter { $0.layout == .floating }.map(\.bundleIdentifier)
    ))
    let memory = workspace.tilingMemory ?? settings.layout.defaultTilingMemory
    let sessionTree = state.tilingTrees[workspace.id]
    let zoomed = state.fullscreenZoomed[workspace.id] ?? []
    let insertionPoint = state.insertionPoint[workspace.id]
    // Borrow markers live across displays; this display's composition was just
    // cleared, so this is any *other* display's borrows that the global marker
    // push below must preserve.
    let borrowedMarkers = Self.borrowMarkerTargets(state: state)

    let hudName = workspace.name
    let hudIcon = workspace.symbolIconName
    let hudSubtitle = dismissedBorrowName.map { "Returned \($0)" }
    let hudDurationMs = state.config.settings.hud.durationMs

    // Floating windows need Screen Recording for their mirrors. Don't fail
    // silently ("floating just doesn't stay on top"): surface the system
    // prompt and a HUD pointing at the Settings row, once per session.
    var screenRecordingWarning: Effect<Action> = .none
    if !floatingBundleIds.isEmpty,
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
          subtitle: "Floating windows can't stay above the tiles without it — grant in Settings → General → Permissions, then relaunch"
        )
      )
    }

    // Watchdog: `isActivating` is only ever cleared by
    // `activationCompleted` — if the activation effect wedges past every
    // AX timeout (or dies without reporting), the latch would refuse all
    // future activations and syncs for the rest of the session. Cancelled
    // by `activationCompleted` on the normal path.
    let watchdog = Effect<Action>.run { [clock] send in
      try? await clock.sleep(for: .seconds(10))
      await send(.activationTimedOut)
    }
    .cancellable(id: CancelID.activationWatchdog, cancelInFlight: true)

    // `.userInteractive`: the whole effect is the visible response to a
    // hotkey press. Under system load the default priority leaves our
    // main-actor hops queued behind everything else — exactly when the
    // switch already crawls on slow AX replies.
    return .merge(screenRecordingWarning, watchdog, .run(priority: .userInteractive) { [
      mgr = workspaceManager,
      tiler = windowTiler,
      store = layoutStore,
      hud = workspaceHUD,
      mouse = mouse,
      overlay = floatingOverlay,
      marker = marker,
      snapshot = windowSnapshot,
      displays = displays,
      debugLog = debugLog
    ] send in
      // Wall-clock per phase — AX round trips block on *other* apps' run
      // loops, so when a switch crawls under load this names the phase
      // (and thus the app set) that ate the time.
      let timer = ContinuousClock()
      var phaseStart = timer.now
      var phases: [(String, Duration)] = []
      func mark(_ name: String) {
        let now = timer.now
        phases.append((name, now - phaseStart))
        phaseStart = now
      }
      if showHUD {
        await hud.show(hudName, hudIcon, hudSubtitle, hudDurationMs)
      }
      // Tear down the outgoing workspace's mirrors in the same beat as the
      // hide pass — leaving them to the post-tile `setFloating` made the
      // floating windows visibly outlive the windows they mirror.
      overlay.retainOnly(Set(floatingBundleIds))
      await mgr.activate(request)
      mark("showHide")
      // Superseded by a newer switch: stop before the tile pass. `send`
      // on a cancelled effect is already a no-op, but the AX work below
      // is not — without these checks a superseded activation would keep
      // writing the *old* workspace's frames interleaved with the new
      // activation's main-actor hops.
      guard !Task.isCancelled else { return }
      if !isPaused {
        let persistedSnapshot: LayoutSnapshot? =
          memory == .persistent && sessionTree == nil
            ? await store.load(workspaceId)
            : nil
        // Cache-first discovery: a warm `WindowKeyCache` entry costs zero
        // AX round trips — AX scans block on each target app's run loop
        // (measured 50 ms–1.2 s per switch), which is what made switching
        // crawl under system load. Misses scan one bundle per main-actor
        // hop so a busy app can't hold the main thread through its
        // neighbors' turns. `activationCompleted` schedules the
        // revalidation sweep that repairs any staleness.
        var discovered: [WindowKey] = []
        for bundleId in bundleIds {
          guard !Task.isCancelled else { return }
          discovered += await MainActor.run { snapshot.cachedKeys([bundleId], true) }
        }
        let keys = discovered
        mark("discover")
        let (tree, frames, restoredZoom) = await MainActor.run {
          () -> (BSPNode<WindowKey>?, [WindowKey: CGRect], Set<WindowKey>) in
          let workArea = displays.workArea(targetDisplay).insetBy(
            dx: CGFloat(settings.layout.gapOuter),
            dy: CGFloat(settings.layout.gapOuter)
          )
          var base = sessionTree
          var persistedZoomBundleIds: [String] = []
          if let snapshot = persistedSnapshot {
            base = BSPNode.hydrate(template: snapshot.tree, keys: keys)
            persistedZoomBundleIds = snapshot.fullscreenZoomedBundleIds
          }
          let merged = Self.mergeTree(
            existing: base,
            target: keys,
            focused: { snapshot.focusedWindowKey() },
            insertionPoint: insertionPoint,
            workArea: workArea,
            settings: settings
          )
          let axis = settings.layout.autoBalance
          let tree = axis == .none ? merged : merged?.balanced(axis: axis)
          let resolvedZoom: Set<WindowKey> = {
            if !zoomed.isEmpty { return zoomed }
            guard let tree else { return [] }
            return Self.resolveFullscreenZoom(
              bundleIds: persistedZoomBundleIds, among: tree.windows
            )
          }()
          let frames = Self.computeFrames(
            tree: tree,
            settings: settings,
            targetDisplay: targetDisplay,
            fullscreenZoomed: resolvedZoom
          )
          return (tree, frames, resolvedZoom)
        }
        mark("layout")
        await send(.tilingTreeUpdated(workspaceId: workspaceId, tree: tree))
        if !restoredZoom.isEmpty, zoomed.isEmpty {
          await send(.persistedFullscreenZoomRestored(workspaceId: workspaceId, keys: restoredZoom))
        }
        if memory == .persistent, let tree {
          store.save(
            workspaceId,
            LayoutSnapshot(
              tree: tree.mapWindows { $0.bundleId },
              fullscreenZoomedBundleIds: restoredZoom.map(\.bundleId).sorted()
            )
          )
        }
        guard !Task.isCancelled else { return }
        if !frames.isEmpty {
          await tiler.apply(
            FrameApplication(windowFrames: frames, targetDisplay: targetDisplay)
          )
        }
        mark("apply")
        // Mirror floating windows onto always-on-top panels (the Topit /
        // Floaty technique): a foreign window's level can't be raised without
        // SIP, so instead of trying we paint a live mirror above the tiles.
        // Passing the resolved set (possibly empty) also tears down mirrors
        // for apps that were just un-floated or belong to another workspace.
        // Same cache-first, per-bundle main-actor hops as the tile
        // discovery above.
        var floatingDiscovered: Set<WindowKey> = []
        for bundleId in floatingBundleIds {
          guard !Task.isCancelled else { return }
          floatingDiscovered.formUnion(
            await MainActor.run { snapshot.cachedKeys([bundleId], false) }
          )
        }
        let floatingKeys = floatingDiscovered
        mark("float")
        overlay.setFloating(floatingKeys)
        // Markers ride the same discovery — `activationCompleted` used to
        // re-run a full AX scan for the floating keys this pass just
        // resolved.
        let markerCfg = settings.marker
        marker.setTargets(
          Self.markerTargets(
            fullscreenZoomed: markerCfg.fullscreenEnabled ? restoredZoom : [],
            floatingKeys: markerCfg.floatingEnabled ? Array(floatingKeys) : [],
            borrowed: borrowedMarkers,
            cfg: markerCfg
          ),
          markerCfg.size, markerCfg.corner, markerCfg.hideOnHover
        )
        if warpMouse {
          let center = await MainActor.run { () -> CGPoint? in
            guard let key = snapshot.focusedWindowKey(), let rect = frames[key] else { return nil }
            return CGPoint(x: rect.midX, y: rect.midY)
          }
          if let center { mouse.warp(center) }
        }
      }
      debugLog.log(
        "Activate",
        "phases " + phases.map { "\($0.0)=\(ms($0.1))ms" }.joined(separator: " ")
      )
      await send(.activationCompleted(workspaceId: workspaceId, display: targetDisplay))
    }
    .cancellable(id: CancelID.activation, cancelInFlight: true))
  }

  // MARK: - Cycle

  func cycle(by direction: Int, state: inout State) -> Effect<Action> {
    let anchor = state.activatingWorkspaceID ?? state.primaryActiveWorkspaceID
    let workspaces = state.config.activeProfile?.workspaces
    let name = { (id: Workspace.ID?) -> String in
      id.flatMap { workspaces?[id: $0]?.name } ?? "nil"
    }
    guard let id = adjacentWorkspaceId(by: direction, state: state) else {
      debugLog.log(
        "Activate",
        "cycle \(direction > 0 ? "next" : "previous") from=\(name(anchor)): no eligible target"
      )
      return .none
    }
    debugLog.log(
      "Activate",
      "cycle \(direction > 0 ? "next" : "previous") from=\(name(anchor)) → \(name(id))"
    )
    return .send(.activate(workspaceId: id, setFocus: true))
  }

  /// The workspace `direction` steps from the active one, honoring the
  /// `loop` / `skipEmpty` switching preferences. Shared by cycling and by
  /// "move focused app to next/previous workspace". Returns `nil` when there
  /// is no eligible target (e.g. at an end with looping off).
  func adjacentWorkspaceId(by direction: Int, state: State) -> Workspace.ID? {
    // Scratchpads are borrow-only — never a cycle destination.
    guard let all = state.config.activeProfile?.workspaces
            .filter({ $0.kind != .scratchpad }),
          !all.isEmpty
    else { return nil }
    let settings = state.config.settings
    // Scope the cycle. `cycleAcrossDisplays` → every workspace. Otherwise stay
    // on the cursor's display: pinned workspaces by their display, dynamic
    // (unpinned) ones by the display they were last activated on (never-active
    // ones are included so they stay reachable).
    let workspaces: IdentifiedArrayOf<Workspace>
    if !settings.switching.cycleAcrossDisplays, let focused = state.focusedDisplay {
      workspaces = all.filter { ws in
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
      workspaces = all
    }
    guard !workspaces.isEmpty else { return nil }
    // Anchor at the in-flight activation's target when there is one, else
    // the active workspace on the focused display. `primaryActive` only
    // updates on completion, so without the in-flight anchor every press
    // during a slow switch re-resolved to the same target.
    let currentID = state.activatingWorkspaceID ?? state.primaryActiveWorkspaceID
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

  /// Map persisted fullscreen-zoom bundle ids back onto live windows,
  /// consuming a distinct window per entry so that several zoomed windows
  /// of the *same* app each resolve to a different window (mirrors
  /// `BSPNode.hydrate`, which drains a per-bundle queue). Entries with no
  /// remaining live match are dropped — the layout degrades gracefully
  /// when an app has fewer windows than it did at save time.
  static func resolveFullscreenZoom(
    bundleIds: [String],
    among windows: [WindowKey]
  ) -> Set<WindowKey> {
    var available = windows
    var resolved: Set<WindowKey> = []
    for bundleId in bundleIds {
      guard let i = available.firstIndex(where: { $0.bundleId == bundleId })
      else { continue }
      resolved.insert(available.remove(at: i))
    }
    return resolved
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
    targetRect: CGRect? = nil
  ) -> [WindowKey: CGRect] {
    guard let tree else { return [:] }
    // `targetRect` (a composition sub-rect) is already inset; only the
    // full-display path applies the outer gap.
    let workArea = targetRect ?? ScreenGeometry.workArea(for: targetDisplay).insetBy(
      dx: CGFloat(settings.layout.gapOuter),
      dy: CGFloat(settings.layout.gapOuter)
    )
    let gap = CGFloat(settings.layout.gapInner)
    let activeZoom = fullscreenZoomed.filter { tree.pathTo(window: $0) != nil }
    if !activeZoom.isEmpty {
      var trimmed: BSPNode<WindowKey>? = tree
      for key in activeZoom { trimmed = trimmed?.removing(key) }
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
    gap: CGFloat
  ) -> (host: CGRect, borrowed: CGRect) {
    let axis: BSPNode<WindowKey>.SplitAxis =
      (edge == .left || edge == .right) ? .vertical : .horizontal
    switch edge {
    case .left, .top:
      let (b, h) = axis.subdivide(workArea, ratio: fraction, gap: gap)
      return (host: h, borrowed: b)
    case .right, .bottom:
      let (h, b) = axis.subdivide(workArea, ratio: 1 - fraction, gap: gap)
      return (host: h, borrowed: b)
    }
  }

  /// Flush the display's composition (host + borrowed blocks) in one apply:
  /// each workspace's tree laid into its sub-rect, frames merged, applied
  /// together. No-op when the display has no active composition.
  func applyComposition(display: DisplayName?, state: State) -> Effect<Action> {
    let settings = state.config.settings
    guard let display,
          let comp = state.compositionsByDisplay[display],
          let slot = comp.borrowed.first,
          let hostTree = state.tilingTrees[comp.host]
    else { return .none }
    let borrowedTree = state.tilingTrees[slot.workspace]
    let hostZoom = state.fullscreenZoomed[comp.host] ?? []
    let borrowedZoom = state.fullscreenZoomed[slot.workspace] ?? []
    let edge = slot.edge
    let fraction = slot.fraction
    return .run { [tiler = windowTiler, displays] _ in
      let merged: [WindowKey: CGRect] = await MainActor.run {
        let workArea = displays.workArea(display).insetBy(
          dx: CGFloat(settings.layout.gapOuter),
          dy: CGFloat(settings.layout.gapOuter)
        )
        let gap = CGFloat(settings.layout.gapInner)
        let (hostRect, borrowedRect) = Self.subRects(
          workArea: workArea, edge: edge, fraction: fraction, gap: gap
        )
        let hf = Self.computeFrames(
          tree: hostTree, settings: settings, targetDisplay: display,
          fullscreenZoomed: hostZoom, targetRect: hostRect
        )
        let bf = Self.computeFrames(
          tree: borrowedTree, settings: settings, targetDisplay: display,
          fullscreenZoomed: borrowedZoom, targetRect: borrowedRect
        )
        return hf.merging(bf) { current, _ in current }
      }
      guard !merged.isEmpty else { return }
      await tiler.apply(FrameApplication(windowFrames: merged, targetDisplay: display))
    }
    .cancellable(id: CancelID.applyComposition(display), cancelInFlight: true)
  }

  /// Borrow `targetId` into the focused display's host workspace, docked to
  /// `edge`. Re-borrowing a target already borrowed there just re-docks it to
  /// the new edge. Live: the borrowed block reuses the target's real tree, so
  /// edits persist to it. Only the borrowed workspace's *tiled* apps take part
  /// — its floating / unmanaged apps are ignored while borrowed.
  func performBorrow(
    targetId: Workspace.ID,
    edge: BorrowEdge,
    state: inout State
  ) -> Effect<Action> {
    guard let profile = state.config.activeProfile,
          let target = profile.workspaces[id: targetId],
          let display = state.focusedDisplay ?? state.activeWorkspacesByDisplay.keys.first,
          let hostId = state.activeWorkspacesByDisplay[display],
          hostId != targetId,
          let hostWs = profile.workspaces[id: hostId]
    else { return .none }
    // Already borrowed here → re-dock to the new edge instead of toggling off
    // (the apps are already visible, so just re-flush the composition).
    if let existing = state.compositionsByDisplay[display],
       let idx = existing.borrowed.firstIndex(where: { $0.workspace == targetId }) {
      var comp = existing
      comp.borrowed[idx].edge = edge
      state.compositionsByDisplay[display] = comp
      debugLog.log("Borrow", "re-dock \(target.name) → \(edge)")
      return applyComposition(display: display, state: state)
    }
    let fraction = target.borrowFraction ?? state.config.settings.switching.borrowFraction
    let slot = BorrowedSlot(workspace: targetId, edge: edge, fraction: fraction)
    state.compositionsByDisplay[display] = Composition(host: hostId, borrowed: [slot])
    // Only tiled apps from the borrowed workspace participate; float / unmanaged
    // are ignored while borrowed. A scratchpad forces auto-open on all of them
    // (it only ever shows when borrowed, so its apps should come up then).
    let tiledBorrowed = target.apps.filter { $0.layout == .tiled }
    let tiledBorrowedBundleIds = tiledBorrowed.map(\.bundleIdentifier)
    let borrowedApps: [AppAssignment] = target.kind == .scratchpad
      ? tiledBorrowed.map { var a = $0; a.autoOpen = true; return a }
      : tiledBorrowed
    let request = ActivationRequest(
      workspace: hostWs, sharedApps: state.config.sharedApps,
      targetDisplay: display, setFocus: false, borrowedApps: borrowedApps
    )
    let settings = state.config.settings
    let existingBorrowedTree = state.tilingTrees[targetId]
    debugLog.log("Borrow", "borrow \(target.name) → host=\(hostWs.name) edge=\(edge)")
    let hud = hudEffect(
      state, \.borrow,
      "Borrowed \(target.name)",
      Self.borrowEdgeIcon(edge)
    )
    let render = Effect<Action>.run { [mgr = workspaceManager, snapshot = windowSnapshot, displays] send in
      await mgr.activate(request)
      var discovered: [WindowKey] = []
      for bundleId in tiledBorrowedBundleIds {
        discovered += await MainActor.run { snapshot.cachedKeys([bundleId], true) }
      }
      let keys = discovered
      let tree = await MainActor.run { () -> BSPNode<WindowKey>? in
        let workArea = displays.workArea(display).insetBy(
          dx: CGFloat(settings.layout.gapOuter),
          dy: CGFloat(settings.layout.gapOuter)
        )
        return Self.mergeTree(
          existing: existingBorrowedTree, target: keys,
          focused: { snapshot.focusedWindowKey() },
          insertionPoint: nil, workArea: workArea, settings: settings
        )
      }
      await send(.tilingTreeUpdated(workspaceId: targetId, tree: tree))
      await send(.flushComposition(display: display))
    }
    return .merge(render, hud)
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

  /// End the borrow on `display`: drop the composition and re-activate the
  /// host alone, which hides the borrowed apps (no longer in keepVisible) and
  /// re-tiles the host to the full work area. Fire-and-forget.
  /// The recent workspace on the focused display (falls back to any recent) —
  /// the target for recent-workspace activate / assign / borrow.
  func recentWorkspaceId(state: State) -> Workspace.ID? {
    state.focusedDisplay.flatMap { state.previousWorkspacesByDisplay[$0] }
      ?? state.previousWorkspacesByDisplay.values.first
  }

  func dismissBorrow(display: DisplayName?, state: inout State) -> Effect<Action> {
    // A hotkey passes nil → resolve the focused display (then any composed one).
    let display = display ?? state.focusedDisplay
      ?? state.compositionsByDisplay.keys.first
    guard let display, let comp = state.compositionsByDisplay[display] else { return .none }
    debugLog.log("Borrow", "dismiss borrow on \(display.name) → restore host")
    // Re-activate the host: performActivate drops the composition, tiles the
    // host full-screen, and its switch HUD announces the returned borrow in its
    // subtitle.
    return .send(.activate(workspaceId: comp.host, setFocus: true))
  }

  /// Disarm the borrow direction pick: clear the target, remove the tap, and
  /// cancel the auto-timeout.
  func endBorrowCapture(state: inout State) -> Effect<Action> {
    state.borrowCaptureTarget = nil
    return .merge(
      .run { [borrowChord] _ in await borrowChord.setArmed(false) },
      .cancel(id: CancelID.borrowChordTimeout)
    )
  }

  /// Auto-cancel the borrow direction pick after a few idle seconds so a
  /// half-finished borrow can't keep the key tap swallowing keystrokes.
  func borrowChordTimeout() -> Effect<Action> {
    .run { [clock] send in
      try? await clock.sleep(for: .seconds(5))
      await send(.borrowChordKey(.cancel))
    }
    .cancellable(id: CancelID.borrowChordTimeout, cancelInFlight: true)
  }

  /// HUD hint while a borrow direction pick is armed: which workspace, and
  /// that a direction key places it.
  func borrowChordHint(state: State) -> Effect<Action> {
    guard state.config.settings.hud.shows(\.borrow),
          let target = state.borrowCaptureTarget,
          let name = state.config.activeProfile?.workspaces[id: target]?.name
    else { return .none }
    let durationMs = max(state.config.settings.hud.durationMs, 4000)
    return .run { [workspaceHUD] _ in
      await workspaceHUD.show(
        "Borrow \(name)", "rectangle.split.2x1", "press a direction · h j k l / arrows · esc", durationMs
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
    state: State
  ) -> (target: WindowKey, display: DisplayName?, tree: BSPNode<WindowKey>, rect: CGRect, zoomed: Set<WindowKey>)? {
    guard let display = state.focusedDisplay,
          let comp = state.compositionsByDisplay[display],
          let slot = comp.borrowed.first
    else { return nil }
    let dirEdge: BorrowEdge = {
      switch direction {
      case .east: .right
      case .west: .left
      case .north: .top
      case .south: .bottom
      }
    }()
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
    if let display = state.focusedDisplay,
       let comp = state.compositionsByDisplay[display],
       let slot = comp.borrowed.first {
      let workArea = tilingWorkArea(for: display, settings: state.config.settings)
      let gap = CGFloat(state.config.settings.layout.gapInner)
      let (hostRect, borrowedRect) = Self.subRects(
        workArea: workArea, edge: slot.edge, fraction: slot.fraction, gap: gap
      )
      if workspaceId == comp.host { return (display, hostRect) }
      if workspaceId == slot.workspace { return (display, borrowedRect) }
    }
    let display = state.config.activeProfile?.workspaces[id: workspaceId]?.displayHint
      ?? displays.current()
    return (display, tilingWorkArea(for: display, settings: state.config.settings))
  }
}

/// Whole milliseconds of a `Duration`, for the activation phase log.
private func ms(_ duration: Duration) -> Int64 {
  duration.components.seconds * 1000
    + duration.components.attoseconds / 1_000_000_000_000_000
}

/// Live AX read of the frontmost app's focused window. Reducers go
/// through `WindowSnapshotClient.focusedWindowKey` instead, which wraps
/// this in its live value.
@MainActor
func liveFocusedWindowKey() -> WindowKey? {
  guard let app = NSWorkspace.shared.frontmostApplication,
        let bundleId = app.bundleIdentifier
  else { return nil }
  let axApp = AXUIElementCreateApplication(app.processIdentifier)
  var raw: CFTypeRef?
  guard AXUIElementCopyAttributeValue(
    axApp,
    kAXFocusedWindowAttribute as CFString,
    &raw
  ) == .success,
    let value = raw,
    CFGetTypeID(value) == AXUIElementGetTypeID()
  else { return nil }
  return WindowKey(
    axWindow: value as! AXUIElement,
    pid: app.processIdentifier,
    bundleId: bundleId
  )
}

extension SplitTypePreference {
  /// Translate the user-facing preference to the internal split axis
  /// used by `BSPNode.inserting(...)`. `.auto` returns nil so the
  /// aspect-ratio heuristic kicks in.
  func bspSplitAxis() -> BSPNode<WindowKey>.SplitAxis? {
    switch self {
    case .auto: return nil
    case .horizontal: return .horizontal
    case .vertical: return .vertical
    }
  }
}
