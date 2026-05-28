import AppKit
import ApplicationServices
import ComposableArchitecture
import Foundation
import Sharing

/// Tracks the active workspace per display, owns per-workspace BSP
/// trees, and dispatches activation + window-layout side effects.
///
/// The reducer plays the event-loop role: window create/destroy/focus
/// notifications arrive, the BSP tree mutates, and the new layout is
/// flushed through `WindowTilerClient`. Workspace switching is layered
/// on top via `WorkspaceManagerClient` (show/hide policy).
@Reducer
public struct WorkspaceActivationFeature {
  @ObservableState
  public struct State: Equatable {
    @Shared(.tatamiConfig) public var config = AppConfig()
    public var activeWorkspacesByDisplay: [DisplayName: Workspace.ID] = [:]
    public var previousWorkspaceID: Workspace.ID?
    public var isActivating = false
    /// Runtime-only "pause tiling" flag. Workspace switching keeps
    /// running while tiling is paused; flipped by `togglePaused`.
    public var isTilingPaused = false
    /// Per-workspace BSP tree of window keys, kept in-memory only.
    public var tilingTrees: [Workspace.ID: BSPNode<WindowKey>] = [:]
    /// Sticky per-workspace insertion point. The next window inserted
    /// lands next to this one (and the `insertDirection` set on its
    /// leaf decides north/east/south/west/stack). Updated by focus
    /// events and by the user's `bspSetInsertDirection` action.
    public var insertionPoint: [Workspace.ID: WindowKey] = [:]
    /// Per-workspace set of fullscreen-zoomed windows. Tatami-specific
    /// multi-window fullscreen: each member is trimmed from the tree
    /// before layout and rendered at the workspace's work area. Several
    /// can be active at once; focus determines which sits on top
    /// visually. Persisted via `LayoutSnapshot.fullscreenZoomedBundleIds`.
    /// Parent-zoom is *not* tracked here — that one lives inside the
    /// tree leaves directly.
    public var fullscreenZoomed: [Workspace.ID: Set<WindowKey>] = [:]

    public init() {}

    public var primaryActiveWorkspaceID: Workspace.ID? {
      activeWorkspacesByDisplay.values.first
    }
  }

  public enum Action {
    case startObservingWindowEvents
    /// Activate a sensible workspace on launch so tiling starts
    /// immediately instead of waiting for the first manual switch.
    case activateInitial
    case activate(workspaceId: Workspace.ID, setFocus: Bool)
    case activateNext
    case activatePrevious
    case activateRecent
    case moveFocusedAppTo(workspaceId: Workspace.ID)
    case focusedAppResolved(bundleId: String, workspaceId: Workspace.ID)
    case toggleFloatingOnFocusedApp
    case focusedFloatToggleResolved(bundleId: String, name: String)
    case togglePaused
    case bspFocus(BSPDirection)
    case bspFocusResolved(windowKey: WindowKey, direction: BSPDirection)
    case bspSwap(BSPDirection)
    case bspResize(direction: BSPDirection, delta: CGFloat)
    case bspToggleOrientation
    /// Per-leaf zoom: the focused leaf renders at its parent
    /// branch's area, only one active per subtree, tree shape
    /// unchanged.
    case bspToggleZoomParent
    /// Tatami's fullscreen-zoom: multi-window, takes the window out of
    /// the tree's layout and renders it at the work area.
    case bspToggleZoomFullscreen
    case bspBalance
    case bspRotate(degrees: Int)
    case bspMirror(axis: BSPNode<WindowKey>.SplitAxis)
    /// Set the insertion direction on the focused leaf so the next
    /// inserted window lands there. Pass nil to clear.
    case bspSetInsertDirection(BSPNode<WindowKey>.InsertDirection?)
    case bspOpResolved(windowKey: WindowKey, op: BSPOp)
    case windowChanged(WindowChangeEvent)
    case windowResizeCommitted(key: WindowKey, frame: CGRect)
    case windowMoveCommitted(key: WindowKey, frame: CGRect)
    /// Incrementally reconcile a single app's windows into the active
    /// tree: add new windows, drop gone ones, touch nothing else.
    case syncAppWindows(bundleId: String)
    /// Wake / native-Space-change / "something on the system shifted":
    /// re-reconcile every tree-resident + registered app.
    case reconcileAllTrackedApps
    case startObservingAppLaunches
    case appLaunched(bundleId: String, name: String)
    case appActivated(bundleId: String)
    case appTerminated(bundleId: String)
    case tilingTreeUpdated(workspaceId: Workspace.ID, tree: BSPNode<WindowKey>?)
    /// Activation discovered fullscreen-zoomed bundle ids on disk and
    /// we resolved them to live `WindowKey`s.
    case persistedFullscreenZoomRestored(workspaceId: Workspace.ID, keys: Set<WindowKey>)
    case activationCompleted(workspaceId: Workspace.ID, display: DisplayName?)
  }

  /// Tag used to dispatch a BSP mutation once we've resolved the
  /// focused window's `WindowKey`.
  public enum BSPOp: Sendable, Hashable {
    case swap(BSPDirection)
    case resize(BSPDirection, delta: CGFloat)
    case toggleOrientation
    case toggleZoomParent
    case toggleZoomFullscreen
    case setInsertDirection(BSPNode<WindowKey>.InsertDirection?)
  }

  /// Cancellation identifiers for debounced window-event handling.
  private enum CancelID: Hashable {
    case windowResize(WindowKey)
    case windowMove(WindowKey)
    case sync(String)
    /// Coalesces frame application per workspace: a newer layout
    /// cancels an in-flight apply so a stale one can't land after it.
    case apply(Workspace.ID)
  }

  @Dependency(\.workspaceManager) var workspaceManager
  @Dependency(\.windowTiler) var windowTiler
  @Dependency(\.windowObserver) var windowObserver
  @Dependency(\.appLaunch) var appLaunch
  @Dependency(\.displays) var displays
  @Dependency(\.layoutStore) var layoutStore
  @Dependency(\.workspaceHUD) var workspaceHUD
  @Dependency(\.mouse) var mouse
  @Dependency(\.marker) var marker
  @Dependency(\.sls) var sls

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .startObservingWindowEvents:
        return .run { [client = windowObserver] send in
          for await event in client.events() {
            await send(.windowChanged(event))
          }
        }

      case .windowChanged(let event):
        switch event {
        case .windowResized(let key, let frame):
          // AX fires continuously during the drag; wait for quiescence
          // before committing the new ratio so we don't fight the user
          // mid-drag.
          return .run { send in
            try? await Task.sleep(for: .milliseconds(150))
            await send(.windowResizeCommitted(key: key, frame: frame))
          }
          .cancellable(id: CancelID.windowResize(key), cancelInFlight: true)
        case .windowMoved(let key, let frame):
          return .run { send in
            try? await Task.sleep(for: .milliseconds(150))
            await send(.windowMoveCommitted(key: key, frame: frame))
          }
          .cancellable(id: CancelID.windowMove(key), cancelInFlight: true)
        case .windowCreated(let bundleId):
          return debouncedSync(bundleId, delayMs: 0)
        case .windowDestroyed(let bundleId):
          return debouncedSync(bundleId, delayMs: 0)
        case .windowFocused(let bundleId, let key):
          // Keep the per-workspace insertion point current — even for
          // same-app window switches (which don't fire
          // didActivateApplication).
          if let key, let wsId = state.primaryActiveWorkspaceID,
             state.tilingTrees[wsId]?.windows.contains(key) == true
          {
            state.insertionPoint[wsId] = key
          }
          return debouncedSync(bundleId, delayMs: 0)
        }

      case .windowResizeCommitted(let key, let frame):
        return syncTreeRatio(for: key, frame: frame, state: &state)

      case .windowMoveCommitted(let key, let frame):
        return handleWindowMoved(key: key, frame: frame, state: &state)

      case .syncAppWindows(let bundleId):
        return syncAppWindows(bundleId: bundleId, state: &state)

      case .startObservingAppLaunches:
        return .run { [client = appLaunch] send in
          for await event in client.events() {
            switch event {
            case .launched(let bundleId, let name):
              await send(.appLaunched(bundleId: bundleId, name: name))
            case .activated(let bundleId):
              await send(.appActivated(bundleId: bundleId))
            case .terminated(let bundleId):
              await send(.appTerminated(bundleId: bundleId))
            case .activeSpaceChanged, .didWake:
              await send(.reconcileAllTrackedApps)
            }
          }
        }

      case .reconcileAllTrackedApps:
        // Union of tree members + registered apps in the active
        // workspace: refresh every app we currently care about.
        var bundleIds: Set<String> = []
        for tree in state.tilingTrees.values {
          for window in tree.windows { bundleIds.insert(window.bundleId) }
        }
        if let workspaceId = state.primaryActiveWorkspaceID,
           let workspace = state.config.activeProfile?
             .workspaces.first(where: { $0.id == workspaceId })
        {
          for app in workspace.apps { bundleIds.insert(app.bundleIdentifier) }
        }
        guard !bundleIds.isEmpty else { return .none }
        return .merge(bundleIds.map { debouncedSync($0, delayMs: 40) })

      case .appLaunched(let bundleId, _):
        return debouncedSync(bundleId, delayMs: 40)

      case .appActivated(let bundleId):
        if bundleId == "dev.PangMo5.Tatami" || bundleId == "dev.PangMo5.Tatami.dev" {
          return .none
        }
        if !state.isActivating,
           state.config.settings.switching.followAppFocus,
           !state.config.floatingApps.contains(where: { $0.bundleIdentifier == bundleId }),
           let owner = state.config.activeProfile?.workspaces.first(where: {
             $0.apps.contains { $0.bundleIdentifier == bundleId }
           }),
           state.primaryActiveWorkspaceID != owner.id {
          return .send(.activate(workspaceId: owner.id, setFocus: false))
        }
        return debouncedSync(bundleId, delayMs: 40)

      case .appTerminated(let bundleId):
        return debouncedSync(bundleId, delayMs: 0)

      case .activateInitial:
        guard let profile = state.config.activeProfile,
              !profile.workspaces.isEmpty
        else { return .none }
        let frontBundle = MainActor.assumeIsolated {
          NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        let target = profile.workspaces.first { ws in
          guard let fb = frontBundle else { return false }
          return ws.apps.contains { $0.bundleIdentifier == fb }
        } ?? profile.workspaces[0]
        return .send(.activate(workspaceId: target.id, setFocus: false))

      case .activate(let workspaceId, let setFocus):
        return performActivate(
          workspaceId: workspaceId,
          setFocus: setFocus,
          state: &state
        )

      case .activateNext:
        return cycle(by: 1, state: &state)

      case .activatePrevious:
        return cycle(by: -1, state: &state)

      case .activateRecent:
        guard let id = state.previousWorkspaceID else { return .none }
        return .send(.activate(workspaceId: id, setFocus: true))

      case .moveFocusedAppTo(let workspaceId):
        return resolveFrontmostBundleId { bundleId in
          .focusedAppResolved(bundleId: bundleId, workspaceId: workspaceId)
        }

      case .focusedAppResolved(let bundleId, let workspaceId):
        state.$config.withLock { config in
          config.mutateActiveProfile { profile in
            for i in profile.workspaces.indices {
              profile.workspaces[i].apps.removeAll { $0.bundleIdentifier == bundleId }
            }
            if let idx = profile.workspaces.firstIndex(where: { $0.id == workspaceId }) {
              profile.workspaces[idx].apps.append(
                AppAssignment(bundleIdentifier: bundleId, name: bundleId)
              )
            }
          }
        }
        state.tilingTrees[workspaceId] = nil
        return .send(.activate(workspaceId: workspaceId, setFocus: true))

      case .toggleFloatingOnFocusedApp:
        return .run { send in
          let resolved = await MainActor.run {
            NSWorkspace.shared.frontmostApplication.map {
              (bundleId: $0.bundleIdentifier ?? "", name: $0.localizedName ?? "")
            }
          }
          guard let resolved, !resolved.bundleId.isEmpty else { return }
          await send(
            .focusedFloatToggleResolved(bundleId: resolved.bundleId, name: resolved.name)
          )
        }

      case .focusedFloatToggleResolved(let bundleId, let name):
        state.$config.withLock { config in
          if config.floatingApps.contains(where: { $0.bundleIdentifier == bundleId }) {
            config.floatingApps.removeAll { $0.bundleIdentifier == bundleId }
          } else {
            config.floatingApps.append(
              FloatingApp(bundleIdentifier: bundleId, name: name.isEmpty ? bundleId : name)
            )
          }
        }
        return refreshMarkers(state: state)

      case .togglePaused:
        let wasPaused = state.isTilingPaused
        state.isTilingPaused.toggle()
        if wasPaused {
          return reflowActiveWorkspace(state: &state)
        }
        return .none

      case .bspFocus(let direction):
        return resolveFocusedWindowKey { key in
          .bspFocusResolved(windowKey: key, direction: direction)
        }

      case .bspFocusResolved(let key, let direction):
        guard let workspaceId = state.primaryActiveWorkspaceID,
              let workspace = state.config.activeProfile?
                .workspaces.first(where: { $0.id == workspaceId }),
              let tree = state.tilingTrees[workspaceId]
        else { return .none }
        let settings = state.config.settings
        let display = workspace.displayHint ?? displays.current()
        let gap = CGFloat(settings.layout.gapInner)
        let workArea = MainActor.assumeIsolated {
          ScreenGeometry.workArea(for: display).insetBy(
            dx: CGFloat(settings.layout.gapOuter),
            dy: CGFloat(settings.layout.gapOuter)
          )
        }
        // Directional focus stays within the tiled set.
        guard let target = tree.directionalNeighbor(
          of: key,
          direction: direction,
          in: workArea,
          gap: gap,
          focusOrder: tree.windows
        ) else { return .none }
        let warpMouse = settings.focus.mouseFollowsFocus
        let zoomed = state.fullscreenZoomed[workspaceId] ?? []
        return .run { [mouse = mouse] _ in
          await MainActor.run {
            focusWindow(pid: target.pid, windowID: target.windowID)
            if warpMouse {
              let frames = Self.computeFrames(
                tree: tree, settings: settings, targetDisplay: display, fullscreenZoomed: zoomed
              )
              if let rect = frames[target] {
                mouse.warp(CGPoint(x: rect.midX, y: rect.midY))
              }
            }
          }
        }

      case .bspSwap(let direction):
        return resolveFocusedWindowKey { key in
          .bspOpResolved(windowKey: key, op: .swap(direction))
        }

      case .bspResize(let direction, let delta):
        return resolveFocusedWindowKey { key in
          .bspOpResolved(windowKey: key, op: .resize(direction, delta: delta))
        }

      case .bspToggleOrientation:
        return resolveFocusedWindowKey { key in
          .bspOpResolved(windowKey: key, op: .toggleOrientation)
        }

      case .bspToggleZoomParent:
        return resolveFocusedWindowKey { key in
          .bspOpResolved(windowKey: key, op: .toggleZoomParent)
        }

      case .bspToggleZoomFullscreen:
        return resolveFocusedWindowKey { key in
          .bspOpResolved(windowKey: key, op: .toggleZoomFullscreen)
        }

      case .bspSetInsertDirection(let direction):
        return resolveFocusedWindowKey { key in
          .bspOpResolved(windowKey: key, op: .setInsertDirection(direction))
        }

      case .bspBalance:
        let axis = bspAxis(for: state.config.settings.layout.autoBalance)
        return applyTreeTransform(state: &state) { $0.balanced(axis: axis) }

      case .bspRotate(let degrees):
        return applyTreeTransform(state: &state) { $0.rotated(by: degrees) }

      case .bspMirror(let axis):
        return applyTreeTransform(state: &state) { $0.mirrored(axis: axis) }

      case .bspOpResolved(let key, let op):
        return applyBSPOp(windowKey: key, op: op, state: &state)

      case .persistedFullscreenZoomRestored(let workspaceId, let keys):
        state.fullscreenZoomed[workspaceId] = keys.isEmpty ? nil : keys
        return .none

      case .tilingTreeUpdated(let workspaceId, let tree):
        state.tilingTrees[workspaceId] = tree
        // Seed the insertion point with the focused leaf's top window
        // (or first leaf's top if focus isn't in the tree), so the
        // very next insert has somewhere to anchor.
        if let tree {
          let firstLeafWindow = tree.windows.first
          state.insertionPoint[workspaceId] = firstLeafWindow
        } else {
          state.insertionPoint[workspaceId] = nil
        }
        return .none

      case .activationCompleted(let id, let display):
        state.isActivating = false
        if let display, let previous = state.activeWorkspacesByDisplay[display], previous != id {
          state.previousWorkspaceID = previous
        }
        if let display {
          state.activeWorkspacesByDisplay[display] = id
        }
        let treeIds = state.tilingTrees[id]?.windows.map(\.bundleId)
        let registeredIds = state.config.activeProfile?
          .workspaces.first(where: { $0.id == id })?
          .apps.map(\.bundleIdentifier) ?? []
        let observeIds = Array(Set(treeIds ?? registeredIds))
        return .merge(
          .run { [observer = windowObserver] _ in await observer.observe(observeIds) },
          refreshMarkers(state: state)
        )
      }
    }
  }

  /// Re-tile the active workspace's current windows WITHOUT touching
  /// app visibility. Used on resume so tiling catches up to whatever
  /// changed while paused.
  private func reflowActiveWorkspace(state: inout State) -> Effect<Action> {
    guard !state.isTilingPaused,
          let workspaceId = state.primaryActiveWorkspaceID,
          let workspace = state.config.activeProfile?
            .workspaces.first(where: { $0.id == workspaceId })
    else { return .none }

    let settings = state.config.settings
    let display = workspace.displayHint ?? displays.current()
    let registered = workspace.apps.map(\.bundleIdentifier)
    let existing = state.tilingTrees[workspaceId]
    // On resume from pause we keep any transient (unregistered-anywhere)
    // members the user may have folded in before pausing. Without the
    // existing tree's bundle ids we'd discover only the registered apps
    // and the transient tiles would drop out silently.
    let existingBundles = existing?.windows.map(\.bundleId) ?? []
    let discoverBundles = Array(Set(registered + existingBundles))
    let slsClient = sls

    let snapshot = MainActor.assumeIsolated {
      () -> (targets: [WindowKey], focused: WindowKey?, workArea: CGRect) in
      let keys = discoverWindowKeys(forBundleIds: discoverBundles, sls: slsClient)
      let workArea = ScreenGeometry.workArea(for: display).insetBy(
        dx: CGFloat(settings.layout.gapOuter), dy: CGFloat(settings.layout.gapOuter)
      )
      return (keys, focusedWindowKey(), workArea)
    }

    let merged = Self.mergeTree(
      existing: existing,
      target: snapshot.targets,
      focused: snapshot.focused,
      insertionPoint: state.insertionPoint[workspaceId],
      workArea: snapshot.workArea,
      settings: settings
    )
    let axis = bspAxis(for: settings.layout.autoBalance)
    let balanced = axis == .none ? merged : merged?.balanced(axis: axis)
    state.tilingTrees[workspaceId] = balanced
    guard let tree = balanced else { return .none }
    if state.insertionPoint[workspaceId] == nil {
      state.insertionPoint[workspaceId] = tree.windows.first
    }
    let zoomed = state.fullscreenZoomed[workspaceId] ?? []
    let observeIds = Array(Set(tree.windows.map(\.bundleId)))

    return .merge(
      .run { [tiler = windowTiler] _ in
        let frames = await MainActor.run {
          Self.computeFrames(
            tree: tree, settings: settings, targetDisplay: display, fullscreenZoomed: zoomed
          )
        }
        if !frames.isEmpty {
          await tiler.apply(FrameApplication(windowFrames: frames, targetDisplay: display))
        }
      }
      .cancellable(id: CancelID.apply(workspaceId), cancelInFlight: true),
      .run { [observer = windowObserver] _ in await observer.observe(observeIds) },
      persist(tree, fullscreenZoomed: zoomed, for: workspace, default: settings.layout.defaultTilingMemory)
    )
  }

  private func debouncedSync(_ bundleId: String, delayMs: Int) -> Effect<Action> {
    .run { send in
      if delayMs > 0 {
        try? await Task.sleep(for: .milliseconds(delayMs))
      }
      await send(.syncAppWindows(bundleId: bundleId))
    }
    .cancellable(id: CancelID.sync(bundleId), cancelInFlight: true)
  }

  /// Incrementally reconcile a single app's windows into the active
  /// workspace's tree. Insert windows new to the tree (next to the
  /// insertion point), remove vanished ones, leave the rest.
  /// Unassigned visible apps are *not* folded into the tree.
  private func syncAppWindows(bundleId: String, state: inout State) -> Effect<Action> {
    guard !state.isTilingPaused else { return .none }
    if bundleId == "dev.PangMo5.Tatami" || bundleId == "dev.PangMo5.Tatami.dev" {
      return .none
    }
    // performActivate owns the tree during its async build — let it
    // finish, otherwise an incremental sync races it.
    guard !state.isActivating else { return .none }
    guard let workspaceId = state.primaryActiveWorkspaceID,
          let workspace = state.config.activeProfile?
            .workspaces.first(where: { $0.id == workspaceId })
    else { return .none }

    let settings = state.config.settings
    let display = workspace.displayHint ?? displays.current()
    let registeredSet = Set(workspace.apps.map(\.bundleIdentifier))
    let floatingSet = Set(state.config.floatingApps.map(\.bundleIdentifier))
    let assignedAnywhere = Self.everyAssignedBundleId(in: state.config)
    let existing = state.tilingTrees[workspaceId]
    let inTree = existing?.windows.contains { $0.bundleId == bundleId } ?? false

    if floatingSet.contains(bundleId) { return .none }
    // Eligibility:
    //   * registered in this workspace → always tile.
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
      || inTree
      || isUnregisteredAnywhere

    let slsClient = sls
    let (current, focused, workArea) = MainActor.assumeIsolated {
      () -> (current: [WindowKey], focused: WindowKey?, workArea: CGRect) in
      let cur = discoverWindowKeys(forBundleIds: [bundleId], sls: slsClient)
      let foc = focusedWindowKey()
      let wa = ScreenGeometry.workArea(for: display).insetBy(
        dx: CGFloat(settings.layout.gapOuter),
        dy: CGFloat(settings.layout.gapOuter)
      )
      return (cur, foc, wa)
    }
    if let focused, existing?.windows.contains(focused) == true {
      state.insertionPoint[workspaceId] = focused
    }
    let insertionPointKey = state.insertionPoint[workspaceId]

    var tree = existing
    let currentSet = Set(current)
    for key in (tree?.windows ?? []) where key.bundleId == bundleId && !currentSet.contains(key) {
      tree = tree?.removing(key)
    }

    // Insert new windows next to the insertion point. After each
    // insert, the new window becomes the insertion anchor — that's
    // what makes the dwindle wind instead of all-windows piling onto
    // one node.
    if eligibleToAdd {
      let viewSplit = settings.layout.splitType.bspSplitAxis()
      let placement: BSPNode<WindowKey>.Child = settings.layout.windowPlacement == .first
        ? .first
        : .second
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
          globalPlacement: placement
        )
        anchor = key
        state.insertionPoint[workspaceId] = key
      }
    }

    let axis = bspAxis(for: settings.layout.autoBalance)
    let balanced = axis == .none ? tree : tree?.balanced(axis: axis)
    let oldWindows = Set(existing?.windows ?? [])
    let newWindows = Set(balanced?.windows ?? [])
    state.tilingTrees[workspaceId] = balanced

    let observeIds = Array(Set((balanced?.windows.map(\.bundleId) ?? []) + Array(registeredSet)))
    let observeEffect = Effect<Action>.run { [observer = windowObserver] _ in
      await observer.observe(observeIds)
    }
    let markerRefresh = refreshMarkers(state: state)

    guard oldWindows != newWindows, let final = balanced else {
      return .merge(observeEffect, markerRefresh)
    }

    let zoomed = state.fullscreenZoomed[workspaceId] ?? []
    return .merge(
      .run { [tiler = windowTiler] _ in
        let frames = await MainActor.run {
          Self.computeFrames(
            tree: final,
            settings: settings,
            targetDisplay: display,
            fullscreenZoomed: zoomed
          )
        }
        if !frames.isEmpty {
          await tiler.apply(
            FrameApplication(windowFrames: frames, targetDisplay: display)
          )
        }
      }
      .cancellable(id: CancelID.apply(workspaceId), cancelInFlight: true),
      observeEffect,
      persist(final, fullscreenZoomed: zoomed, for: workspace, default: settings.layout.defaultTilingMemory),
      markerRefresh
    )
  }

  /// Bundle ids registered to any workspace anywhere in the config.
  /// `syncAppWindows` uses this to decide whether a window belongs to
  /// the active workspace's tree (registered here / unregistered
  /// anywhere → transient) or to some other workspace (skip).
  private static func everyAssignedBundleId(in config: AppConfig) -> Set<String> {
    var out: Set<String> = []
    for profile in config.profiles {
      for ws in profile.workspaces {
        for app in ws.apps {
          out.insert(app.bundleIdentifier)
        }
      }
    }
    return out
  }

  /// Incremental merge. Removes vanished windows (sibling promotes),
  /// inserts new windows at the insertion point. Fresh trees (no
  /// existing) build via `BSPNode.build` (which uses the shallowest-
  /// leaf rule for each new window).
  private static func mergeTree(
    existing: BSPNode<WindowKey>?,
    target: [WindowKey],
    focused: WindowKey?,
    insertionPoint: WindowKey?,
    workArea: CGRect,
    settings: AppSettings
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

    let newOnes = target.filter { id in
      !(tree?.windows.contains(id) ?? false)
    }
    guard !newOnes.isEmpty else { return tree }

    let viewSplit = settings.layout.splitType.bspSplitAxis()
    let placement: BSPNode<WindowKey>.Child = settings.layout.windowPlacement == .first
      ? .first
      : .second

    if tree == nil {
      // Fresh tree — each initial insert picks the shallowest leaf,
      // which `inserting(...)` does when no anchor is supplied.
      var t: BSPNode<WindowKey>? = nil
      for key in newOnes {
        if let cur = t {
          t = cur.inserting(
            key, near: nil, in: workArea,
            viewSplitType: viewSplit, globalPlacement: placement
          )
        } else {
          t = .leaf(key)
        }
      }
      return t
    }

    for id in newOnes {
      let anchor: WindowKey? = {
        if let insertionPoint, tree?.windows.contains(insertionPoint) == true {
          return insertionPoint
        }
        if let focused, tree?.windows.contains(focused) == true {
          return focused
        }
        return nil
      }()
      tree = tree?.inserting(
        id, near: anchor, in: workArea,
        viewSplitType: viewSplit, globalPlacement: placement
      ) ?? .leaf(id)
    }
    return tree
  }

  // MARK: - Window key resolution

  private func resolveFocusedWindowKey(
    _ continuation: @escaping @Sendable (WindowKey) -> Action
  ) -> Effect<Action> {
    .run { send in
      let key = await MainActor.run { focusedWindowKey() }
      guard let key else { return }
      await send(continuation(key))
    }
  }

  private func resolveFrontmostBundleId(
    _ continuation: @escaping @Sendable (String) -> Action
  ) -> Effect<Action> {
    .run { send in
      let bundleId = await MainActor.run {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
      }
      guard let bundleId, !bundleId.isEmpty else { return }
      await send(continuation(bundleId))
    }
  }

  /// Snapshot the tree to disk when the workspace opted into
  /// `.persistent` memory. No-op otherwise. The tree is bundle-id
  /// keyed (`WindowKey`s die at process exit); fullscreen-zoom is
  /// recorded so it survives a restart too. Per-leaf parent-zoom is
  /// carried inside the tree itself.
  private func persist(
    _ tree: BSPNode<WindowKey>?,
    fullscreenZoomed: Set<WindowKey>,
    for workspace: Workspace,
    default defaultMemory: TilingMemory
  ) -> Effect<Action> {
    let memory = workspace.tilingMemory ?? defaultMemory
    guard memory == .persistent, let tree else { return .none }
    let id = workspace.id
    let template = tree.mapWindows { $0.bundleId }
    let zoomedBundleIds = fullscreenZoomed.map(\.bundleId).sorted()
    let snapshot = LayoutSnapshot(tree: template, fullscreenZoomedBundleIds: zoomedBundleIds)
    return .run { [store = layoutStore] _ in store.save(id, snapshot) }
  }

  // MARK: - Window marker

  private func markerTargets(state: State) -> [WindowKey: String] {
    var targets: [WindowKey: String] = [:]
    let cfg = state.config.settings.marker
    if cfg.fullscreenEnabled,
       let workspaceId = state.primaryActiveWorkspaceID
    {
      for key in state.fullscreenZoomed[workspaceId] ?? [] {
        targets[key] = cfg.fullscreenColorHex
      }
    }
    if cfg.floatingEnabled {
      let bundleIds = state.config.floatingApps.map(\.bundleIdentifier)
      let slsClient = sls
      let keys = MainActor.assumeIsolated {
        discoverWindowKeys(forBundleIds: bundleIds, sls: slsClient)
      }
      for key in keys { targets[key] = cfg.floatingColorHex }
    }
    return targets
  }

  private func refreshMarkers(state: State) -> Effect<Action> {
    let targets = markerTargets(state: state)
    let cfg = state.config.settings.marker
    let size = cfg.size
    let corner = cfg.corner
    let hideOnHover = cfg.hideOnHover
    return .run { [marker] _ in
      marker.setTargets(targets, size, corner, hideOnHover)
    }
  }

  // MARK: - Activation

  private func performActivate(
    workspaceId: Workspace.ID,
    setFocus: Bool,
    state: inout State
  ) -> Effect<Action> {
    guard let profile = state.config.activeProfile,
          let workspace = profile.workspaces.first(where: { $0.id == workspaceId })
    else { return .none }
    guard !state.isActivating else { return .none }
    state.isActivating = true
    let isPaused = state.isTilingPaused

    let targetDisplay = workspace.displayHint ?? displays.current()
    let request = ActivationRequest(
      workspace: workspace,
      floatingApps: state.config.floatingApps,
      targetDisplay: targetDisplay,
      setFocus: setFocus,
      mouseHidesOnFocus: setFocus && state.config.settings.focus.mouseHidesOnFocus
    )
    let warpMouse = setFocus && state.config.settings.focus.mouseFollowsFocus
    let showHUD = setFocus && state.config.settings.hud.enabled

    let settings = state.config.settings
    let bundleIds = workspace.apps.map(\.bundleIdentifier)
    let memory = workspace.tilingMemory ?? settings.layout.defaultTilingMemory
    let sessionTree = memory == .fresh ? nil : state.tilingTrees[workspace.id]
    if memory == .fresh {
      state.fullscreenZoomed[workspace.id] = nil
    }
    let zoomed = state.fullscreenZoomed[workspace.id] ?? []
    let insertionPoint = state.insertionPoint[workspace.id]

    let hudName = workspace.name
    let hudIcon = workspace.symbolIconName
    let slsClient = sls

    return .run { [
      mgr = workspaceManager,
      tiler = windowTiler,
      store = layoutStore,
      hud = workspaceHUD,
      mouse = mouse
    ] send in
      if showHUD {
        await hud.show(hudName, hudIcon)
      }
      await mgr.activate(request)
      if !isPaused {
        let persistedSnapshot: LayoutSnapshot? =
          memory == .persistent && sessionTree == nil
            ? await store.load(workspaceId)
            : nil
        let (tree, frames, restoredZoom) = await MainActor.run {
          () -> (BSPNode<WindowKey>?, [WindowKey: CGRect], Set<WindowKey>) in
          let keys = discoverWindowKeys(forBundleIds: bundleIds, sls: slsClient)
          let focused = focusedWindowKey()
          let workArea = ScreenGeometry.workArea(for: targetDisplay).insetBy(
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
          let axis = bspAxis(for: settings.layout.autoBalance)
          let tree = axis == .none ? merged : merged?.balanced(axis: axis)
          let resolvedZoom: Set<WindowKey> = {
            if !zoomed.isEmpty { return zoomed }
            guard !persistedZoomBundleIds.isEmpty, let tree else { return [] }
            var resolved: Set<WindowKey> = []
            for bundleId in persistedZoomBundleIds {
              if let key = tree.windows.first(where: { $0.bundleId == bundleId }) {
                resolved.insert(key)
              }
            }
            return resolved
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
        if warpMouse {
          let center = await MainActor.run { () -> CGPoint? in
            guard let key = focusedWindowKey(), let rect = frames[key] else { return nil }
            return CGPoint(x: rect.midX, y: rect.midY)
          }
          if let center { mouse.warp(center) }
        }
      }
      await send(.activationCompleted(workspaceId: workspaceId, display: targetDisplay))
    }
  }

  // MARK: - Manual resize sync (AX debounce path)

  private func syncTreeRatio(
    for key: WindowKey,
    frame: CGRect,
    state: inout State
  ) -> Effect<Action> {
    guard let workspaceId = state.primaryActiveWorkspaceID,
          let workspace = state.config.activeProfile?
            .workspaces.first(where: { $0.id == workspaceId }),
          let tree = state.tilingTrees[workspaceId],
          let path = tree.pathTo(window: key), !path.isEmpty
    else { return .none }

    let parentPath = Array(path.dropLast())
    guard let side = path.last,
          case .branch(let branch) = tree.subtree(at: parentPath)
    else { return .none }

    let settings = state.config.settings
    let display = workspace.displayHint ?? displays.current()
    let gap = CGFloat(settings.layout.gapInner)
    let workArea = MainActor.assumeIsolated {
      ScreenGeometry.workArea(for: display).insetBy(
        dx: CGFloat(settings.layout.gapOuter),
        dy: CGFloat(settings.layout.gapOuter)
      )
    }
    let parentRect = tree.rect(at: parentPath, in: workArea, gap: gap)

    let newRatio: CGFloat
    switch branch.split {
    case .vertical:
      let total = parentRect.width - gap
      guard total > 0 else { return .none }
      let leftWidth = side == .left ? frame.width : total - frame.width
      newRatio = leftWidth / total
    case .horizontal:
      let total = parentRect.height - gap
      guard total > 0 else { return .none }
      let topHeight = side == .left ? frame.height : total - frame.height
      newRatio = topHeight / total
    }

    // 1.5 px geometric tolerance — bail out if the change is smaller
    // than that, which usually means we're seeing our own apply echo
    // rather than a real user resize.
    if abs(newRatio - branch.ratio) * (branch.split == .vertical ? parentRect.width : parentRect.height) < 1.5 {
      return .none
    }

    let newTree = tree.updatingRatio(at: parentPath, ratio: newRatio)
    state.tilingTrees[workspaceId] = newTree
    let zoomed = state.fullscreenZoomed[workspaceId] ?? []

    return .merge(
      .run { [tiler = windowTiler] _ in
        let frames = await MainActor.run {
          Self.computeFrames(
            tree: newTree,
            settings: settings,
            targetDisplay: display,
            fullscreenZoomed: zoomed
          )
        }
        if !frames.isEmpty {
          await tiler.apply(
            FrameApplication(windowFrames: frames, targetDisplay: display)
          )
        }
      },
      persist(newTree, fullscreenZoomed: zoomed, for: workspace, default: settings.layout.defaultTilingMemory)
    )
  }

  // MARK: - Drag-to-drop (drop-zone triangles)

  /// AX reported the user moved `key` to `frame`. Inspect the drop
  /// quadrant relative to the target tile:
  ///   * center → swap (or stack, future config)
  ///   * top triangle → warp to top child (SPLIT_X, CHILD_FIRST)
  ///   * right triangle → warp to right child (SPLIT_Y, CHILD_SECOND)
  ///   * bottom triangle → warp to bottom child (SPLIT_X, CHILD_SECOND)
  ///   * left triangle → warp to left child (SPLIT_Y, CHILD_FIRST)
  /// Either way the layout is reapplied, yanking the dragged window
  /// back to its real tile slot.
  private func handleWindowMoved(
    key: WindowKey,
    frame: CGRect,
    state: inout State
  ) -> Effect<Action> {
    guard let workspaceId = state.primaryActiveWorkspaceID,
          let workspace = state.config.activeProfile?
            .workspaces.first(where: { $0.id == workspaceId }),
          let tree = state.tilingTrees[workspaceId],
          tree.pathTo(window: key) != nil
    else { return .none }

    let settings = state.config.settings
    let display = workspace.displayHint ?? displays.current()
    let workArea = MainActor.assumeIsolated {
      ScreenGeometry.workArea(for: display).insetBy(
        dx: CGFloat(settings.layout.gapOuter),
        dy: CGFloat(settings.layout.gapOuter)
      )
    }
    let allFrames = tree.frames(in: workArea, gap: CGFloat(settings.layout.gapInner))
    let dropCenter = CGPoint(x: frame.midX, y: frame.midY)

    // Which tile sits under the drop center?
    let target = allFrames.first(where: { other, rect in
      other != key && rect.contains(dropCenter)
    })?.key

    var newTree = tree
    if let target, let targetRect = allFrames[target] {
      let drop = dropQuadrant(point: dropCenter, in: targetRect)
      switch drop {
      case .none:
        newTree = tree
      case .center:
        newTree = tree.swapping(key, target)
      case .top:
        newTree = warpInto(tree: tree, source: key, target: target, axis: .horizontal, child: .first)
      case .right:
        newTree = warpInto(tree: tree, source: key, target: target, axis: .vertical, child: .second)
      case .bottom:
        newTree = warpInto(tree: tree, source: key, target: target, axis: .horizontal, child: .second)
      case .left:
        newTree = warpInto(tree: tree, source: key, target: target, axis: .vertical, child: .first)
      }
    }
    state.tilingTrees[workspaceId] = newTree
    let zoomed = state.fullscreenZoomed[workspaceId] ?? []

    return .merge(
      .run { [tiler = windowTiler] _ in
        let frames = await MainActor.run {
          Self.computeFrames(
            tree: newTree,
            settings: settings,
            targetDisplay: display,
            fullscreenZoomed: zoomed
          )
        }
        if !frames.isEmpty {
          await tiler.apply(
            FrameApplication(windowFrames: frames, targetDisplay: display)
          )
        }
      },
      persist(newTree, fullscreenZoomed: zoomed, for: workspace, default: settings.layout.defaultTilingMemory)
    )
  }

  /// Returns which quadrant of `rect` `point` falls into. The center
  /// is a square covering the middle 50% of the rect; outside it the
  /// four triangles fan out to the corners.
  private enum DropQuadrant { case none, center, top, right, bottom, left }
  private func dropQuadrant(point: CGPoint, in rect: CGRect) -> DropQuadrant {
    let wp = CGPoint(x: point.x - rect.origin.x, y: point.y - rect.origin.y)
    let centerRect = CGRect(
      x: 0.25 * rect.width, y: 0.25 * rect.height,
      width: 0.5 * rect.width, height: 0.5 * rect.height
    )
    if centerRect.contains(wp) { return .center }
    // Four triangles. Use signed cross products against the rect's
    // diagonals to classify.
    let mid = CGPoint(x: 0.5 * rect.width, y: 0.5 * rect.height)
    let onAboveDownDiag = (wp.x - 0) * (rect.height - 0) - (wp.y - 0) * (rect.width - 0) < 0
    let onAboveUpDiag = (wp.x - 0) * (0 - rect.height) - (wp.y - rect.height) * (rect.width - 0) < 0
    _ = mid
    switch (onAboveDownDiag, onAboveUpDiag) {
    case (true, true):   return .top
    case (false, true):  return .right
    case (false, false): return .bottom
    case (true, false):  return .left
    }
  }

  /// Warp `source` next to `target` with a specific split axis +
  /// child placement: remove source from current slot, then re-insert
  /// next to target after seeding the target leaf's `preferredSplit`
  /// + `preferredChild`.
  private func warpInto(
    tree: BSPNode<WindowKey>,
    source: WindowKey,
    target: WindowKey,
    axis: BSPNode<WindowKey>.SplitAxis,
    child: BSPNode<WindowKey>.Child
  ) -> BSPNode<WindowKey> {
    guard let targetPath = tree.pathTo(window: target) else { return tree }
    let seeded = tree.replacing_(path: targetPath) { node in
      guard case .leaf(var leaf) = node else { return node }
      leaf.preferredSplit = axis
      leaf.preferredChild = child
      return .leaf(leaf)
    }
    guard let removed = seeded.removing(source) else { return tree }
    return removed.inserting(source, near: target, in: CGRect(x: 0, y: 0, width: 1, height: 1))
  }

  // MARK: - BSP ops

  private func applyBSPOp(
    windowKey: WindowKey,
    op: BSPOp,
    state: inout State
  ) -> Effect<Action> {
    guard let workspaceId = state.primaryActiveWorkspaceID,
          let workspace = state.config.activeProfile?
            .workspaces.first(where: { $0.id == workspaceId }),
          var tree = state.tilingTrees[workspaceId]
    else { return .none }

    let settings = state.config.settings
    let display = workspace.displayHint ?? displays.current()
    let gap = CGFloat(settings.layout.gapInner)
    let workArea = MainActor.assumeIsolated {
      ScreenGeometry.workArea(for: display).insetBy(
        dx: CGFloat(settings.layout.gapOuter),
        dy: CGFloat(settings.layout.gapOuter)
      )
    }

    switch op {
    case .swap(let direction):
      if let target = tree.directionalNeighbor(
        of: windowKey,
        direction: direction,
        in: workArea,
        gap: gap,
        focusOrder: tree.windows
      ) {
        tree = tree.swapping(windowKey, target)
      } else {
        let warped = tree.warping(windowKey, direction: direction)
        guard warped != tree else { return .none }
        tree = warped
      }

    case .resize(let direction, let delta):
      // Fence-based resize: pick the nearest ancestor whose split
      // axis matches `direction` and extends past the focused window
      // in that direction.
      guard let path = tree.fence(of: windowKey, direction: direction, in: workArea, gap: gap)
      else { break }
      guard case .branch(let parent) = tree.subtree(at: path) else { break }
      // Positive delta = grow focused window. If the focused window is
      // on the right/bottom side of the fence, flip sign so growing
      // means shrinking the parent ratio (which describes the
      // left/top child's share).
      guard let focusedPath = tree.pathTo(window: windowKey) else { break }
      let sideIntoFence = focusedPath[path.count]
      let signedDelta = sideIntoFence == .left ? delta : -delta
      let newRatio = max(0.1, min(0.9, parent.ratio + signedDelta))
      tree = tree.updatingRatio(at: path, ratio: newRatio)

    case .toggleOrientation:
      tree = tree.togglingSplit(at: windowKey)

    case .toggleZoomParent:
      // Per-leaf zoom: tree unchanged, the focused leaf renders at
      // its parent branch's area on the next layout pass.
      tree = tree.togglingParentZoom(at: windowKey)

    case .toggleZoomFullscreen:
      // Tatami-specific multi-window fullscreen. Track in workspace
      // state; the tree itself is untouched. computeFrames trims
      // these windows out and overlays them on the work area.
      var set = state.fullscreenZoomed[workspaceId] ?? []
      if set.contains(windowKey) {
        set.remove(windowKey)
      } else {
        set.insert(windowKey)
      }
      state.fullscreenZoomed[workspaceId] = set.isEmpty ? nil : set

    case .setInsertDirection(let direction):
      tree = tree.settingInsertDirection(at: windowKey, direction: direction)
      // Update the per-workspace insertion point to this window so
      // the next inserted window honors the direction.
      if direction != nil {
        state.insertionPoint[workspaceId] = windowKey
      }
    }

    state.tilingTrees[workspaceId] = tree
    let zoomed = state.fullscreenZoomed[workspaceId] ?? []

    return .merge(
      .run { [tiler = windowTiler] _ in
        let frames = await MainActor.run {
          Self.computeFrames(
            tree: tree,
            settings: settings,
            targetDisplay: display,
            fullscreenZoomed: zoomed
          )
        }
        await tiler.apply(
          FrameApplication(windowFrames: frames, targetDisplay: display)
        )
      },
      persist(tree, fullscreenZoomed: zoomed, for: workspace, default: settings.layout.defaultTilingMemory),
      refreshMarkers(state: state)
    )
  }

  private func applyTreeTransform(
    state: inout State,
    _ transform: (BSPNode<WindowKey>) -> BSPNode<WindowKey>
  ) -> Effect<Action> {
    guard let workspaceId = state.primaryActiveWorkspaceID,
          let workspace = state.config.activeProfile?
            .workspaces.first(where: { $0.id == workspaceId }),
          let tree = state.tilingTrees[workspaceId]
    else { return .none }
    let newTree = transform(tree)
    state.tilingTrees[workspaceId] = newTree
    let settings = state.config.settings
    let display = workspace.displayHint ?? displays.current()
    let zoomed = state.fullscreenZoomed[workspaceId] ?? []
    return .merge(
      .run { [tiler = windowTiler] _ in
        let frames = await MainActor.run {
          Self.computeFrames(
            tree: newTree,
            settings: settings,
            targetDisplay: display,
            fullscreenZoomed: zoomed
          )
        }
        if !frames.isEmpty {
          await tiler.apply(
            FrameApplication(windowFrames: frames, targetDisplay: display)
          )
        }
      },
      persist(newTree, fullscreenZoomed: zoomed, for: workspace, default: settings.layout.defaultTilingMemory)
    )
  }

  // MARK: - Cycle

  private func cycle(by direction: Int, state: inout State) -> Effect<Action> {
    guard let workspaces = state.config.activeProfile?.workspaces, !workspaces.isEmpty
    else { return .none }
    let settings = state.config.settings
    let currentID = state.activeWorkspacesByDisplay.values.first
      ?? state.primaryActiveWorkspaceID
    let currentIndex = workspaces.firstIndex { $0.id == currentID } ?? -1
    let count = workspaces.count

    let runningBundleIds: Set<String> = settings.switching.skipEmpty
      ? MainActor.assumeIsolated {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
      }
      : []

    var index = currentIndex
    for _ in 0 ..< count {
      let next = index + direction
      if settings.switching.loop {
        index = (next + count) % count
      } else {
        guard next >= 0, next < count else { return .none }
        index = next
      }
      let candidate = workspaces[index]
      if settings.switching.skipEmpty {
        let hasRunning = candidate.apps.contains {
          runningBundleIds.contains($0.bundleIdentifier)
        }
        if !hasRunning { continue }
      }
      return .send(.activate(workspaceId: candidate.id, setFocus: true))
    }
    return .none
  }

  // MARK: - Helpers

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

@MainActor
func focusedWindowKey() -> WindowKey? {
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

/// Map an `AutoBalanceMode` to the `BSPNode.balanced(axis:)` enum.
private func bspAxis(for mode: AutoBalanceMode) -> AutoBalanceAxis {
  switch mode {
  case .none: return .none
  case .horizontal: return .horizontal
  case .vertical: return .vertical
  case .both: return .both
  }
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

// MARK: - BSPNode internal helper used by drag warp

extension BSPNode {
  /// File-internal `replacing(path:with:)` exposed under a different
  /// name so the reducer can patch leaf metadata directly. Identical
  /// implementation to the file-private version inside BSPTree.swift —
  /// we re-expose it here rather than make the original public so the
  /// public surface stays terse.
  fileprivate func replacing_(
    path: [Side],
    with transform: (BSPNode) -> BSPNode
  ) -> BSPNode {
    guard let next = path.first else {
      return transform(self)
    }
    switch self {
    case .leaf:
      return transform(self)
    case .branch(let b):
      let rest = Array(path.dropFirst())
      switch next {
      case .left:
        return .branch(BSPBranch(
          split: b.split,
          ratio: b.ratio,
          preferredChild: b.preferredChild,
          left: b.left.replacing_(path: rest, with: transform),
          right: b.right
        ))
      case .right:
        return .branch(BSPBranch(
          split: b.split,
          ratio: b.ratio,
          preferredChild: b.preferredChild,
          left: b.left,
          right: b.right.replacing_(path: rest, with: transform)
        ))
      }
    }
  }
}
