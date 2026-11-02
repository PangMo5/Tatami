// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Testing
@testable import DemoRecorderKit

@Suite("Recording cadence loss accounting")
struct CadenceAccountingTests {
  @Test
  func `encoder backpressure is not counted again by the next timestamp gap`() {
    var clock = CadenceAccounting()
    #expect(clock.reserve(elapsed: 0, fps: 30) == 0)
    #expect(clock.reserve(elapsed: 1.0 / 30, fps: 30) == 1)
    clock.rejectReservedFrame()
    #expect(clock.reserve(elapsed: 2.0 / 30, fps: 30) == 2)
    #expect(clock.droppedFrameCount == 1)
  }

  @Test
  func `missed timer deadlines and a rejected slot are distinct losses`() {
    var clock = CadenceAccounting()
    _ = clock.reserve(elapsed: 0, fps: 60)
    #expect(clock.reserve(elapsed: 4.0 / 60, fps: 60) == 4)
    clock.rejectReservedFrame()
    #expect(clock.droppedFrameCount == 4)
    _ = clock.reserve(elapsed: 5.0 / 60, fps: 60)
    #expect(clock.droppedFrameCount == 4)
  }

  @Test
  func `a rejected final slot is counted without requiring another callback`() {
    var clock = CadenceAccounting()
    _ = clock.reserve(elapsed: 0, fps: 30)
    clock.rejectReservedFrame()
    #expect(clock.nextFrameIndex == 1)
    #expect(clock.droppedFrameCount == 1)
  }
}
