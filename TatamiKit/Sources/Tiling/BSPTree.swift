import Foundation

/// Pure value-typed Binary Space Partitioning tree.
///
/// Algorithm follows yabai's `view.c`:
/// * leaves carry a single window identifier; internal nodes carry a
///   split axis + ratio
/// * insertion places the new window at the **shallowest leaf** (BFS)
///   and chooses the split axis from the **target leaf's aspect**
///   (wider → vertical split / side-by-side; taller → horizontal split
///   / top-bottom)
/// * removal collapses the surviving sibling into the parent
/// * frame layout subtracts an inner `gap` at every split so adjacent
///   siblings share exactly one gap regardless of depth
public indirect enum BSPNode<WindowID: Hashable & Sendable>: Hashable, Sendable {
  case leaf(WindowID)
  case branch(split: SplitAxis, ratio: CGFloat, left: BSPNode, right: BSPNode)

  public enum SplitAxis: Sendable, Hashable {
    /// Cut the area horizontally — children stack top/bottom.
    case horizontal
    /// Cut the area vertically — children sit side-by-side.
    case vertical
  }
}

extension BSPNode {
  /// All window IDs in tree order.
  public var windows: [WindowID] {
    switch self {
    case .leaf(let id): [id]
    case .branch(_, _, let left, let right): left.windows + right.windows
    }
  }

  public var leafCount: Int {
    switch self {
    case .leaf: 1
    case .branch(_, _, let left, let right): left.leafCount + right.leafCount
    }
  }

  /// Build a balanced-ish tree from a sequence of windows, in order.
  /// Uses the same insertion policy as live edits so the tree shape is
  /// deterministic across runs.
  public static func build(
    _ windows: [WindowID],
    in rect: CGRect,
    defaultRatio: CGFloat = 0.5
  ) -> BSPNode? {
    var tree: BSPNode? = nil
    for window in windows {
      tree = tree?.inserting(window, in: rect, defaultRatio: defaultRatio)
        ?? .leaf(window)
    }
    return tree
  }

  /// Insert a window into the tree. If `focusedWindow` is supplied and
  /// is already a leaf, the new window splits *that* leaf — the yabai
  /// "open next to the focused window" behavior. Otherwise falls back
  /// to splitting the shallowest leaf.
  ///
  /// Split axis is chosen from the target leaf's aspect ratio: wider
  /// than tall → vertical split (side-by-side); taller than wide →
  /// horizontal split (top/bottom).
  public func inserting(
    _ window: WindowID,
    near focusedWindow: WindowID? = nil,
    in rect: CGRect,
    defaultRatio: CGFloat = 0.5
  ) -> BSPNode {
    let leaves = leavesByDepth(currentRect: rect)
    let target: LeafInfo? = {
      if let focused = focusedWindow,
         let hit = leaves.first(where: { leaf in
           guard case .leaf(let id) = self.subtree(at: leaf.path) else { return false }
           return id == focused
         })
      {
        return hit
      }
      return leaves.min(by: { $0.depth < $1.depth })
    }()
    guard let target else { return .leaf(window) }
    return replacing(path: target.path) { leaf in
      let axis: SplitAxis = target.rect.width >= target.rect.height
        ? .vertical
        : .horizontal
      return .branch(split: axis, ratio: defaultRatio, left: leaf, right: .leaf(window))
    }
  }

  /// Replace the ratio of the branch whose left subtree contains `window`
  /// — used to sync manual user resizes back into the tree.
  public func updatingRatio(containingLeft window: WindowID, ratio: CGFloat) -> BSPNode {
    guard let path = pathTo(window: window) else { return self }
    // Walk the path from the root and find the highest ancestor where
    // this window is in the left subtree.
    var leftAncestor: [Side]? = nil
    var partial: [Side] = []
    for side in path {
      if side == .left {
        leftAncestor = partial
        break
      }
      partial.append(side)
    }
    guard let ancestorPath = leftAncestor else { return self }
    return replacing(path: ancestorPath) { node in
      guard case .branch(let split, _, let left, let right) = node else { return node }
      return .branch(split: split, ratio: max(0.1, min(0.9, ratio)), left: left, right: right)
    }
  }

  /// Subtree at the given path (for internal lookup only).
  private func subtree(at path: [Side]) -> BSPNode {
    var current = self
    for side in path {
      guard case .branch(_, _, let left, let right) = current else { return current }
      current = side == .left ? left : right
    }
    return current
  }

  /// Remove the given window. If the tree has only that window, returns nil.
  /// Otherwise collapses the surviving sibling into its parent's slot.
  public func removing(_ window: WindowID) -> BSPNode? {
    switch self {
    case .leaf(let id):
      return id == window ? nil : self

    case .branch(let split, let ratio, let left, let right):
      let newLeft = left.removing(window)
      let newRight = right.removing(window)
      switch (newLeft, newRight) {
      case (nil, let r?): return r
      case (let l?, nil): return l
      case (let l?, let r?):
        return .branch(split: split, ratio: ratio, left: l, right: r)
      case (nil, nil):
        return nil
      }
    }
  }

  /// Resolve every leaf's frame given the display rect and inner gap.
  /// Returns a dictionary from window ID to frame.
  public func frames(in rect: CGRect, gap: CGFloat) -> [WindowID: CGRect] {
    var out: [WindowID: CGRect] = [:]
    layout(into: &out, rect: rect, gap: gap)
    return out
  }

  /// Swap the positions of two windows in the tree. No-op if either is
  /// missing.
  public func swapping(_ a: WindowID, _ b: WindowID) -> BSPNode {
    guard a != b else { return self }
    switch self {
    case .leaf(let id):
      if id == a { return .leaf(b) }
      if id == b { return .leaf(a) }
      return self
    case .branch(let split, let ratio, let left, let right):
      return .branch(
        split: split,
        ratio: ratio,
        left: left.swapping(a, b),
        right: right.swapping(a, b)
      )
    }
  }

  /// Flip the split axis at the parent of `window`. No-op if `window`
  /// is at the root.
  public func togglingSplit(at window: WindowID) -> BSPNode {
    guard let path = pathTo(window: window), !path.isEmpty else { return self }
    let parentPath = Array(path.dropLast())
    return replacing(path: parentPath) { node in
      switch node {
      case .branch(let split, let ratio, let left, let right):
        let flipped: SplitAxis = split == .horizontal ? .vertical : .horizontal
        return .branch(split: flipped, ratio: ratio, left: left, right: right)
      case .leaf:
        return node
      }
    }
  }

  /// Adjust the ratio at the nearest ancestor of `window` whose split
  /// axis is `axis`. `delta` is added to the current ratio and clamped
  /// to `[0.1, 0.9]`.
  public func resizing(
    window: WindowID,
    axis: SplitAxis,
    delta: CGFloat
  ) -> BSPNode {
    guard let path = pathTo(window: window) else { return self }
    let ancestorPath = nearestAncestor(matching: axis, on: path)
    guard let ancestorPath else { return self }
    return replacing(path: ancestorPath) { node in
      guard case .branch(let split, let ratio, let left, let right) = node
      else { return node }
      let newRatio = max(0.1, min(0.9, ratio + delta))
      return .branch(split: split, ratio: newRatio, left: left, right: right)
    }
  }

  /// Path of left/right turns from the root to the leaf carrying `window`,
  /// or `nil` if the window is not in the tree.
  public func pathTo(window: WindowID) -> [Side]? {
    switch self {
    case .leaf(let id):
      return id == window ? [] : nil
    case .branch(_, _, let left, let right):
      if let leftPath = left.pathTo(window: window) {
        return [.left] + leftPath
      }
      if let rightPath = right.pathTo(window: window) {
        return [.right] + rightPath
      }
      return nil
    }
  }

  /// Walk `path` from the root, returning the path to the nearest
  /// ancestor whose split axis matches `axis`. Returns nil if no such
  /// ancestor exists along the path.
  private func nearestAncestor(matching axis: SplitAxis, on path: [Side]) -> [Side]? {
    var current = self
    var traveled: [Side] = []
    var best: [Side]?
    for side in path {
      guard case .branch(let split, _, let left, let right) = current else { break }
      if split == axis {
        best = traveled
      }
      current = side == .left ? left : right
      traveled.append(side)
    }
    return best
  }

  // MARK: - Private helpers

  private struct LeafInfo {
    var path: [Side]
    var rect: CGRect
    var depth: Int
  }

  public enum Side: Sendable, Hashable { case left, right }

  private func leavesByDepth(
    currentRect: CGRect,
    path: [Side] = [],
    depth: Int = 0
  ) -> [LeafInfo] {
    switch self {
    case .leaf:
      return [LeafInfo(path: path, rect: currentRect, depth: depth)]
    case .branch(let split, let ratio, let left, let right):
      let (lRect, rRect) = split.subdivide(currentRect, ratio: ratio, gap: 0)
      return left.leavesByDepth(
        currentRect: lRect,
        path: path + [.left],
        depth: depth + 1
      ) + right.leavesByDepth(
        currentRect: rRect,
        path: path + [.right],
        depth: depth + 1
      )
    }
  }

  private func replacing(
    path: [Side],
    with transform: (BSPNode) -> BSPNode
  ) -> BSPNode {
    guard let next = path.first else {
      return transform(self)
    }
    switch self {
    case .leaf:
      return transform(self)
    case .branch(let split, let ratio, let left, let right):
      let rest = Array(path.dropFirst())
      switch next {
      case .left:
        return .branch(
          split: split,
          ratio: ratio,
          left: left.replacing(path: rest, with: transform),
          right: right
        )
      case .right:
        return .branch(
          split: split,
          ratio: ratio,
          left: left,
          right: right.replacing(path: rest, with: transform)
        )
      }
    }
  }

  private func layout(
    into out: inout [WindowID: CGRect],
    rect: CGRect,
    gap: CGFloat
  ) {
    switch self {
    case .leaf(let id):
      out[id] = rect.integral
    case .branch(let split, let ratio, let left, let right):
      let (lRect, rRect) = split.subdivide(rect, ratio: ratio, gap: gap)
      left.layout(into: &out, rect: lRect, gap: gap)
      right.layout(into: &out, rect: rRect, gap: gap)
    }
  }
}

extension BSPNode.SplitAxis {
  /// Subdivide `rect` into left/right children, applying a single
  /// `gap` between them (matching yabai's `area_make_pair`).
  fileprivate func subdivide(
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
