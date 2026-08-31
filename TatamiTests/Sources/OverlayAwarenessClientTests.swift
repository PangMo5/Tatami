// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Testing
@testable import TatamiKit

// MARK: - OverlayAwarenessClientTests

struct OverlayAwarenessClientTests {

  // MARK: Internal

  @Test
  func `elevated on screen top level window preserves process`() {
    #expect(
      hasVisibleElevatedOverlay(
        topLevelWindowIDs: topLevel,
        ownerPID: pid,
        surfaces: [surface(windowID: 200, ownerPID: pid, layer: 1000)],
      )
    )
  }

  @Test(arguments: [
    [OverlayWindowSurface(windowID: 300, ownerPID: 41, layer: 1000, alpha: 1, frame: .unit)],
    [OverlayWindowSurface(windowID: 200, ownerPID: 99, layer: 1000, alpha: 1, frame: .unit)],
    [OverlayWindowSurface(windowID: 200, ownerPID: 41, layer: 0, alpha: 1, frame: .unit)],
    [OverlayWindowSurface(windowID: 200, ownerPID: 41, layer: 3, alpha: 0, frame: .unit)],
    [OverlayWindowSurface(windowID: 200, ownerPID: 41, layer: 3, alpha: 1, frame: .zero)],
  ])
  func `non overlay surfaces do not preserve`(_ surfaces: [OverlayWindowSurface]) {
    #expect(
      !hasVisibleElevatedOverlay(
        topLevelWindowIDs: topLevel,
        ownerPID: pid,
        surfaces: surfaces,
      )
    )
  }

  @Test
  func `background registry tracks processes independently`() {
    let state = OverlayAwarenessState()
    let first = OverlayAwareProcess(bundleId: "notion.id", pid: 41)
    let second = OverlayAwareProcess(bundleId: "notion.id", pid: 42)
    state.configure(["notion.id"])

    state.setBackgrounded(first, true)
    state.setBackgrounded(second, true)
    state.setBackgrounded(first, false)

    #expect(!state.isBackgrounded(pid: first.pid))
    #expect(state.isBackgrounded(pid: second.pid))
    #expect(state.isBackgrounded(bundleId: "notion.id"))
  }

  @Test
  func `removing allowlist retains suppression until hide completes`() {
    let state = OverlayAwarenessState()
    let process = OverlayAwareProcess(bundleId: "notion.id", pid: 41)
    state.configure(["notion.id"])
    state.setBackgrounded(process, true)

    state.configure([])

    #expect(state.isBackgrounded(pid: process.pid))
    state.setBackgrounded(process, false)
    #expect(!state.isBackgrounded(pid: process.pid))
  }

  @Test
  func `ending evaluation clears only its provisional suppression`() {
    let state = OverlayAwarenessState()
    let process = OverlayAwareProcess(bundleId: "notion.id", pid: 41)
    state.configure(["notion.id"])

    let first = state.beginEvaluation([process])
    let second = state.beginEvaluation([process])
    state.endEvaluation(first)

    #expect(state.isBackgrounded(pid: process.pid))
    state.endEvaluation(second)
    #expect(!state.isBackgrounded(pid: process.pid))
  }

  @Test
  func `committed suppression outlives evaluation lease`() {
    let state = OverlayAwarenessState()
    let process = OverlayAwareProcess(bundleId: "notion.id", pid: 41)
    state.configure(["notion.id"])

    let evaluation = state.beginEvaluation([process])
    let committed = state.commitEvaluation(evaluation, preserving: [process])
    state.endEvaluation(evaluation)

    #expect(committed == [process])
    #expect(state.isBackgrounded(pid: process.pid))
    state.setBackgrounded(process, false)
    #expect(!state.isBackgrounded(pid: process.pid))
  }

  @Test
  func `clearing target bundle removes committed and provisional suppression`() {
    let state = OverlayAwarenessState()
    let process = OverlayAwareProcess(bundleId: "notion.id", pid: 41)
    state.configure(["notion.id"])

    _ = state.beginEvaluation([process])
    state.setBackgrounded(process, true)
    state.clearBackgrounded(bundleId: process.bundleId)

    #expect(!state.isBackgrounded(bundleId: process.bundleId))
    #expect(!state.isBackgrounded(pid: process.pid))
  }

  @Test
  func `revoked evaluation cannot resurrect a cleared process`() {
    let state = OverlayAwarenessState()
    let process = OverlayAwareProcess(bundleId: "notion.id", pid: 41)
    state.configure(["notion.id"])

    let evaluation = state.beginEvaluation([process])
    state.clearBackgrounded(pid: process.pid)
    let committed = state.commitEvaluation(evaluation, preserving: [process])
    let promoted = state.promoteBackgrounded(process, from: evaluation)

    #expect(committed.isEmpty)
    #expect(!promoted)
    #expect(!state.isBackgrounded(pid: process.pid))
  }

  @Test
  func `failed hide can retain suppression after allowlist removal`() {
    let state = OverlayAwarenessState()
    let process = OverlayAwareProcess(bundleId: "notion.id", pid: 41)
    state.configure(["notion.id"])

    let evaluation = state.beginEvaluation([process])
    state.configure([])
    let promoted = state.promoteBackgrounded(process, from: evaluation)
    state.endEvaluation(evaluation)

    #expect(promoted)
    #expect(state.isBackgrounded(pid: process.pid))
  }

  // MARK: Private

  private let pid: pid_t = 41
  private let topLevel: Set<CGWindowID> = [100, 200]

  private func surface(
    windowID: CGWindowID,
    ownerPID: pid_t,
    layer: Int,
  ) -> OverlayWindowSurface {
    OverlayWindowSurface(
      windowID: windowID,
      ownerPID: ownerPID,
      layer: layer,
      alpha: 1,
      frame: CGRect(x: 10, y: 10, width: 184, height: 184),
    )
  }

}

extension CGRect {
  fileprivate static let unit = CGRect(x: 0, y: 0, width: 10, height: 10)
}
