// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import DemoDriverKit
import Foundation
import Testing
@testable import DemoCtlKit

@MainActor
@Suite("Capture contract")
struct CaptureContractTests {
  @Test
  func `window readiness counts same-app windows and exact checks reject leftovers`() {
    #expect(!CaptureGate.containsWindowSet(["Docs"], expected: ["Docs", "Docs"], exact: false))
    #expect(CaptureGate.containsWindowSet(["Docs", "Docs", "Editor"], expected: ["Docs", "Docs"], exact: false))
    #expect(!CaptureGate.containsWindowSet(["Docs", "Docs", "Editor"], expected: ["Docs", "Docs"], exact: true))
    #expect(CaptureGate.containsWindowSet(["Docs", "Editor", "Docs"], expected: ["Editor", "Docs", "Docs"], exact: true))
    #expect(CaptureGate.containsWindowSet([], expected: [], exact: true))
  }

  @Test
  func `exact window readiness is opt-in for existing scene files`() throws {
    for exact in [false, true] {
      let data = Data("{\"kind\":\"waitWindows\",\"apps\":[\"Docs\",\"Docs\"]\(exact ? ",\"exact\":true" : "")}".utf8)
      let step = try JSONDecoder().decode(SceneStep.self, from: data)
      guard case .waitWindows(let apps, _, let decodedExact) = step else {
        Issue.record("Expected a window readiness step")
        return
      }
      #expect(apps == ["Docs", "Docs"])
      #expect(decodedExact == exact)
    }
  }

  @Test
  func `arrow events retain their hardware key identity without adding modifiers to letters`() {
    let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskShift]
    let arrow = KeyDriver.eventFlags(for: 124, modifiers: modifiers)
    #expect(arrow.contains(.maskNumericPad))
    #expect(arrow.contains(.maskSecondaryFn))
    #expect(arrow.contains(modifiers))
    #expect(KeyDriver.eventFlags(for: 37, modifiers: modifiers) == modifiers)
  }

  @Test
  func `restoration rejects a missing, extra, moved, or resized window`() {
    let original = ["Editor:1": CGRect(x: 12, y: 40, width: 900, height: 1100)]
    #expect(CaptureGate.matches(original, original))
    #expect(!CaptureGate.matches([:], original))
    #expect(!CaptureGate.matches(original.merging(["Docs:2": .zero]) { a, _ in a }, original))
    #expect(!CaptureGate.matches(["Editor:1": CGRect(x: 22, y: 40, width: 900, height: 1100)], original))
    #expect(!CaptureGate.matches(["Editor:1": CGRect(x: 12, y: 40, width: 910, height: 1100)], original))
  }

  @Test
  func `published scenes stage off camera and never claim synthetic key presses`() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for name in ["tour", "workspaces", "tiling", "borrow", "shared", "switching", "autoopen"] {
      let scene = try JSONDecoder().decode(Scene.self, from: Data(contentsOf: root.appendingPathComponent("scenes/\(name).json")))
      #expect(!(scene.setup ?? []).isEmpty)
      #expect(scene.steps.contains {
        if case .caption = $0 {
          true
        } else {
          false
        }
      })
      for step in scene.steps {
        if case .keys(let chord) = step {
          #expect(chord.isEmpty, "keycast must come from a key or hold step")
        }
        if case .quitApps(let apps) = step {
          #expect(apps != nil, "whole-stage teardown belongs in setup")
        }
        if case .beat(let ms, _) = step {
          #expect(ms <= 3000, "avoid long static beats")
        }
        if case .caption(let text) = step {
          let parts = text.components(separatedBy: " | ")
          #expect(try #require(parts.first?.count) <= 66)
          #expect(parts.dropFirst().joined().count <= 78)
        }
      }
    }
  }
}
