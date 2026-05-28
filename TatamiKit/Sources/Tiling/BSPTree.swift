import Foundation

/// Pure value-typed Binary Space Partitioning tree.
///
/// * leaves carry a single window identifier; internal nodes carry a
///   split axis + ratio
/// * insertion places the new window next to the focused/anchor leaf,
///   and Tatami falls back to the **deepest leaf** of the spiral tail
///   when no anchor is set — producing a dwindle layout. Split axis is
///   chosen from the target leaf's aspect (wider → vertical split /
///   side-by-side; taller → horizontal split / top-bottom)
/// * removal collapses the surviving sibling into the parent
/// * frame layout subtracts an inner `gap` at every split so adjacent
///   siblings share exactly one gap regardless of depth
public indirect enum BSPNode<WindowID: Hashable & Sendable>: Hashable, Sendable {
  case leaf(WindowID)
  case branch(split: SplitAxis, ratio: CGFloat, left: BSPNode, right: BSPNode)

  public enum SplitAxis: String, Sendable, Hashable, Codable {
    /// Cut the area horizontally — children stack top/bottom.
    case horizontal
    /// Cut the area vertically — children sit side-by-side.
    case vertical
  }
}

extension BSPNode: Codable where WindowID: Codable {}

extension BSPNode where WindowID == WindowKey {
  /// Rebuild a live tree from a persisted bundle-id `template`,
  /// assigning the current `keys` to matching leaves in order. Leaves
  /// whose bundle id has no available window collapse (sibling
  /// promotes), so a saved layout gracefully degrades when an app
  /// isn't running. Windows present in `keys` but absent from the
  /// template are NOT added here — the caller folds those in via the
  /// normal merge/insert path afterward.
  public static func hydrate(
    template: BSPNode<String>,
    keys: [WindowKey]
  ) -> BSPNode<WindowKey>? {
    var queues: [String: [WindowKey]] = [:]
    for key in keys {
      queues[key.bundleId, default: []].append(key)
    }
    func build(_ node: BSPNode<String>) -> BSPNode<WindowKey>? {
      switch node {
      case .leaf(let bundleId):
        guard var queue = queues[bundleId], !queue.isEmpty else { return nil }
        let key = queue.removeFirst()
        queues[bundleId] = queue
        return BSPNode<WindowKey>.leaf(key)
      case .branch(let split, let ratio, let left, let right):
        let l = build(left)
        let r = build(right)
        // SplitAxis is nested in BSPNode, so the String-tree and
        // WindowKey-tree variants are distinct types — bridge via the
        // shared String raw value.
        let axis = BSPNode<WindowKey>.SplitAxis(rawValue: split.rawValue) ?? .vertical
        switch (l, r) {
        case (nil, nil): return nil
        case (let l?, nil): return l
        case (nil, let r?): return r
        case (let l?, let r?):
          return BSPNode<WindowKey>.branch(split: axis, ratio: ratio, left: l, right: r)
        }
      }
    }
    return build(template)
  }
}

extension BSPNode {
  /// Rebuild the tree with each leaf's window id transformed by `f`,
  /// preserving every split axis + ratio. Used to convert a live
  /// `BSPNode<WindowKey>` into a serializable `BSPNode<String>`
  /// (bundle-id keyed) for persistent layout snapshots.
  public func mapWindows<T: Hashable & Sendable>(
    _ f: (WindowID) -> T
  ) -> BSPNode<T> {
    switch self {
    case .leaf(let id):
      return BSPNode<T>.leaf(f(id))
    case .branch(let split, let ratio, let left, let right):
      let axis = BSPNode<T>.SplitAxis(rawValue: split.rawValue) ?? .vertical
      return BSPNode<T>.branch(
        split: axis,
        ratio: ratio,
        left: left.mapWindows(f),
        right: right.mapWindows(f)
      )
    }
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

  /// The window id of the deepest leaf (ties broken toward the right /
  /// second child). In a dwindle spiral this is the smallest, most
  /// recently split tile — the natural anchor for the next insert so
  /// the spiral keeps winding instead of restarting at the root.
  public var deepestLeaf: WindowID? {
    func search(_ node: BSPNode, _ depth: Int) -> (id: WindowID, depth: Int)? {
      switch node {
      case .leaf(let id):
        return (id, depth)
      case .branch(_, _, let left, let right):
        let l = search(left, depth + 1)
        let r = search(right, depth + 1)
        switch (l, r) {
        case (nil, nil): return nil
        case (let l?, nil): return l
        case (nil, let r?): return r
        case (let l?, let r?):
          // Prefer the right/second child on ties.
          return r.depth >= l.depth ? r : l
        }
      }
    }
    return search(self, 0)?.id
  }

  /// Build a dwindle (spiral) tree: insert each window in order,
  /// splitting the *previously inserted* leaf. The first window takes
  /// half the space, the next a quarter, and so on, alternating split
  /// axis by the leaf's aspect. `rect` is the real work area so the
  /// axis choices match the screen.
  public static func dwindleBuild(
    _ windows: [WindowID],
    in rect: CGRect
  ) -> BSPNode? {
    guard let first = windows.first else { return nil }
    var tree: BSPNode = .leaf(first)
    for i in 1..<windows.count {
      tree = tree.inserting(windows[i], near: windows[i - 1], in: rect)
    }
    return tree
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
  /// is already a leaf, the new window splits *that* leaf — placing it
  /// next to the focused window. Otherwise falls back to splitting the
  /// shallowest leaf.
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

  /// Subtree at the given path. Returns `self` if the path runs past
  /// a leaf.
  public func subtree(at path: [Side]) -> BSPNode {
    var current = self
    for side in path {
      guard case .branch(_, _, let left, let right) = current else { return current }
      current = side == .left ? left : right
    }
    return current
  }

  /// Rect of the subtree at `path` after subdividing `workArea` along
  /// the same splits that `frames(in:gap:)` walks. Used by the resize
  /// sync to translate an AX-reported frame back into a parent split's
  /// ratio.
  public func rect(at path: [Side], in workArea: CGRect, gap: CGFloat) -> CGRect {
    var rect = workArea
    var node = self
    for side in path {
      guard case .branch(let split, let ratio, let left, let right) = node else {
        return rect
      }
      let (l, r) = split.subdivide(rect, ratio: ratio, gap: gap)
      rect = side == .left ? l : r
      node = side == .left ? left : right
    }
    return rect
  }

  /// Update the split ratio of the branch at `path`. Clamps to
  /// `[0.1, 0.9]`. No-op if `path` does not land on a branch.
  public func updatingRatio(at path: [Side], ratio: CGFloat) -> BSPNode {
    replacing(path: path) { node in
      guard case .branch(let split, _, let left, let right) = node else { return node }
      return .branch(
        split: split,
        ratio: max(0.1, min(0.9, ratio)),
        left: left,
        right: right
      )
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

  /// Move `window` in `direction` when there's no tile neighbor to swap
  /// with. Rewrites the window's parent split so its axis matches the
  /// requested direction (east/west → side-by-side, north/south →
  /// stacked) and places the window on the corresponding side. So two
  /// side-by-side windows "warped" downward become stacked with the
  /// moved window on the bottom. No-op if `window` is the root leaf.
  public func warping(_ window: WindowID, direction: BSPDirection) -> BSPNode {
    guard let path = pathTo(window: window), let side = path.last else { return self }
    let parentPath = Array(path.dropLast())
    let desiredAxis: SplitAxis =
      (direction == .east || direction == .west) ? .vertical : .horizontal
    let desiredSide: Side = (direction == .west || direction == .north) ? .left : .right
    return replacing(path: parentPath) { node in
      guard case .branch(_, let ratio, let left, let right) = node else { return node }
      let windowChild = side == .left ? left : right
      let siblingChild = side == .left ? right : left
      let newLeft = desiredSide == .left ? windowChild : siblingChild
      let newRight = desiredSide == .left ? siblingChild : windowChild
      // Mirror the ratio when the window changes sides so the moved
      // window keeps roughly its share rather than jumping size.
      let newRatio = (desiredSide == (side == .left ? .left : .right)) ? ratio : 1 - ratio
      return .branch(split: desiredAxis, ratio: newRatio, left: newLeft, right: newRight)
    }
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
  /// axis is `axis`. Positive `delta` always means "grow the focused
  /// window": the sign is flipped when the focused leaf sits on the
  /// right/bottom side of the ancestor split, because in that case
  /// growing the focused window means shrinking the parent ratio (which
  /// describes the left/top child's share). Result clamped to `[0.1, 0.9]`.
  public func resizing(
    window: WindowID,
    axis: SplitAxis,
    delta: CGFloat
  ) -> BSPNode {
    guard let path = pathTo(window: window) else { return self }
    let ancestorPath = nearestAncestor(matching: axis, on: path)
    guard let ancestorPath else { return self }
    // The step *into* the ancestor's matching child decides the sign.
    let sideIntoAncestor = path[ancestorPath.count]
    let signedDelta = sideIntoAncestor == .left ? delta : -delta
    return replacing(path: ancestorPath) { node in
      guard case .branch(let split, let ratio, let left, let right) = node
      else { return node }
      let newRatio = max(0.1, min(0.9, ratio + signedDelta))
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

extension BSPNode {
  /// Equalize every split so child sizes match the number of leaves
  /// they contain. A 1:3 sibling split becomes 0.25, regardless of any
  /// user-applied ratios.
  public func balanced() -> BSPNode {
    switch self {
    case .leaf:
      return self
    case .branch(let split, _, let left, let right):
      let bl = left.balanced()
      let br = right.balanced()
      let lc = bl.leafCount
      let rc = br.leafCount
      let total = lc + rc
      let ratio = total == 0 ? 0.5 : CGFloat(lc) / CGFloat(total)
      return .branch(
        split: split,
        ratio: max(0.1, min(0.9, ratio)),
        left: bl,
        right: br
      )
    }
  }

  /// Rotate the entire tree clockwise by 90 / 180 / 270 degrees.
  /// The swap-and-flip rules differ per quadrant so each rotation is
  /// one pass.
  public func rotated(by degrees: Int) -> BSPNode {
    let d = ((degrees % 360) + 360) % 360
    switch self {
    case .leaf:
      return self
    case .branch(let split, let ratio, let left, let right):
      let shouldSwap =
        (d == 90 && split == .vertical)
        || (d == 270 && split == .horizontal)
        || d == 180
      let newLeft = shouldSwap ? right : left
      let newRight = shouldSwap ? left : right
      let newRatio = shouldSwap ? 1 - ratio : ratio
      let newSplit: SplitAxis = d == 180
        ? split
        : (split == .horizontal ? .vertical : .horizontal)
      return .branch(
        split: newSplit,
        ratio: newRatio,
        left: newLeft.rotated(by: d),
        right: newRight.rotated(by: d)
      )
    }
  }

  /// Mirror the tree along `axis`. Splits matching the axis flip
  /// left/right and invert their ratio — splits on the orthogonal
  /// axis are unchanged.
  public func mirrored(axis: SplitAxis) -> BSPNode {
    switch self {
    case .leaf:
      return self
    case .branch(let split, let ratio, let left, let right):
      if split == axis {
        return .branch(
          split: split,
          ratio: 1 - ratio,
          left: right.mirrored(axis: axis),
          right: left.mirrored(axis: axis)
        )
      } else {
        return .branch(
          split: split,
          ratio: ratio,
          left: left.mirrored(axis: axis),
          right: right.mirrored(axis: axis)
        )
      }
    }
  }
}

/// Compass directions for geometric "neighbor of focused" lookups
/// (swap/focus/resize). North = up, South = down in AX top-origin
/// coordinates.
public enum BSPDirection: Sendable, Hashable {
  case west, east, north, south
}

extension BSPNode {
  /// Closest leaf adjacent to `key` in `direction`. Scores candidates
  /// by distance along the axis plus a perpendicular penalty, so
  /// windows that share an edge with the focused one win over ones
  /// diagonally further away.
  public func directionalNeighbor(
    of key: WindowID,
    direction: BSPDirection,
    in workArea: CGRect,
    gap: CGFloat
  ) -> WindowID? {
    let frames = self.frames(in: workArea, gap: gap)
    guard let mine = frames[key] else { return nil }
    let myCenter = CGPoint(x: mine.midX, y: mine.midY)

    var best: (id: WindowID, score: CGFloat)?
    for (other, rect) in frames where other != key {
      let c = CGPoint(x: rect.midX, y: rect.midY)
      let score: CGFloat
      switch direction {
      case .east:
        guard c.x > myCenter.x else { continue }
        score = (c.x - myCenter.x) + abs(c.y - myCenter.y) * 0.5
      case .west:
        guard c.x < myCenter.x else { continue }
        score = (myCenter.x - c.x) + abs(c.y - myCenter.y) * 0.5
      case .south:
        guard c.y > myCenter.y else { continue }
        score = (c.y - myCenter.y) + abs(c.x - myCenter.x) * 0.5
      case .north:
        guard c.y < myCenter.y else { continue }
        score = (myCenter.y - c.y) + abs(c.x - myCenter.x) * 0.5
      }
      if best == nil || score < best!.score {
        best = (other, score)
      }
    }
    return best?.id
  }
}

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
