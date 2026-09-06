// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CoreGraphics
import DemoDriverKit
import Testing
@testable import DemoCtlKit

@MainActor
@Suite("Capture contract")
struct CaptureContractTests {
  @Test("arrow events retain their hardware key identity without adding modifiers to letters")
  func arrowIdentity() {
    let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskShift]
    let arrow = KeyDriver.eventFlags(for: 124, modifiers: modifiers)
    #expect(arrow.contains(.maskNumericPad))
    #expect(arrow.contains(.maskSecondaryFn))
    #expect(arrow.contains(modifiers))
    #expect(KeyDriver.eventFlags(for: 37, modifiers: modifiers) == modifiers)
  }

  @Test("restoration rejects a missing, extra, moved, or resized window")
  func restore() {
    let original = ["Editor:1": CGRect(x: 12, y: 40, width: 900, height: 1100)]
    #expect(CaptureGate.matches(original, original))
    #expect(!CaptureGate.matches([:], original))
    #expect(!CaptureGate.matches(original.merging(["Docs:2": .zero]) { a, _ in a }, original))
    #expect(!CaptureGate.matches(["Editor:1": CGRect(x: 22, y: 40, width: 900, height: 1100)], original))
    #expect(!CaptureGate.matches(["Editor:1": CGRect(x: 12, y: 40, width: 910, height: 1100)], original))
  }

  @Test("published scenes stage off camera and never claim synthetic key presses")
  func scenes() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for name in ["tour", "workspaces", "tiling", "borrow", "shared", "switching", "autoopen"] {
      let scene = try JSONDecoder().decode(Scene.self, from: Data(contentsOf: root.appendingPathComponent("scenes/\(name).json")))
      #expect(!(scene.setup ?? []).isEmpty)
      #expect(scene.steps.contains { if case .caption = $0 { true } else { false } })
      for step in scene.steps {
        if case .keys(let chord) = step { #expect(chord.isEmpty, "keycast must come from a key or hold step") }
        if case .quitApps(let apps) = step { #expect(apps != nil, "whole-stage teardown belongs in setup") }
        if case .beat(let ms, _) = step { #expect(ms <= 3000, "avoid long static beats") }
        if case .caption(let text) = step {
          let parts = text.components(separatedBy: " | ")
          #expect(parts.first!.count <= 66)
          #expect(parts.dropFirst().joined().count <= 78)
        }
      }
    }
  }
}
