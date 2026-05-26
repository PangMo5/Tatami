import Foundation
import Testing
@testable import TatamiKit

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
    // Wider-than-tall display → vertical split (side-by-side).
    #expect(frames[1] == CGRect(x: 0, y: 0, width: 500, height: 600))
    #expect(frames[2] == CGRect(x: 500, y: 0, width: 500, height: 600))
  }

  @Test
  func tallDisplaySplitsHorizontallyFirst() {
    let display = CGRect(x: 0, y: 0, width: 600, height: 1000)
    let tree = BSPNode.build([1, 2], in: display)
    let frames = tree?.frames(in: display, gap: 0) ?? [:]
    // Taller-than-wide → horizontal split (stacked top/bottom).
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
  func removingAWindowCollapsesTheSibling() {
    let display = CGRect(x: 0, y: 0, width: 1000, height: 600)
    var tree = BSPNode.build([1, 2, 3], in: display)
    // After three insertions the left subtree (containing 1) gets split
    // again to host 3; removing 2 promotes the (1, 3) subtree to the root,
    // and that subtree now owns the full display rect.
    tree = tree?.removing(2)
    #expect(Set(tree?.windows ?? []) == [1, 3])
    let frames = tree?.frames(in: display, gap: 0) ?? [:]
    #expect(frames[1] == CGRect(x: 0, y: 0, width: 1000, height: 300))
    #expect(frames[3] == CGRect(x: 0, y: 300, width: 1000, height: 300))
  }

  @Test
  func removingTheOnlyWindowReturnsNil() {
    let tree: BSPNode<Int> = .leaf(1)
    #expect(tree.removing(1) == nil)
  }

  @Test
  func swappingTwoWindowsTransposesFrames() {
    let display = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let tree = BSPNode.build([1, 2], in: display)!
    let frames = tree.swapping(1, 2).frames(in: display, gap: 0)
    #expect(frames[2] == CGRect(x: 0, y: 0, width: 500, height: 600))
    #expect(frames[1] == CGRect(x: 500, y: 0, width: 500, height: 600))
  }

  @Test
  func togglingSplitFlipsParentAxis() {
    let display = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let tree = BSPNode.build([1, 2], in: display)!  // vertical split
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
  func pathToFindsTheLeaf() {
    let display = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let tree = BSPNode.build([1, 2, 3], in: display)!
    #expect(tree.pathTo(window: 2) == [.right])
  }
}
