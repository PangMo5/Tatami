// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import DemoAppKit
import Foundation
import Testing

@Suite("Shared work across demo apps")
struct StoryTests {
  @Test("copy validation follows the saved content, not a staged success screen")
  func checksFollowContent() {
    var draft = LaunchStory(locale: .en)
    #expect(draft.evaluateCopy().filter(\.passed).count == 2)
    draft.headline = "A calmer way to work."
    #expect(draft.evaluateCopy().allSatisfy { $0.passed })
    draft.body = ""
    #expect(draft.evaluateCopy().filter(\.passed).count == 1)
  }

  @Test("independent apps read the same saved draft, review and follow-up")
  func persistence() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let editor = StoryRepository(file: directory.appendingPathComponent("story.json"))
    let reviewer = StoryRepository(file: editor.file)
    var draft = LaunchStory(locale: .en)
    draft.headline = "A calmer way to work."
    try editor.write(draft)
    var review = try reviewer.load()
    #expect(review.headline == draft.headline)
    review.checks = review.evaluateCopy()
    review.approved = true
    review.tasks.append(StoryTask(id: 3, text: "Add a screenshot", done: false))
    try reviewer.write(review)
    let reopened = try editor.load()
    #expect(reopened.approved)
    #expect(reopened.tasks.last?.text == "Add a screenshot")
    #expect(reopened.checks.allSatisfy { $0.passed })
  }

  @Test("corrupt saved work fails instead of silently becoming the initial fixture")
  func corruption() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("not a draft".utf8).write(to: file)
    #expect(throws: (any Error).self) { try StoryRepository(file: file).load() }
  }
}
