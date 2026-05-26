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

  /// Insert a window at the shallowest leaf, splitting along the leaf's
  /// long axis. `rect` is the root display rect; required to evaluate
  /// the aspect of leaves whose own frames are not yet known.
  public func inserting(
    _ window: WindowID,
    in rect: CGRect,
    defaultRatio: CGFloat = 0.5
  ) -> BSPNode {
    let leaves = leavesByDepth(currentRect: rect)
    guard let target = leaves.min(by: { $0.depth < $1.depth }) else {
      return .leaf(window)
    }
    return replacing(path: target.path) { leaf in
      let axis: SplitAxis = target.rect.width >= target.rect.height
        ? .vertical
        : .horizontal
      return .branch(split: axis, ratio: defaultRatio, left: leaf, right: .leaf(window))
    }
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

  // MARK: - Private helpers

  private struct LeafInfo {
    var path: [Side]
    var rect: CGRect
    var depth: Int
  }

  fileprivate enum Side { case left, right }

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
