// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TatamiKit

struct CaptureStreamFrameGateTests {
  @Test
  func `late frames from a replaced stream are rejected`() {
    let first = NSObject()
    let second = NSObject()
    let gate = CaptureStreamFrameGate()
    gate.activate(ObjectIdentifier(first))
    #expect(gate.accepts(ObjectIdentifier(first)))
    gate.activate(ObjectIdentifier(second))
    #expect(!gate.accepts(ObjectIdentifier(first)))
    #expect(gate.accepts(ObjectIdentifier(second)))
  }

  @Test
  func `stop rejects further output while retaining no stream identity`() {
    let stream = NSObject()
    let gate = CaptureStreamFrameGate()
    gate.activate(ObjectIdentifier(stream))
    gate.invalidate()
    #expect(!gate.accepts(ObjectIdentifier(stream)))
  }

  @Test
  func `old stop callback cannot retire the replacement stream`() {
    let old = NSObject()
    let current = NSObject()
    let gate = CaptureStreamFrameGate()
    gate.activate(ObjectIdentifier(old))
    gate.activate(ObjectIdentifier(current))
    gate.deactivate(ObjectIdentifier(old))
    #expect(gate.accepts(ObjectIdentifier(current)))
  }
}
