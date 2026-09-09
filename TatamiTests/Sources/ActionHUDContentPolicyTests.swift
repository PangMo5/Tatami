// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TatamiKit

struct ActionHUDContentPolicyTests {

  // MARK: Internal

  @Test(arguments: [false, true])
  func `completion remains the headline regardless of navigation arrival order`(_ resultFirst: Bool) throws {
    let id = UUID()
    let completion = request("Added App → Work", priority: .completion, context: id, contextName: "Work")
    let navigation = request("Work", subtitle: "Desk Chain\nReturned Mail", symbol: "link", context: id)
    let merged = try #require(ActionHUDContentPolicy.merge(
      current: resultFirst ? completion : navigation,
      incoming: resultFirst ? navigation : completion,
    ))
    #expect(merged.name == completion.name)
    #expect(merged.priority == .completion)
    #expect(merged.subtitle == "Desk Chain\nReturned Mail")
    #expect(merged.subtitleSymbolIconName == "link")
  }

  @Test
  func `a new workspace starts fresh instead of carrying an unrelated completion`() {
    let result = request("Added App → Work", priority: .completion, context: UUID())
    let next = request("Home", context: UUID())
    #expect(ActionHUDContentPolicy.merge(current: result, incoming: next) == next)
  }

  @Test
  func `navigation with no new information cannot erase or repeat a completion`() {
    let id = UUID()
    let result = request("Added App → Work", priority: .completion, context: id, contextName: "Work")
    #expect(ActionHUDContentPolicy.merge(current: result, incoming: request("Work", context: id)) == nil)
  }

  @Test
  func `a failure stays visible until its own recovery or a higher priority prompt`() {
    let error = request("Save failed", priority: .warning, warningDomain: "ConfigSave")
    #expect(ActionHUDContentPolicy.merge(current: error, incoming: request("Work")) == nil)
    #expect(ActionHUDContentPolicy.merge(
      current: error,
      incoming: request("Other issue resolved", priority: .completion, warningDomain: "Other"),
    ) == nil)
    let recovery = request("Save issue resolved", priority: .completion, warningDomain: "ConfigSave")
    #expect(ActionHUDContentPolicy.merge(current: error, incoming: recovery) == recovery)
    let prompt = request("Confirm move", priority: .instruction)
    #expect(ActionHUDContentPolicy.merge(current: error, incoming: prompt) == prompt)
  }

  @Test
  func `direction prompt is replaced only by its own completion or an urgent message`() {
    let id = UUID()
    let prompt = request("Choose direction", priority: .instruction, context: id)
    #expect(ActionHUDContentPolicy.merge(current: prompt, incoming: request("Work", context: id)) == nil)
    #expect(ActionHUDContentPolicy.merge(
      current: prompt,
      incoming: request("Other action done", priority: .completion, context: UUID()),
    ) == nil)
    let completed = request("Borrowed Work", priority: .completion, context: id)
    #expect(ActionHUDContentPolicy.merge(current: prompt, incoming: completed) == completed)
    let failure = request("Permission needed", priority: .warning)
    #expect(ActionHUDContentPolicy.merge(current: prompt, incoming: failure) == failure)
  }

  // MARK: Private

  private func request(
    _ title: String,
    subtitle: String? = nil,
    symbol: String? = nil,
    priority: ActionHUDPriority = .navigation,
    context: UUID? = nil,
    contextName: String? = nil,
    warningDomain: String? = nil,
  ) -> ActionHUDRequest {
    ActionHUDRequest(
      name: title,
      symbolIconName: nil,
      subtitle: subtitle,
      subtitleSymbolIconName: symbol,
      durationMs: 900,
      position: .top,
      size: .standard,
      priority: priority,
      contextID: context,
      contextName: contextName,
      warningDomain: warningDomain,
    )
  }

}
