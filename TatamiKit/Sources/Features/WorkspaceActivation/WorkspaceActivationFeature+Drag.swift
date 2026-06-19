import AppKit
import ComposableArchitecture
import Foundation

extension WorkspaceActivationFeature {
  // MARK: - Manual resize / snap-back

  func syncTreeRatio(
    for key: WindowKey,
    frame newFrame: CGRect,
    state: inout State
  ) -> Effect<Action> {
    guard let workspaceId = state.workspaceOwning(key) ?? state.primaryActiveWorkspaceID,
          let workspace = state.config.activeProfile?
            .workspaces[id: workspaceId],
          let tree = state.tilingTrees[workspaceId]
    else { return .none }

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
      guard let fencePath = newTree.fence(of: key, direction: direction, in: workArea, gap: gap),
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
    let zoomed = state.fullscreenZoomed[workspaceId] ?? []

    return .merge(
      flushLayout(workspaceId: workspaceId, state: state),
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
  /// Live, cursor-based drop decision for a window being dragged: which tile
  /// the cursor is over and which region of it (→ swap or directional
  /// insert). Returns nil when the cursor isn't over another tile. Used both
  /// to drive the overlay and — frozen into `pendingDrop` — to commit on
  /// mouse-up, so preview and result always agree.
  func dropDecision(
    dragged: WindowKey,
    state: State
  ) -> (target: WindowKey, targetRect: CGRect, zone: DropZone)? {
    // Resolve the dragged window's owning block; the drop target is searched
    // within that one tree, so a drop can't cross the workspace boundary.
    guard let workspaceId = state.workspaceOwning(dragged) ?? state.primaryActiveWorkspaceID,
          let tree = state.tilingTrees[workspaceId],
          tree.pathTo(window: dragged) != nil
    else { return nil }

    let settings = state.config.settings
    let (_, workArea) = tilingContext(for: workspaceId, state: state)
    // Cursor in AX top-left coords (matches `frames` / `workArea`).
    let cursor = mouse.axLocation()

    let allFrames = tree.frames(in: workArea, gap: CGFloat(settings.layout.gapInner))
    guard let target = allFrames.first(where: { other, rect in
            other != dragged && rect.contains(cursor)
          })?.key,
          let targetRect = allFrames[target]
    else { return nil }

    switch dropQuadrant(point: cursor, in: targetRect) {
    case .none: return nil
    case .center: return (target, targetRect, .swap)
    case .top: return (target, targetRect, .top)
    case .right: return (target, targetRect, .right)
    case .bottom: return (target, targetRect, .bottom)
    case .left: return (target, targetRect, .left)
    }
  }

  /// Commit a frozen drop decision: swap the two windows in place, or warp
  /// the dragged one into the chosen side of the target. Re-tiles + persists.
  func applyDrop(
    _ drop: State.PendingDrop,
    state: inout State
  ) -> Effect<Action> {
    // Both windows must live in the same block's tree — the drop decision was
    // made within one tree, so a cross-boundary drop never reaches here.
    guard let workspaceId = state.workspaceOwning(drop.dragged) ?? state.primaryActiveWorkspaceID,
          let workspace = state.config.activeProfile?
            .workspaces[id: workspaceId],
          let tree = state.tilingTrees[workspaceId],
          tree.pathTo(window: drop.dragged) != nil,
          tree.pathTo(window: drop.target) != nil
    else { return .none }

    let settings = state.config.settings
    let newTree: BSPNode<WindowKey>
    switch drop.zone {
    case .swap:
      newTree = tree.swapping(drop.dragged, drop.target)
    case .top:
      newTree = warpInto(tree: tree, source: drop.dragged, target: drop.target, axis: .horizontal, child: .first)
    case .right:
      newTree = warpInto(tree: tree, source: drop.dragged, target: drop.target, axis: .vertical, child: .second)
    case .bottom:
      newTree = warpInto(tree: tree, source: drop.dragged, target: drop.target, axis: .horizontal, child: .second)
    case .left:
      newTree = warpInto(tree: tree, source: drop.dragged, target: drop.target, axis: .vertical, child: .first)
    }
    state.tilingTrees[workspaceId] = newTree
    let zoomed = state.fullscreenZoomed[workspaceId] ?? []

    return .merge(
      flushLayout(workspaceId: workspaceId, state: state),
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
    // Coordinates are AX top-left (y grows downward), so the *top* triangle
    // is the small-y one, `(false, false)`, and the bottom is `(true, true)`.
    switch (onAboveDownDiag, onAboveUpDiag) {
    case (false, false): return .top
    case (false, true):  return .right
    case (true, true):   return .bottom
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
    let seeded = tree.replacing(path: targetPath) { node in
      guard case .leaf(var leaf) = node else { return node }
      leaf.preferredSplit = axis
      leaf.preferredChild = child
      return .leaf(leaf)
    }
    guard let removed = seeded.removing(source) else { return tree }
    return removed.inserting(source, near: target, in: CGRect(x: 0, y: 0, width: 1, height: 1))
  }
}
