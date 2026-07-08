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
  /// Bundle-id template. `zoomedBundleIds` is a *list* (not a set): a workspace
  /// can hold several windows of the same app, and each fullscreen entry is one
  /// window — matching `LayoutSnapshot.fullscreenZoomedBundleIds`.
  case template(BSPNode<String>, zoomedBundleIds: [String])

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
    return .template(template, zoomedBundleIds: snapshot?.fullscreenZoomedBundleIds ?? [])
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
                   liveKey: r.leaf.windowList.first)
      }
      let dividers = trimmed.branchRegions(in: rect, gap: 0).map {
        RenderDivider(path: $0.path, rect: $0.rect, axis: $0.axis, ratio: $0.ratio)
      }
      return (tiles, dividers)
    case .template(let tree, let zoomedBundleIds):
      guard let base = Self.trimTemplate(tree, zoomedBundleIds: zoomedBundleIds, hidden: hidden)
      else { return ([], []) }
      let trimmed = pendingRatio.map { base.applying(.setRatio(path: $0.path, ratio: $0.ratio)) } ?? base
      let tiles = trimmed.leafRegions(in: rect, gap: 0).map { r in
        RenderLeaf(path: r.path, rect: r.rect, bundleIds: r.leaf.windowList, liveKey: nil)
      }
      let dividers = trimmed.branchRegions(in: rect, gap: 0).map {
        RenderDivider(path: $0.path, rect: $0.rect, axis: $0.axis, ratio: $0.ratio)
      }
      return (tiles, dividers)
    }
  }

  public func fullscreenItems() -> [(bundleId: String, liveKey: WindowKey?)] {
    switch self {
    case .live(let tree, let zoomed):
      return zoomed
        .filter { tree.pathTo(window: $0) != nil }
        .sorted { $0.windowID < $1.windowID }
        .map { (bundleId: $0.bundleId, liveKey: $0) }
    case .template(let tree, let zoomedBundleIds):
      let present = Set(tree.windows)
      return zoomedBundleIds.filter { present.contains($0) }.sorted().map { (bundleId: $0, liveKey: nil) }
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
    case .template(let tree, let zoomedBundleIds):
      // Walk the token trees, not the bundle-id tree: `pathTo(window: bundleId)`
      // would collapse repeated same-app leaves to the first occurrence, so a
      // same-app relocate/swap would target the wrong (or its own) leaf.
      let t = Self.tokenizedTrim(tree, zoomedBundleIds: zoomedBundleIds, hidden: hidden)
      guard let trimmed = t.trimmed,
            case .leaf(let leaf) = trimmed.subtree(at: trimmedLeafPath),
            let token = leaf.windowList.first
      else { return nil }
      return t.full.pathTo(window: token)
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
    case .template(let tree, let zoomedBundleIds):
      let t = Self.tokenizedTrim(tree, zoomedBundleIds: zoomedBundleIds, hidden: hidden)
      guard let trimmed = t.trimmed,
            case .branch(let b) = trimmed.subtree(at: trimmedBranchPath),
            let l = b.left.windows.first, let r = b.right.windows.first,
            let lp = t.full.pathTo(window: l), let rp = t.full.pathTo(window: r)
      else { return nil }
      return Self.commonPrefix(lp, rp)
    }
  }

  private static func trim(_ tree: BSPNode<WindowKey>, removing zoomed: Set<WindowKey>) -> BSPNode<WindowKey>? {
    var trimmed: BSPNode<WindowKey>? = tree
    for key in zoomed where tree.pathTo(window: key) != nil { trimmed = trimmed?.removing(key) }
    return trimmed
  }

  /// Tokenized trim shared by rendering and path-mapping. Rekeys the template to
  /// unique `Int` tokens (so same-bundle-id leaves stay distinct), drops every
  /// window of a `hidden` app (a shared app with no live window — it wouldn't
  /// tile on switch), and drops the fullscreen-zoomed windows by count per
  /// bundle id (a workspace with several windows of one app trims only as many
  /// as are zoomed). Returns the full and trimmed *token* trees plus the
  /// token→bundle-id map. Path mapping walks the token trees, so a repeated
  /// bundle id never collapses to its first occurrence.
  private static func tokenizedTrim(
    _ tree: BSPNode<String>,
    zoomedBundleIds: [String],
    hidden: Set<String>
  ) -> (full: BSPNode<Int>, trimmed: BSPNode<Int>?, back: [Int: String]) {
    let (tokenized, back) = tree.tokenized()
    guard !zoomedBundleIds.isEmpty || !hidden.isEmpty else { return (tokenized, tokenized, back) }
    var counts: [String: Int] = [:]
    for bid in zoomedBundleIds { counts[bid, default: 0] += 1 }
    var remove: Set<Int> = []
    for token in tokenized.windows where hidden.contains(back[token]!) { remove.insert(token) }
    for (bid, count) in counts {
      let matching = tokenized.windows.filter { back[$0] == bid }
      remove.formUnion(matching.prefix(count))
    }
    guard !remove.isEmpty else { return (tokenized, tokenized, back) }
    var trimmed: BSPNode<Int>? = tokenized
    for token in remove { trimmed = trimmed?.removing(token) }
    return (tokenized, trimmed, back)
  }

  /// Trim the template for rendering, mapped back to bundle ids.
  private static func trimTemplate(
    _ tree: BSPNode<String>,
    zoomedBundleIds: [String],
    hidden: Set<String>
  ) -> BSPNode<String>? {
    let t = tokenizedTrim(tree, zoomedBundleIds: zoomedBundleIds, hidden: hidden)
    return t.trimmed?.mapWindows { t.back[$0]! }
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
