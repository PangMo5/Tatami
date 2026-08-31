// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Darwin
import Foundation
import Testing
@testable import TatamiKit

// MARK: - HookDefinitionTests

struct HookDefinitionTests {
  @Test
  func `defaults decode and round trip`() throws {
    let data = Data(#"{"id":"notify","event":"workspaceActivated","command":["/usr/bin/true"]}"#.utf8)
    let hook = try JSONDecoder().decode(HookDefinition.self, from: data)

    #expect(hook.enabled)
    #expect(hook.timeoutMs == 5_000)
    #expect(hook.workingDirectory == nil)
    #expect(hook.environment.isEmpty)
    #expect(try JSONDecoder().decode(HookDefinition.self, from: JSONEncoder().encode(hook)) == hook)
  }

  @Test
  func `tatami launched event decodes and round trips`() throws {
    let data = Data(#"{"id":"launch","event":"tatamiLaunched","command":["/usr/bin/true"]}"#.utf8)
    let hook = try JSONDecoder().decode(HookDefinition.self, from: data)

    #expect(hook.event == .tatamiLaunched)
    #expect(try JSONDecoder().decode(HookDefinition.self, from: JSONEncoder().encode(hook)) == hook)
  }

  @Test
  func `semantic validation rejects only invalid entries`() {
    let valid = HookDefinition(
      id: "valid-hook",
      event: .profileChanged,
      command: ["/usr/bin/true"],
    )
    let duplicateA = HookDefinition(
      id: "duplicate",
      event: .profileChanged,
      command: ["/usr/bin/true"],
    )
    let duplicateB = HookDefinition(
      id: "duplicate",
      event: .workspaceActivated,
      command: ["/usr/bin/true"],
    )
    let relativeDirectory = HookDefinition(
      id: "relative",
      event: .workspaceActivated,
      command: ["/usr/bin/true"],
      workingDirectory: "tmp",
    )

    let result = HookDefinition.validate([valid, duplicateA, duplicateB, relativeDirectory])

    #expect(result.validHooks == [valid])
    #expect(result.issues.contains { $0.contains("duplicated") })
    #expect(result.issues.contains { $0.contains("workingDirectory") })
  }

  @Test
  func `semantic validation reports every invalid field on one hook`() {
    let invalid = HookDefinition(
      id: "bad id",
      event: .workspaceActivated,
      command: ["", "bad\0argument"],
      timeoutMs: 99,
      workingDirectory: "relative/path",
      environment: [
        "1INVALID": "value",
        "VALID_KEY": "bad\0value",
      ],
    )

    let result = HookDefinition.validate([invalid])

    #expect(result.validHooks.isEmpty)
    #expect(result.detailedIssues.map(\.hookIndex) == [0, 0, 0, 0, 0, 0, 0])
    #expect(Set(result.detailedIssues.map(\.code)) == [
      .invalidID,
      .emptyCommand,
      .nulCommand,
      .timeoutOutOfRange,
      .invalidWorkingDirectory,
      .invalidEnvironment,
    ])
    #expect(result.detailedIssues.contains {
      $0.field == .environment(key: "1INVALID") && $0.code == .invalidEnvironment
    })
    #expect(result.detailedIssues.contains {
      $0.field == .environment(key: "VALID_KEY") && $0.code == .invalidEnvironment
    })
    #expect(result.issues == [
      "Hook \"bad id\" has an invalid id (use ASCII letters, numbers, '.', '_' or '-')",
      "Hook \"bad id\" has an empty command",
      "Hook \"bad id\" has a command argument containing NUL",
      "Hook \"bad id\" timeoutMs must be between 100 and 300000",
      "Hook \"bad id\" workingDirectory must be absolute or start with ~/",
      "Hook \"bad id\" has an invalid environment entry \"1INVALID\"",
      "Hook \"bad id\" has an invalid environment entry \"VALID_KEY\"",
    ])
  }

  @Test
  func `empty and overlong ids report their specific codes`() {
    let empty = HookDefinition(
      id: "",
      event: .profileChanged,
      command: ["/usr/bin/true"],
    )
    let overlong = HookDefinition(
      id: String(repeating: "a", count: 65),
      event: .profileChanged,
      command: ["/usr/bin/true"],
    )

    let result = HookDefinition.validate([empty, overlong])

    #expect(result.validHooks.isEmpty)
    #expect(result.detailedIssues.contains {
      $0.hookIndex == 0 && $0.field == .id && $0.code == .emptyID
    })
    #expect(result.detailedIssues.contains {
      $0.hookIndex == 1 && $0.field == .id && $0.code == .invalidID
    })
  }

  @Test
  func `duplicate id reports every related hook index while flat issues stay deduplicated`() {
    let first = HookDefinition(
      id: "duplicate",
      event: .profileChanged,
      command: ["/usr/bin/true"],
    )
    let second = HookDefinition(
      id: "duplicate",
      event: .workspaceActivated,
      command: ["/usr/bin/true"],
    )

    let result = HookDefinition.validate([first, second])
    let duplicateIssues = result.detailedIssues.filter { $0.code == .duplicateID }

    #expect(result.validHooks.isEmpty)
    #expect(duplicateIssues.map(\.hookIndex) == [0, 1])
    #expect(duplicateIssues.allSatisfy { $0.field == .id })
    #expect(result.issues.count { $0 == "Hook id \"duplicate\" is duplicated" } == 1)
  }

  @Test
  func `empty command array and empty executable are both invalid`() {
    let missing = HookDefinition(
      id: "missing",
      event: .profileChanged,
      command: [],
    )
    let emptyExecutable = HookDefinition(
      id: "empty-executable",
      event: .profileChanged,
      command: ["", "argument"],
    )

    let result = HookDefinition.validate([missing, emptyExecutable])

    #expect(result.validHooks.isEmpty)
    #expect(result.detailedIssues.filter { $0.code == .emptyCommand }.map(\.hookIndex) == [0, 1])
    #expect(result.detailedIssues.filter { $0.code == .emptyCommand }.allSatisfy {
      $0.field == .command
    })
  }

  @Test
  func `timeout accepts inclusive boundaries and rejects adjacent values`() {
    let hooks = [99, 100, 300_000, 300_001].enumerated().map { index, timeout in
      HookDefinition(
        id: "timeout-\(index)",
        event: .profileChanged,
        command: ["/usr/bin/true"],
        timeoutMs: timeout,
      )
    }

    let result = HookDefinition.validate(hooks)

    #expect(result.validHooks == [hooks[1], hooks[2]])
    #expect(result.detailedIssues.filter { $0.code == .timeoutOutOfRange }.map(\.hookIndex) == [0, 3])
    #expect(result.detailedIssues.filter { $0.code == .timeoutOutOfRange }.allSatisfy {
      $0.field == .timeoutMs
    })
  }

  @Test
  func `working directory accepts absolute and home relative paths`() {
    let absolute = HookDefinition(
      id: "absolute",
      event: .profileChanged,
      command: ["/usr/bin/true"],
      workingDirectory: "/tmp",
    )
    let homeRelative = HookDefinition(
      id: "home-relative",
      event: .profileChanged,
      command: ["/usr/bin/true"],
      workingDirectory: "~/Documents",
    )
    let bareHome = HookDefinition(
      id: "bare-home",
      event: .profileChanged,
      command: ["/usr/bin/true"],
      workingDirectory: "~",
    )

    let result = HookDefinition.validate([absolute, homeRelative, bareHome])

    #expect(result.validHooks == [absolute, homeRelative])
    #expect(result.detailedIssues.count == 1)
    #expect(result.detailedIssues[0].hookIndex == 2)
    #expect(result.detailedIssues[0].field == .workingDirectory)
    #expect(result.detailedIssues[0].code == .invalidWorkingDirectory)
  }

  @Test
  func `environment validates key grammar and NUL values`() {
    let valid = HookDefinition(
      id: "valid-environment",
      event: .profileChanged,
      command: ["/usr/bin/true"],
      environment: ["_A": "", "ABC_123": "value"],
    )
    let invalid = HookDefinition(
      id: "invalid-environment",
      event: .profileChanged,
      command: ["/usr/bin/true"],
      environment: ["BAD-KEY": "value", "GOOD_KEY": "bad\0value"],
    )

    let result = HookDefinition.validate([valid, invalid])
    let environmentIssues = result.detailedIssues.filter { $0.code == .invalidEnvironment }

    #expect(result.validHooks == [valid])
    #expect(environmentIssues.map(\.hookIndex) == [1, 1])
    #expect(Set(environmentIssues.map(\.field)) == [
      .environment(key: "BAD-KEY"),
      .environment(key: "GOOD_KEY"),
    ])
  }

  @Test
  func `legacy validation initializer defaults detailed issues to empty`() {
    let valid = HookDefinition(
      id: "valid",
      event: .profileChanged,
      command: ["/usr/bin/true"],
    )
    let validation = HookConfigurationValidation(validHooks: [valid], issues: [])

    #expect(validation.validHooks == [valid])
    #expect(validation.issues.isEmpty)
    #expect(validation.detailedIssues.isEmpty)
  }
}

// MARK: - HookRunnerTests

struct HookRunnerTests {

  // MARK: Internal

  @Test
  func `passes arguments environment working directory and JSON`() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatami-hook-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let profile = HookInvocation.ProfileSnapshot(
      id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
      name: "Dual",
    )
    let invocation = HookInvocation(
      event: .profileChanged,
      occurredAt: Date(timeIntervalSince1970: 0),
      profile: profile,
    )
    let script = #"""
      printf '%s\n' "$TATAMI_HOOK_EVENT"
      printf '%s\n' "$CUSTOM_VALUE"
      pwd
      cat
      """#
    let hook = HookDefinition(
      id: "runner",
      event: .profileChanged,
      command: ["/bin/zsh", "-c", script],
      timeoutMs: 2_000,
      workingDirectory: directory.path,
      environment: [
        "CUSTOM_VALUE": "from-config",
        "TATAMI_HOOK_EVENT": "must-not-win",
      ],
    )

    let result = await HookRunnerClient.liveValue.run(hook, invocation)
    guard case .success(let stdout, let stderr) = result else {
      Issue.record("Expected hook success, got \(result)")
      return
    }

    let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.count >= 5)
    #expect(lines[0] == "profileChanged")
    #expect(lines[1] == "from-config")
    let reportedDirectory = URL(fileURLWithPath: String(lines[2])).resolvingSymlinksInPath()
    #expect(reportedDirectory == directory.resolvingSymlinksInPath())
    let payload = Data(lines[3].utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    #expect(try decoder.decode(HookInvocation.self, from: payload) == invocation)
    #expect(stderr.isEmpty)
  }

  @Test
  func `nonzero exit captures both streams`() async {
    let hook = HookDefinition(
      id: "failure",
      event: .profileChanged,
      command: ["/bin/zsh", "-c", "print output; print error >&2; exit 7"],
    )

    let result = await HookRunnerClient.liveValue.run(hook, invocation())

    guard case .failure(let message, let stdout, let stderr) = result else {
      Issue.record("Expected hook failure, got \(result)")
      return
    }
    #expect(message == "Exited with status 7")
    #expect(stdout == "output\n")
    #expect(stderr == "error\n")
  }

  @Test
  func `timeout terminates the child process group`() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatami-hook-timeout-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidURL = directory.appendingPathComponent("child.pid")
    // The parent uses default SIGTERM behavior, while its child deliberately
    // ignores TERM. swift-subprocess 1.0 observes the parent exit and otherwise
    // stops before its implicit group SIGKILL, which is the leak we guard.
    let script = """
      /bin/zsh -c 'trap "" TERM; print -r -- $$ > "$1"; i=0; while (( i < 30 )); do /bin/sleep 1; (( i++ )); done' child "\(pidURL.path)" &
      wait
      """
    let hook = HookDefinition(
      id: "timeout",
      event: .profileChanged,
      command: ["/bin/zsh", "-c", script],
      timeoutMs: 2_000,
    )
    let clock = ContinuousClock()
    let started = clock.now
    let task = Task {
      await HookRunnerClient.liveValue.run(hook, invocation())
    }
    defer { task.cancel() }

    let startDeadline = clock.now.advanced(by: .seconds(3))
    while !FileManager.default.fileExists(atPath: pidURL.path), clock.now < startDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(FileManager.default.fileExists(atPath: pidURL.path))

    let result = await task.value

    guard case .failure(let message, _, _) = result else {
      Issue.record("Expected timeout failure, got \(result)")
      return
    }
    #expect(message == "Timed out after 2000 ms")
    #expect(started.duration(to: clock.now) < .seconds(4))
    let pid = try #require(Int32(
      String(contentsOf: pidURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    ))
    defer { _ = Darwin.kill(pid, SIGKILL) }
    let stopDeadline = clock.now.advanced(by: .seconds(2))
    var probe = Darwin.kill(pid, 0)
    while probe == 0, clock.now < stopDeadline {
      try await Task.sleep(for: .milliseconds(10))
      probe = Darwin.kill(pid, 0)
    }
    #expect(probe == -1)
    #expect(errno == ESRCH)
  }

  @Test
  func `leader exit also terminates surviving descendants`() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatami-hook-exit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidURL = directory.appendingPathComponent("child.pid")
    let script = """
      /bin/zsh -c 'trap "" TERM; print -r -- $$ > "$1"; i=0; while (( i < 30 )); do /bin/sleep 1; (( i++ )); done' child "\(pidURL.path)" &
      while [[ ! -s "\(pidURL.path)" ]]; do /bin/sleep 0.01; done
      """
    let hook = HookDefinition(
      id: "descendant",
      event: .profileChanged,
      command: ["/bin/zsh", "-c", script],
      timeoutMs: 5_000,
    )

    let result = await HookRunnerClient.liveValue.run(hook, invocation())
    #expect(result == .success(stdout: "", stderr: ""))
    let pid = try #require(Int32(
      String(contentsOf: pidURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    ))
    defer { _ = Darwin.kill(pid, SIGKILL) }
    #expect(Darwin.kill(pid, 0) == -1)
    #expect(errno == ESRCH)
  }

  @Test
  func `parent cancellation returns cancelled`() async {
    let hook = HookDefinition(
      id: "cancel",
      event: .profileChanged,
      command: ["/bin/sleep", "10"],
      timeoutMs: 5_000,
    )
    let task = Task {
      await HookRunnerClient.liveValue.run(hook, invocation())
    }
    await Task.yield()
    task.cancel()

    #expect(await task.value == .cancelled)
  }

  // MARK: Private

  private func invocation() -> HookInvocation {
    HookInvocation(
      event: .profileChanged,
      occurredAt: Date(timeIntervalSince1970: 0),
      profile: .init(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Default",
      ),
    )
  }

}

// MARK: - HooksFeatureTests

@MainActor
struct HooksFeatureTests {

  // MARK: Internal

  @Test
  func `invalid configuration reports the localized validation detail`() async {
    let invalid = HookDefinition(
      id: "missing-command",
      event: .profileChanged,
      command: [],
    )
    let report = LockIsolated<[String]>([])
    let state = HooksFeature.State()
    state.$config = Shared(value: AppConfig(hooks: [invalid]))
    let store = TestStore(initialState: state) {
      HooksFeature()
    } withDependencies: {
      $0.errorReporter.report = { domain, title, detail in
        report.withValue { $0 = [domain, title, detail ?? ""] }
      }
    }
    store.exhaustivity = .off

    await store.send(.configurationChanged)

    #expect(report.value == [
      "Hooks",
      String(localized: "Hook configuration is invalid"),
      String(localized: HookValidationIssue.Code.emptyCommand.localizedMessage),
    ])
  }

  @Test
  func `matching enabled hooks run and failures resolve per hook`() async {
    let matching = HookDefinition(
      id: "matching",
      event: .workspaceActivated,
      command: ["/usr/bin/true"],
    )
    let disabled = HookDefinition(
      id: "disabled",
      event: .workspaceActivated,
      enabled: false,
      command: ["/usr/bin/true"],
    )
    let otherEvent = HookDefinition(
      id: "profile",
      event: .profileChanged,
      command: ["/usr/bin/true"],
    )
    let state = HooksFeature.State()
    state.$config = Shared(value: AppConfig(hooks: [matching, disabled, otherEvent]))
    let ran = LockIsolated<[String]>([])
    let resolved = LockIsolated<[String]>([])
    let store = TestStore(initialState: state) {
      HooksFeature()
    } withDependencies: {
      $0.hookRunner.run = { hook, _ in
        ran.withValue { $0.append(hook.id) }
        return .success(stdout: "", stderr: "")
      }
      $0.errorReporter.resolve = { domain in
        resolved.withValue { $0.append(domain) }
      }
    }
    store.exhaustivity = .off

    await store.send(.emit(workspaceInvocation()))
    await store.finish()

    #expect(ran.value == ["matching"])
    #expect(resolved.value.contains("Hook:matching"))
  }

  @Test
  func `consecutive lifecycle events both run without cancelling each other`() async {
    let hook = HookDefinition(
      id: "notify",
      event: .workspaceActivated,
      command: ["/usr/bin/true"],
    )
    let state = HooksFeature.State()
    state.$config = Shared(value: AppConfig(hooks: [hook]))
    let started = LockIsolated<[Date]>([])
    let cancelled = LockIsolated(0)
    let store = TestStore(initialState: state) {
      HooksFeature()
    } withDependencies: {
      $0.hookRunner.run = { _, invocation in
        started.withValue { $0.append(invocation.occurredAt) }
        do {
          try await Task.sleep(for: .milliseconds(50))
          return .success(stdout: "", stderr: "")
        } catch {
          cancelled.withValue { $0 += 1 }
          return .cancelled
        }
      }
    }
    store.exhaustivity = .off
    var secondInvocation = workspaceInvocation()
    secondInvocation.occurredAt.addTimeInterval(1)

    await store.send(.emit(workspaceInvocation()))
    await store.send(.emit(secondInvocation))
    await store.finish()

    #expect(Set(started.value) == Set([
      workspaceInvocation().occurredAt,
      secondInvocation.occurredAt,
    ]))
    #expect(cancelled.value == 0)
  }

  @Test
  func `runtime failure reports first stderr line and later success resolves`() async {
    let reports = LockIsolated<[(String, String?)]>([])
    let resolved = LockIsolated<[String]>([])
    var state = HooksFeature.State()
    state.latestGenerationByHookID["notify"] = 1
    state.$config = Shared(value: AppConfig())
    let store = TestStore(initialState: state) {
      HooksFeature()
    } withDependencies: {
      $0.errorReporter.report = { domain, _, detail in
        reports.withValue { $0.append((domain, detail)) }
      }
      $0.errorReporter.resolve = { domain in
        resolved.withValue { $0.append(domain) }
      }
    }

    await store.send(.hookFinished(
      id: "notify",
      generation: 1,
      .failure(message: "Exited", stdout: "", stderr: "first\nsecond"),
    )) {
      $0.failingHookIDs.insert("notify")
    }
    await store.send(.hookFinished(
      id: "notify",
      generation: 1,
      .success(stdout: "", stderr: ""),
    )) {
      $0.failingHookIDs.remove("notify")
    }

    #expect(reports.value.first?.0 == "Hook:notify")
    #expect(reports.value.first?.1 == "first")
    #expect(resolved.value == ["Hook:notify"])
  }

  @Test
  func `stale completion cannot overwrite the latest hook result`() async {
    let resolved = LockIsolated<[String]>([])
    let logs = LockIsolated<[String]>([])
    var state = HooksFeature.State()
    state.latestGenerationByHookID["notify"] = 2
    state.failingHookIDs.insert("notify")
    let store = TestStore(initialState: state) {
      HooksFeature()
    } withDependencies: {
      $0.errorReporter.resolve = { domain in
        resolved.withValue { $0.append(domain) }
      }
      $0.debugLog.isEnabled = { true }
      $0.debugLog.log = { _, message in logs.withValue { $0.append(message) } }
    }

    await store.send(.hookFinished(
      id: "notify",
      generation: 1,
      .success(stdout: "old", stderr: ""),
    ))
    #expect(resolved.value.isEmpty)
    #expect(store.state.failingHookIDs == ["notify"])
    #expect(logs.value.contains { $0.contains("old") })

    await store.send(.hookFinished(
      id: "notify",
      generation: 1,
      .failure(message: "Old failure", stdout: "", stderr: "stale stderr"),
    ))
    #expect(logs.value.contains { $0.contains("Old failure") })
    #expect(logs.value.contains { $0.contains("stale stderr") })
  }

  @Test
  func `disabling a failed hook resolves its standing runtime problem`() async {
    let hook = HookDefinition(
      id: "notify",
      event: .workspaceActivated,
      command: ["/usr/bin/true"],
    )
    let disabled = HookDefinition(
      id: hook.id,
      event: hook.event,
      enabled: false,
      command: hook.command,
    )
    let resolved = LockIsolated<[String]>([])
    var state = HooksFeature.State()
    state.activeDefinitions[hook.id] = hook
    state.failingHookIDs.insert(hook.id)
    state.latestGenerationByHookID[hook.id] = 1
    state.$config = Shared(value: AppConfig(hooks: [disabled]))
    let store = TestStore(initialState: state) {
      HooksFeature()
    } withDependencies: {
      $0.errorReporter.resolve = { domain in
        resolved.withValue { $0.append(domain) }
      }
    }
    store.exhaustivity = .off

    await store.send(.configurationChanged) {
      $0.activeDefinitions = [:]
      $0.failingHookIDs = []
      $0.latestGenerationByHookID[hook.id] = 2
    }

    #expect(resolved.value.contains("Hook:notify"))
  }

  @Test
  func `changing a failed hook resolves the old definition problem`() async {
    let hook = HookDefinition(
      id: "notify",
      event: .workspaceActivated,
      command: ["/usr/bin/false"],
    )
    let changed = HookDefinition(
      id: hook.id,
      event: hook.event,
      command: ["/usr/bin/true"],
    )
    let resolved = LockIsolated<[String]>([])
    var state = HooksFeature.State()
    state.activeDefinitions[hook.id] = hook
    state.failingHookIDs.insert(hook.id)
    state.latestGenerationByHookID[hook.id] = 1
    state.$config = Shared(value: AppConfig(hooks: [changed]))
    let store = TestStore(initialState: state) {
      HooksFeature()
    } withDependencies: {
      $0.errorReporter.resolve = { domain in
        resolved.withValue { $0.append(domain) }
      }
      $0.hookRunner.run = { _, _ in .success(stdout: "", stderr: "") }
    }
    store.exhaustivity = .off

    await store.send(.emit(workspaceInvocation()))
    await store.finish()

    #expect(resolved.value.contains("Hook:notify"))
    #expect(store.state.activeDefinitions[hook.id] == changed)
    #expect(store.state.failingHookIDs.isEmpty)
  }

  // MARK: Private

  private func workspaceInvocation() -> HookInvocation {
    HookInvocation(
      event: .workspaceActivated,
      occurredAt: Date(timeIntervalSince1970: 0),
      profile: .init(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Default",
      ),
      workspace: .init(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        name: "Work",
        kind: .normal,
      ),
    )
  }

}
