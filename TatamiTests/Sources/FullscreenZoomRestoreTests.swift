import CoreGraphics
import Foundation
import Testing
@testable import TatamiKit

/// A persisted layout saves the fullscreen-zoomed windows as a
/// list of bundle ids (window identity is process-scoped and meaningless
/// after a restart). On restore, each persisted entry must consume a
/// *distinct* live window so that several zoomed windows of the same app
/// don't collapse onto one.
@Suite("FullscreenZoomRestore")
struct FullscreenZoomRestoreTests {
  private func key(_ pid: pid_t, _ wid: CGWindowID, _ bundle: String) -> WindowKey {
    WindowKey(pid: pid, windowID: wid, bundleId: bundle)
  }

  @Test
  func differentAppsBothRestore() {
    let a = key(1, 10, "com.a")
    let b = key(2, 20, "com.b")
    let resolved = WorkspaceActivationFeature.resolveFullscreenZoom(
      bundleIds: ["com.a", "com.b"], among: [a, b]
    )
    #expect(resolved == [a, b])
  }

  @Test
  func sameAppWindowsEachRestoreToADistinctWindow() {
    let a1 = key(1, 10, "com.a")
    let a2 = key(1, 11, "com.a")
    let resolved = WorkspaceActivationFeature.resolveFullscreenZoom(
      bundleIds: ["com.a", "com.a"], among: [a1, a2]
    )
    // The regression: a plain `first(where:)` collapses both onto a1.
    #expect(resolved == [a1, a2])
    #expect(resolved.count == 2)
  }

  @Test
  func mixedSameAndDifferentApps() {
    let a1 = key(1, 10, "com.a")
    let a2 = key(1, 11, "com.a")
    let b = key(2, 20, "com.b")
    let resolved = WorkspaceActivationFeature.resolveFullscreenZoom(
      bundleIds: ["com.a", "com.b", "com.a"], among: [a1, a2, b]
    )
    #expect(resolved == [a1, a2, b])
  }

  @Test
  func degradesWhenFewerLiveWindowsThanSaved() {
    let a1 = key(1, 10, "com.a")
    // Saved two "com.a" zooms but only one window is live now.
    let resolved = WorkspaceActivationFeature.resolveFullscreenZoom(
      bundleIds: ["com.a", "com.a"], among: [a1]
    )
    #expect(resolved == [a1])
  }

  @Test
  func dropsEntriesWithNoLiveMatch() {
    let a = key(1, 10, "com.a")
    let resolved = WorkspaceActivationFeature.resolveFullscreenZoom(
      bundleIds: ["com.a", "com.missing"], among: [a]
    )
    #expect(resolved == [a])
  }
}
