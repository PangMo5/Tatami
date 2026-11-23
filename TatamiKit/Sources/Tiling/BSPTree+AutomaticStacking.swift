// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

extension BSPNode {

  // MARK: Internal

  var hasAutomaticStacks: Bool {
    firstLeaf { $0.automaticStackGroups != nil } != nil
  }

  static func nontrivialStackGroups(_ groups: [[WindowID]]?) -> [[WindowID]]? {
    let occupied = groups?.filter { !$0.isEmpty } ?? []
    return occupied.count > 1 ? occupied : nil
  }

  /// Windows sharing a tile because of a stack group.
  func collectAutomaticallyStackedWindows(into windows: inout Set<WindowID>) {
    switch self {
    case .leaf(let leaf):
      if leaf.automaticStackGroups != nil {
        windows.formUnion(leaf.windowList)
      }

    case .branch(let branch):
      branch.left.collectAutomaticallyStackedWindows(into: &windows)
      branch.right.collectAutomaticallyStackedWindows(into: &windows)
    }
  }

  /// Compare memberships at each split. A change to the windows in a surviving
  /// tile does not change the number or position of visible subdivisions.
  func hasSameTileSubdivisions(as other: BSPNode) -> Bool {
    switch (self, other) {
    case (.leaf(let lhs), .leaf(let rhs)):
      lhs.windowList.contains(where: rhs.contains)

    case (.branch(let lhs), .branch(let rhs)):
      lhs.split == rhs.split
        && lhs.left.hasSameTileSubdivisions(as: rhs.left)
        && lhs.right.hasSameTileSubdivisions(as: rhs.right)

    default:
      false
    }
  }

  /// Apply the current grouping to a live or hydrated layout. Manual stacks
  /// stay intact and mixed-app manual stacks keep their own tile.
  func reconcilingAutomaticStacks<Group: Hashable>(
    in area: CGRect,
    splitAxis: SplitAxis?,
    placement: Child,
    groupForWindow: (WindowID) -> Group?,
  ) -> BSPNode {
    var tree = self
    for region in tree.leafRegions(in: area, gap: 0) {
      let leaf = region.leaf
      guard
        let groups = Self.nontrivialStackGroups(leaf.automaticStackGroups),
        group(of: leaf, using: groupForWindow) == nil
      else { continue }
      let expanded = Self.expandingStack(leaf, groups: groups, in: region.rect, splitAxis: splitAxis, placement: placement)
      tree = tree.replacing(path: region.path) { _ in expanded }
    }

    var anchors = [Group: WindowID]()
    var absorbed = [WindowID: [BSPLeaf<WindowID>]]()
    var removed = Set<WindowID>()
    for region in tree.leafRegions(in: area, gap: 0) {
      let leaf = region.leaf
      guard let group = group(of: leaf, using: groupForWindow), let representative = leaf.windowList.first else { continue }
      if let anchor = anchors[group] {
        absorbed[anchor, default: []].append(leaf)
        removed.formUnion(leaf.windowList)
      } else {
        anchors[group] = representative
      }
    }
    guard let reduced = tree.removingAll(removed), !absorbed.isEmpty else { return tree }
    return reduced.appendingAutomaticGroups(absorbed)
  }

  /// Add a window to its established tile before considering regular BSP
  /// splitting. The return flag identifies whether an app stack was used.
  func insertingManagedWindow(
    _ window: WindowID,
    near anchor: WindowID?,
    in area: CGRect,
    splitAxis: SplitAxis?,
    placement: Child,
    groupForWindow: (WindowID) -> some Hashable?,
  ) -> (tree: BSPNode, joinedStack: Bool) {
    if
      let representative = automaticStackTarget(for: window, groupForWindow: groupForWindow),
      let stacked = stackingAutomatically(window, on: representative)
    {
      return (stacked, true)
    }
    return (
      inserting(window, near: anchor, in: area, viewSplitType: splitAxis, globalPlacement: placement),
      false,
    )
  }

  func automaticStackTarget(
    for window: WindowID,
    groupForWindow: (WindowID) -> some Hashable?,
  ) -> WindowID? {
    guard let group = groupForWindow(window) else { return nil }
    return firstLeaf(where: { self.group(of: $0, using: groupForWindow) == group })?.windowList.first
  }

  func stackingAutomatically(_ window: WindowID, on target: WindowID) -> BSPNode? {
    guard
      pathTo(window: window) == nil,
      let path = pathTo(window: target),
      case .leaf(let leaf) = subtree(at: path)
    else { return nil }
    return replacing(path: path) { _ in
      .leaf(leaf.joiningAutomaticStack(BSPLeaf(windowList: [window]), mostRecent: true))
    }
  }

  // MARK: Private

  private static func expandingStack(
    _ leaf: BSPLeaf<WindowID>,
    groups: [[WindowID]],
    in area: CGRect,
    splitAxis: SplitAxis?,
    placement: Child,
  ) -> BSPNode {
    var leaves = groups.enumerated().map { index, group in
      var result = index == 0 ? leaf : BSPLeaf(windowList: group)
      let members = Set(group)
      result.windowList = leaf.windowList.filter(members.contains)
      result.windowOrder = leaf.windowOrder.filter(members.contains)
      result.automaticStackGroups = nil
      return result
    }
    if placement == .first {
      leaves.reverse()
    }
    func build(_ index: Int, in rect: CGRect) -> BSPNode {
      guard index < leaves.count - 1 else { return .leaf(leaves[index]) }
      let axis = splitAxis ?? (rect.width >= rect.height ? .vertical : .horizontal)
      let (_, next) = axis.subdivide(rect, ratio: 0.5, gap: 0)
      return .branch(BSPBranch(
        split: axis,
        ratio: 0.5,
        left: .leaf(leaves[index]),
        right: build(index + 1, in: next),
      ))
    }
    return build(0, in: area)
  }

  private func group<Group: Hashable>(
    of leaf: BSPLeaf<WindowID>,
    using groupForWindow: (WindowID) -> Group?,
  ) -> Group? {
    guard
      let first = leaf.windowList.first,
      let group = groupForWindow(first),
      leaf.windowList.dropFirst().allSatisfy({ groupForWindow($0) == group })
    else { return nil }
    return group
  }

  private func firstLeaf(where matches: (BSPLeaf<WindowID>) -> Bool) -> BSPLeaf<WindowID>? {
    switch self {
    case .leaf(let leaf): matches(leaf) ? leaf : nil
    case .branch(let branch): branch.left.firstLeaf(where: matches) ?? branch.right.firstLeaf(where: matches)
    }
  }

  private func appendingAutomaticGroups(_ absorbed: [WindowID: [BSPLeaf<WindowID>]]) -> Self {
    switch self {
    case .leaf(let leaf):
      guard let anchor = leaf.windowList.first, let groups = absorbed[anchor] else { return self }
      return .leaf(groups.reduce(leaf) { $0.joiningAutomaticStack($1, mostRecent: false) })

    case .branch(let branch):
      return .branch(branch.with(
        left: branch.left.appendingAutomaticGroups(absorbed),
        right: branch.right.appendingAutomaticGroups(absorbed),
      ))
    }
  }

}

extension BSPLeaf {
  fileprivate func joiningAutomaticStack(_ other: Self, mostRecent: Bool) -> Self {
    var joined = self
    joined.automaticStackGroups = (automaticStackGroups ?? [windowList])
      + (other.automaticStackGroups ?? [other.windowList])
    joined.windowList.append(contentsOf: other.windowList)
    joined.windowOrder = mostRecent ? other.windowOrder + windowOrder : windowOrder + other.windowOrder
    return joined
  }
}
