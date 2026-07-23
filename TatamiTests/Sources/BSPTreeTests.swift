import Foundation
import Testing
@testable import TatamiKit

/// BSP tree tests cover the value-typed surface of the tiling engine:
/// insertion picks the shallowest leaf (no spiral fallback), removal
/// collapses to the surviving sibling, parent-zoom flips a leaf to its
/// parent's area, fence/resize updates the right ancestor ratio.
@Suite("BSPTree")
struct BSPTreeTests {
  @Test
  func singleWindowFillsTheRect() {
    let display = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let tree = BSPNode.build([1], in: display)
    let frames = tree?.frames(in: display, gap: 0) ?? [:]
    #expect(frames[1] == display)
  }

  @Test
  func twoWindowsSplitTheWiderAxisFirst() {
    let display = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let tree = BSPNode.build([1, 2], in: display)
    let frames = tree?.frames(in: display, gap: 0) ?? [:]
    // Wider-than-tall → vertical split (side-by-side).
    #expect(frames[1] == CGRect(x: 0, y: 0, width: 500, height: 600))
    #expect(frames[2] == CGRect(x: 500, y: 0, width: 500, height: 600))
  }

  @Test
  func tallDisplaySplitsHorizontallyFirst() {
    let display = CGRect(x: 0, y: 0, width: 600, height: 1000)
    let tree = BSPNode.build([1, 2], in: display)
    let frames = tree?.frames(in: display, gap: 0) ?? [:]
    #expect(frames[1] == CGRect(x: 0, y: 0, width: 600, height: 500))
    #expect(frames[2] == CGRect(x: 0, y: 500, width: 600, height: 500))
  }

  @Test
  func gapIsAppliedOnceBetweenSiblings() {
    let display = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let tree = BSPNode.build([1, 2], in: display)
    let frames = tree?.frames(in: display, gap: 10) ?? [:]
    #expect(frames[1]?.maxX == 495)
    #expect(frames[2]?.minX == 505)
    #expect(frames[2]!.minX - frames[1]!.maxX == 10)
  }

  @Test
  func minDepthInsertionBalancesAcrossSiblings() {
    // After three windows on a wide display, the shallowest-leaf
    // (BFS) rule picks the same depth each time. Inserting 1 → root.
    // 2 → splits root (left=1, right=2).
    // 3 → both leaves are depth 1, the BFS picks the first encountered
    // (left). So the tree becomes (((1,3)|2)).
    let display = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let tree = BSPNode.build([1, 2, 3], in: display)
    let frames = tree?.frames(in: display, gap: 0) ?? [:]
    #expect(frames.count == 3)
    // The right half stays whole, the left half splits horizontally.
    #expect(frames[2] == CGRect(x: 500, y: 0, width: 500, height: 600))
  }

  @Test
  func removingAWindowCollapsesTheSibling() {
    let display = CGRect(x: 0, y: 0, width: 1000, height: 600)
    var tree = BSPNode.build([1, 2, 3], in: display)
    tree = tree?.removing(2)
    #expect(Set(tree?.windows ?? []) == [1, 3])
  }

  @Test
  func removingTheOnlyWindowReturnsNil() {
    let tree: BSPNode<Int> = .leaf(1)
    #expect(tree.removing(1) == nil)
  }

  @Test
  func swappingTwoWindowsTransposesFrames() {
    let display = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let tree = BSPNode.build([1, 2], in: display)
    let frames = tree?.swapping(1, 2).frames(in: display, gap: 0) ?? [:]
    #expect(frames[2] == CGRect(x: 0, y: 0, width: 500, height: 600))
    #expect(frames[1] == CGRect(x: 500, y: 0, width: 500, height: 600))
  }

  @Test
  func directionalSwapUsesANeighborThenWarpsAtTheOuterEdge() {
    let display = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let tree = BSPNode.build([1, 2], in: display)!

    let swapped = tree.applyingDirectionalSwap(
      window: 1,
      direction: .east,
      in: display,
      gap: 0,
    )
    #expect(swapped == tree.swapping(1, 2))

    let warped = tree.applyingDirectionalSwap(
      window: 1,
      direction: .south,
      in: display,
      gap: 0,
    )
    let frames = warped.frames(in: display, gap: 0)
    #expect(frames[2] == CGRect(x: 0, y: 0, width: 1000, height: 300))
    #expect(frames[1] == CGRect(x: 0, y: 300, width: 1000, height: 300))
  }

  @Test
  func togglingSplitFlipsParentAxis() {
    let display = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let tree = BSPNode.build([1, 2], in: display)!
    let toggled = tree.togglingSplit(at: 2)
    let frames = toggled.frames(in: display, gap: 0)
    // After flip the children stack top/bottom rather than side-by-side.
    #expect(frames[1] == CGRect(x: 0, y: 0, width: 1000, height: 300))
    #expect(frames[2] == CGRect(x: 0, y: 300, width: 1000, height: 300))
  }

  @Test
  func resizingNudgesNearestAxisAncestor() {
    let display = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let tree = BSPNode.build([1, 2], in: display)!  // vertical split, ratio 0.5
    let grown = tree.resizing(window: 1, axis: .vertical, delta: 0.2)
    let frames = grown.frames(in: display, gap: 0)
    #expect(frames[1] == CGRect(x: 0, y: 0, width: 700, height: 600))
    #expect(frames[2] == CGRect(x: 700, y: 0, width: 300, height: 600))
  }

  @Test
  func directionalResizeAlwaysGrowsTheFocusedSide() {
    let display = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let tree = BSPNode.build([1, 2], in: display)!
    let grown = tree.resizing(window: 2, direction: .east, delta: 0.2)
    let frames = grown.frames(in: display, gap: 0)
    #expect(frames[1]?.width == 300)
    #expect(frames[2]?.width == 700)
  }

  @Test
  func pathToFindsTheLeaf() {
    let display = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let tree = BSPNode.build([1, 2, 3], in: display)!
    #expect(tree.pathTo(window: 2) == [.right])
  }

  @Test
  func parentZoomFillsTheParentBranch() {
    let display = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let tree = BSPNode.build([1, 2], in: display)!
    let zoomed = tree.togglingParentZoom(at: 2)
    let frames = zoomed.frames(in: display, gap: 0)
    // Parent of 2 is the root branch — its area is the whole display.
    // Window 1 stays in its left half (the layout walk still visits
    // it), but window 2 now renders at the parent's full area.
    #expect(frames[2] == display)
  }

  @Test
  func stackInsertPushesOntoLeaf() {
    let display = CGRect(x: 0, y: 0, width: 1000, height: 600)
    var tree: BSPNode<Int>? = .leaf(1)
    tree = tree?.settingInsertDirection(at: 1, direction: .stack)
    tree = tree?.inserting(2, near: 1, in: display)
    // Both windows occupy the same leaf, so both get the full area.
    let frames = tree?.frames(in: display, gap: 0) ?? [:]
    #expect(frames[1] == display)
    #expect(frames[2] == display)
  }

  @Test
  func balancedRedistributesByLeafCount() {
    let display = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let tree = BSPNode.build([1, 2, 3], in: display)!
    let balanced = tree.balanced(axis: .both)
    let frames = balanced.frames(in: display, gap: 0)
    #expect(frames.count == 3)
  }
}
