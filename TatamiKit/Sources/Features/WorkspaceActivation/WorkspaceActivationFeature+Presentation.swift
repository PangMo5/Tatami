// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ComposableArchitecture
import Foundation
import OrderedCollections

extension WorkspaceActivationFeature {

  // MARK: Internal

  /// The active workspace's floating apps + shared floating apps — the
  /// set whose live windows get mirror panels and marker dots.
  static func floatingBundleIds(state: State) -> [String] {
    floatingBundleIds(state: state, workspaceIDs: state.visibleWorkspaceIDs)
  }

  static func floatingBundleIds(
    state: State,
    workspaceIDs: Set<Workspace.ID>,
  ) -> [String] {
    let perWorkspace = workspaceIDs.flatMap { id in
      state.config.activeProfile?.workspaces[id: id]?
        .apps.filter { $0.layout == .floating }.map(\.bundleIdentifier) ?? []
    }
    let shared = state.config.sharedApps.filter { $0.layout == .floating }.map(\.bundleIdentifier)
    return Array(OrderedSet(perWorkspace + shared))
  }

  /// The active workspace's unmanaged apps + shared unmanaged apps —
  /// members that are neither tiled nor mirrored, but still count as
  /// window-cycle targets and (via the discovery cache) FFM hit-test
  /// windows.
  static func unmanagedBundleIds(state: State) -> [String] {
    unmanagedBundleIds(state: state, workspaceIDs: state.visibleWorkspaceIDs)
  }

  static func unmanagedBundleIds(
    state: State,
    workspaceIDs: Set<Workspace.ID>,
  ) -> [String] {
    let perWorkspace = workspaceIDs.flatMap { id in
      state.config.activeProfile?.workspaces[id: id]?
        .apps.filter { $0.layout == .unmanaged }.map(\.bundleIdentifier) ?? []
    }
    let shared = state.config.sharedApps.filter { $0.layout == .unmanaged }.map(\.bundleIdentifier)
    return Array(OrderedSet(perWorkspace + shared))
  }

  /// Marker targets: fullscreen-zoom dots (focus-gated) + floating dots
  /// (always visible — the dot is what identifies a floating window / its
  /// mirror at a glance). Callers pass only the keys whose categories are
  /// enabled in `cfg`.
  static func markerTargets(
    fullscreenZoomed: Set<WindowKey>,
    floatingKeys: [WindowKey],
    borrowed: [WindowKey: String],
    cfg: AppSettings.Marker,
  ) -> [WindowKey: MarkerTarget] {
    var targets = [WindowKey: MarkerTarget]()
    for key in fullscreenZoomed {
      targets[key] = MarkerTarget(colorHex: cfg.fullscreenColorHex)
    }
    for key in floatingKeys {
      targets[key] = MarkerTarget(colorHex: cfg.floatingColorHex, alwaysVisible: true)
    }
    // Borrowed windows badge with the borrowed workspace's icon — always
    // visible (the point is to see what's on loan regardless of focus), and
    // pushed last so a borrowed window wins over a stray floating/zoom mark.
    for (key, symbol) in borrowed {
      targets[key] = MarkerTarget(colorHex: cfg.borrowColorHex, alwaysVisible: true, symbol: symbol)
    }
    return targets
  }

  /// Borrowed-window markers across every live composition: each borrowed
  /// window keyed to its source workspace's icon. Empty when the category is
  /// off or nothing is borrowed.
  static func borrowMarkerTargets(state: State) -> [WindowKey: String] {
    guard state.config.settings.marker.borrowEnabled else { return [:] }
    var out = [WindowKey: String]()
    for comp in state.compositionsByDisplay.values {
      for slot in comp.borrowed {
        guard let ws = state.config.activeProfile?.workspaces[id: slot.workspace]
        else { continue }
        let symbol = ws.symbolIconName ?? "square.stack.3d.up"
        for key in state.tilingTrees[slot.workspace]?.windows ?? [] {
          out[key] = symbol
        }
      }
    }
    return out
  }

  /// Warp the cursor to the center of `key`'s tile when mouse-follows-focus is
  /// on. No-op when the setting is off or `key` has no frame. The shared body
  /// behind every "focus moved → follow it" path that isn't a hotkey (new
  /// window, refocus-on-close).
  func warpToWindow(
    _ key: WindowKey,
    in tree: BSPNode<WindowKey>,
    workspaceId: Workspace.ID,
    state: State,
    skipIfCursorInside: Bool = false,
    clearsPendingCenter: Bool = false,
  ) -> Effect<Action> {
    guard state.config.settings.focus.mouseFollowsFocus else { return .none }
    let settings = state.config.settings
    let (display, rect) = tilingContext(for: workspaceId, state: state)
    let zoomed = state.fullscreenZoomed[workspaceId] ?? []
    return .run { [mouse] send in
      let center = await MainActor.run { () -> CGPoint? in
        let frames = Self.computeFrames(
          tree: tree,
          settings: settings,
          targetDisplay: display,
          fullscreenZoomed: zoomed,
          targetRect: rect,
        )
        guard let r = frames[key] else { return nil }
        // For focus changes we only observe (cmd+`, menu, click), skip the warp
        // when the cursor is already on the target tile: a click put it there,
        // so warping to the center would yank it off. A keyboard switch leaves
        // the cursor elsewhere, so it still follows. (axLocation shares the BSP
        // frame's coordinate space.)
        if skipIfCursorInside, r.contains(mouse.axLocation()) { return nil }
        return CGPoint(x: r.midX, y: r.midY)
      }
      guard !Task.isCancelled else { return }
      if let center { mouse.warp(center) }
      if clearsPendingCenter {
        await send(.cursorWarpFinished(workspaceId: workspaceId, target: key))
      }
    }
    .cancellable(id: CancelID.warp(workspaceId), cancelInFlight: true)
  }

  /// Start an unconditional center warp whose policy survives an AX focus echo.
  /// The pending target keeps observed focus notifications from replacing this
  /// requested warp before it clears the obligation.
  func requiredCenterWarpToWindow(
    _ key: WindowKey,
    in tree: BSPNode<WindowKey>,
    workspaceId: Workspace.ID,
    state: inout State,
  ) -> Effect<Action> {
    guard state.config.settings.focus.mouseFollowsFocus else { return .none }
    state.pendingCenterWarps[workspaceId] = key
    return warpToWindow(
      key,
      in: tree,
      workspaceId: workspaceId,
      state: state,
      clearsPendingCenter: true,
    )
  }

  /// Complete a close-driven focus transition after the new layout is on
  /// screen. Reading the live AX frame here is intentional: the target tile's
  /// pre-layout BSP frame is stale until `flushLayout` has finished applying
  /// the survivor's expanded frame.
  func settleFocusAfterLayout(
    _ key: WindowKey,
    workspaceId: Workspace.ID,
    shouldFocus: Bool,
    borrowCompletion: BorrowPhase? = nil,
    state: inout State,
  ) -> Effect<Action> {
    let shouldWarp = state.config.settings.focus.mouseFollowsFocus
    guard shouldFocus || shouldWarp else {
      guard let phase = borrowCompletion else { return .none }
      return .send(
        .borrowFocusCompleted(
          display: phase.display,
          workspaceId: phase.workspaceId,
          generation: phase.generation,
          composition: phase.composition,
        )
      )
    }
    if shouldWarp { state.pendingCenterWarps[workspaceId] = key }

    return .run {
      [focus = focusManager, snapshot = windowSnapshot, mouse, debugLog] send in
      if shouldFocus { await focus.focusWindow(key) }
      guard !Task.isCancelled else { return }

      if shouldWarp {
        let frame = await snapshot.windowFrameOffMain(key)
        guard !Task.isCancelled else { return }
        // Validate focus last. The frame read is cross-process IPC and focus
        // can change while it is suspended; checking before it could warp to
        // a target that was already stale by the time geometry arrived.
        let live = await snapshot.focusedWindowKeyOffMain()
        guard !Task.isCancelled else { return }
        let stillOwnsFocus =
          if let live {
            live == key
          } else {
            // A focus Tatami just requested can briefly have no AX focused
            // window while the app activates. An observed/layout-only warp has
            // no such ownership proof and must not revive a stale target.
            shouldFocus
          }
        if !stillOwnsFocus {
          debugLog.log(
            "Focus",
            "post-layout skip stale target \(key.bundleId)#\(key.windowID) "
              + "live=\(live.map { "\($0.bundleId)#\($0.windowID)" } ?? "nil")",
          )
        } else if let frame {
          let center = CGPoint(x: frame.midX, y: frame.midY)
          debugLog.log(
            "Focus",
            "post-layout center \(key.bundleId)#\(key.windowID) "
              + "frame=\(frame) center=\(center)",
          )
          mouse.warp(center)
        } else {
          debugLog.log(
            "Focus",
            "post-layout frame unavailable \(key.bundleId)#\(key.windowID)",
          )
          // A WindowServer destroy can race a Borrow summon: the cached tree
          // still names the retired surface, so app-level focus succeeds while
          // there is no live frame to warp into. Reconcile that app now; the
          // sync either selects its replacement window or empties/dismisses the
          // borrowed block instead of silently leaving pointer and focus split.
          await send(.syncAppWindows(bundleId: key.bundleId))
        }
        await send(.cursorWarpFinished(workspaceId: workspaceId, target: key))
      }
      guard !Task.isCancelled else { return }
      if let phase = borrowCompletion {
        await send(
          .borrowFocusCompleted(
            display: phase.display,
            workspaceId: phase.workspaceId,
            generation: phase.generation,
            composition: phase.composition,
          )
        )
      }
    }
    .cancellable(id: CancelID.warp(workspaceId), cancelInFlight: true)
  }

  /// Show a HUD message when its category (and the master switch) is
  /// enabled in settings — every non-workspace-switch HUD funnels through
  /// here so the per-category toggles stay authoritative.
  func hudEffect(
    _ state: State,
    _ category: KeyPath<AppSettings.HUD, Bool>,
    _ title: LocalizedStringResource,
    _ icon: String?,
    subtitle: LocalizedStringResource? = nil,
  ) -> Effect<Action> {
    guard state.config.settings.hud.shows(category) else { return .none }
    let durationMs = state.config.settings.hud.durationMs
    let title = String(localized: title)
    let subtitle = subtitle.map { String(localized: $0) }
    return .run { [hud = workspaceHUD] _ in
      await hud.show(title, icon, subtitle, durationMs)
    }
  }

  /// Push marker targets from the warm floating-window cache. Floating-window
  /// events refresh that cache through `refreshFloatingPresentation`; marker-
  /// only changes must not enumerate every floating app again.
  func refreshMarkers(
    state: State,
    resolvedFloatingKeys: [WindowKey]? = nil,
  ) -> Effect<Action> {
    let cfg = state.config.settings.marker
    let zoomedKeys = Self.fullscreenMarkerKeys(state: state)
    let floatingIds = cfg.floatingEnabled ? Self.floatingBundleIds(state: state) : []
    let borrowed = Self.borrowMarkerTargets(state: state)
    return .run { [marker, snapshot = windowSnapshot] _ in
      guard !Task.isCancelled else { return }
      let floatingKeys: [WindowKey] =
        if let resolvedFloatingKeys {
          resolvedFloatingKeys
        } else {
          floatingIds.isEmpty
            ? []
            : await snapshot.cachedKeysOffMain(floatingIds, false)
        }
      guard !Task.isCancelled else { return }
      await marker.setTargets(
        Self.markerTargets(
          fullscreenZoomed: zoomedKeys,
          floatingKeys: floatingKeys,
          borrowed: borrowed,
          cfg: cfg,
        ),
        cfg.size,
        cfg.corner,
        cfg.hideOnHover,
      )
    }
    .cancellable(id: CancelID.markerRefresh, cancelInFlight: true)
  }

  /// One floating-window discovery feeding both presentation consumers —
  /// the mirror overlay (replace set; empty tears every mirror down) and
  /// the marker dots — instead of two full AX scans back to back. Used
  /// whenever a floating app's windows change.
  func refreshFloatingPresentation(state: State) -> Effect<Action> {
    let bundleIds = Self.floatingBundleIds(state: state)
    return .run { [snapshot = windowSnapshot] send in
      guard !Task.isCancelled else { return }
      let keys = await snapshot.discoverKeysOffMain(bundleIds, false)
      guard !Task.isCancelled else { return }
      await send(.floatingPresentationResolved(keys))
    }
    .cancellable(id: CancelID.floatingDiscovery, cancelInFlight: true)
  }

  // MARK: Private

  /// The fullscreen-zoom marker keys for the active workspace (empty when
  /// the category is disabled) — the marker inputs that need no discovery.
  private static func fullscreenMarkerKeys(state: State) -> Set<WindowKey> {
    guard state.config.settings.marker.fullscreenEnabled else { return [] }
    return state.visibleWorkspaceIDs.reduce(into: Set<WindowKey>()) { keys, workspaceId in
      keys.formUnion(state.fullscreenZoomed[workspaceId] ?? [])
    }
  }

}
