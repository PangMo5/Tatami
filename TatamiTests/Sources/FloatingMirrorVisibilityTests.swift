// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ApplicationServices
import CoreGraphics
import Testing
@testable import TatamiKit

struct FloatingMirrorVisibilityTests {

  // MARK: Internal

  @Test
  func `missing source is not a completed handover`() {
    #expect(!exposed([window(20, pid: 2)]))
    var hidden = window(10, pid: 1)
    hidden.alpha = 0
    #expect(!exposed([hidden]))
  }

  @Test
  func `source geometry must match the displayed mirror`() {
    var moved = window(10, pid: 1)
    moved.surface.frame.origin.x += 20
    #expect(!exposed([moved]))
  }

  @Test
  func `normal window above the source delays handover`() {
    #expect(!exposed([window(20, pid: 2), window(10, pid: 1)]))
    #expect(exposed([window(10, pid: 1), window(20, pid: 2)]))
  }

  @Test
  func `focused handover verifies sibling floating occlusion too`() {
    let windows = [window(20, pid: 2), window(10, pid: 1)]
    #expect(!exposed(windows))
    #expect(exposed(windows, ignoring: [2]))
  }

  @Test
  func `unrelated display and elevated controls do not delay handover`() {
    var otherDisplay = window(20, pid: 2)
    otherDisplay.surface.frame.origin.x = 2000
    var elevated = window(30, pid: 3)
    elevated.surface.layer = 1000
    #expect(exposed([otherDisplay, elevated, window(10, pid: 1)]))
  }

  @Test
  func `focus waits for the restored mirror identity geometry and opacity`() {
    var panel = window(90, pid: 9)
    panel.surface.layer = 5
    let frames: [CGWindowID: CGRect] = [90: frame]
    #expect(areFloatingMirrorsPresented(frames, ownerPID: 9, windows: [panel]))
    #expect(!areFloatingMirrorsPresented(frames, ownerPID: 8, windows: [panel]))
    #expect(!areFloatingMirrorsPresented(frames, ownerPID: 9, windows: []))
    panel.alpha = 0.5
    #expect(!areFloatingMirrorsPresented(frames, ownerPID: 9, windows: [panel]))
    panel.alpha = 1
    panel.surface.frame.origin.x += 20
    #expect(!areFloatingMirrorsPresented(frames, ownerPID: 9, windows: [panel]))
  }

  @Test
  func `native titlebar surfaces do not keep their parent captured`() {
    var titlebar = window(11, pid: 1)
    titlebar.surface.frame = CGRect(x: 10, y: 10, width: 66, height: 20)
    #expect(isFloatingMirrorSourceExposed(
      key,
      frame: frame,
      ignoringPIDs: [],
      windows: [titlebar, window(10, pid: 1)],
      sourceWindowIDs: [10],
    ))
  }

  @Test
  func `another real window of the same app still blocks handover`() {
    #expect(!isFloatingMirrorSourceExposed(
      key,
      frame: frame,
      ignoringPIDs: [],
      windows: [window(11, pid: 1), window(10, pid: 1)],
      sourceWindowIDs: [10, 11],
    ))
  }

  @Test
  func `demoted mirror proxies do not count as native occluders`() {
    #expect(isFloatingMirrorSourceExposed(
      key,
      frame: frame,
      ignoringPIDs: [],
      windows: [window(90, pid: 9), window(10, pid: 1)],
      sourceWindowIDs: [10],
      mirrorWindowIDs: [90],
    ))
    #expect(!isFloatingMirrorSourceExposed(
      key,
      frame: frame,
      ignoringPIDs: [],
      windows: [window(91, pid: 9), window(10, pid: 1)],
      sourceWindowIDs: [10],
      mirrorWindowIDs: [90],
    ))
  }

  @Test
  func `capture controls and native dialogs do not occlude their parent interaction`() {
    #expect(!isFloatingMirrorOccludingSubrole(kAXDialogSubrole))
    #expect(isFloatingMirrorOccludingSubrole(kAXStandardWindowSubrole))
    #expect(isFloatingMirrorOccludingSubrole(nil))
    #expect(isFloatingMirrorOccludingSubrole("UnknownWindow"))
  }

  // MARK: Private

  private let key = WindowKey(pid: 1, windowID: 10, bundleId: "app.floating")
  private let frame = CGRect(x: 0, y: 0, width: 600, height: 400)

  private func exposed(_ windows: [WindowServerWindow], ignoring: Set<Int32> = []) -> Bool {
    isFloatingMirrorSourceExposed(key, frame: frame, ignoringPIDs: ignoring, windows: windows)
  }

  private func window(_ id: CGWindowID, pid: Int32) -> WindowServerWindow {
    WindowServerWindow(id: id, surface: WindowServerSurface(ownerPID: pid, layer: 0, frame: frame), title: nil)
  }

}
