import AppKit
import ComposableArchitecture
import Foundation

extension WorkspaceActivationFeature {
  /// `tree` with its fullscreen-zoomed windows trimmed out — the layout the
  /// user actually sees behind / around the zoom overlay. Mirrors the trim in
  /// `computeFrames` so drag hit-testing reads the rendered frames, not the
  /// raw tree (where a zoomed window still occupies its old slot). Returns nil
  /// when every window is zoomed.
  static func treeTrimmingZoomed(
    _ tree: BSPNode<WindowKey>,
    zoomed: Set<WindowKey>,
  ) -> BSPNode<WindowKey>? {
    let active = zoomed.intersection(Set(tree.windows))
    guard !active.isEmpty else { return tree }
    return tree.removingAll(active)
  }

  /// Mouse-up hands geometry ownership from the target app back to Tatami.
  /// The app can finish its native drag transaction after our first AX write
  /// and restore one of the pre-drop frames, so pointer commits must publish
  /// one complete frame set and keep the visible tree armed until any delayed
  /// presentation change has converged.
  func flushPointerDrivenLayout(
    workspaceId: Workspace.ID,
    state: inout State,
  ) -> Effect<Action> {
    flushLayout(
      workspaceId: workspaceId,
      state: &state,
      forceAllFrames: true,
      monitorsPresentationChanges: true,
    )
  }

  func syncTreeRatio(
    for key: WindowKey,
    frame newFrame: CGRect,
    state: inout State,
  ) -> Effect<Action> {
    guard
      let workspaceId = state.workspaceOwning(key) ?? state.primaryActiveWorkspaceID,
      let workspace = state.config.activeProfile?
        .workspaces[id: workspaceId],
      let tree = state.tilingTrees[workspaceId]
    else { return .none }

    // A fullscreen-zoomed window is rendered at the full work area, not at a
    // tile — dragging its edge isn't a tile resize, so don't rewrite tree
    // ratios from it. Snap it back to its fullscreen frame instead.
    let zoomed = state.fullscreenZoomed[workspaceId] ?? []
    if zoomed.contains(key) {
      return flushPointerDrivenLayout(workspaceId: workspaceId, state: &state)
    }

    let settings = state.config.settings
    // Resize against the block's geometry (composition sub-rect when composed).
    let (_, workArea) = tilingContext(for: workspaceId, state: state)
    let gap = CGFloat(settings.layout.gapInner)

    // The window's currently-tiled frame; compared against the new AX frame
    // to see which edge(s) the user dragged. (1.5 px tolerance also rejects
    // the echo of our own apply.)
    guard let expected = tree.frames(in: workArea, gap: gap)[key] else { return .none }
    let tolerance: CGFloat = 1.5

    // Each dragged edge maps to the nearest ancestor split running along it
    // (its `fence`); set that split's divider to the edge's new position. This
    // resizes against the *right join* — unlike the immediate parent, which
    // controls a single axis and can't express, say, a height change when it
    // happens to be a vertical (left/right) split.
    var newTree = tree
    func adjust(_ direction: BSPDirection, edge: CGFloat) {
      guard
        let fencePath = newTree.fence(of: key, direction: direction, in: workArea, gap: gap),
        case .branch(let branch) = newTree.subtree(at: fencePath)
      else { return }
      let fenceRect = newTree.rect(at: fencePath, in: workArea, gap: gap)
      // `subdivide` lays children out as [first][gap][second]. For a window in
      // the *second* child (the .west / .north fence) the dragged edge is that
      // child's leading edge = divider + gap, so back the gap out to recover
      // the divider position; first-child edges (.east / .south) sit on it.
      let ratio: CGFloat
      switch branch.split {
      case .vertical:
        let total = fenceRect.width - gap
        guard total > 0 else { return }
        let divider = direction == .west ? edge - gap : edge
        ratio = (divider - fenceRect.minX) / total

      case .horizontal:
        let total = fenceRect.height - gap
        guard total > 0 else { return }
        let divider = direction == .north ? edge - gap : edge
        ratio = (divider - fenceRect.minY) / total
      }
      newTree = newTree.updatingRatio(at: fencePath, ratio: ratio)
    }

    if abs(newFrame.minX - expected.minX) > tolerance { adjust(.west, edge: newFrame.minX) }
    if abs(newFrame.maxX - expected.maxX) > tolerance { adjust(.east, edge: newFrame.maxX) }
    if abs(newFrame.minY - expected.minY) > tolerance { adjust(.north, edge: newFrame.minY) }
    if abs(newFrame.maxY - expected.maxY) > tolerance { adjust(.south, edge: newFrame.maxY) }

    guard newTree != tree else { return .none }
    state.tilingTrees[workspaceId] = newTree

    return .merge(
      flushPointerDrivenLayout(workspaceId: workspaceId, state: &state),
      persist(
        newTree,
        fullscreenZoomed: zoomed,
        unresolvedFullscreenZoomSlots:
        state.unresolvedFullscreenZoomSlots[workspaceId] ?? [],
        for: workspace,
      ),
    )
  }

  /// AX reported the user moved `key` to `frame`. Inspect the drop
  /// quadrant relative to the target tile:
  ///   * center → swap (or stack, future config)
  ///   * top triangle → warp to top child (SPLIT_X, CHILD_FIRST)
  ///   * right triangle → warp to right child (SPLIT_Y, CHILD_SECOND)
  ///   * bottom triangle → warp to bottom child (SPLIT_X, CHILD_SECOND)
  ///   * left triangle → warp to left child (SPLIT_Y, CHILD_FIRST)
  /// Either way the layout is reapplied, yanking the dragged window
  /// back to its real tile slot.
  /// Live, cursor-based drop decision for a window being dragged: which tile
  /// the cursor is over and which region of it (→ swap or directional
  /// insert). Returns nil when the cursor isn't over another tile. Used both
  /// to drive the overlay and — frozen into `pendingDrop` — to commit on
  /// mouse-up, so preview and result always agree.
  func dropDecision(
    dragged: WindowKey,
    state: State,
  ) -> (target: WindowKey, targetRect: CGRect, zone: DropZone)? {
    // Resolve the dragged window's owning block; the drop target is searched
    // within that one tree, so a drop can't cross the workspace boundary.
    guard
      let workspaceId = state.workspaceOwning(dragged) ?? state.primaryActiveWorkspaceID,
      let tree = state.tilingTrees[workspaceId],
      tree.pathTo(window: dragged) != nil
    else { return nil }

    let zoomed = state.fullscreenZoomed[workspaceId] ?? []
    // Dragging a fullscreen-zoomed window: it owns the whole work area, so
    // there's no tile-level drop target — and the tiles hidden behind it must
    // not light up an overlay.
    if zoomed.contains(dragged) { return nil }

    let settings = state.config.settings
    let (_, workArea) = tilingContext(for: workspaceId, state: state)
    // Cursor in AX top-left coords (matches `frames` / `workArea`).
    let cursor = mouse.axLocation()

    // Hit-test against the frames the user actually sees: fullscreen-zoomed
    // windows are trimmed (the rest reshape around them, exactly as
    // `computeFrames` renders), so a zoomed window's stale tile slot never
    // becomes a drop target for another window's drag.
    guard let visible = Self.treeTrimmingZoomed(tree, zoomed: zoomed) else { return nil }
    let allFrames = visible.frames(in: workArea, gap: CGFloat(settings.layout.gapInner))
    guard
      let target = allFrames.first(where: { other, rect in
        other != dragged && rect.contains(cursor)
      })?.key,
      let targetRect = allFrames[target]
    else { return nil }

    guard let zone = DropZone.quadrant(point: cursor, in: targetRect) else { return nil }
    return (target, targetRect, zone)
  }

  /// Commit a frozen drop decision: swap the two windows in place, or warp
  /// the dragged one into the chosen side of the target. Re-tiles + persists.
  func applyDrop(
    _ drop: State.PendingDrop,
    state: inout State,
  ) -> Effect<Action> {
    // Both windows must live in the same block's tree — the drop decision was
    // made within one tree, so a cross-boundary drop never reaches here.
    guard
      let workspaceId = state.workspaceOwning(drop.dragged) ?? state.primaryActiveWorkspaceID,
      let workspace = state.config.activeProfile?
        .workspaces[id: workspaceId],
      let tree = state.tilingTrees[workspaceId],
      tree.pathTo(window: drop.dragged) != nil,
      tree.pathTo(window: drop.target) != nil
    else { return .none }

    let newTree: BSPNode<WindowKey> =
      switch drop.zone {
      case .swap:
        tree.swapping(drop.dragged, drop.target)
      case .top:
        tree.warpingInto(source: drop.dragged, target: drop.target, axis: .horizontal, child: .first)
      case .right:
        tree.warpingInto(source: drop.dragged, target: drop.target, axis: .vertical, child: .second)
      case .bottom:
        tree.warpingInto(source: drop.dragged, target: drop.target, axis: .horizontal, child: .second)
      case .left:
        tree.warpingInto(source: drop.dragged, target: drop.target, axis: .vertical, child: .first)
      }
    state.tilingTrees[workspaceId] = newTree
    let zoomed = state.fullscreenZoomed[workspaceId] ?? []

    return .merge(
      flushPointerDrivenLayout(workspaceId: workspaceId, state: &state),
      persist(
        newTree,
        fullscreenZoomed: zoomed,
        unresolvedFullscreenZoomSlots:
        state.unresolvedFullscreenZoomSlots[workspaceId] ?? [],
        for: workspace,
      ),
    )
  }
}
