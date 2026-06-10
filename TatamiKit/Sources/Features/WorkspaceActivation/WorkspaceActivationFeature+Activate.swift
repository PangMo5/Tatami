import AppKit
import ApplicationServices
import ComposableArchitecture
import Foundation

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
    guard !state.isActivating else {
      debugLog.log("Activate", "skip workspaceId=\(workspaceId): already activating")
      return .none
    }
    state.isActivating = true
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
    let request = ActivationRequest(
      workspace: workspace,
      sharedApps: state.config.sharedApps,
      targetDisplay: targetDisplay,
      setFocus: setFocus,
      mouseHidesOnFocus: setFocus && state.config.settings.focus.mouseHidesOnFocus
    )
    let warpMouse = setFocus && state.config.settings.focus.mouseFollowsFocus
    let showHUD = setFocus && state.config.settings.hud.shows(\.workspaceSwitch)

    let settings = state.config.settings
    // Tile target: this workspace's tiled apps + shared tiled apps. Floating
    // apps (per-workspace or shared) are shown by the manager but kept out of
    // the tree.
    let bundleIds = workspace.apps.filter { !$0.floating }.map(\.bundleIdentifier)
      + state.config.sharedApps.filter { !$0.floating }.map(\.bundleIdentifier)
    // Floating apps (per-workspace + shared) are raised above the tiles after
    // the tile pass.
    let floatingBundleIds = workspace.apps.filter(\.floating).map(\.bundleIdentifier)
      + state.config.sharedApps.filter(\.floating).map(\.bundleIdentifier)
    let memory = workspace.tilingMemory ?? settings.layout.defaultTilingMemory
    let sessionTree = state.tilingTrees[workspace.id]
    let zoomed = state.fullscreenZoomed[workspace.id] ?? []
    let insertionPoint = state.insertionPoint[workspace.id]

    let hudName = workspace.name
    let hudIcon = workspace.symbolIconName
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

    return .merge(screenRecordingWarning, watchdog, .run { [
      mgr = workspaceManager,
      tiler = windowTiler,
      store = layoutStore,
      hud = workspaceHUD,
      mouse = mouse,
      overlay = floatingOverlay,
      marker = marker,
      snapshot = windowSnapshot,
      displays = displays
    ] send in
      if showHUD {
        await hud.show(hudName, hudIcon, nil, hudDurationMs)
      }
      // Tear down the outgoing workspace's mirrors in the same beat as the
      // hide pass — leaving them to the post-tile `setFloating` made the
      // floating windows visibly outlive the windows they mirror.
      overlay.retainOnly(Set(floatingBundleIds))
      await mgr.activate(request)
      if !isPaused {
        let persistedSnapshot: LayoutSnapshot? =
          memory == .persistent && sessionTree == nil
            ? await store.load(workspaceId)
            : nil
        let (tree, frames, restoredZoom) = await MainActor.run {
          () -> (BSPNode<WindowKey>?, [WindowKey: CGRect], Set<WindowKey>) in
          let keys = snapshot.discoverKeys(bundleIds, true)
          let focused = snapshot.focusedWindowKey()
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
            focused: focused,
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
        if !frames.isEmpty {
          await tiler.apply(
            FrameApplication(windowFrames: frames, targetDisplay: targetDisplay)
          )
        }
        // Mirror floating windows onto always-on-top panels (the Topit /
        // Floaty technique): a foreign window's level can't be raised without
        // SIP, so instead of trying we paint a live mirror above the tiles.
        // Passing the resolved set (possibly empty) also tears down mirrors
        // for apps that were just un-floated or belong to another workspace.
        let floatingKeys = await MainActor.run {
          Set(snapshot.discoverKeys(floatingBundleIds, false))
        }
        overlay.setFloating(floatingKeys)
        // Markers ride the same discovery — `activationCompleted` used to
        // re-run a full AX scan for the floating keys this pass just
        // resolved.
        let markerCfg = settings.marker
        marker.setTargets(
          Self.markerTargets(
            fullscreenZoomed: markerCfg.fullscreenEnabled ? restoredZoom : [],
            floatingKeys: markerCfg.floatingEnabled ? Array(floatingKeys) : [],
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
      await send(.activationCompleted(workspaceId: workspaceId, display: targetDisplay))
    })
  }

  // MARK: - Cycle

  func cycle(by direction: Int, state: inout State) -> Effect<Action> {
    guard let id = adjacentWorkspaceId(by: direction, state: state) else { return .none }
    return .send(.activate(workspaceId: id, setFocus: true))
  }

  /// The workspace `direction` steps from the active one, honoring the
  /// `loop` / `skipEmpty` switching preferences. Shared by cycling and by
  /// "move focused app to next/previous workspace". Returns `nil` when there
  /// is no eligible target (e.g. at an end with looping off).
  func adjacentWorkspaceId(by direction: Int, state: State) -> Workspace.ID? {
    guard let all = state.config.activeProfile?.workspaces, !all.isEmpty
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
    // Anchor at the active workspace on the focused display.
    let currentID = state.primaryActiveWorkspaceID
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
    fullscreenZoomed: Set<WindowKey> = []
  ) -> [WindowKey: CGRect] {
    guard let tree else { return [:] }
    let workArea = ScreenGeometry.workArea(for: targetDisplay).insetBy(
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
  return WindowKey.from(
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
