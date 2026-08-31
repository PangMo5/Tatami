// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Dependencies
import DependenciesMacros
import Foundation
import Subprocess

// MARK: - HookExecutionResult

public enum HookExecutionResult: Equatable, Sendable {
  case success(stdout: String, stderr: String)
  case failure(message: String, stdout: String, stderr: String)
  case cancelled
}

// MARK: - HookRunnerClient

@DependencyClient
struct HookRunnerClient: Sendable {
  var run: @Sendable (HookDefinition, HookInvocation) async -> HookExecutionResult = { _, _ in
    .cancelled
  }
}

// MARK: DependencyKey

extension HookRunnerClient: DependencyKey {
  static var liveValue: HookRunnerClient {
    HookRunnerClient(run: runHook)
  }

  static var testValue: HookRunnerClient {
    HookRunnerClient()
  }

  static var previewValue: HookRunnerClient {
    testValue
  }
}

extension DependencyValues {
  var hookRunner: HookRunnerClient {
    get { self[HookRunnerClient.self] }
    set { self[HookRunnerClient.self] = newValue }
  }
}

// MARK: - HookProcessResult

private struct HookProcessResult: Sendable {
  var termination: HookTermination
  var stdout: String
  var stderr: String
}

// MARK: - HookTermination

private enum HookTermination: Sendable {
  case exited(Int32)
  case signaled(Int32)
}

// MARK: - HookSupervisionResult

private enum HookSupervisionResult: Sendable {
  case cancelled
  case completed
  case timedOut
}

// MARK: - HookSupervisionEvent

private enum HookSupervisionEvent: Sendable {
  case cancelled
  case processExited
  case timedOut
}

private func runHook(
  _ hook: HookDefinition,
  _ invocation: HookInvocation,
) async -> HookExecutionResult {
  do {
    try Task.checkCancellation()

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let input = String(decoding: try encoder.encode(invocation), as: UTF8.self) + "\n"

    guard let executableValue = hook.command.first else {
      return .failure(message: String(localized: "Command is empty"), stdout: "", stderr: "")
    }
    let expandedExecutable = expandHome(in: executableValue)
    let executable: Executable = executableValue.contains("/")
      ? .path(.init(expandedExecutable))
      : .name(executableValue)
    let arguments = Arguments(Array(hook.command.dropFirst()))

    var environment = Subprocess.Environment.inherit
      .updating(environmentOverrides(hook.environment))
    environment = environment.updating(environmentOverrides(invocation.environment(hookID: hook.id)))
    let processEnvironment = environment

    var options = PlatformOptions()
    options.createSession = true
    options.qualityOfService = .utility
    options.teardownSequence = [
      .gracefulShutDown(
        toProcessGroup: true,
        allowedDurationToNextStep: .milliseconds(250),
      )
    ]
    let platformOptions = options

    let workingDirectory = hook.workingDirectory
      .map(expandHome(in:))
      ?? ConfigLocation.directory.path
    let result = try await run(
      executable,
      arguments: arguments,
      environment: processEnvironment,
      workingDirectory: .init(workingDirectory),
      platformOptions: platformOptions,
      input: .string(input),
      output: .string(limit: 65_536),
      error: .string(limit: 65_536),
    ) { execution in
      await supervise(execution, timeoutMs: hook.timeoutMs)
    }
    if result.closureResult == .cancelled { return .cancelled }
    if result.closureResult == .timedOut {
      return .failure(
        message: String(
          localized: "Timed out after \(hook.timeoutMs, format: .number.grouping(.never)) ms"
        ),
        stdout: result.standardOutput,
        stderr: result.standardError,
      )
    }
    let termination: HookTermination =
      switch result.terminationStatus {
      case .exited(let code): .exited(code)
      case .signaled(let signal): .signaled(signal)
      }
    let process = HookProcessResult(
      termination: termination,
      stdout: result.standardOutput,
      stderr: result.standardError,
    )

    switch process.termination {
    case .exited(0):
      return .success(stdout: process.stdout, stderr: process.stderr)

    case .exited(let code):
      return .failure(
        message: String(localized: "Exited with status \(code, format: .number.grouping(.never))"),
        stdout: process.stdout,
        stderr: process.stderr,
      )

    case .signaled(let signal):
      return .failure(
        message: String(localized: "Terminated by signal \(signal, format: .number.grouping(.never))"),
        stdout: process.stdout,
        stderr: process.stderr,
      )
    }
  } catch is CancellationError {
    return .cancelled
  } catch {
    if Task.isCancelled { return .cancelled }
    return .failure(message: String(describing: error), stdout: "", stderr: "")
  }
}

/// Supervise the isolated process session while swift-subprocess still owns the
/// unreaped leader pid. This makes session identity stable: even if the leader
/// exits before a TERM-ignoring descendant, the pid cannot be reused before
/// the terminal group SIGKILL is sent.
private func supervise(
  _ execution: Execution<some InputProtocol, some OutputProtocol, some OutputProtocol>,
  timeoutMs: Int,
) async -> HookSupervisionResult {
  let leaderPID = execution.processIdentifier.value
  let sessionID = Darwin.getsid(leaderPID) == leaderPID ? leaderPID : nil
  let exitEvents = processExitEvents(for: leaderPID)
  let first = await withTaskGroup(of: HookSupervisionEvent.self) { group in
    group.addTask {
      for await _ in exitEvents { return .processExited }
      return .cancelled
    }
    group.addTask {
      do {
        try await Task.sleep(for: .milliseconds(timeoutMs))
        return .timedOut
      } catch {
        return .cancelled
      }
    }
    let first = await group.next() ?? .cancelled
    group.cancelAll()
    return first
  }

  switch first {
  case .processExited:
    // Hooks may not daemonize descendants. Kill anything that outlived the
    // command while its zombie leader still pins the session identity. Shells
    // can put background jobs in separate process groups, so group-only cleanup
    // is insufficient even though Tatami created a fresh session.
    await killHookSession(sessionID, fallback: execution)
    return .completed

  case .timedOut:
    await terminateHookSession(sessionID, fallback: execution)
    return .timedOut

  case .cancelled:
    await terminateHookSession(sessionID, fallback: execution)
    return .cancelled
  }
}

private func terminateHookSession(
  _ sessionID: pid_t?,
  fallback execution: Execution<some InputProtocol, some OutputProtocol, some OutputProtocol>,
) async {
  if let sessionID {
    signalProcesses(inSession: sessionID, signal: SIGTERM)
  } else {
    try? execution.send(signal: .terminate, toProcessGroup: true)
  }
  // Cancellation must not skip the grace period. This child task is awaited,
  // and does not inherit the caller's cancelled state.
  await Task { try? await Task.sleep(for: .milliseconds(250)) }.value
  await killHookSession(sessionID, fallback: execution)
}

private func killHookSession(
  _ sessionID: pid_t?,
  fallback execution: Execution<some InputProtocol, some OutputProtocol, some OutputProtocol>,
) async {
  guard let sessionID else {
    try? execution.send(signal: .kill, toProcessGroup: true)
    return
  }
  // Re-scan to close the small fork-during-cleanup window. The leader remains
  // unreaped until this function returns, so this session id cannot be reused.
  for attempt in 0 ..< 3 {
    signalProcesses(inSession: sessionID, signal: SIGKILL)
    if attempt < 2 {
      await Task { try? await Task.sleep(for: .milliseconds(10)) }.value
    }
  }
}

private func signalProcesses(inSession sessionID: pid_t, signal: Int32) {
  let capacity = max(Int(Darwin.proc_listallpids(nil, 0)) + 64, 64)
  var pids = [pid_t](repeating: 0, count: capacity)
  let count = pids.withUnsafeMutableBytes { buffer in
    Darwin.proc_listallpids(buffer.baseAddress, Int32(buffer.count))
  }
  guard count > 0 else { return }
  for pid in pids.prefix(min(Int(count), pids.count))
    where pid > 1 && Darwin.getsid(pid) == sessionID
  {
    _ = Darwin.kill(pid, signal)
  }
}

private func processExitEvents(for pid: pid_t) -> AsyncStream<Void> {
  AsyncStream { continuation in
    let monitor = ProcessExitMonitor(pid: pid, continuation: continuation)
    continuation.onTermination = { _ in monitor.cancel() }
    monitor.activate()
  }
}

// MARK: - ProcessExitMonitor

private final class ProcessExitMonitor: @unchecked Sendable {

  // MARK: Lifecycle

  init(pid: pid_t, continuation: AsyncStream<Void>.Continuation) {
    source = DispatchSource.makeProcessSource(
      identifier: pid,
      eventMask: .exit,
      queue: .global(qos: .utility),
    )
    source.setEventHandler {
      continuation.yield()
      continuation.finish()
    }
    source.setCancelHandler { continuation.finish() }
  }

  // MARK: Internal

  func activate() {
    source.activate()
  }

  func cancel() {
    source.cancel()
  }

  // MARK: Private

  private let source: DispatchSourceProcess

}

private func environmentOverrides(_ values: [String: String]) -> [Subprocess.Environment.Key: String?] {
  Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
    guard let environmentKey = Subprocess.Environment.Key(rawValue: key) else { return nil }
    return (environmentKey, value)
  })
}

private func expandHome(in path: String) -> String {
  if path == "~" { return NSHomeDirectory() }
  guard path.hasPrefix("~/") else { return path }
  return NSHomeDirectory() + path.dropFirst()
}

extension HookInvocation {
  fileprivate func environment(hookID: String) -> [String: String] {
    var values = [
      "TATAMI_HOOK_ID": hookID,
      "TATAMI_HOOK_EVENT": event.rawValue,
      "TATAMI_PROFILE_ID": profile.id.uuidString,
      "TATAMI_PROFILE_NAME": profile.name,
    ]
    if let workspace {
      values["TATAMI_WORKSPACE_ID"] = workspace.id.uuidString
      values["TATAMI_WORKSPACE_NAME"] = workspace.name
      values["TATAMI_WORKSPACE_KIND"] = workspace.kind.rawValue
    }
    if let display {
      values["TATAMI_DISPLAY_NAME"] = display.name
      if let uuid = display.uuid { values["TATAMI_DISPLAY_UUID"] = uuid }
    }
    return values
  }
}
