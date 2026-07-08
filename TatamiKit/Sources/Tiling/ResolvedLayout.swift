import CoreGraphics
import Foundation

/// The layout to preview for one workspace: the *live* window tree when the
/// workspace is active, or a bundle-id *template* (persisted snapshot, else
/// synthesized from the tiled apps) otherwise. Fullscreen-zoomed windows are
/// trimmed out of the tile layout — exactly as `computeFrames` does — and shown
/// in a separate fullscreen band, so the remaining tiles reshape and stay
/// editable. Because trimming changes the tree shape, edit ops computed against
/// the trimmed layout are mapped back to *full-tree* paths before they're sent.
///
/// Payload-agnostic and SwiftUI-free so both the reducer (which owns the tree
/// resolution + trimmed→full mapping) and the view (which renders) share it.
public enum ResolvedLayout: Equatable {
  case live(BSPNode<WindowKey>, zoomed: Set<WindowKey>)
  /// `SlotID` template (persisted snapshot, else synthesized). `zoomedSlots`
  /// identifies the fullscreen-zoomed windows by slot, so which window of an app
  /// is zoomed is exact — matching `LayoutSnapshot.fullscreenZoomedSlots`.
  case template(BSPNode<SlotID>, zoomedSlots: [SlotID])

  public static func resolve(
    workspace: Workspace,
    sharedApps: [SharedApp],
    presentBundleIds: Set<String>,
    isActive: Bool,
    liveTree: BSPNode<WindowKey>?,
    liveZoomed: Set<WindowKey>,
    snapshot: LayoutSnapshot?,
    autoBalance: AutoBalanceMode
  ) -> ResolvedLayout? {
    // Only the *currently active* workspace has an authoritative live tree.
    // A workspace that was active earlier keeps a stale tree in `tilingTrees`,
    // but editing it would route to the wrong (active) workspace — so treat
    // any non-active workspace as a saved template.
    if isActive, let liveTree, !liveTree.windows.isEmpty {
      return .live(liveTree, zoomed: liveZoomed)
    }
    guard var template = previewLayoutTemplate(
      snapshot: snapshot?.tree,
      workspace: workspace,
      sharedApps: sharedApps,
      presentBundleIds: presentBundleIds
    ), !template.windows.isEmpty
    else { return nil }
    // Activation applies auto-balance to the tree it builds (and to a restored
    // snapshot) — mirror it so the inactive preview matches. Balancing only
    // re-weights ratios, so edit-op paths are unaffected.
    if autoBalance != .none { template = template.balanced(axis: autoBalance) }
    return .template(template, zoomedSlots: snapshot?.fullscreenZoomedSlots ?? [])
  }

  public var isLive: Bool { if case .live = self { return true } else { return false } }

  public var hasFullscreen: Bool {
    switch self {
    case .live(let t, let z): return z.contains { t.pathTo(window: $0) != nil }
    case .template(let t, let z): let w = Set(t.windows); return z.contains { w.contains($0) }
    }
  }

  /// Tiles + dividers for the *non-zoomed* windows, laid out in `rect` after
  /// trimming the fullscreen-zoomed (and `hidden`) ones so the rest reshapes to
  /// fill. `pendingRatio` (a trimmed branch path + ratio) applies a live resize
  /// preview to the *trimmed* tree, so the view never needs a full-tree path.
  public func renderRegions(
    in rect: CGRect,
    hidden: Set<String>,
    pendingRatio: (path: [BSPSide], ratio: CGFloat)? = nil
  ) -> (tiles: [RenderLeaf], dividers: [RenderDivider]) {
    switch self {
    case .live(let tree, let zoomed):
      guard let base = Self.trim(tree, removing: zoomed) else { return ([], []) }
      let trimmed = pendingRatio.map { base.applying(.setRatio(path: $0.path, ratio: $0.ratio)) } ?? base
      let tiles = trimmed.leafRegions(in: rect, gap: 0).map { r in
        RenderLeaf(path: r.path, rect: r.rect, bundleIds: r.leaf.windowList.map(\.bundleId),
                   liveKey: r.leaf.windowList.first, slot: nil)
      }
      let dividers = trimmed.branchRegions(in: rect, gap: 0).map {
        RenderDivider(path: $0.path, rect: $0.rect, axis: $0.axis, ratio: $0.ratio)
      }
      return (tiles, dividers)
    case .template(let tree, let zoomedSlots):
      guard let base = Self.trimTemplate(tree, zoomedSlots: zoomedSlots, hidden: hidden)
      else { return ([], []) }
      let trimmed = pendingRatio.map { base.applying(.setRatio(path: $0.path, ratio: $0.ratio)) } ?? base
      let tiles = trimmed.leafRegions(in: rect, gap: 0).map { r in
        RenderLeaf(path: r.path, rect: r.rect, bundleIds: r.leaf.windowList.map(\.bundleId),
                   liveKey: nil, slot: r.leaf.windowList.first)
      }
      let dividers = trimmed.branchRegions(in: rect, gap: 0).map {
        RenderDivider(path: $0.path, rect: $0.rect, axis: $0.axis, ratio: $0.ratio)
      }
      return (tiles, dividers)
    }
  }

  public func fullscreenItems() -> [(bundleId: String, liveKey: WindowKey?, slot: SlotID?)] {
    switch self {
    case .live(let tree, let zoomed):
      return zoomed
        .filter { tree.pathTo(window: $0) != nil }
        .sorted { $0.windowID < $1.windowID }
        .map { (bundleId: $0.bundleId, liveKey: $0, slot: nil) }
    case .template(let tree, let zoomedSlots):
      let present = Set(tree.windows)
      return zoomedSlots
        .filter { present.contains($0) }
        .sorted { ($0.bundleId, $0.occurrence) < ($1.bundleId, $1.occurrence) }
        .map { (bundleId: $0.bundleId, liveKey: nil, slot: $0) }
    }
  }

  // MARK: Trimmed → full-tree path mapping

  public func fullLeafPath(trimmedLeafPath: [BSPSide], hidden: Set<String>) -> [BSPSide]? {
    switch self {
    case .live(let tree, let zoomed):
      guard let trimmed = Self.trim(tree, removing: zoomed),
            case .leaf(let leaf) = trimmed.subtree(at: trimmedLeafPath),
            let rep = leaf.windowList.first
      else { return nil }
      return tree.pathTo(window: rep)
    case .template(let tree, let zoomedSlots):
      // `SlotID` is unique per leaf, so a direct `pathTo` disambiguates same-app
      // leaves — no tokenization needed.
      guard let trimmed = Self.trimTemplate(tree, zoomedSlots: zoomedSlots, hidden: hidden),
            case .leaf(let leaf) = trimmed.subtree(at: trimmedLeafPath),
            let slot = leaf.windowList.first
      else { return nil }
      return tree.pathTo(window: slot)
    }
  }

  public func fullBranchPath(trimmedBranchPath: [BSPSide], hidden: Set<String>) -> [BSPSide]? {
    switch self {
    case .live(let tree, let zoomed):
      guard let trimmed = Self.trim(tree, removing: zoomed),
            case .branch(let b) = trimmed.subtree(at: trimmedBranchPath),
            let l = b.left.windows.first, let r = b.right.windows.first,
            let lp = tree.pathTo(window: l), let rp = tree.pathTo(window: r)
      else { return nil }
      return Self.commonPrefix(lp, rp)
    case .template(let tree, let zoomedSlots):
      guard let trimmed = Self.trimTemplate(tree, zoomedSlots: zoomedSlots, hidden: hidden),
            case .branch(let b) = trimmed.subtree(at: trimmedBranchPath),
            let l = b.left.windows.first, let r = b.right.windows.first,
            let lp = tree.pathTo(window: l), let rp = tree.pathTo(window: r)
      else { return nil }
      return Self.commonPrefix(lp, rp)
    }
  }

  private static func trim(_ tree: BSPNode<WindowKey>, removing zoomed: Set<WindowKey>) -> BSPNode<WindowKey>? {
    var trimmed: BSPNode<WindowKey>? = tree
    for key in zoomed where tree.pathTo(window: key) != nil { trimmed = trimmed?.removing(key) }
    return trimmed
  }

  /// Trim the template for rendering + path-mapping: drop every slot of a
  /// `hidden` app (a shared app with no live window — it wouldn't tile on
  /// switch) and every fullscreen-zoomed slot. `SlotID` is unique per leaf, so
  /// removal is exact (no count-based guessing) and the surviving structure maps
  /// back to full-tree paths via a plain `pathTo`.
  private static func trimTemplate(
    _ tree: BSPNode<SlotID>,
    zoomedSlots: [SlotID],
    hidden: Set<String>
  ) -> BSPNode<SlotID>? {
    var remove = Set(zoomedSlots)
    for slot in tree.windows where hidden.contains(slot.bundleId) { remove.insert(slot) }
    guard !remove.isEmpty else { return tree }
    var trimmed: BSPNode<SlotID>? = tree
    for slot in remove { trimmed = trimmed?.removing(slot) }
    return trimmed
  }

  private static func commonPrefix(_ a: [BSPSide], _ b: [BSPSide]) -> [BSPSide] {
    var result: [BSPSide] = []
    for (x, y) in zip(a, b) {
      if x == y { result.append(x) } else { break }
    }
    return result
  }
}

/// One preview tile (a BSP leaf), positioned in canvas coordinates.
public struct RenderLeaf: Identifiable {
  public var path: [BSPSide]
  public var rect: CGRect
  public var bundleIds: [String]
  public var liveKey: WindowKey?
  /// The template slot of the leaf's first window (nil when live). Lets the view
  /// target a specific same-app window (occurrence) for inactive fullscreen.
  public var slot: SlotID?
  public var id: [BSPSide] { path }
  public var representative: String? { bundleIds.first }
  public var stackCount: Int { bundleIds.count }
}

/// One split divider (a BSP branch), positioned in canvas coordinates.
public struct RenderDivider: Identifiable {
  public var path: [BSPSide]
  public var rect: CGRect
  public var axis: BSPSplitAxis
  public var ratio: CGFloat
  public var id: [BSPSide] { path }
}
