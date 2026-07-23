import DequeModule
import Foundation

/// Pure value-typed Binary Space Partitioning tree.
///
/// Value-typed so the TCA reducer can own the tree without aliasing.
/// Shape:
///
///   * each **leaf** carries a stack of window ids (`windowList` =
///     in-place order, `windowOrder` = focus recency) plus the user's
///     intended insertion settings on this leaf (`insertDirection`,
///     `preferredChild`, `preferredSplit`) and a parent-zoom flag.
///   * each **branch** carries a split axis, a ratio, an optional child
///     override, and its two children.
///   * insertion picks the **shallowest** leaf (BFS) when no explicit
///     `insertionPoint` is set. No spiral/deepest-leaf fallback.
///   * removing a window collapses the surviving sibling into the
///     parent's slot.
///   * **parent-zoom** is per-leaf: the leaf renders at its parent
///     branch's full area, hiding its sibling but keeping the tree
///     intact. Only one window's parent-zoom is meaningful per
///     subtree.
///   * **fullscreen-zoom** is *not* part of the tree; the activation
///     reducer keeps a separate `Set<WindowKey>` per workspace and
///     trims those windows out of the tree before layout. Several
///     fullscreen-zoomed windows can coexist, each filling the work
///     area, and the rest of the tree lays out as if those windows
///     weren't present.
public indirect enum BSPNode<WindowID: Hashable & Sendable>: Hashable, Sendable {
  case leaf(BSPLeaf<WindowID>)
  case branch(BSPBranch<WindowID>)

  // The metadata enums live at the top level (below) — nesting them in
  // the generic made `BSPNode<String>.SplitAxis` and
  // `BSPNode<WindowKey>.SplitAxis` distinct types, forcing rawValue
  // bridges (with fake `?? .vertical` fallbacks) through `hydrate` and
  // `mapWindows`. The aliases keep the familiar qualified spelling.
  public typealias SplitAxis = BSPSplitAxis
  public typealias Side = BSPSide
  public typealias Child = BSPChild
  public typealias InsertDirection = BSPInsertDirection
}

/// Axis along which a branch divides its rectangle.
public enum BSPSplitAxis: String, Sendable, Hashable, Codable {
  /// Cut horizontally — children stack top/bottom.
  case horizontal
  /// Cut vertically — children sit side-by-side.
  case vertical
}

/// Which side of a branch a child sits on. Path component used by
/// the recursive update helpers.
public enum BSPSide: Sendable, Hashable { case left, right }

/// `first` = the existing window stays in the left/top slot and the
/// new window goes right/bottom. `second` reverses it.
public enum BSPChild: String, Sendable, Hashable, Codable {
  case first, second
}

/// Pre-set intent on a leaf: "the next window I insert should split
/// this leaf in this direction (or stack on top of it)". `.stack`
/// means: don't split, push the new window onto this leaf's stack.
public enum BSPInsertDirection: String, Sendable, Hashable, Codable {
  case north, east, south, west, stack
}

/// One BSP leaf — the value payload at the tree's terminals.
public struct BSPLeaf<WindowID: Hashable & Sendable>: Hashable, Sendable {
  /// Geometric/visual order of the stack (windowList[0] is the bottom
  /// of the stack, .last is the most recently inserted). Length 1
  /// for the common, non-stacked case.
  public var windowList: [WindowID]
  /// Focus order — `windowOrder[0]` is the most recently focused.
  /// Used for swap/warp tiebreaks and stack navigation.
  public var windowOrder: [WindowID]
  /// User-set insertion intent on this leaf. nil = no override.
  public var insertDirection: BSPNode<WindowID>.InsertDirection?
  /// Child-side override consumed on the next split of this leaf.
  public var preferredChild: BSPNode<WindowID>.Child?
  /// Split-axis override consumed on the next split of this leaf.
  public var preferredSplit: BSPNode<WindowID>.SplitAxis?
  /// When true, this leaf renders at its parent branch's full area
  /// (single-tile parent-zoom). Caller resets it when the sibling
  /// structure changes.
  public var parentZoom: Bool

  public init(
    windowList: [WindowID],
    windowOrder: [WindowID]? = nil,
    insertDirection: BSPNode<WindowID>.InsertDirection? = nil,
    preferredChild: BSPNode<WindowID>.Child? = nil,
    preferredSplit: BSPNode<WindowID>.SplitAxis? = nil,
    parentZoom: Bool = false
  ) {
    self.windowList = windowList
    self.windowOrder = windowOrder ?? windowList
    self.insertDirection = insertDirection
    self.preferredChild = preferredChild
    self.preferredSplit = preferredSplit
    self.parentZoom = parentZoom
  }

  /// True when this leaf participates in a stack (more than one window
  /// occupies the same area).
  public var isStack: Bool { windowList.count > 1 }

  /// Top-of-focus window — `windowOrder[0]` if present, else the first
  /// element of `windowList`.
  public var topWindow: WindowID? {
    windowOrder.first ?? windowList.first
  }

  public func contains(_ id: WindowID) -> Bool {
    windowList.contains(id)
  }
}

/// One BSP branch — the internal node holding a split + two children.
public struct BSPBranch<WindowID: Hashable & Sendable>: Hashable, Sendable {
  public var split: BSPNode<WindowID>.SplitAxis
  public var ratio: CGFloat
  /// Child-side override consumed on the next split rooted at this
  /// branch. Rarely used — typically only set when warp/stack ops
  /// rewrite the parent.
  public var preferredChild: BSPNode<WindowID>.Child?
  public var left: BSPNode<WindowID>
  public var right: BSPNode<WindowID>

  public init(
    split: BSPNode<WindowID>.SplitAxis,
    ratio: CGFloat,
    preferredChild: BSPNode<WindowID>.Child? = nil,
    left: BSPNode<WindowID>,
    right: BSPNode<WindowID>
  ) {
    self.split = split
    self.ratio = ratio
    self.preferredChild = preferredChild
    self.left = left
    self.right = right
  }
}

extension BSPLeaf: Codable where WindowID: Codable {}
extension BSPBranch: Codable where WindowID: Codable {}
extension BSPNode: Codable where WindowID: Codable {}

extension BSPBranch {
  /// Copy with selected fields replaced. Every tree transform rebuilds a
  /// branch around one or two changed fields — spelling out all five at
  /// each site buried the actual change in boilerplate.
  func with(
    split: BSPSplitAxis? = nil,
    ratio: CGFloat? = nil,
    left: BSPNode<WindowID>? = nil,
    right: BSPNode<WindowID>? = nil
  ) -> BSPBranch {
    BSPBranch(
      split: split ?? self.split,
      ratio: ratio ?? self.ratio,
      preferredChild: preferredChild,
      left: left ?? self.left,
      right: right ?? self.right
    )
  }
}

// MARK: - Convenience constructors

extension BSPNode {
  /// Single-window leaf shorthand for tests / one-shot tree builds.
  public static func leaf(_ id: WindowID) -> BSPNode {
    .leaf(BSPLeaf(windowList: [id]))
  }
}

// MARK: - Hydrate (persistent → live)

extension BSPNode where WindowID == WindowKey {
  /// Rebuild a live tree from a persisted `SlotID` `template`, matching each
  /// slot against the live window that holds it — the Nth window of that app by
  /// `windowID` ascending (see `slotToKey`). Leaves whose slot has no matching
  /// live window collapse (sibling promotes), so a saved layout gracefully
  /// degrades when an app isn't running. Leaf metadata (insertDirection,
  /// preferredChild, preferredSplit, parentZoom) is preserved. Windows present
  /// in `keys` but absent from the template are NOT added here — the caller
  /// folds those in via the normal merge/insert path afterward.
  ///
  /// Unlike the old bundle-id template, matching is by `SlotID` (windowID rank),
  /// not a positional FIFO queue, so two windows of one app land in the exact
  /// slots the layout recorded rather than in Accessibility-enumeration order.
  public static func hydrate(
    template: BSPNode<SlotID>,
    keys: [WindowKey]
  ) -> BSPNode<WindowKey>? {
    let keyForSlot = slotToKey(keys)
    func build(_ node: BSPNode<SlotID>) -> BSPNode<WindowKey>? {
      switch node {
      case .leaf(let slotLeaf):
        var hydratedList: [WindowKey] = []
        for slot in slotLeaf.windowList {
          guard let key = keyForSlot[slot] else { continue }
          hydratedList.append(key)
        }
        guard !hydratedList.isEmpty else { return nil }
        var hydratedOrder: [WindowKey] = []
        for slot in slotLeaf.windowOrder {
          if let key = keyForSlot[slot], !hydratedOrder.contains(key) {
            hydratedOrder.append(key)
          }
        }
        for key in hydratedList where !hydratedOrder.contains(key) {
          hydratedOrder.append(key)
        }
        let leaf = BSPLeaf<WindowKey>(
          windowList: hydratedList,
          windowOrder: hydratedOrder,
          insertDirection: slotLeaf.insertDirection,
          preferredChild: slotLeaf.preferredChild,
          preferredSplit: slotLeaf.preferredSplit,
          parentZoom: slotLeaf.parentZoom
        )
        return .leaf(leaf)
      case .branch(let slotBranch):
        let l = build(slotBranch.left)
        let r = build(slotBranch.right)
        switch (l, r) {
        case (nil, nil): return nil
        case (let l?, nil): return l
        case (nil, let r?): return r
        case (let l?, let r?):
          return .branch(BSPBranch(
            split: slotBranch.split,
            ratio: slotBranch.ratio,
            preferredChild: slotBranch.preferredChild,
            left: l,
            right: r
          ))
        }
      }
    }
    return build(template)
  }
}

extension BSPNode {
  /// Rebuild the tree with each leaf's window ids transformed by `f`,
  /// preserving every leaf-stack, split axis, ratio, and leaf metadata.
  /// Used to convert a live `BSPNode<WindowKey>` into a serializable
  /// `BSPNode<String>` for persistent layout snapshots.
  public func mapWindows<T: Hashable & Sendable>(
    _ f: (WindowID) -> T
  ) -> BSPNode<T> {
    switch self {
    case .leaf(let leaf):
      return .leaf(BSPLeaf<T>(
        windowList: leaf.windowList.map(f),
        windowOrder: leaf.windowOrder.map(f),
        insertDirection: leaf.insertDirection,
        preferredChild: leaf.preferredChild,
        preferredSplit: leaf.preferredSplit,
        parentZoom: leaf.parentZoom
      ))
    case .branch(let branch):
      return .branch(BSPBranch<T>(
        split: branch.split,
        ratio: branch.ratio,
        preferredChild: branch.preferredChild,
        left: branch.left.mapWindows(f),
        right: branch.right.mapWindows(f)
      ))
    }
  }
}

// MARK: - Inspection

extension BSPNode {
  /// All window ids in tree order. Stacks expand by `windowList` order.
  public var windows: [WindowID] {
    var out: [WindowID] = []
    appendWindows(into: &out)
    return out
  }

  /// Append tree-order window ids into a shared buffer — avoids the
  /// per-branch `left.windows + right.windows` concatenation that
  /// reallocated a fresh array at every node on a full walk.
  private func appendWindows(into out: inout [WindowID]) {
    switch self {
    case .leaf(let leaf): out.append(contentsOf: leaf.windowList)
    case .branch(let b):
      b.left.appendWindows(into: &out)
      b.right.appendWindows(into: &out)
    }
  }

  /// Number of leaves (not windows). Used by `balanced(axis:)` to weigh
  /// each subtree by structural depth.
  public var leafCount: Int {
    switch self {
    case .leaf: 1
    case .branch(let b): b.left.leafCount + b.right.leafCount
    }
  }

  /// Path of left/right turns from the root to the leaf containing
  /// `window`, or `nil` if it isn't in the tree.
  public func pathTo(window: WindowID) -> [Side]? {
    switch self {
    case .leaf(let leaf):
      return leaf.contains(window) ? [] : nil
    case .branch(let b):
      if let l = b.left.pathTo(window: window) { return [.left] + l }
      if let r = b.right.pathTo(window: window) { return [.right] + r }
      return nil
    }
  }

  /// Subtree at the given path. Returns `self` if the path runs past
  /// a leaf.
  public func subtree(at path: [Side]) -> BSPNode {
    var current = self
    for side in path {
      guard case .branch(let b) = current else { return current }
      current = side == .left ? b.left : b.right
    }
    return current
  }

  /// Rect of the subtree at `path` after subdividing `workArea` along
  /// the same splits that `frames(in:gap:)` walks. Used by the resize
  /// sync to translate an AX frame back into a parent split's ratio.
  public func rect(at path: [Side], in workArea: CGRect, gap: CGFloat) -> CGRect {
    var rect = workArea
    var node = self
    for side in path {
      guard case .branch(let b) = node else { return rect }
      let (l, r) = b.split.subdivide(rect, ratio: b.ratio, gap: gap)
      rect = side == .left ? l : r
      node = side == .left ? b.left : b.right
    }
    return rect
  }
}

// MARK: - Build

extension BSPNode {
  /// Build a tree from a sequence of windows in order. Uses the same
  /// insertion policy as live edits so the tree shape stays
  /// deterministic across runs.
  public static func build(
    _ windows: [WindowID],
    in rect: CGRect,
    defaultRatio: CGFloat = 0.5
  ) -> BSPNode? {
    var tree: BSPNode? = nil
    for window in windows {
      if let current = tree {
        tree = current.inserting(window, in: rect, defaultRatio: defaultRatio)
      } else {
        tree = .leaf(window)
      }
    }
    return tree
  }
}

// MARK: - Insertion

extension BSPNode {
  /// Insert `window` into the tree. Selection rule:
  ///
  ///   1. an explicit `near` window — if it resolves to a leaf, that
  ///      leaf is the target (the sticky workspace insertion point).
  ///   2. otherwise the shallowest leaf (BFS).
  ///
  /// If the target leaf carries `insertDirection == .stack`, the new
  /// window joins that leaf's stack instead of splitting. Otherwise the
  /// leaf is split: axis chosen from `preferredSplit ?? viewSplitType
  /// ?? aspect`, and child placement from `preferredChild ??
  /// globalPlacement`.
  public func inserting(
    _ window: WindowID,
    near anchor: WindowID? = nil,
    in rect: CGRect,
    defaultRatio: CGFloat = 0.5,
    viewSplitType: SplitAxis? = nil,
    globalPlacement: Child = .second
  ) -> BSPNode {
    let info = leafInfos(currentRect: rect)
    let target: LeafInfoT? = {
      if let anchor,
         let hit = info.first(where: { leaf in
           if case .leaf(let l) = self.subtree(at: leaf.path) { return l.contains(anchor) }
           return false
         })
      {
        return hit
      }
      return info.min(by: { $0.depth < $1.depth })
    }()
    guard let target else { return .leaf(window) }
    return replacing(path: target.path) { node in
      guard case .leaf(var leaf) = node else { return node }
      if leaf.insertDirection == .stack {
        leaf.windowList.append(window)
        leaf.windowOrder.insert(window, at: 0)
        leaf.insertDirection = nil
        leaf.preferredChild = nil
        leaf.preferredSplit = nil
        return .leaf(leaf)
      }
      let axis: SplitAxis = {
        if let s = leaf.preferredSplit { return s }
        if let s = viewSplitType { return s }
        return target.rect.width >= target.rect.height ? .vertical : .horizontal
      }()
      let placement: Child = leaf.preferredChild ?? globalPlacement
      // `placement = .first` → new window on the left/top, existing
      // leaf on the right/bottom.
      var oldLeaf = leaf
      oldLeaf.insertDirection = nil
      oldLeaf.preferredChild = nil
      oldLeaf.preferredSplit = nil
      // Parent-zoom is *per-leaf*; on a split it stays with the old
      // leaf only — the new leaf starts un-zoomed.
      let newLeaf = BSPLeaf<WindowID>(windowList: [window])
      let (l, r): (BSPNode, BSPNode) = placement == .first
        ? (.leaf(newLeaf), .leaf(oldLeaf))
        : (.leaf(oldLeaf), .leaf(newLeaf))
      return .branch(BSPBranch(
        split: axis,
        ratio: defaultRatio,
        preferredChild: nil,
        left: l,
        right: r
      ))
    }
  }

}

// MARK: - Removal

extension BSPNode {
  /// Remove `window`. If it was part of a stacked leaf, only that entry
  /// is dropped (leaf survives). If it was the sole occupant of a leaf,
  /// the leaf collapses and its sibling promotes into the parent's slot.
  /// Returns nil only when removing the very last window in the tree.
  public func removing(_ window: WindowID) -> BSPNode? {
    switch self {
    case .leaf(var leaf):
      guard leaf.contains(window) else { return self }
      leaf.windowList.removeAll { $0 == window }
      leaf.windowOrder.removeAll { $0 == window }
      return leaf.windowList.isEmpty ? nil : .leaf(leaf)
    case .branch(let b):
      let newLeft = b.left.removing(window)
      let newRight = b.right.removing(window)
      switch (newLeft, newRight) {
      case (nil, let r?): return r
      case (let l?, nil): return l
      case (let l?, let r?):
        return .branch(b.with(left: l, right: r))
      case (nil, nil):
        return nil
      }
    }
  }
}

// MARK: - Swap / warp / split toggle

extension BSPNode {
  /// Swap positions of two windows. If they live in the same leaf,
  /// only their stack indices change. Otherwise the leaf payloads are
  /// exchanged wholesale (stacks travel together).
  public func swapping(_ a: WindowID, _ b: WindowID) -> BSPNode {
    guard a != b else { return self }
    switch self {
    case .leaf(var leaf):
      guard leaf.contains(a) || leaf.contains(b) else { return self }
      func swap(in xs: inout [WindowID]) {
        guard let ia = xs.firstIndex(of: a), let ib = xs.firstIndex(of: b) else { return }
        xs.swapAt(ia, ib)
      }
      swap(in: &leaf.windowList)
      swap(in: &leaf.windowOrder)
      return .leaf(leaf)
    case .branch(let br):
      // Find a's and b's enclosing leaves.
      guard let pa = pathTo(window: a), let pb = pathTo(window: b) else { return self }
      if pa == pb {
        return replacing(path: pa) { $0.swapping(a, b) }
      }
      // Different leaves: exchange their windowList + windowOrder
      // wholesale. Stacks travel together.
      guard case .leaf(let leafA) = subtree(at: pa),
            case .leaf(let leafB) = subtree(at: pb)
      else { return self }
      var newA = leafA
      newA.windowList = leafB.windowList
      newA.windowOrder = leafB.windowOrder
      var newB = leafB
      newB.windowList = leafA.windowList
      newB.windowOrder = leafA.windowOrder
      // Parent-zoom is locality-specific (it refers to the *position*
      // in the tree, not the window itself) — clear on the moved leaves
      // so a swap doesn't accidentally fullscreen the destination tile.
      newA.parentZoom = false
      newB.parentZoom = false
      _ = br
      let withA = replacing(path: pa) { _ in .leaf(newA) }
      return withA.replacing(path: pb) { _ in .leaf(newB) }
    }
  }

  /// Reorient `window`'s parent split so the window moves in
  /// `direction` (no neighbor existed to swap with). Two side-by-side
  /// windows + warp-down become stacked with the moved window on the
  /// bottom. No-op if `window` is the root leaf.
  public func warping(_ window: WindowID, direction: BSPDirection) -> BSPNode {
    guard let path = pathTo(window: window), let side = path.last else { return self }
    let parentPath = Array(path.dropLast())
    let desiredAxis: SplitAxis =
      (direction == .east || direction == .west) ? .vertical : .horizontal
    let desiredSide: Side = (direction == .west || direction == .north) ? .left : .right
    return replacing(path: parentPath) { node in
      guard case .branch(let b) = node else { return node }
      let windowChild = side == .left ? b.left : b.right
      let siblingChild = side == .left ? b.right : b.left
      let newLeft = desiredSide == .left ? windowChild : siblingChild
      let newRight = desiredSide == .left ? siblingChild : windowChild
      let newRatio = (desiredSide == side) ? b.ratio : 1 - b.ratio
      return .branch(b.with(split: desiredAxis, ratio: newRatio, left: newLeft, right: newRight))
    }
  }

  /// Apply Tatami's directional swap contract: exchange with a geometric
  /// neighbour when one exists; at an outer edge, rotate/reorder the focused
  /// window's parent split toward the requested direction instead. The live
  /// reducer and safe previews share this entry point so edge warps cannot
  /// drift into a preview-only swap rule.
  public func applyingDirectionalSwap(
    window: WindowID,
    direction: BSPDirection,
    in workArea: CGRect,
    gap: CGFloat,
    focusOrder: [WindowID] = []
  ) -> BSPNode {
    if
      let target = directionalNeighbor(
        of: window,
        direction: direction,
        in: workArea,
        gap: gap,
        focusOrder: focusOrder,
      )
    {
      return swapping(window, target)
    }
    return warping(window, direction: direction)
  }

  /// Flip the parent split axis of `window`. No-op if `window` is at
  /// the root.
  public func togglingSplit(at window: WindowID) -> BSPNode {
    guard let path = pathTo(window: window), !path.isEmpty else { return self }
    let parentPath = Array(path.dropLast())
    return replacing(path: parentPath) { node in
      guard case .branch(let b) = node else { return node }
      let flipped: SplitAxis = b.split == .horizontal ? .vertical : .horizontal
      return .branch(b.with(split: flipped))
    }
  }
}

// MARK: - Resize / fence

extension BSPNode {
  /// Adjust the ratio at the nearest ancestor of `window` whose split
  /// axis matches `axis`. Positive `delta` always means "grow the
  /// focused window": the sign is flipped when the focused leaf sits on
  /// the right/bottom side of the ancestor split. Result clamped to
  /// `[0.1, 0.9]`.
  public func resizing(
    window: WindowID,
    axis: SplitAxis,
    delta: CGFloat
  ) -> BSPNode {
    guard let path = pathTo(window: window) else { return self }
    guard let ancestorPath = nearestAncestor(matching: axis, on: path) else { return self }
    let sideIntoAncestor = path[ancestorPath.count]
    let signedDelta = sideIntoAncestor == .left ? delta : -delta
    return replacing(path: ancestorPath) { node in
      guard case .branch(let b) = node else { return node }
      let newRatio = max(0.1, min(0.9, b.ratio + signedDelta))
      return .branch(b.with(ratio: newRatio))
    }
  }

  /// Grow or shrink the focused window along the axis implied by a compass
  /// direction. Positive deltas always grow the focused side; negative deltas
  /// shrink it, regardless of which child owns the window.
  public func resizing(
    window: WindowID,
    direction: BSPDirection,
    delta: CGFloat
  ) -> BSPNode {
    let axis: SplitAxis =
      (direction == .east || direction == .west) ? .vertical : .horizontal
    return resizing(window: window, axis: axis, delta: delta)
  }

  /// Update the split ratio at `path`. Clamps to `[0.1, 0.9]`. No-op if
  /// the path lands on a leaf.
  public func updatingRatio(at path: [Side], ratio: CGFloat) -> BSPNode {
    replacing(path: path) { node in
      guard case .branch(let b) = node else { return node }
      return .branch(b.with(ratio: max(0.1, min(0.9, ratio))))
    }
  }

  /// Path to the nearest ancestor of `window` whose split axis matches
  /// `direction`'s axis and which actually extends past `window` in
  /// that direction. Returns nil when no such ancestor exists (the
  /// window is already at the workspace edge). Used by resize so we
  /// nudge the right join rather than the immediate parent.
  public func fence(
    of window: WindowID,
    direction: BSPDirection,
    in workArea: CGRect,
    gap: CGFloat
  ) -> [Side]? {
    guard let path = pathTo(window: window) else { return nil }
    let windowRect = rect(at: path, in: workArea, gap: gap)
    let targetAxis: SplitAxis = (direction == .east || direction == .west)
      ? .vertical
      : .horizontal
    // Walk from the root toward the leaf, keeping the deepest ancestor
    // whose area extends past the window in the requested direction.
    var bestPath: [Side]?
    for i in (0..<path.count).reversed() {
      let candidatePath = Array(path.prefix(i))
      let candidateRect = rect(at: candidatePath, in: workArea, gap: gap)
      guard case .branch(let b) = subtree(at: candidatePath),
            b.split == targetAxis
      else { continue }
      let extendsPast: Bool = {
        switch direction {
        case .north: return candidateRect.minY < windowRect.minY
        case .south: return candidateRect.maxY > windowRect.maxY
        case .west:  return candidateRect.minX < windowRect.minX
        case .east:  return candidateRect.maxX > windowRect.maxX
        }
      }()
      if extendsPast {
        bestPath = candidatePath
        break
      }
    }
    return bestPath
  }
}

// MARK: - Balance / rotate / mirror

extension BSPNode {
  /// Equalize every split per axis so child sizes match the number of
  /// leaves they contain. `.none` is a no-op. `.both` does both axes.
  /// Takes the user preference (`AutoBalanceMode`) directly — a separate
  /// axis enum here was a case-for-case copy plus a hand-written mapper.
  public func balanced(axis: AutoBalanceMode = .both) -> BSPNode {
    switch self {
    case .leaf:
      return self
    case .branch(let b):
      let bl = b.left.balanced(axis: axis)
      let br = b.right.balanced(axis: axis)
      let lc = bl.leafCount
      let rc = br.leafCount
      let total = lc + rc
      let shouldBalance: Bool = {
        switch axis {
        case .none: return false
        case .both: return true
        case .horizontal: return b.split == .horizontal
        case .vertical:   return b.split == .vertical
        }
      }()
      let ratio = (!shouldBalance || total == 0)
        ? b.ratio
        : CGFloat(lc) / CGFloat(total)
      return .branch(b.with(ratio: max(0.1, min(0.9, ratio)), left: bl, right: br))
    }
  }

  /// Rotate the entire tree clockwise by 90 / 180 / 270 degrees.
  public func rotated(by degrees: Int) -> BSPNode {
    let d = ((degrees % 360) + 360) % 360
    switch self {
    case .leaf:
      return self
    case .branch(let b):
      let shouldSwap =
        (d == 90 && b.split == .vertical)
        || (d == 270 && b.split == .horizontal)
        || d == 180
      let newLeft = shouldSwap ? b.right : b.left
      let newRight = shouldSwap ? b.left : b.right
      let newRatio = shouldSwap ? 1 - b.ratio : b.ratio
      let newSplit: SplitAxis = d == 180
        ? b.split
        : (b.split == .horizontal ? .vertical : .horizontal)
      return .branch(b.with(
        split: newSplit, ratio: newRatio,
        left: newLeft.rotated(by: d), right: newRight.rotated(by: d)
      ))
    }
  }

  /// Mirror the tree along `axis`. Splits matching `axis` swap children
  /// and invert their ratio; splits on the orthogonal axis are
  /// unchanged.
  public func mirrored(axis: SplitAxis) -> BSPNode {
    switch self {
    case .leaf:
      return self
    case .branch(let b):
      if b.split == axis {
        return .branch(b.with(
          ratio: 1 - b.ratio,
          left: b.right.mirrored(axis: axis),
          right: b.left.mirrored(axis: axis)
        ))
      } else {
        return .branch(b.with(
          left: b.left.mirrored(axis: axis),
          right: b.right.mirrored(axis: axis)
        ))
      }
    }
  }
}

// MARK: - Frames

extension BSPNode {
  /// Resolve every window's frame given the work-area rect and the
  /// inner gap. Parent-zoom leaves render at their parent branch's
  /// rect (filling the sibling slot as well). Stack leaves emit the
  /// same rect for every stacked window.
  public func frames(in rect: CGRect, gap: CGFloat) -> [WindowID: CGRect] {
    var out: [WindowID: CGRect] = [:]
    layout(into: &out, rect: rect, parentRect: rect, gap: gap)
    return out
  }

  private func layout(
    into out: inout [WindowID: CGRect],
    rect: CGRect,
    parentRect: CGRect,
    gap: CGFloat
  ) {
    switch self {
    case .leaf(let leaf):
      let area = leaf.parentZoom ? parentRect : rect
      for id in leaf.windowList {
        out[id] = area.integral
      }
    case .branch(let b):
      let (lRect, rRect) = b.split.subdivide(rect, ratio: b.ratio, gap: gap)
      b.left.layout(into: &out, rect: lRect, parentRect: rect, gap: gap)
      b.right.layout(into: &out, rect: rRect, parentRect: rect, gap: gap)
    }
  }
}

// MARK: - Leaf metadata mutation

extension BSPNode {
  /// Set `direction` on the leaf containing `window`. Pass nil to clear.
  /// Also derives `preferredChild` + `preferredSplit` from the direction:
  ///   * north → horizontal split, child .first
  ///   * south → horizontal split, child .second
  ///   * east  → vertical split,   child .second
  ///   * west  → vertical split,   child .first
  ///   * stack → no axis/child preference
  public func settingInsertDirection(
    at window: WindowID,
    direction: InsertDirection?
  ) -> BSPNode {
    guard let path = pathTo(window: window) else { return self }
    return replacing(path: path) { node in
      guard case .leaf(var leaf) = node else { return node }
      leaf.insertDirection = direction
      switch direction {
      case .north:
        leaf.preferredSplit = .horizontal
        leaf.preferredChild = .first
      case .south:
        leaf.preferredSplit = .horizontal
        leaf.preferredChild = .second
      case .east:
        leaf.preferredSplit = .vertical
        leaf.preferredChild = .second
      case .west:
        leaf.preferredSplit = .vertical
        leaf.preferredChild = .first
      case .stack, .none:
        leaf.preferredSplit = nil
        leaf.preferredChild = nil
      }
      return .leaf(leaf)
    }
  }

  /// Toggle parent-zoom on the leaf containing `window`. Clears the
  /// flag on every other leaf so at most one node is parent-zoomed at
  /// a time.
  public func togglingParentZoom(at window: WindowID) -> BSPNode {
    guard let path = pathTo(window: window) else { return self }
    let cleared = clearingParentZoom(except: path)
    guard case .leaf(let leaf) = cleared.subtree(at: path) else { return cleared }
    return cleared.replacing(path: path) { _ in
      var l = leaf
      l.parentZoom.toggle()
      return .leaf(l)
    }
  }

  /// Clear `parentZoom` on every leaf except the one at `keepPath`.
  public func clearingParentZoom(except keepPath: [Side]) -> BSPNode {
    // Single bottom-up rebuild clearing every leaf but `keepPath`, instead
    // of one full root→leaf `replacing(path:)` rebuild per leaf (which made
    // this O(leaves²) tree reconstructions).
    func walk(_ node: BSPNode, _ path: [Side]) -> BSPNode {
      switch node {
      case .leaf(var leaf):
        if path != keepPath { leaf.parentZoom = false }
        return .leaf(leaf)
      case .branch(var b):
        b.left = walk(b.left, path + [.left])
        b.right = walk(b.right, path + [.right])
        return .branch(b)
      }
    }
    return walk(self, [])
  }
}

// MARK: - Direction enum

/// Compass directions for geometric neighbor lookups (swap/focus/
/// resize/warp). North = up, South = down in AX top-origin
/// coordinates.
public enum BSPDirection: String, Sendable, Hashable, Codable {
  case west, east, north, south
}

// MARK: - Directional neighbor

extension BSPNode {
  /// Closest leaf adjacent to `key` in `direction`. Score every other
  /// leaf by axis-aligned distance, tiebreak by recency in the focus
  /// order (front-to-back), reject candidates that don't actually lie
  /// in `direction`.
  public func directionalNeighbor(
    of key: WindowID,
    direction: BSPDirection,
    in workArea: CGRect,
    gap: CGFloat,
    focusOrder: [WindowID] = []
  ) -> WindowID? {
    let frames = self.frames(in: workArea, gap: gap)
    guard let mine = frames[key] else { return nil }
    // Precompute the focus-order rank (first index per id) once so the
    // recency tiebreak is an O(1) lookup, not a fresh O(n) `firstIndex`
    // scan per candidate (was O(candidates × focusOrder)).
    var rankByID: [WindowID: Int] = [:]
    for (i, id) in focusOrder.enumerated() where rankByID[id] == nil { rankByID[id] = i }
    var best: (id: WindowID, distance: CGFloat, rank: Int)?
    for (other, rect) in frames where other != key {
      guard inDirection(from: mine, to: rect, direction: direction) else { continue }
      let dist = distance(from: mine, to: rect, direction: direction)
      let rank = rankByID[other] ?? Int.max
      if let b = best {
        if dist < b.distance || (dist == b.distance && rank < b.rank) {
          best = (other, dist, rank)
        }
      } else {
        best = (other, dist, rank)
      }
    }
    return best?.id
  }

  /// Does `to` actually extend past `from` along `direction`?
  private func inDirection(from a: CGRect, to b: CGRect, direction: BSPDirection) -> Bool {
    switch direction {
    case .north:
      guard b.maxY <= a.minY + 0.5 else { return false }
      return overlaps1D(a.minX, a.maxX, b.minX, b.maxX)
    case .south:
      guard b.minY >= a.maxY - 0.5 else { return false }
      return overlaps1D(a.minX, a.maxX, b.minX, b.maxX)
    case .west:
      guard b.maxX <= a.minX + 0.5 else { return false }
      return overlaps1D(a.minY, a.maxY, b.minY, b.maxY)
    case .east:
      guard b.minX >= a.maxX - 0.5 else { return false }
      return overlaps1D(a.minY, a.maxY, b.minY, b.maxY)
    }
  }

  private func overlaps1D(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> Bool {
    !(b1 <= a0 || b0 >= a1)
  }

  private func distance(from a: CGRect, to b: CGRect, direction: BSPDirection) -> CGFloat {
    switch direction {
    case .north: return a.minY - b.maxY
    case .south: return b.minY - a.maxY
    case .west:  return a.minX - b.maxX
    case .east:  return b.minX - a.maxX
    }
  }
}

// MARK: - Private helpers

extension BSPNode {
  /// Path + current rect + depth for a leaf, computed during the
  /// recursive walk that picks an insertion target.
  fileprivate struct LeafInfoT {
    var path: [Side]
    var rect: CGRect
    var depth: Int
  }

  fileprivate func leafInfos(
    currentRect: CGRect,
    path: [Side] = [],
    depth: Int = 0
  ) -> [LeafInfoT] {
    switch self {
    case .leaf:
      return [LeafInfoT(path: path, rect: currentRect, depth: depth)]
    case .branch(let b):
      let (lRect, rRect) = b.split.subdivide(currentRect, ratio: b.ratio, gap: 0)
      return b.left.leafInfos(currentRect: lRect, path: path + [.left], depth: depth + 1)
        + b.right.leafInfos(currentRect: rRect, path: path + [.right], depth: depth + 1)
    }
  }

  /// Rebuild the tree with the subtree at `path` replaced by
  /// `transform`'s result. Internal (not public) so the framework
  /// surface stays terse — the activation reducer uses it to patch leaf
  /// metadata for drag-warp.
  func replacing(
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
        return .branch(b.with(left: b.left.replacing(path: rest, with: transform)))
      case .right:
        return .branch(b.with(right: b.right.replacing(path: rest, with: transform)))
      }
    }
  }

  fileprivate func nearestAncestor(matching axis: SplitAxis, on path: [Side]) -> [Side]? {
    var current = self
    var traveled: [Side] = []
    var best: [Side]?
    for side in path {
      guard case .branch(let b) = current else { break }
      if b.split == axis {
        best = traveled
      }
      current = side == .left ? b.left : b.right
      traveled.append(side)
    }
    return best
  }
}

// MARK: - Geometry

extension BSPNode.SplitAxis {
  /// Subdivide `rect` into left/right children, applying a single
  /// `gap` between them.
  func subdivide(
    _ rect: CGRect,
    ratio: CGFloat,
    gap: CGFloat
  ) -> (CGRect, CGRect) {
    switch self {
    case .vertical:
      let usable = rect.width - gap
      let leftW = (usable * ratio).rounded()
      let rightW = usable - leftW
      let left = CGRect(x: rect.minX, y: rect.minY, width: leftW, height: rect.height)
      let right = CGRect(
        x: rect.minX + leftW + gap,
        y: rect.minY,
        width: rightW,
        height: rect.height
      )
      return (left, right)
    case .horizontal:
      let usable = rect.height - gap
      let topH = (usable * ratio).rounded()
      let bottomH = usable - topH
      let top = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: topH)
      let bottom = CGRect(
        x: rect.minX,
        y: rect.minY + topH + gap,
        width: rect.width,
        height: bottomH
      )
      return (top, bottom)
    }
  }
}
