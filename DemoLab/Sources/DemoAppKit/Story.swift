// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Observation

public struct StoryTask: Codable, Identifiable, Equatable, Sendable {
  public let id: Int
  public var text: String
  public var done: Bool
  public init(id: Int, text: String, done: Bool) { self.id = id; self.text = text; self.done = done }
}
public struct StoryMessage: Codable, Identifiable, Equatable, Sendable {
  public let id: Int
  public init(id: Int, author: String, text: String) { self.id = id; self.author = author; self.text = text }
  public let author: String
  public let text: String
}
public struct CopyCheck: Codable, Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let passed: Bool
}
public struct LaunchStory: Codable, Equatable, Sendable {
  public var headline = "A better way to manage all the windows on your desktop."
  public var body = "Give every task its own workspace. Bring the apps you need together, keep their layout, and return to your work without rearranging windows."
  public var designTheme = "cobalt"
  public var exported = false
  public var revision = 1
  public var approved = false
  public var reviewComment = ""
  public var checks: [CopyCheck] = []
  public var tasks = [StoryTask(id: 1, text: "Review the launch copy", done: false),
                      StoryTask(id: 2, text: "Add a product screenshot", done: false)]
  public var messages = [StoryMessage(id: 1, author: "Mina", text: "The launch brief is ready. Can you make the headline a little shorter?"),
                         StoryMessage(id: 2, author: "You", text: "On it. I’ll send the updated copy here."),
                         StoryMessage(id: 3, author: "Mina", text: "Thanks! Let’s keep it calm and easy to understand.")]
  public init() {}

  public func evaluateCopy() -> [CopyCheck] {
    [CopyCheck(id: "headline", title: "Headline is 1–40 characters", passed: (1...40).contains(headline.count)),
     CopyCheck(id: "body", title: "Description explains the workflow", passed: body.count >= 40),
     CopyCheck(id: "workspace", title: "The main idea is workspaces", passed: body.lowercased().contains("workspace"))]
  }
}

public struct StoryRepository: Sendable {
  public let file: URL
  public init(file: URL = DemoControl.directory.appendingPathComponent("launch-story.json")) { self.file = file }
  public func load() throws -> LaunchStory {
    guard FileManager.default.fileExists(atPath: file.path) else { return LaunchStory() }
    return try JSONDecoder().decode(LaunchStory.self, from: Data(contentsOf: file))
  }
  public func write(_ story: LaunchStory) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(story).write(to: file, options: .atomic)
    DistributedNotificationCenter.default().postNotificationName(Self.changed, object: nil, userInfo: nil, deliverImmediately: true)
  }
  public static let changed = Notification.Name("dev.PangMo5.DemoLab.storyChanged")
}

/// Shared persisted work, observed across the seven independent app processes.
@MainActor @Observable
public final class StorySession {
  public var story = LaunchStory()
  public var error = ""
  @ObservationIgnored private var observation: NSObjectProtocol?
  @ObservationIgnored private let repository = StoryRepository()
  public init() {}
  public func start() {
    refresh()
    guard observation == nil else { return }
    observation = DistributedNotificationCenter.default().addObserver(forName: StoryRepository.changed, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }
  public func refresh() {
    do { story = try repository.load(); error = "" }
    catch { self.error = String(describing: error) }
  }
  public func update(_ change: (inout LaunchStory) -> Void) {
    do {
      var latest = try repository.load()
      change(&latest)
      try repository.write(latest)
      story = latest
      error = ""
    } catch { self.error = String(describing: error) }
  }
}
