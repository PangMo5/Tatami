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

    public init() {}

    public var primaryActiveWorkspaceID: Workspace.ID? {
      activeWorkspacesByDisplay.values.first
    }
  }

  public enum Action {
    case startObservingWindowEvents
    case activate(workspaceId: Workspace.ID, setFocus: Bool)
    case activateNext
    case activatePrevious
    case activateRecent
    case moveFocusedAppTo(workspaceId: Workspace.ID)
    case focusedAppResolved(bundleId: String, workspaceId: Workspace.ID)
    case toggleFloatingOnFocusedApp
    case focusedFloatToggleResolved(bundleId: String, name: String)
    case togglePaused
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
  }

  @Dependency(\.workspaceManager) var workspaceManager
  @Dependency(\.windowTiler) var windowTiler
  @Dependency(\.windowObserver) var windowObserver
  @Dependency(\.appLaunch) var appLaunch
  @Dependency(\.displays) var displays

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
        case .windowCreated, .windowDestroyed:
          return retileActiveWorkspace(state: &state)
        }

      case .windowResizeCommitted(let key, let frame):
        return syncTreeRatio(for: key, frame: frame, state: &state)

      case .windowMoveCommitted(let key, let frame):
        return handleWindowMoved(key: key, frame: frame, state: &state)

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

      case .appLaunched:
        return retileActiveWorkspace(state: &state)

      case .appActivated(let bundleId):
        // Ignore our own re-activations to avoid retile loops.
        if bundleId == "dev.PangMo5.Tatami" || bundleId == "dev.PangMo5.Tatami.dev" {
          return .none
        }
        return retileActiveWorkspace(state: &state)

      case .appTerminated:
        return retileActiveWorkspace(state: &state)

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
        state.$config.withLock { config in
          config.settings.isPaused.toggle()
        }
        return .none

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
        return .none

      case .activationCompleted(let id, let display):
        state.isActivating = false
        if let display, let previous = state.activeWorkspacesByDisplay[display], previous != id {
          state.previousWorkspaceID = previous
        }
        if let display {
          state.activeWorkspacesByDisplay[display] = id
        }
        let bundleIds = state.config.activeProfile?
          .workspaces.first(where: { $0.id == id })?
          .apps.map(\.bundleIdentifier) ?? []
        return .run { [observer = windowObserver] _ in
          await observer.observe(bundleIds)
        }
      }
    }
  }

  /// Re-tile the workspace currently active on the main display.
  /// The tile set is `workspace.apps` + every currently-visible
  /// unassigned + non-floating regular app, joined in that order.
  /// The transient inclusion means apps the user opens ad-hoc (e.g.
  /// KakaoTalk) join the BSP layout without being permanently
  /// written into the workspace.
  ///
  /// The tree is merged with the cached one — windows that are gone
  /// get removed (sibling promotes up), and new windows are inserted
  /// next to the currently-focused window (yabai-style). User-applied
  /// ratios on surviving nodes carry over because we mutate the
  /// cached tree instead of rebuilding from scratch.
  private func retileActiveWorkspace(state: inout State) -> Effect<Action> {
    guard let workspaceId = state.primaryActiveWorkspaceID,
          let workspace = state.config.activeProfile?
            .workspaces.first(where: { $0.id == workspaceId })
    else { return .none }
    let display = workspace.displayHint ?? displays.current()
    let settings = state.config.settings
    let registered = workspace.apps.map(\.bundleIdentifier)
    let registeredSet = Set(registered)
    let allAssigned = Self.everyAssignedBundleId(in: state.config)
    let floatingSet = Set(state.config.floatingApps.map(\.bundleIdentifier))
    let existing = state.tilingTrees[workspaceId]

    // Resolve targets + focused WindowKey synchronously on the main
    // thread so the tree merge sees a stable snapshot.
    let snapshot = MainActor.assumeIsolated {
      () -> (targets: [WindowKey], focused: WindowKey?) in
      let visibleUnassigned = NSWorkspace.shared.runningApplications
        .filter {
          $0.activationPolicy == .regular
            && !$0.isHidden
            && !$0.isTerminated
        }
        .compactMap(\.bundleIdentifier)
        .filter { id in
          !registeredSet.contains(id)
            && !floatingSet.contains(id)
            && !allAssigned.contains(id)
            && id != "dev.PangMo5.Tatami"
            && id != "dev.PangMo5.Tatami.dev"
        }
      let registeredKeys = discoverWindowKeys(forBundleIds: registered)
      let unassignedKeys = discoverWindowKeys(forBundleIds: visibleUnassigned)
      let focused = focusedWindowKey()
      return (registeredKeys + unassignedKeys, focused)
    }

    let mergedTree = Self.mergeTree(
      existing: existing,
      target: snapshot.targets,
      focused: snapshot.focused
    )
    state.tilingTrees[workspaceId] = mergedTree

    guard let tree = mergedTree else { return .none }
    let zoomed = state.zoomedWindow[workspaceId]

    return .run { [tiler = windowTiler] _ in
      let frames = await MainActor.run {
        Self.computeFrames(
          tree: tree,
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
    focused: WindowKey?
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

    // Step 2: insert any window not yet in the tree next to the
    // focused window (or shallowest leaf if focused isn't in target).
    let existingIDs = Set(tree?.windows ?? [])
    let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    for id in target where !existingIDs.contains(id) {
      tree = tree?
        .inserting(id, near: focused, in: unitRect)
        ?? .leaf(id)
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
    let existingTree = state.tilingTrees[workspace.id]
    let zoomed = state.zoomedWindow[workspace.id]

    return .run { [
      mgr = workspaceManager,
      tiler = windowTiler
    ] send in
      await mgr.activate(request)
      let (tree, frames) = await MainActor.run {
        () -> (BSPNode<WindowKey>?, [WindowKey: CGRect]) in
        let keys = discoverWindowKeys(forBundleIds: bundleIds)
        let focused = focusedWindowKey()
        let tree = Self.mergeTree(existing: existingTree, target: keys, focused: focused)
        let frames = Self.computeFrames(
          tree: tree,
          settings: settings,
          targetDisplay: targetDisplay,
          zoomed: zoomed
        )
        return (tree, frames)
      }
      await send(.tilingTreeUpdated(workspaceId: workspaceId, tree: tree))
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

    return .run { [tiler = windowTiler] _ in
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
    }
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

    return .run { [tiler = windowTiler] _ in
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
    }
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
      guard let target = tree.directionalNeighbor(
        of: windowKey,
        direction: direction,
        in: workArea,
        gap: gap
      ) else { return .none }
      tree = tree.swapping(windowKey, target)

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

    return .run { [tiler = windowTiler] _ in
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
    }
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
    return .run { [tiler = windowTiler] _ in
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
    }
  }

  // MARK: - Cycle

  private func cycle(by direction: Int, state: inout State) -> Effect<Action> {
    guard let workspaces = state.config.activeProfile?.workspaces, !workspaces.isEmpty
    else { return .none }
    let currentID = state.activeWorkspacesByDisplay.values.first
      ?? state.primaryActiveWorkspaceID
    let currentIndex = workspaces.firstIndex { $0.id == currentID } ?? -1
    let count = workspaces.count
    let nextIndex = (currentIndex + direction + count) % count
    return .send(.activate(workspaceId: workspaces[nextIndex].id, setFocus: true))
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

