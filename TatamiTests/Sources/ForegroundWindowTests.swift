// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Testing
@testable import TatamiKit

struct ForegroundWindowTests {

  // MARK: Internal

  @Test
  func `raised document is adopted while elevated controls remain visible`() {
    let overlay = window(201, pid: 20, layer: 1000)
    let document = window(200, pid: 20)
    let background = window(100, pid: 10)
    #expect(isForegroundWorkWindow(key, in: [overlay, document, background]))
  }

  @Test
  func `preserved document behind the active workspace is not foreground work`() {
    let overlay = window(201, pid: 20, layer: 1000)
    let activeWorkspace = window(100, pid: 10)
    let preservedDocument = window(200, pid: 20)
    #expect(!isForegroundWorkWindow(key, in: [overlay, activeWorkspace, preservedDocument]))
  }

  @Test
  func `focused elevated control cannot reclaim a workspace`() {
    let overlayKey = WindowKey(pid: 20, windowID: 201, bundleId: key.bundleId)
    #expect(!isForegroundWorkWindow(overlayKey, in: [window(201, pid: 20, layer: 1000), window(200, pid: 20)]))
  }

  @Test
  func `other display windows do not occlude the focused document`() {
    var otherDisplay = window(100, pid: 10)
    otherDisplay.surface.frame.origin.x = 1000
    #expect(isForegroundWorkWindow(key, in: [otherDisplay, window(200, pid: 20)]))
  }

  @Test
  func `missing or transparent document is not foreground evidence`() {
    #expect(!isForegroundWorkWindow(key, in: [window(100, pid: 10)]))
    var hidden = window(200, pid: 20)
    hidden.alpha = 0
    #expect(!isForegroundWorkWindow(key, in: [hidden]))
  }

  // MARK: Private

  private let key = WindowKey(pid: 20, windowID: 200, bundleId: "app.document")
  private let frame = CGRect(x: 0, y: 0, width: 800, height: 600)

  private func window(_ id: CGWindowID, pid: Int32, layer: Int = 0) -> WindowServerWindow {
    WindowServerWindow(id: id, surface: WindowServerSurface(ownerPID: pid, layer: layer, frame: frame), title: nil)
  }

}
