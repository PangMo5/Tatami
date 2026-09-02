// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import Testing
@testable import TatamiKit

// MARK: - WorkspaceHUDPresentationTests

struct WorkspaceHUDPresentationTests {

  // MARK: Internal

  @Test
  @MainActor
  func `superseded animation completion is finished and cannot satisfy its replacement`() async {
    let model = HUDPresentationModel()
    let entrance = model.setPhase(.expanded)
    let exit = model.setPhase(.collapsing)

    #expect(entrance.transition.revision != exit.transition.revision)
    var entranceIterator = entrance.completion.makeAsyncIterator()
    #expect(await entranceIterator.next() == nil)

    model.animationDidComplete(exit.transition)
    var exitIterator = exit.completion.makeAsyncIterator()
    #expect(await exitIterator.next() != nil)
    #expect(await exitIterator.next() == nil)
  }

  @Test
  func `effective presentation resolves its display and readable duration`() {
    let display = DisplayName(uuid: "display-a", name: "Built-in")
    let request = ActionHUDRequest(
      name: "Focus moved",
      symbolIconName: "arrow.right.to.line",
      subtitle: "Work is on Built-in",
      durationMs: 900,
      position: .topLeading,
      size: .small,
    )

    let presentation = ActionHUDPresentation(request: request, display: display)

    #expect(presentation.title == request.name)
    #expect(presentation.symbolIconName == request.symbolIconName)
    #expect(presentation.subtitle == request.subtitle)
    #expect(presentation.durationMs == 1_800)
    #expect(presentation.position == .topLeading)
    #expect(presentation.size == .small)
    #expect(presentation.display == display)
  }

  @Test
  func `presentation bridge emits every successful eligible HUD exactly once`() async {
    let presentedTitles = LockIsolated<[String]>([])
    let bridge = ActionHUDPresentationBridge { request in
      presentedTitles.withValue { $0.append(request.name) }
      guard request.name != "No screen" else { return nil }
      return ActionHUDPresentation(
        request: request,
        display: DisplayName(uuid: "display-a", name: "Built-in"),
      )
    }
    let first = request(name: "First")
    let second = request(name: "Second", subtitle: "Details")
    let suppressed = ActionHUDRequest(
      name: "Hook failed",
      symbolIconName: "exclamationmark.triangle.fill",
      subtitle: "Exited with status 1",
      durationMs: 2_400,
      position: .bottom,
      size: .large,
      emitsHookEvent: false,
    )
    let unresolved = request(name: "No screen")

    await bridge.show(first)
    await bridge.show(second)
    await bridge.show(suppressed)
    await bridge.show(unresolved)
    bridge.finish()
    var presentations = [ActionHUDPresentation]()
    for await presentation in bridge.presentations {
      presentations.append(presentation)
    }

    #expect(presentedTitles.value == ["First", "Second", "Hook failed", "No screen"])
    #expect(presentations.map(\.title) == ["First", "Second"])
    #expect(presentations.map(\.durationMs) == [900, 1_800])
    #expect(presentations.allSatisfy { $0.display?.uuid == "display-a" })
  }

  // MARK: Private

  private func request(name: String, subtitle: String? = nil) -> ActionHUDRequest {
    ActionHUDRequest(
      name: name,
      symbolIconName: nil,
      subtitle: subtitle,
      durationMs: 900,
      position: .top,
      size: .standard,
    )
  }

}
