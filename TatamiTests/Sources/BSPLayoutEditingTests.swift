// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Testing
@testable import TatamiKit

/// Tests the payload-agnostic layout-edit layer the GUI preview drives:
/// `applying(_:)` for each `LayoutEditOp`, the path-based structural helpers,
/// tokenize round-trip, and the region walks used to render + hit-test.
struct BSPLayoutEditingTests {

  // MARK: Internal

  @Test
  func `applying set ratio updates root branch`() throws {
    let tree = try #require(BSPNode.build([1, 2], in: wide))
    let edited = tree.applying(.setRatio(path: [], ratio: 0.7))
    let frames = edited.frames(in: wide, gap: 0)
    #expect(frames[1] == CGRect(x: 0, y: 0, width: 700, height: 600))
    #expect(frames[2] == CGRect(x: 700, y: 0, width: 300, height: 600))
  }

  @Test
  func `applying set ratio clamps to range`() throws {
    let tree = try #require(BSPNode.build([1, 2], in: wide))
    let edited = tree.applying(.setRatio(path: [], ratio: 0.99))
    let frames = edited.frames(in: wide, gap: 0)
    // Clamped to 0.9.
    #expect(frames[1]?.width == 900)
  }

  @Test
  func `applying balance matches direct call`() throws {
    let tree = try #require(BSPNode.build([1, 2, 3], in: wide))
    #expect(tree.applying(.balance) == tree.balanced(axis: .both))
  }

  @Test
  func `applying rotate matches direct call`() throws {
    let tree = try #require(BSPNode.build([1, 2, 3], in: wide))
    #expect(tree.applying(.rotate(degrees: 90)) == tree.rotated(by: 90))
  }

  @Test
  func `applying mirror matches direct call`() throws {
    let tree = try #require(BSPNode.build([1, 2, 3], in: wide))
    #expect(tree.applying(.mirror(axis: .vertical)) == tree.mirrored(axis: .vertical))
  }

  @Test
  func `toggle orientation flips parent split`() throws {
    let tree = try #require(BSPNode.build([1, 2], in: wide))
    let toggled = tree.applying(.toggleOrientation(leafPath: [.right]))
    let frames = toggled.frames(in: wide, gap: 0)
    // Was side-by-side (vertical); now stacked (horizontal).
    #expect(frames[1] == CGRect(x: 0, y: 0, width: 1000, height: 300))
    #expect(frames[2] == CGRect(x: 0, y: 300, width: 1000, height: 300))
  }

  @Test
  func `toggle orientation at root leaf is no op`() {
    let tree = BSPNode<Int>.leaf(1)
    #expect(tree.togglingSplit(atLeafPath: []) == tree)
  }

  @Test
  func `swapping leaves transposes payloads`() throws {
    let tree = try #require(BSPNode.build([1, 2], in: wide))
    let swapped = tree.applying(.swap(a: [.left], b: [.right]))
    let frames = swapped.frames(in: wide, gap: 0)
    #expect(frames[2] == CGRect(x: 0, y: 0, width: 500, height: 600))
    #expect(frames[1] == CGRect(x: 500, y: 0, width: 500, height: 600))
  }

  @Test
  func `swapping leaves matches id swap for distinct leaves`() throws {
    let tree = try #require(BSPNode.build([1, 2], in: wide))
    #expect(tree.swappingLeaves([.left], [.right]) == tree.swapping(1, 2))
  }

  @Test
  func `relocate swap zone exchanges tiles`() throws {
    let tree = try #require(BSPNode.build([1, 2], in: wide))
    let moved = tree.applying(.relocate(source: [.left], target: [.right], zone: .swap))
    #expect(moved == tree.swappingLeaves([.left], [.right]))
  }

  @Test
  func `relocate preserves every window`() throws {
    // (((1,3)|2)): 1→[.left,.left], 3→[.left,.right], 2→[.right].
    let tree = try #require(BSPNode.build([1, 2, 3], in: wide))
    let moved = tree.applying(.relocate(source: [.right], target: [.left, .left], zone: .bottom))
    #expect(Set(moved.windows) == [1, 2, 3])
    // Window 2 lands stacked under window 1 → same column, larger y.
    let frames = moved.frames(in: wide, gap: 0)
    #expect(try #require(frames[2]?.minY) > #require(frames[1]?.minY))
    #expect(try frames[2]?.minX == #require(frames[1]?.minX))
  }

  @Test
  func `tokenized round trips to original`() throws {
    let tree = try #require(BSPNode.build([10, 20, 30], in: wide))
    let (tok, back) = tree.tokenized()
    let restored = tok.mapWindows { back[$0]! }
    #expect(restored == tree)
  }

  @Test
  func `tokenized assigns unique tokens for duplicate payload`() throws {
    // Two leaves carrying the SAME bundle id — tokens must still be unique so
    // id-based ops (relocate) can't confuse them.
    let tree = try #require(BSPNode.build(["a", "a"], in: wide))
    let (tok, back) = tree.tokenized()
    #expect(Set(tok.windows).count == 2)
    #expect(back.count == 2)
    // Relocate one "a" over the other by path — the set of ids is preserved.
    let moved = tree.applying(.relocate(source: [.left], target: [.right], zone: .top))
    #expect(moved.windows.count == 2)
  }

  @Test
  func `leaf regions carry paths and frames`() throws {
    let tree = try #require(BSPNode.build([1, 2], in: wide))
    let regions = tree.leafRegions(in: wide, gap: 0)
    #expect(regions.count == 2)
    let left = regions.first { $0.path == [.left] }
    let right = regions.first { $0.path == [.right] }
    #expect(left?.rect == CGRect(x: 0, y: 0, width: 500, height: 600))
    #expect(right?.rect == CGRect(x: 500, y: 0, width: 500, height: 600))
    #expect(left?.leaf.windowList == [1])
  }

  @Test
  func `branch regions report split and ratio`() throws {
    let tree = try #require(BSPNode.build([1, 2], in: wide))
    let branches = tree.branchRegions(in: wide, gap: 0)
    #expect(branches.count == 1)
    #expect(branches.first?.path == [])
    #expect(branches.first?.axis == .vertical)
    #expect(branches.first?.ratio == 0.5)
    #expect(branches.first?.rect == wide)
  }

  @Test
  func `synthesized template builds from bundle ids`() {
    let template = BSPNode<SlotID>.synthesizedTemplate(tiledBundleIds: ["a", "b"])
    #expect(Set((template?.windows ?? []).map(\.bundleId)) == ["a", "b"])
  }

  @Test
  func `synthesized template gives repeated app distinct occurrences`() {
    let template = BSPNode<SlotID>.synthesizedTemplate(tiledBundleIds: ["a", "a"])
    #expect(Set(template?.windows ?? []) == [
      SlotID(bundleId: "a", occurrence: 0),
      SlotID(bundleId: "a", occurrence: 1),
    ])
  }

  @Test
  func `synthesized template is nil when empty`() {
    #expect(BSPNode<SlotID>.synthesizedTemplate(tiledBundleIds: []) == nil)
  }

  @Test
  func `drop zone quadrant classifies regions`() {
    let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
    #expect(DropZone.quadrant(point: CGPoint(x: 50, y: 50), in: rect) == .swap)
    #expect(DropZone.quadrant(point: CGPoint(x: 50, y: 5), in: rect) == .top)
    #expect(DropZone.quadrant(point: CGPoint(x: 50, y: 95), in: rect) == .bottom)
    #expect(DropZone.quadrant(point: CGPoint(x: 5, y: 50), in: rect) == .left)
    #expect(DropZone.quadrant(point: CGPoint(x: 95, y: 50), in: rect) == .right)
    #expect(DropZone.quadrant(point: CGPoint(x: 150, y: 50), in: rect) == nil)
  }

  // MARK: Private

  private let wide = CGRect(x: 0, y: 0, width: 1000, height: 600)

}
