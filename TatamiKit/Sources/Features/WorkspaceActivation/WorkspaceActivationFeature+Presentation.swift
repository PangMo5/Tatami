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
    floatingBundleIds(state: state, workspaceIDs: state.layoutWorkspaceIDs)
  }

  static func floatingBundleIds(
    state: State,
    workspaceIDs: Set<Workspace.ID>,
  ) -> [String] {
    let perWorkspace = workspaceIDs.flatMap { id in
      state.presentedWorkspace(id)?
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
    unmanagedBundleIds(state: state, workspaceIDs: state.layoutWorkspaceIDs)
  }

  static func unmanagedBundleIds(
    state: State,
    workspaceIDs: Set<Workspace.ID>,
  ) -> [String] {
    let perWorkspace = workspaceIDs.flatMap { id in
      state.presentedWorkspace(id)?
        .apps.filter { $0.layout == .unmanaged }.map(\.bundleIdentifier) ?? []
    }
    let shared = state.config.sharedApps.filter { $0.layout == .unmanaged }.map(\.bundleIdentifier)
    return Array(OrderedSet(perWorkspace + shared))
  }

  /// Compose each enabled status independently. Window exposure, not status
  /// or keyboard focus, determines whether its complete badge strip is visible.
  static func markerTargets(
    fullscreenZoomed: Set<WindowKey>,
    floatingKeys: [WindowKey],
    borrowed: [WindowKey: String],
    cfg: AppSettings.Marker,
    sharedKeys: Set<WindowKey> = [],
    stackedColors: [WindowKey: String] = [:],
  ) -> [WindowKey: MarkerTarget] {
    var targets = [WindowKey: MarkerTarget]()
    for key in fullscreenZoomed {
      targets[key, default: MarkerTarget()].badges.append(.init(kind: .fullscreen, colorHex: cfg.fullscreenColorHex))
    }
    for key in Set(floatingKeys) {
      targets[key, default: MarkerTarget()].badges.append(.init(kind: .floating, colorHex: cfg.floatingColorHex))
    }
    for (key, symbol) in borrowed {
      targets[key, default: MarkerTarget()].badges.append(.init(kind: .borrowed, colorHex: cfg.borrowColorHex, symbol: symbol))
    }
    for key in sharedKeys where cfg.sharedEnabled {
      targets[key, default: MarkerTarget()].badges.append(.init(
        kind: .shared,
        colorHex: cfg.sharedColorHex,
        symbol: "person.2.fill",
      ))
    }
    for (key, color) in stackedColors where cfg.stackEnabled {
      targets[key, default: MarkerTarget()].badges.append(.init(kind: .stacked, colorHex: color, symbol: "rectangle.stack.fill"))
    }
    return targets
  }

  /// Borrowed-window markers across every live composition: each borrowed
  /// window keyed to its source workspace's icon. Empty when the category is
  /// off or nothing is borrowed.
  static func borrowMarkerTargets(state: State) -> [WindowKey: String] {
    guard state.config.settings.marker.borrowEnabled else { return [:] }
    var out = [WindowKey: String]()
    for (display, comp) in state.compositionsByDisplay {
      guard state.desktops.isAvailable(on: display) else { continue }
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

  static func stackedWindowColors(in workspaceIDs: Set<Workspace.ID>, state: State) -> [WindowKey: String] {
    let shared = StackGroupColors.colors(for: state.config.sharedStackGroups, scope: .shared)
    return workspaceIDs.reduce(into: [WindowKey: String]()) { colors, id in
      guard let tree = state.tilingTrees[id], let workspace = state.presentedWorkspace(id) else { return }
      var keys = Set<WindowKey>()
      tree.collectAutomaticallyStackedWindows(into: &keys)
      guard !keys.isEmpty else { return }

      let grouping = state.windowGrouping(in: workspace)
      let local = StackGroupColors.colors(for: workspace.stackGroups, scope: .workspace)
      for key in keys {
        switch grouping.group(for: key) {
        case .workspace(let group): colors[key] = local[group]
        case .shared(let group): colors[key] = shared[group]
        case .allAssigned: colors[key] = state.config.settings.marker.stackColorHex
        case nil: break
        }
      }
    }
  }

  /// A newer explicit focus/workspace request owns input. Layout discovery may
  /// finish in the background, but an older Borrow must not take focus later.
  func supersedePendingFocus(state: inout State) -> Effect<Action> {
    var effects = [Effect<Action>]()
    var workspaces = state.visibleWorkspaceIDs.union(state.pendingCenterWarps.keys)
    if let activating = state.activatingWorkspaceID {
      workspaces.insert(activating)
    }
    for workspace in workspaces { effects.append(.cancel(id: CancelID.warp(workspace))) }
    for display in state.compositionsByDisplay.keys {
      effects.append(.cancel(id: CancelID.borrowFocus(display)))
    }
    state.pendingBorrowCompletionByDisplay = [:]
    state.pendingCenterWarps = [:]
    return .merge(effects)
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
    guard state.canManageWorkspace(workspaceId) else { return .none }
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
        if skipIfCursorInside, r.contains(mouse.axLocation()) {
          return nil
        }
        return CGPoint(x: r.midX, y: r.midY)
      }
      guard !Task.isCancelled else { return }
      if let center {
        mouse.warp(center)
      }
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
    expectedFrame: CGRect? = nil,
    borrowCompletion: BorrowPhase? = nil,
    state: inout State,
  ) -> Effect<Action> {
    guard state.canManageWorkspace(workspaceId) else { return .none }
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
    if shouldWarp {
      state.pendingCenterWarps[workspaceId] = key
    }

    return .run {
      [focus = focusManager, snapshot = windowSnapshot, mouse, debugLog] send in
      if shouldFocus {
        await focus.focusWindow(key)
      }
      guard !Task.isCancelled else { return }

      if shouldWarp {
        let frame = await snapshot.visibleWindowFrameOffMain(key, expectedFrame: expectedFrame)
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
    display: DisplayName? = nil,
    priority: ActionHUDPriority = .completion,
    contextID: UUID? = nil,
    confirmationID: UUID? = nil,
  ) -> Effect<Action> {
    guard confirmationID != nil || state.config.settings.hud.shows(category) else { return .none }
    let durationMs = state.config.settings.hud.durationMs
    let position = state.config.settings.hud.position
    let size = state.config.settings.hud.size
    let contextName = contextID.flatMap { state.config.workspace(id: $0)?.name }
    let title = String(localized: title)
    let subtitle = subtitle.map { String(localized: $0) }
    return .run { [hud = workspaceHUD] _ in
      await hud.showAction(
        ActionHUDRequest(
          name: title,
          symbolIconName: icon,
          subtitle: subtitle,
          durationMs: durationMs,
          position: position,
          size: size,
          display: display,
          priority: priority,
          contextID: contextID,
          contextName: contextName,
          replacingConfirmationID: confirmationID,
        )
      )
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
    let sharedApps = cfg.sharedEnabled ? state.config.sharedApps : []
    let sharedIds = Set(sharedApps.map(\.bundleIdentifier))
    let sharedNonTiledIds = sharedApps.filter { $0.layout != .tiled }.map(\.bundleIdentifier)
    let cachedIds = Array(OrderedSet(sharedNonTiledIds + (resolvedFloatingKeys == nil ? floatingIds : [])))
    let nativeFullscreen = Set(state.desktops.snapshot?.displays.flatMap(\.fullscreenWindows).map(\.windowID) ?? [])
    let stackedColors = cfg.stackEnabled
      ? Self.stackedWindowColors(in: state.layoutWorkspaceIDs, state: state)
        .filter { !nativeFullscreen.contains($0.key.windowID) }
      : [:]
    let sharedTiles = Set(state.layoutWorkspaceIDs.filter(state.canManageWorkspace)
      .flatMap { state.tilingTrees[$0]?.windows ?? [] }.filter { sharedIds.contains($0.bundleId) })
    return .run { [marker, snapshot = windowSnapshot] _ in
      guard !Task.isCancelled else { return }
      let cached = cachedIds.isEmpty ? [] : await snapshot.cachedKeysOffMain(cachedIds, false)
      let floatingKeys = cfg.floatingEnabled ? resolvedFloatingKeys ?? cached.filter { floatingIds.contains($0.bundleId) } : []
      // Membership outlives visibility. The marker controller places each
      // panel only while a fresh native or mirror surface exists.
      let sharedKeys = sharedTiles.union(cached.filter { sharedIds.contains($0.bundleId) })
        .union((resolvedFloatingKeys ?? []).filter { sharedIds.contains($0.bundleId) })
        .filter { !nativeFullscreen.contains($0.windowID) }
      guard !Task.isCancelled else { return }
      await marker.setTargets(
        Self.markerTargets(
          fullscreenZoomed: zoomedKeys,
          floatingKeys: floatingKeys,
          borrowed: borrowed,
          cfg: cfg,
          sharedKeys: sharedKeys,
          stackedColors: stackedColors,
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
  func refreshFloatingPresentation(state: State, onlyVisibleWindows: Bool = false) -> Effect<Action> {
    let revision = state.desktops.revision
    let bundleIds = Self.floatingBundleIds(state: state)
    return .run { [snapshot = windowSnapshot] send in
      guard !Task.isCancelled else { return }
      let keys = bundleIds.isEmpty ? [] : await snapshot.discoverKeysOffMain(bundleIds, false)
      let visible: [WindowKey]
      if onlyVisibleWindows {
        let ids = await snapshot.onScreenWindowIDsOffMain()
        visible = keys.filter { ids.contains($0.windowID) }
      } else {
        visible = keys
      }
      guard !Task.isCancelled else { return }
      await send(.floatingPresentationResolved(visible, desktopRevision: revision))
    }
    .cancellable(id: CancelID.floatingDiscovery, cancelInFlight: true)
  }

  // MARK: Private

  /// The fullscreen-zoom marker keys for the active workspace (empty when
  /// the category is disabled) — the marker inputs that need no discovery.
  private static func fullscreenMarkerKeys(state: State) -> Set<WindowKey> {
    guard state.config.settings.marker.fullscreenEnabled else { return [] }
    return state.layoutWorkspaceIDs.reduce(into: Set<WindowKey>()) { keys, workspaceId in
      keys.formUnion(state.fullscreenZoomed[workspaceId] ?? [])
    }
  }

}
