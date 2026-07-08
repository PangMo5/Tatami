import CoreGraphics
import Foundation

/// A single layout edit expressed against a BSP tree's *structure* — every
/// case is a `[BSPSide]` path or a whole-tree transform, never a window id.
/// That keeps it payload-agnostic: the same op applies to a live
/// `BSPNode<WindowKey>` (active workspace) and a serialized `BSPNode<String>`
/// (a persisted / synthesized layout template) alike, so the GUI preview can
/// drive both through one channel. The view computes the op against a tree
/// structurally identical to the reducer's authoritative one, so the paths
/// line up when the reducer applies it.
public enum LayoutEditOp: Hashable, Sendable {
  /// Set the split ratio of the branch at `path`.
  case setRatio(path: [BSPSide], ratio: CGFloat)
  /// Flip the split axis of the branch that is the parent of the leaf at
  /// `leafPath`.
  case toggleOrientation(leafPath: [BSPSide])
  /// Rotate the whole tree clockwise (90 / 180 / 270).
  case rotate(degrees: Int)
  /// Mirror the whole tree along `axis`.
  case mirror(axis: BSPSplitAxis)
  /// Equalize every split so child sizes match their leaf counts.
  case balance
  /// Exchange the leaves at two paths in place.
  case swap(a: [BSPSide], b: [BSPSide])
  /// Move the leaf at `source` next to the leaf at `target`, dropped into
  /// `zone` (`.swap` exchanges them; the four edges insert on that side).
  case relocate(source: [BSPSide], target: [BSPSide], zone: DropZone)
}

extension BSPNode {
  /// Apply one structural edit, returning the new tree. Id-based sub-ops
  /// (`relocate`) require window ids be unique across leaves — callers with a
  /// non-unique payload (e.g. a bundle-id template) `tokenized()` first.
  public func applying(_ op: LayoutEditOp) -> BSPNode {
    switch op {
    case .setRatio(let path, let ratio):
      return updatingRatio(at: path, ratio: ratio)
    case .toggleOrientation(let leafPath):
      return togglingSplit(atLeafPath: leafPath)
    case .rotate(let degrees):
      return rotated(by: degrees)
    case .mirror(let axis):
      return mirrored(axis: axis)
    case .balance:
      return balanced(axis: .both)
    case .swap(let a, let b):
      return swappingLeaves(a, b)
    case .relocate(let source, let target, let zone):
      guard case .leaf(let s) = subtree(at: source), let sourceId = s.topWindow,
            case .leaf(let t) = subtree(at: target), let targetId = t.topWindow
      else { return self }
      switch zone {
      case .swap:   return swappingLeaves(source, target)
      case .top:    return warpingInto(source: sourceId, target: targetId, axis: .horizontal, child: .first)
      case .bottom: return warpingInto(source: sourceId, target: targetId, axis: .horizontal, child: .second)
      case .left:   return warpingInto(source: sourceId, target: targetId, axis: .vertical, child: .first)
      case .right:  return warpingInto(source: sourceId, target: targetId, axis: .vertical, child: .second)
      }
    }
  }
}

// MARK: - Path-based structural edits

extension BSPNode {
  /// Flip the split axis of the branch that is the parent of the leaf at
  /// `leafPath`. No-op when the leaf is the root (no parent split).
  public func togglingSplit(atLeafPath leafPath: [Side]) -> BSPNode {
    guard !leafPath.isEmpty else { return self }
    let parentPath = Array(leafPath.dropLast())
    return replacing(path: parentPath) { node in
      guard case .branch(let b) = node else { return node }
      let flipped: SplitAxis = b.split == .horizontal ? .vertical : .horizontal
      return .branch(b.with(split: flipped))
    }
  }

  /// Exchange the two leaves at paths `a` and `b`. Their window stacks travel;
  /// each position keeps its own split metadata. Parent-zoom is cleared on
  /// both (it refers to a position, not a window). No-op unless both paths hit
  /// leaves. Mirrors the cross-leaf branch of `swapping(_:_:)`.
  public func swappingLeaves(_ a: [Side], _ b: [Side]) -> BSPNode {
    guard a != b,
          case .leaf(let leafA) = subtree(at: a),
          case .leaf(let leafB) = subtree(at: b)
    else { return self }
    var newA = leafA
    newA.windowList = leafB.windowList
    newA.windowOrder = leafB.windowOrder
    newA.parentZoom = false
    var newB = leafB
    newB.windowList = leafA.windowList
    newB.windowOrder = leafA.windowOrder
    newB.parentZoom = false
    // Two distinct leaves — neither path prefixes the other — so the sequential
    // replaces don't interfere.
    let withA = replacing(path: a) { _ in .leaf(newA) }
    return withA.replacing(path: b) { _ in .leaf(newB) }
  }

  /// Move `source` next to `target` with a specific split axis + child side:
  /// seed the target leaf's preferred split/child, remove `source`, re-insert
  /// it next to `target`. Generic over `WindowID`; assumes ids unique across
  /// leaves. Shared by the live window drag-drop and the layout preview.
  public func warpingInto(
    source: WindowID,
    target: WindowID,
    axis: SplitAxis,
    child: Child
  ) -> BSPNode {
    guard let targetPath = pathTo(window: target) else { return self }
    let seeded = replacing(path: targetPath) { node in
      guard case .leaf(var leaf) = node else { return node }
      leaf.preferredSplit = axis
      leaf.preferredChild = child
      return .leaf(leaf)
    }
    guard let removed = seeded.removing(source) else { return self }
    return removed.inserting(source, near: target, in: CGRect(x: 0, y: 0, width: 1, height: 1))
  }
}

// MARK: - Tokenize (unique-id rekey for id-based ops on non-unique payloads)

extension BSPNode {
  /// Re-key every window to a fresh unique `Int` token, returning the
  /// tokenized tree plus a token→original map. Lets id-based edits
  /// (`relocate`) run safely on a tree whose payload repeats — e.g. a
  /// bundle-id template where the same app occupies two leaves. Structure,
  /// split metadata, and `windowOrder` correspondence are preserved (a
  /// duplicated id inside one stacked leaf is paired by occurrence order).
  public func tokenized() -> (BSPNode<Int>, [Int: WindowID]) {
    var counter = 0
    var back: [Int: WindowID] = [:]
    func build(_ node: BSPNode<WindowID>) -> BSPNode<Int> {
      switch node {
      case .leaf(let leaf):
        var listTokens: [Int] = []
        var pools: [WindowID: [Int]] = [:]
        for id in leaf.windowList {
          let token = counter
          counter += 1
          back[token] = id
          listTokens.append(token)
          pools[id, default: []].append(token)
        }
        var orderTokens: [Int] = []
        for id in leaf.windowOrder {
          guard var queue = pools[id], let token = queue.first else { continue }
          queue.removeFirst()
          pools[id] = queue
          orderTokens.append(token)
        }
        for token in listTokens where !orderTokens.contains(token) {
          orderTokens.append(token)
        }
        return .leaf(BSPLeaf<Int>(
          windowList: listTokens,
          windowOrder: orderTokens,
          insertDirection: leaf.insertDirection,
          preferredChild: leaf.preferredChild,
          preferredSplit: leaf.preferredSplit,
          parentZoom: leaf.parentZoom
        ))
      case .branch(let b):
        return .branch(BSPBranch<Int>(
          split: b.split,
          ratio: b.ratio,
          preferredChild: b.preferredChild,
          left: build(b.left),
          right: build(b.right)
        ))
      }
    }
    return (build(self), back)
  }
}

// MARK: - Region walks (for rendering the preview)

extension BSPNode {
  /// A leaf's laid-out rect + path, computed by subdividing `rect` the same
  /// way `frames(in:gap:)` does. Used to place preview tiles + drop targets.
  public struct LeafRegion {
    public var path: [BSPSide]
    public var rect: CGRect
    public var leaf: BSPLeaf<WindowID>
  }

  /// A branch's rect + split, used to place a draggable divider handle at the
  /// split position.
  public struct BranchRegion {
    public var path: [BSPSide]
    public var rect: CGRect
    public var axis: BSPSplitAxis
    public var ratio: CGFloat
  }

  public func leafRegions(in rect: CGRect, gap: CGFloat) -> [LeafRegion] {
    var out: [LeafRegion] = []
    func walk(_ node: BSPNode, _ r: CGRect, _ path: [Side]) {
      switch node {
      case .leaf(let leaf):
        out.append(LeafRegion(path: path, rect: r.integral, leaf: leaf))
      case .branch(let b):
        let (l, rr) = b.split.subdivide(r, ratio: b.ratio, gap: gap)
        walk(b.left, l, path + [.left])
        walk(b.right, rr, path + [.right])
      }
    }
    walk(self, rect, [])
    return out
  }

  public func branchRegions(in rect: CGRect, gap: CGFloat) -> [BranchRegion] {
    var out: [BranchRegion] = []
    func walk(_ node: BSPNode, _ r: CGRect, _ path: [Side]) {
      guard case .branch(let b) = node else { return }
      out.append(BranchRegion(path: path, rect: r, axis: b.split, ratio: b.ratio))
      let (l, rr) = b.split.subdivide(r, ratio: b.ratio, gap: gap)
      walk(b.left, l, path + [.left])
      walk(b.right, rr, path + [.right])
    }
    walk(self, rect, [])
    return out
  }
}

// MARK: - Synthesized template (preview when no live tree / snapshot exists)

extension BSPNode where WindowID == String {
  /// Build a bundle-id layout template from tiled app assignments in order,
  /// using the same insertion policy live tiling uses — so the preview matches
  /// what activation would actually produce. nil when there are no tiled apps.
  /// The view and the reducer both call this so their tree structure (and thus
  /// edit-op paths) line up.
  public static func synthesizedTemplate(tiledBundleIds: [String]) -> BSPNode<String>? {
    BSPNode<String>.build(tiledBundleIds, in: CGRect(x: 0, y: 0, width: 1, height: 1))
  }
}

/// Bundle ids that tile into a workspace's layout, in a stable order: the
/// workspace's own tiled apps, then tiled shared apps (present in every
/// workspace, so they join each workspace's tree). Floating / unmanaged apps —
/// workspace-local or shared — never enter the tree. A scratchpad only borrows
/// its own apps into a host (which already carries the shared apps), so shared
/// apps are excluded there. The preview view and the detail reducer both call
/// this so their synthesized template (and thus edit-op paths) match.
public func tiledLayoutBundleIds(workspace: Workspace, sharedApps: [SharedApp]) -> [String] {
  let own = workspace.apps.filter { $0.layout == .tiled }.map(\.bundleIdentifier)
  guard workspace.kind != .scratchpad else { return own }
  return own + sharedApps.filter { $0.layout == .tiled }.map(\.bundleIdentifier)
}

// MARK: - Drop-zone geometry (shared by live drag + preview)

extension DropZone {
  /// Classify `point` within a tile `rect` into a drop zone: the central 50%
  /// square is `.swap`; outside it four triangles fan to the edges. Coordinates
  /// are AX top-left (y grows downward), so the top triangle is the small-y
  /// one. Returns nil when the point is outside `rect`.
  public static func quadrant(point: CGPoint, in rect: CGRect) -> DropZone? {
    guard rect.contains(point) else { return nil }
    let wp = CGPoint(x: point.x - rect.origin.x, y: point.y - rect.origin.y)
    let centerRect = CGRect(
      x: 0.25 * rect.width, y: 0.25 * rect.height,
      width: 0.5 * rect.width, height: 0.5 * rect.height
    )
    if centerRect.contains(wp) { return .swap }
    // Signed cross products against the rect's two diagonals classify the
    // four triangles.
    let onAboveDownDiag = wp.x * rect.height - wp.y * rect.width < 0
    let onAboveUpDiag = wp.x * (-rect.height) - (wp.y - rect.height) * rect.width < 0
    switch (onAboveDownDiag, onAboveUpDiag) {
    case (false, false): return .top
    case (false, true):  return .right
    case (true, true):   return .bottom
    case (true, false):  return .left
    }
  }
}
