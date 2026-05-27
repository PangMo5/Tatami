import AppKit
import ApplicationServices
import ComposableArchitecture
import Foundation
import Sharing

/// Tracks the active workspace per display, owns per-workspace BSP
/// trees, and dispatches activation + window-layout side effects.
@Reducer
public struct WorkspaceActivationFeature {
  @ObservableState
  public struct State: Equatable {
    @Shared(.tatamiConfig) public var config = AppConfig()
    public var activeWorkspacesByDisplay: [DisplayName: Workspace.ID] = [:]
    public var previousWorkspaceID: Workspace.ID?
    public var isActivating = false
    /// Per-workspace BSP tree of window keys, kept in-memory only.
    public var tilingTrees: [Workspace.ID: BSPNode<WindowKey>] = [:]
    /// Per-workspace "zoomed" window — when set, that leaf fills the
    /// work area and the rest of the tree stays stacked behind it.
    /// Mirrors yabai's `window --toggle zoom-fullscreen`.
    public var zoomedWindow: [Workspace.ID: WindowKey] = [:]
    /// Last window that held focus and was a member of a tree — yabai's
    /// "insertion point". A freshly opened window is already frontmost
    /// (so live focus points at it, not the tree) — splitting *this*
    /// instead reproduces yabai's "open next to the previously focused
    /// window" behavior.
    public var lastFocusedKey: WindowKey?

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
    case bspToggleZoom
    case bspBalance
    case bspRotate(degrees: Int)
    case bspMirror(axis: BSPNode<WindowKey>.SplitAxis)
    case bspOpResolved(windowKey: WindowKey, op: BSPOp)
    case windowChanged(WindowChangeEvent)
    case windowResizeCommitted(key: WindowKey, frame: CGRect)
    case windowMoveCommitted(key: WindowKey, frame: CGRect)
    /// Incrementally reconcile a single app's windows into the active
    /// tree (yabai-style): add new windows, drop gone ones, touch
    /// nothing else. Far cheaper than rescanning the whole workspace.
    case syncAppWindows(bundleId: String)
    case startObservingAppLaunches
    case appLaunched(bundleId: String, name: String)
    case appActivated(bundleId: String)
    case appTerminated(bundleId: String)
    case tilingTreeUpdated(workspaceId: Workspace.ID, tree: BSPNode<WindowKey>?)
    case activationCompleted(workspaceId: Workspace.ID, display: DisplayName?)
  }

  /// Tag used to dispatch a BSP mutation once we've resolved the
  /// focused window's `WindowKey`.
  public enum BSPOp: Sendable, Hashable {
    case swap(BSPDirection)
    case resize(BSPDirection, delta: CGFloat)
    case toggleOrientation
    case toggleZoom
  }

  /// Cancellation identifiers for debounced window-event handling.
  private enum CancelID: Hashable {
    case windowResize(WindowKey)
    case windowMove(WindowKey)
    case sync(String)
    /// Coalesces frame application per workspace: a newer layout cancels
    /// an in-flight apply so a stale (older-tree) apply can't land after
    /// it and scramble the layout during rapid window churn.
    case apply(Workspace.ID)
  }

  @Dependency(\.workspaceManager) var workspaceManager
  @Dependency(\.windowTiler) var windowTiler
  @Dependency(\.windowObserver) var windowObserver
  @Dependency(\.appLaunch) var appLaunch
  @Dependency(\.displays) var displays
  @Dependency(\.layoutStore) var layoutStore
  @Dependency(\.workspaceHUD) var workspaceHUD

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
          // Reconcile just this app's windows — a tiny settle delay lets
          // the new window's AX attributes populate first.
          return debouncedSync(bundleId, delayMs: 15)
        case .windowDestroyed(let bundleId):
          return debouncedSync(bundleId, delayMs: 0)
        case .windowFocused(let key):
          // Keep the insertion point current even for same-app window
          // switches (which don't fire didActivateApplication). Pure
          // state update — no retile.
          if let wsId = state.primaryActiveWorkspaceID,
             state.tilingTrees[wsId]?.windows.contains(key) == true
          {
            state.lastFocusedKey = key
          }
          return .none
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
            }
          }
        }

      case .appLaunched(let bundleId, _):
        return debouncedSync(bundleId, delayMs: 40)

      case .appActivated(let bundleId):
        // Ignore our own re-activations to avoid loops.
        if bundleId == "dev.PangMo5.Tatami" || bundleId == "dev.PangMo5.Tatami.dev" {
          return .none
        }
        // activeWorkspaceOnFocusChange: if a non-floating app is focused
        // and it belongs to a workspace that isn't active, switch to it.
        // (Skipped while activating to avoid feedback loops.)
        if !state.isActivating,
           state.config.settings.activeWorkspaceOnFocusChange,
           !state.config.floatingApps.contains(where: { $0.bundleIdentifier == bundleId }),
           let owner = state.config.activeProfile?.workspaces.first(where: {
             $0.apps.contains { $0.bundleIdentifier == bundleId }
           }),
           state.primaryActiveWorkspaceID != owner.id {
          return .send(.activate(workspaceId: owner.id, setFocus: false))
        }
        // Reconcile this app — if its window set is unchanged (the
        // common focus-churn case) syncAppWindows is a cheap no-op.
        return debouncedSync(bundleId, delayMs: 40)

      case .appTerminated(let bundleId):
        return debouncedSync(bundleId, delayMs: 0)

      case .activateInitial:
        guard let profile = state.config.activeProfile,
              !profile.workspaces.isEmpty
        else { return .none }
        // Prefer the workspace that owns the currently frontmost app so
        // launch doesn't yank the user somewhere else; fall back to the
        // first workspace. setFocus:false keeps the current focus.
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
        // Invalidate the destination workspace's tree so the next
        // activation rebuilds with the new participant.
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
        return .none

      case .togglePaused:
        let wasPaused = state.config.settings.isPaused
        state.$config.withLock { config in
          config.settings.isPaused.toggle()
        }
        // Resuming: re-tile right away. Use reflow (not activate) so we
        // don't hide transient members like an ad-hoc KakaoTalk window.
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
        let gap = CGFloat(settings.gapInner)
        let workArea = MainActor.assumeIsolated {
          ScreenGeometry.workArea(for: display).insetBy(
            dx: CGFloat(settings.gapOuter),
            dy: CGFloat(settings.gapOuter)
          )
        }
        // Directional focus stays *within the tiled set* — the neighbor
        // is resolved from the BSP tree, so floating/unmanaged windows
        // are never targeted.
        guard let target = tree.directionalNeighbor(
          of: key,
          direction: direction,
          in: workArea,
          gap: gap
        ) else { return .none }
        return .run { _ in
          await MainActor.run {
            focusWindow(pid: target.pid, windowID: target.windowID)
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

      case .bspToggleZoom:
        return resolveFocusedWindowKey { key in
          .bspOpResolved(windowKey: key, op: .toggleZoom)
        }

      case .bspBalance:
        return applyTreeTransform(state: &state) { $0.balanced() }

      case .bspRotate(let degrees):
        return applyTreeTransform(state: &state) { $0.rotated(by: degrees) }

      case .bspMirror(let axis):
        return applyTreeTransform(state: &state) { $0.mirrored(axis: axis) }

      case .bspOpResolved(let key, let op):
        return applyBSPOp(windowKey: key, op: op, state: &state)

      case .tilingTreeUpdated(let workspaceId, let tree):
        state.tilingTrees[workspaceId] = tree
        // Seed the insertion point at the spiral tail so the first
        // window opened after activation lands at the end of the
        // dwindle — not split off the previously frontmost (often
        // left-hand) window. A real focus change updates it afterward.
        state.lastFocusedKey = tree?.deepestLeaf
        return .none

      case .activationCompleted(let id, let display):
        state.isActivating = false
        if let display, let previous = state.activeWorkspacesByDisplay[display], previous != id {
          state.previousWorkspaceID = previous
        }
        if let display {
          state.activeWorkspacesByDisplay[display] = id
        }
        // Observe the tree's actual members (registered + transient)
        // so a second window on any of them triggers a retile. Falls
        // back to the registered apps if the tree isn't built yet.
        let treeIds = state.tilingTrees[id]?.windows.map(\.bundleId)
        let registeredIds = state.config.activeProfile?
          .workspaces.first(where: { $0.id == id })?
          .apps.map(\.bundleIdentifier) ?? []
        let observeIds = Array(Set(treeIds ?? registeredIds))
        return .run { [observer = windowObserver] _ in
          await observer.observe(observeIds)
        }
      }
    }
  }

  /// Re-tile the active workspace's current windows WITHOUT touching app
  /// visibility (no hide/show). Used on resume: tiling needs to catch up
  /// to whatever changed while paused, but re-activating would hide
  /// transient members (e.g. a KakaoTalk window opened ad-hoc).
  private func reflowActiveWorkspace(state: inout State) -> Effect<Action> {
    guard !state.config.settings.isPaused,
          let workspaceId = state.primaryActiveWorkspaceID,
          let workspace = state.config.activeProfile?
            .workspaces.first(where: { $0.id == workspaceId })
    else { return .none }

    let settings = state.config.settings
    let display = workspace.displayHint ?? displays.current()
    let registered = workspace.apps.map(\.bundleIdentifier)
    let registeredSet = Set(registered)
    let allAssigned = Self.everyAssignedBundleId(in: state.config)
    let floatingSet = Set(state.config.floatingApps.map(\.bundleIdentifier))
    let existing = state.tilingTrees[workspaceId]

    let snapshot = MainActor.assumeIsolated {
      () -> (targets: [WindowKey], focused: WindowKey?, workArea: CGRect) in
      let visibleUnassigned = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular && !$0.isHidden && !$0.isTerminated }
        .compactMap(\.bundleIdentifier)
        .filter { id in
          !registeredSet.contains(id) && !floatingSet.contains(id)
            && !allAssigned.contains(id)
            && id != "dev.PangMo5.Tatami" && id != "dev.PangMo5.Tatami.dev"
        }
      let keys = discoverWindowKeys(forBundleIds: registered)
        + discoverWindowKeys(forBundleIds: visibleUnassigned)
      let workArea = ScreenGeometry.workArea(for: display).insetBy(
        dx: CGFloat(settings.gapOuter), dy: CGFloat(settings.gapOuter)
      )
      return (keys, focusedWindowKey(), workArea)
    }

    let merged = Self.mergeTree(
      existing: existing,
      target: snapshot.targets,
      focused: snapshot.focused,
      workArea: snapshot.workArea
    )
    let balanced = settings.autoBalance ? merged?.balanced() : merged
    state.tilingTrees[workspaceId] = balanced
    guard let tree = balanced else { return .none }
    state.lastFocusedKey = tree.deepestLeaf
    let zoomed = state.zoomedWindow[workspaceId]
    let observeIds = Array(Set(tree.windows.map(\.bundleId)))

    return .merge(
      .run { [tiler = windowTiler] _ in
        let frames = await MainActor.run {
          Self.computeFrames(
            tree: tree, settings: settings, targetDisplay: display, zoomed: zoomed
          )
        }
        if !frames.isEmpty {
          await tiler.apply(FrameApplication(windowFrames: frames, targetDisplay: display))
        }
      }
      .cancellable(id: CancelID.apply(workspaceId), cancelInFlight: true),
      .run { [observer = windowObserver] _ in await observer.observe(observeIds) },
      persist(tree, for: workspace, default: settings.defaultTilingMemory)
    )
  }

  /// Debounce a per-app reconcile. macOS fires window/app notifications
  /// in bursts (especially with focus-follows-mouse), so we wait for a
  /// short lull and coalesce per bundle id. `cancelInFlight` keyed by
  /// bundle id drops superseded syncs for the same app while letting
  /// different apps reconcile independently.
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
  /// workspace's tree (yabai-style). Scans only that app via AX,
  /// inserts windows new to the tree (next to focus / spiral tail),
  /// removes ones that vanished, and leaves every other tile alone.
  /// A no-op (and no AX apply) when nothing changed — so focus churn
  /// stays cheap.
  private func syncAppWindows(bundleId: String, state: inout State) -> Effect<Action> {
    // Paused = tiling is off; don't reflow on window/app churn.
    guard !state.config.settings.isPaused else { return .none }
    if bundleId == "dev.PangMo5.Tatami" || bundleId == "dev.PangMo5.Tatami.dev" {
      return .none
    }
    // While an activation is in flight, performActivate owns the tree
    // (it builds from a snapshot and writes back asynchronously). Let it
    // finish — otherwise an incremental sync races it and one clobbers
    // the other, scrambling the launch layout.
    guard !state.isActivating else { return .none }
    guard let workspaceId = state.primaryActiveWorkspaceID,
          let workspace = state.config.activeProfile?
            .workspaces.first(where: { $0.id == workspaceId })
    else { return .none }

    let settings = state.config.settings
    let display = workspace.displayHint ?? displays.current()
    let registeredSet = Set(workspace.apps.map(\.bundleIdentifier))
    let floatingSet = Set(state.config.floatingApps.map(\.bundleIdentifier))
    let allAssigned = Self.everyAssignedBundleId(in: state.config)
    let existing = state.tilingTrees[workspaceId]
    let inTree = existing?.windows.contains { $0.bundleId == bundleId } ?? false

    // Floating apps never tile. Apps assigned to *other* workspaces only
    // tile here if they're already a transient member of this tree.
    if floatingSet.contains(bundleId) { return .none }
    let isUnassigned = !registeredSet.contains(bundleId) && !allAssigned.contains(bundleId)
    let eligibleToAdd = registeredSet.contains(bundleId) || inTree || isUnassigned

    let (current, focused, workArea, visibleUnassigned) = MainActor.assumeIsolated {
      () -> (current: [WindowKey], focused: WindowKey?, workArea: CGRect, unassigned: [String]) in
      let cur = discoverWindowKeys(forBundleIds: [bundleId])
      let foc = focusedWindowKey()
      let wa = ScreenGeometry.workArea(for: display).insetBy(
        dx: CGFloat(settings.gapOuter),
        dy: CGFloat(settings.gapOuter)
      )
      // Currently-visible apps not assigned anywhere — transient tiling
      // candidates we must keep observing so a window appearing later
      // (e.g. a Notification-Center-opened KakaoTalk) is noticed.
      let unassigned = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular && !$0.isHidden && !$0.isTerminated }
        .compactMap(\.bundleIdentifier)
        .filter {
          !registeredSet.contains($0) && !floatingSet.contains($0)
            && !allAssigned.contains($0)
            && $0 != "dev.PangMo5.Tatami" && $0 != "dev.PangMo5.Tatami.dev"
        }
      return (cur, foc, wa, unassigned)
    }
    // Track the insertion point: if focus is on a window already in the
    // tree, that's the most recent intentional focus — remember it.
    if let focused, existing?.windows.contains(focused) == true {
      state.lastFocusedKey = focused
    }
    let insertionPoint = state.lastFocusedKey

    var tree = existing
    let currentSet = Set(current)

    // Remove this app's windows that are gone (sibling promotes up).
    for key in (tree?.windows ?? []) where key.bundleId == bundleId && !currentSet.contains(key) {
      tree = tree?.removing(key)
    }

    // Insert windows new to the tree next to the insertion point — the
    // previously focused tiled window (yabai "open next to focus"). The
    // live `focused` is unreliable for a brand-new window (it's already
    // frontmost), so prefer the tracked insertion point, then live
    // focus, then the spiral tail. After each insert, focus conceptually
    // moves to the new window, so it becomes the next insertion point —
    // this is what makes the spiral wind instead of piling every new
    // window onto one fixed node.
    if eligibleToAdd {
      var anchorKey = insertionPoint
      for key in current {
        guard let current = tree else {
          tree = .leaf(key)
          anchorKey = key
          state.lastFocusedKey = key
          continue
        }
        if current.windows.contains(key) { continue }
        let present = Set(current.windows)
        let anchor = [anchorKey, focused]
          .compactMap { $0 }
          .first { present.contains($0) }
          ?? current.deepestLeaf
        tree = current.inserting(key, near: anchor, in: workArea)
        anchorKey = key
        state.lastFocusedKey = key
      }
    }

    let balanced = settings.autoBalance ? tree?.balanced() : tree
    let oldWindows = Set(existing?.windows ?? [])
    let newWindows = Set(balanced?.windows ?? [])
    state.tilingTrees[workspaceId] = balanced

    // Observe set must be stable across per-app syncs: tree members +
    // the workspace's registered apps + currently-visible unassigned
    // apps. Otherwise a sync for one app (e.g. ghostty) would reset the
    // observers to just its own set and drop the subscription for an
    // app whose window hasn't appeared yet (e.g. a Notification-Center-
    // opened KakaoTalk that still reports 0 AX windows), so we'd miss
    // its windowCreated.
    var observeSet = Set(balanced?.windows.map(\.bundleId) ?? [])
    observeSet.formUnion(registeredSet)
    observeSet.formUnion(visibleUnassigned)
    let observeIds = Array(observeSet)
    let observeEffect = Effect<Action>.run { [observer = windowObserver] _ in
      await observer.observe(observeIds)
    }

    // Nothing changed in the tree — still (re)subscribe so a later
    // window from this app gets noticed.
    guard oldWindows != newWindows, let final = balanced else {
      return observeEffect
    }

    let zoomed = state.zoomedWindow[workspaceId]
    return .merge(
      .run { [tiler = windowTiler] _ in
        let frames = await MainActor.run {
          Self.computeFrames(
            tree: final,
            settings: settings,
            targetDisplay: display,
            zoomed: zoomed
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
      persist(final, for: workspace, default: settings.defaultTilingMemory)
    )
  }

  /// Yabai-style incremental merge: keep `existing` and reconcile its
  /// leaves against `target`.
  ///   * windows in existing but not in target → removed (sibling
  ///     promotes into the parent slot, preserving user-tuned ratios
  ///     elsewhere)
  ///   * windows in target but not in existing → inserted next to
  ///     `focused` (if focused is a leaf) or at the shallowest leaf
  ///   * windows in both → left in place
  private static func mergeTree(
    existing: BSPNode<WindowKey>?,
    target: [WindowKey],
    focused: WindowKey?,
    workArea: CGRect
  ) -> BSPNode<WindowKey>? {
    guard !target.isEmpty else { return nil }
    let targetSet = Set(target)
    var tree = existing

    // Step 1: remove windows that vanished, keeping surviving ratios.
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

    // Fresh tree (first activation / .fresh memory): build a yabai
    // dwindle spiral — each window splits the previous one, first
    // window gets half, next a quarter, etc. (autoBalance, applied by
    // the caller afterward, evens this out if the user wants a grid.)
    if tree == nil {
      return BSPNode.dwindleBuild(newOnes, in: workArea)
    }

    // Live additions: drop each new window next to the focused window
    // (yabai "open next to focus"). When the focused window isn't in
    // the tree — which is the common case, since a freshly opened
    // window is already frontmost but not yet tiled — anchor on the
    // deepest leaf so the dwindle spiral keeps winding instead of
    // falling back to a shallow split (the left-leaning staircase).
    for id in newOnes {
      let anchor: WindowKey? = {
        if let focused, tree?.windows.contains(focused) == true { return focused }
        return tree?.deepestLeaf
      }()
      tree = tree?.inserting(id, near: anchor, in: workArea) ?? .leaf(id)
    }
    return tree
  }

  /// Bundle IDs registered to any workspace anywhere in the config.
  /// Used to detect "unassigned" apps for transient tiling.
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

  // MARK: - Window key resolution

  /// Resolve the WindowKey for the user's currently-focused window on
  /// the main thread, then dispatch the continuation action.
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
  /// `.persistent` memory. No-op otherwise. The snapshot is bundle-id
  /// keyed so it survives the process-scoped `WindowKey`s dying.
  private func persist(
    _ tree: BSPNode<WindowKey>?,
    for workspace: Workspace,
    default defaultMemory: TilingMemory
  ) -> Effect<Action> {
    let memory = workspace.tilingMemory ?? defaultMemory
    guard memory == .persistent, let tree else { return .none }
    let id = workspace.id
    let template = tree.mapWindows { $0.bundleId }
    return .run { [store = layoutStore] _ in store.save(id, template) }
  }

  // MARK: - Activation

  private func performActivate(
    workspaceId: Workspace.ID,
    setFocus: Bool,
    state: inout State
  ) -> Effect<Action> {
    guard !state.config.settings.isPaused else { return .none }
    guard let profile = state.config.activeProfile,
          let workspace = profile.workspaces.first(where: { $0.id == workspaceId })
    else { return .none }
    guard !state.isActivating else { return .none }
    state.isActivating = true

    let targetDisplay = workspace.displayHint ?? displays.current()
    let request = ActivationRequest(
      workspace: workspace,
      floatingApps: state.config.floatingApps,
      targetDisplay: targetDisplay,
      setFocus: setFocus,
      mouseFollowsFocus: setFocus && state.config.settings.mouseFollowsFocus,
      mouseHidesOnFocus: setFocus && state.config.settings.mouseHidesOnFocus
    )

    let settings = state.config.settings
    let bundleIds = workspace.apps.map(\.bundleIdentifier)
    let memory = workspace.tilingMemory ?? settings.defaultTilingMemory
    // .fresh always starts from scratch on (re)activation; .session and
    // .persistent reuse the in-memory tree. .persistent additionally
    // falls back to the on-disk snapshot when there's no live tree
    // (i.e. first activation after launch).
    let sessionTree = memory == .fresh ? nil : state.tilingTrees[workspace.id]
    // .fresh starts clean — drop any lingering zoom so the workspace
    // doesn't reactivate stuck in fullscreen.
    if memory == .fresh {
      state.zoomedWindow[workspace.id] = nil
    }
    let zoomed = state.zoomedWindow[workspace.id]

    let hudName = workspace.name
    let hudIcon = workspace.symbolIconName

    return .run { [
      mgr = workspaceManager,
      tiler = windowTiler,
      store = layoutStore,
      hud = workspaceHUD
    ] send in
      if setFocus {
        await hud.show(hudName, hudIcon)
      }
      await mgr.activate(request)
      let (tree, frames) = await MainActor.run {
        () -> (BSPNode<WindowKey>?, [WindowKey: CGRect]) in
        let keys = discoverWindowKeys(forBundleIds: bundleIds)
        let focused = focusedWindowKey()
        let workArea = ScreenGeometry.workArea(for: targetDisplay).insetBy(
          dx: CGFloat(settings.gapOuter),
          dy: CGFloat(settings.gapOuter)
        )
        var base = sessionTree
        if memory == .persistent, base == nil,
           let template = store.load(workspaceId)
        {
          base = BSPNode.hydrate(template: template, keys: keys)
        }
        let merged = Self.mergeTree(
          existing: base,
          target: keys,
          focused: focused,
          workArea: workArea
        )
        let tree = settings.autoBalance ? merged?.balanced() : merged
        let frames = Self.computeFrames(
          tree: tree,
          settings: settings,
          targetDisplay: targetDisplay,
          zoomed: zoomed
        )
        return (tree, frames)
      }
      await send(.tilingTreeUpdated(workspaceId: workspaceId, tree: tree))
      if memory == .persistent, let tree {
        store.save(workspaceId, tree.mapWindows { $0.bundleId })
      }
      if !frames.isEmpty {
        await tiler.apply(
          FrameApplication(windowFrames: frames, targetDisplay: targetDisplay)
        )
      }
      await send(.activationCompleted(workspaceId: workspaceId, display: targetDisplay))
    }
  }

  // MARK: - Manual resize sync

  /// AX told us the user finished resizing `key` to `frame`. Translate
  /// that frame back into a split ratio on the parent branch so the
  /// tree's geometry tracks what the user actually sees, then reapply
  /// the layout (the sibling needs to fill the remainder; AX only
  /// notified us about the one window the user dragged).
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
          case .branch(let split, _, _, _) = tree.subtree(at: parentPath)
    else { return .none }

    let settings = state.config.settings
    let display = workspace.displayHint ?? displays.current()
    let gap = CGFloat(settings.gapInner)
    let workArea = MainActor.assumeIsolated {
      ScreenGeometry.workArea(for: display).insetBy(
        dx: CGFloat(settings.gapOuter),
        dy: CGFloat(settings.gapOuter)
      )
    }
    let parentRect = tree.rect(at: parentPath, in: workArea, gap: gap)

    let newRatio: CGFloat
    switch split {
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

    let newTree = tree.updatingRatio(at: parentPath, ratio: newRatio)
    state.tilingTrees[workspaceId] = newTree
    let zoomed = state.zoomedWindow[workspaceId]

    return .merge(
      .run { [tiler = windowTiler] _ in
        let frames = await MainActor.run {
          Self.computeFrames(
            tree: newTree,
            settings: settings,
            targetDisplay: display,
            zoomed: zoomed
          )
        }
        if !frames.isEmpty {
          await tiler.apply(
            FrameApplication(windowFrames: frames, targetDisplay: display)
          )
        }
      },
      persist(newTree, for: workspace, default: settings.defaultTilingMemory)
    )
  }

  // MARK: - Drag-to-swap

  /// AX reported the user moved `key` to `frame`. If the dropped
  /// window's center lands inside another tile's slot, swap the two
  /// in the tree. Either way we re-apply the layout, which yanks the
  /// dragged window back into a real tile slot — yabai's "windows are
  /// always laid out" guarantee.
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
        dx: CGFloat(settings.gapOuter),
        dy: CGFloat(settings.gapOuter)
      )
    }
    let allFrames = tree.frames(in: workArea, gap: CGFloat(settings.gapInner))
    let center = CGPoint(x: frame.midX, y: frame.midY)
    let swapTarget = allFrames.first(where: { other, rect in
      other != key && rect.contains(center)
    })?.key

    let newTree: BSPNode<WindowKey>
    if let target = swapTarget {
      newTree = tree.swapping(key, target)
    } else {
      newTree = tree
    }
    state.tilingTrees[workspaceId] = newTree
    let zoomed = state.zoomedWindow[workspaceId]

    return .merge(
      .run { [tiler = windowTiler] _ in
        let frames = await MainActor.run {
          Self.computeFrames(
            tree: newTree,
            settings: settings,
            targetDisplay: display,
            zoomed: zoomed
          )
        }
        if !frames.isEmpty {
          await tiler.apply(
            FrameApplication(windowFrames: frames, targetDisplay: display)
          )
        }
      },
      persist(newTree, for: workspace, default: settings.defaultTilingMemory)
    )
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
    let gap = CGFloat(settings.gapInner)
    let workArea = MainActor.assumeIsolated {
      ScreenGeometry.workArea(for: display).insetBy(
        dx: CGFloat(settings.gapOuter),
        dy: CGFloat(settings.gapOuter)
      )
    }

    switch op {
    case .swap(let direction):
      if let target = tree.directionalNeighbor(
        of: windowKey,
        direction: direction,
        in: workArea,
        gap: gap
      ) {
        // A tile exists in that direction — swap positions.
        tree = tree.swapping(windowKey, target)
      } else {
        // No neighbor that way — warp: reorient the parent split so the
        // window moves the requested direction (yabai window --warp).
        // e.g. two side-by-side windows + swap-down → stacked layout.
        let warped = tree.warping(windowKey, direction: direction)
        guard warped != tree else { return .none }
        tree = warped
      }

    case .resize(let direction, let delta):
      // Map compass direction to the split axis it acts on: east/west
      // moves the vertical edge → resize the vertical split; north/
      // south moves the horizontal edge → horizontal split.
      let axis: BSPNode<WindowKey>.SplitAxis =
        (direction == .east || direction == .west) ? .vertical : .horizontal
      // The sign depends on which side of the parent split the focused
      // window sits on. updatingRatio clamps internally; resizing()
      // tweaks the nearest matching-axis ancestor.
      tree = tree.resizing(window: windowKey, axis: axis, delta: delta)

    case .toggleOrientation:
      tree = tree.togglingSplit(at: windowKey)

    case .toggleZoom:
      // Toggle the zoom marker for this workspace. The tree itself is
      // unchanged; computeFrames hands the zoomed leaf the full work
      // area when one is set.
      if state.zoomedWindow[workspaceId] == windowKey {
        state.zoomedWindow[workspaceId] = nil
      } else {
        state.zoomedWindow[workspaceId] = windowKey
      }
    }

    state.tilingTrees[workspaceId] = tree
    let zoomed = state.zoomedWindow[workspaceId]

    return .merge(
      .run { [tiler = windowTiler] _ in
        let frames = await MainActor.run {
          Self.computeFrames(
            tree: tree,
            settings: settings,
            targetDisplay: display,
            zoomed: zoomed
          )
        }
        await tiler.apply(
          FrameApplication(windowFrames: frames, targetDisplay: display)
        )
      },
      persist(tree, for: workspace, default: settings.defaultTilingMemory)
    )
  }

  /// Apply a pure tree transform to the active workspace's tree and
  /// reflow the layout. Used by balance/rotate/mirror — all of which
  /// rewrite split ratios + child positions without needing the
  /// focused-window context.
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
    let zoomed = state.zoomedWindow[workspaceId]
    return .merge(
      .run { [tiler = windowTiler] _ in
        let frames = await MainActor.run {
          Self.computeFrames(
            tree: newTree,
            settings: settings,
            targetDisplay: display,
            zoomed: zoomed
          )
        }
        if !frames.isEmpty {
          await tiler.apply(
            FrameApplication(windowFrames: frames, targetDisplay: display)
          )
        }
      },
      persist(newTree, for: workspace, default: settings.defaultTilingMemory)
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

    // "Empty" = no *running* app assigned (matches FlashSpace), not just
    // an empty assignment list.
    let runningBundleIds: Set<String> = settings.skipEmptyWorkspacesOnSwitch
      ? MainActor.assumeIsolated {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
      }
      : []

    // Step through candidates in `direction`, honoring loop + skip-empty.
    var index = currentIndex
    for _ in 0 ..< count {
      let next = index + direction
      if settings.loopWorkspaces {
        index = (next + count) % count
      } else {
        guard next >= 0, next < count else { return .none }
        index = next
      }
      let candidate = workspaces[index]
      if settings.skipEmptyWorkspacesOnSwitch {
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

  @MainActor
  static func computeFrames(
    tree: BSPNode<WindowKey>?,
    settings: AppSettings,
    targetDisplay: DisplayName?,
    zoomed: WindowKey? = nil
  ) -> [WindowKey: CGRect] {
    guard let tree else { return [:] }
    let workArea = ScreenGeometry.workArea(for: targetDisplay).insetBy(
      dx: CGFloat(settings.gapOuter),
      dy: CGFloat(settings.gapOuter)
    )
    var frames = tree.frames(in: workArea, gap: CGFloat(settings.gapInner))
    // Zoom overrides the leaf's tile rect with the full work area so
    // the focused window appears "fullscreen within the workspace"
    // without retiling everything else (yabai's zoom-fullscreen).
    if let zoomed, frames[zoomed] != nil {
      frames[zoomed] = workArea
    }
    return frames
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

