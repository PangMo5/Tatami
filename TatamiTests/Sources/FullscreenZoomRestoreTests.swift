// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Testing
@testable import TatamiKit

/// A persisted layout saves the fullscreen-zoomed windows as `SlotID`s (window
/// identity is process-scoped and meaningless after a restart). On restore,
/// each slot resolves to the live window of that occurrence — the Nth window of
/// the app by `windowID` ascending — so several zoomed windows of one app map to
/// their exact windows rather than collapsing onto the first.
@Suite("FullscreenZoomRestore")
struct FullscreenZoomRestoreTests {

  // MARK: Internal

  @Test
  func `different apps both restore`() {
    let a = key(1, 10, "com.a")
    let b = key(2, 20, "com.b")
    let resolved = WorkspaceActivationFeature.resolveFullscreenZoom(
      slots: [slot("com.a", 0), slot("com.b", 0)],
      keyForSlot: slotToKey([a, b]),
      among: [a, b],
    )
    #expect(resolved == [a, b])
  }

  @Test
  func `same app windows each restore to A distinct window`() {
    let a1 = key(1, 10, "com.a")
    let a2 = key(1, 11, "com.a")
    let resolved = WorkspaceActivationFeature.resolveFullscreenZoom(
      slots: [slot("com.a", 0), slot("com.a", 1)],
      keyForSlot: slotToKey([a1, a2]),
      among: [a1, a2],
    )
    #expect(resolved == [a1, a2])
    #expect(resolved.count == 2)
  }

  @Test
  func `occurrence targets the exact window not just any of that app`() {
    let a1 = key(1, 10, "com.a")
    let a2 = key(1, 11, "com.a")
    // Occurrence 1 = the higher-windowID window (a2), not "some com.a window".
    let resolved = WorkspaceActivationFeature.resolveFullscreenZoom(
      slots: [slot("com.a", 1)],
      keyForSlot: slotToKey([a1, a2]),
      among: [a1, a2],
    )
    #expect(resolved == [a2])
  }

  @Test
  func `mixed same and different apps`() {
    let a1 = key(1, 10, "com.a")
    let a2 = key(1, 11, "com.a")
    let b = key(2, 20, "com.b")
    let resolved = WorkspaceActivationFeature.resolveFullscreenZoom(
      slots: [slot("com.a", 0), slot("com.b", 0), slot("com.a", 1)],
      keyForSlot: slotToKey([a1, a2, b]),
      among: [a1, a2, b],
    )
    #expect(resolved == [a1, a2, b])
  }

  @Test
  func `degrades when fewer live windows than saved`() {
    let a1 = key(1, 10, "com.a")
    // Saved two "com.a" zooms but only one window is live now — occurrence 1
    // has no live match and is dropped.
    let resolved = WorkspaceActivationFeature.resolveFullscreenZoom(
      slots: [slot("com.a", 0), slot("com.a", 1)],
      keyForSlot: slotToKey([a1]),
      among: [a1],
    )
    #expect(resolved == [a1])
  }

  @Test
  func `drops slots with no live match`() {
    let a = key(1, 10, "com.a")
    let resolved = WorkspaceActivationFeature.resolveFullscreenZoom(
      slots: [slot("com.a", 0), slot("com.missing", 0)],
      keyForSlot: slotToKey([a]),
      among: [a],
    )
    #expect(resolved == [a])
  }

  // MARK: Private

  private func key(_ pid: pid_t, _ wid: CGWindowID, _ bundle: String) -> WindowKey {
    WindowKey(pid: pid, windowID: wid, bundleId: bundle)
  }

  private func slot(_ bundle: String, _ occurrence: Int) -> SlotID {
    SlotID(bundleId: bundle, occurrence: occurrence)
  }

}
