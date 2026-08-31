// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import CustomDump
import Foundation
import TatamiCLIProtocol
import Testing
@testable import TatamiKit

struct GestureTests {
  @Test(arguments: [
    ([CGVector(dx: -0.12, dy: 0.01), CGVector(dx: -0.13, dy: 0)], GestureDirection.left),
    ([CGVector(dx: 0.12, dy: -0.01), CGVector(dx: 0.13, dy: 0)], .right),
    ([CGVector(dx: 0.01, dy: 0.12), CGVector(dx: 0, dy: 0.13)], .up),
    ([CGVector(dx: -0.01, dy: -0.12), CGVector(dx: 0, dy: -0.13)], .down),
  ])
  func `Dominant-axis swipe resolves in all four directions`(
    displacements: [CGVector],
    expected: GestureDirection,
  ) {
    #expect(
      GestureDirection.resolve(displacements: displacements, threshold: 0.2) == expected
    )
  }

  @Test
  func `mixed finger directions do not fire`() {
    let direction = GestureDirection.resolve(
      displacements: [
        CGVector(dx: 0.15, dy: 0),
        CGVector(dx: -0.15, dy: 0),
        CGVector(dx: 0.15, dy: 0),
      ],
      threshold: 0.2,
    )
    #expect(direction == nil)
  }

  @Test
  func `gesture lookup uses finger count and direction`() {
    let settings = AppSettings.Gestures(
      threeFinger: .init(left: .nextWorkspace, up: .toggleFullscreen),
      fourFinger: .init(right: .focusNextDisplay, down: .dismissBorrow),
    )

    #expect(settings.action(for: .init(fingerCount: 3, direction: .up)) == .toggleFullscreen)
    #expect(settings.action(for: .init(fingerCount: 4, direction: .right)) == .focusNextDisplay)
    #expect(settings.action(for: .init(fingerCount: 2, direction: .left)) == .none)
  }

  @Test
  func `gesture picker categories do not duplicate fixed actions`() {
    let categorized = GestureAction.Category.allCases.flatMap(\.actions)

    #expect(categorized.count == Set(categorized).count)
    for category in GestureAction.Category.allCases {
      #expect(category.actions.allSatisfy { $0.category == category })
    }
  }

  @Test
  func `every executable gesture capability has a domain CLI command`() throws {
    let workspaceID = try #require(
      UUID(uuidString: "00000000-0000-0000-0000-000000000001")
    )
    let profileID = try #require(
      UUID(uuidString: "00000000-0000-0000-0000-000000000002")
    )
    let actions = GestureAction.fixedActions.filter { $0 != .none } + [
      .activateWorkspace(workspaceID),
      .assignAppToWorkspace(workspaceID),
      .borrowWorkspace(workspaceID),
      .activateProfile(profileID),
    ]
    let routes = actions.compactMap(\.cliDomainCommand)

    expectNoDifference(actions.count, 38)
    expectNoDifference(routes.count, actions.count)
    expectNoDifference(Set(routes), Set(CLIMessage.DomainCommand.allCases))
    expectNoDifference(Set(routes).count, routes.count)
    for (action, route) in zip(actions, routes) {
      expectNoDifference(
        GestureAction.cliAction(
          for: route,
          workspaceId: workspaceID,
          profileId: profileID,
        ),
        action,
      )
    }
  }

  @Test
  func `workspace and profile gesture actions preserve their hotkey targets`() {
    let workspaceID = UUID()
    let profileID = UUID()

    #expect(
      GestureAction.activateWorkspace(workspaceID).hotKeyAction
        == .activateWorkspace(workspaceID)
    )
    #expect(
      GestureAction.assignAppToWorkspace(workspaceID).hotKeyAction
        == .assignFocusedAppToWorkspace(workspaceID)
    )
    #expect(
      GestureAction.borrowWorkspace(workspaceID).hotKeyAction
        == .borrowWorkspace(workspaceID)
    )
    #expect(GestureAction.activateProfile(profileID).hotKeyAction == .activateProfile(profileID))
  }
}
