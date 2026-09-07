// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Darwin

// MARK: - CommandResult

public struct CommandResult: Sendable {

  // MARK: Lifecycle

  public init(status: Int32, standardOutput: String, standardError: String) {
    self.status = status
    self.standardOutput = standardOutput
    self.standardError = standardError
  }

  // MARK: Public

  public let status: Int32
  public let standardOutput: String
  public let standardError: String

  public var succeeded: Bool { status == 0 }

}

// MARK: - CommandError

public struct CommandError: Error, CustomStringConvertible {

  // MARK: Lifecycle

  public init(command: String, result: CommandResult) {
    self.command = command
    self.result = result
  }

  // MARK: Public

  public let command: String
  public let result: CommandResult

  public var description: String {
    let detail = result.standardError.isEmpty ? result.standardOutput : result.standardError
    let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
    return "\(command) failed (exit \(result.status))\(trimmed.isEmpty ? "" : ": \(trimmed)")"
  }

}

// MARK: - DataBox

/// Carries one pipe's bytes back from the draining queue. The write and the read
/// are ordered by the `DispatchGroup`, so no lock is needed.
private final class DataBox: @unchecked Sendable {
  var value = Data()
}

// MARK: - Shell

public enum Shell {

  /// NSWorkspace process notifications need a main run loop. A synchronous
  /// command must check the kernel before trusting cached app enumeration.
  public static func processExists(_ pid: pid_t) -> Bool {
    guard pid > 0 else { return false }
    return Darwin.kill(pid, 0) == 0 || errno == EPERM
  }

  // MARK: Public

  /// Runs an executable directly. No shell is involved: arguments are passed as
  /// argv, never word-split or glob-expanded, which matches how Tatami itself
  /// runs hook commands and keeps demo scripts free of quoting surprises.
  @discardableResult
  public static func run(
    _ executable: URL,
    _ arguments: [String] = [],
    environment: [String: String]? = nil,
    currentDirectory: URL? = nil
  ) throws -> CommandResult {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    if let environment {
      var merged = ProcessInfo.processInfo.environment
      for (key, value) in environment { merged[key] = value }
      process.environment = merged
    }
    if let currentDirectory { process.currentDirectoryURL = currentDirectory }

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    try process.run()
    // Both pipes have to drain at the same time. Reading them one after the
    // other deadlocks: the child parks in write(2) on whichever ~64 KiB pipe
    // buffer we are not reading yet, so it never exits, so the read we are
    // parked in never reaches EOF. `swift build` hits this the moment a broken
    // build puts more than a buffer's worth of diagnostics on stderr.
    let errBox = DataBox()
    let group = DispatchGroup()
    DispatchQueue.global(qos: .userInitiated).async(group: group) {
      errBox.value = errPipe.fileHandleForReading.readDataToEndOfFile()
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    let errData = errBox.value
    process.waitUntilExit()

    return CommandResult(
      status: process.terminationStatus,
      standardOutput: String(decoding: outData, as: UTF8.self),
      standardError: String(decoding: errData, as: UTF8.self)
    )
  }

  @discardableResult
  public static func require(
    _ executable: URL,
    _ arguments: [String] = [],
    environment: [String: String]? = nil,
    currentDirectory: URL? = nil
  ) throws -> CommandResult {
    let result = try run(executable, arguments, environment: environment, currentDirectory: currentDirectory)
    guard result.succeeded else {
      throw CommandError(command: executable.lastPathComponent, result: result)
    }
    return result
  }

  /// Starts a long-lived process and detaches its standard streams.
  ///
  /// A direct child inherits whatever stdout it was given, and a process that
  /// outlives its launcher then holds that pipe open forever. `democtl seed`
  /// launches Tatami and the overlay and exits; a shell running
  /// `democtl seed | tail` waited **two hours** on a `tail` that could never see
  /// EOF, because Tatami was still holding the write end. Detaching the streams
  /// is what makes "launch it and leave it running" safe to script.
  ///
  /// Output goes to a log rather than `/dev/null`: these are exactly the
  /// processes whose first complaint is the one worth reading.
  @discardableResult
  public static func launchDetached(
    _ executable: URL,
    _ arguments: [String] = [],
    log: URL,
    environment: [String: String]? = nil
  ) throws -> Process {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    if let environment {
      var merged = ProcessInfo.processInfo.environment
      for (key, value) in environment { merged[key] = value }
      process.environment = merged
    }

    try FileManager.default.createDirectory(
      at: log.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    if !FileManager.default.fileExists(atPath: log.path) {
      FileManager.default.createFile(atPath: log.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: log)
    // Appending rather than truncating: a log that only holds the last launch
    // is a log that has thrown away the launch that went wrong.
    _ = try? handle.seekToEnd()
    process.standardOutput = handle
    process.standardError = handle
    // Never the caller's stdin: a detached process must not compete for a
    // terminal that may not even exist.
    process.standardInput = FileHandle.nullDevice

    try process.run()
    return process
  }

  /// Blocks until `condition` is true or the deadline passes. Used instead of a
  /// fixed sleep everywhere a real signal exists, so scenes stay as fast as the
  /// machine allows without ever racing.
  @discardableResult
  public static func wait(
    timeout: Duration,
    poll: Duration = .milliseconds(60),
    until condition: () throws -> Bool
  ) rethrows -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if try condition() { return true }
      Thread.sleep(forTimeInterval: seconds(poll))
    }
    return try condition()
  }

  public static func sleep(_ duration: Duration) {
    Thread.sleep(forTimeInterval: seconds(duration))
  }

  /// One place to spell the conversion, so a timeout and the message that
  /// reports it can never disagree about how long the wait actually was.
  public static func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }

}
