// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Testing
@testable import TatamiKit

// MARK: - WorkspaceHUDLayoutTests

struct WorkspaceHUDLayoutTests {
  @Test(arguments: [
    (HUDPosition.topLeading, CGPoint(x: -1604, y: 908)),
    (.top, CGPoint(x: -1040, y: 908)),
    (.topTrailing, CGPoint(x: -476, y: 908)),
    (.leading, CGPoint(x: -1604, y: 477)),
    (.center, CGPoint(x: -1040, y: 477)),
    (.trailing, CGPoint(x: -476, y: 477)),
    (.bottomLeading, CGPoint(x: -1604, y: 46)),
    (.bottom, CGPoint(x: -1040, y: 46)),
    (.bottomTrailing, CGPoint(x: -476, y: 46)),
  ])
  func `action HUD anchors its fixed canvas to the selected position`(
    position: HUDPosition,
    expectedOrigin: CGPoint,
  ) {
    // Negative x plus a non-zero y catches accidental primary-screen or
    // full-frame assumptions for displays arranged beside one another.
    let visibleFrame = CGRect(x: -1600, y: 50, width: 1600, height: 1000)

    let frame = HUDLayout.actionPanelFrame(
      in: visibleFrame,
      position: position,
      size: .standard,
    )

    #expect(frame.origin == expectedOrigin)
    #expect(frame.size == CGSize(width: 480, height: 146))
  }

  @Test(arguments: [
    (HUDSize.small, CGSize(width: 403.2, height: 122.64), CGPoint(x: 2.08, y: 875.28)),
    (.standard, CGSize(width: 480, height: 146), CGPoint(x: -4, y: 858)),
    (.large, CGSize(width: 566.4, height: 172.28), CGPoint(x: -10.84, y: 838.56)),
  ])
  func `action HUD size scales its full panel while preserving the visible edge inset`(
    _ size: HUDSize,
    expectedSize: CGSize,
    expectedOrigin: CGPoint,
  ) {
    let visibleFrame = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    let frame = HUDLayout.actionPanelFrame(
      in: visibleFrame,
      position: .topLeading,
      size: size,
    )
    #expect(abs(frame.width - expectedSize.width) < 0.001)
    #expect(abs(frame.height - expectedSize.height) < 0.001)
    #expect(abs(frame.minX - expectedOrigin.x) < 0.001)
    #expect(abs(frame.minY - expectedOrigin.y) < 0.001)
  }
}
