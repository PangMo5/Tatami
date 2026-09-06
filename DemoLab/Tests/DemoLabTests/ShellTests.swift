// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing

@testable import DemoCtlKit

// MARK: - Shell

@Suite("Shell")
struct ShellTests {

  /// The bug this guards against cost two hours of a shoot.
  ///
  /// `democtl seed` launches Tatami and the overlay and then exits. When those
  /// were plain `Process()` children they inherited `democtl`'s stdout, so a
  /// shell running `democtl seed | tail` never saw EOF and the `&&` chain after
  /// it never ran. Nothing failed; it simply hung forever.
  ///
  /// Writing to the log is the observable proof that the streams were replaced
  /// rather than inherited.
  @Test("launchDetached sends output to its log instead of inheriting stdout")
  func detachedOutputGoesToTheLog() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("demolab-shell-\(ProcessInfo.processInfo.processIdentifier)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("nested/detached.log")

    let process = try Shell.launchDetached(
      URL(fileURLWithPath: "/bin/sh"),
      ["-c", "echo out; echo err 1>&2"],
      log: log
    )
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    let written = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    #expect(written.contains("out"), "stdout was not redirected into the log")
    #expect(written.contains("err"), "stderr was not redirected into the log")
  }

  /// A detached process must not hold a terminal it may not have.
  @Test("launchDetached gives the child no stdin")
  func detachedStdinIsClosed() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("demolab-shell-stdin-\(ProcessInfo.processInfo.processIdentifier)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("stdin.log")

    // `cat` reads to EOF. With the null device it sees EOF at once; with an
    // inherited terminal it would block here forever.
    let process = try Shell.launchDetached(
      URL(fileURLWithPath: "/bin/sh"),
      ["-c", "cat; echo drained"],
      log: log
    )
    let finished = Shell.wait(timeout: .seconds(5)) { !process.isRunning }
    #expect(finished, "a detached child was left waiting on stdin")
    #expect(((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("drained"))
  }

  @Test("run drains both pipes, so a chatty child cannot deadlock it")
  func runDrainsBothPipes() throws {
    // More than a pipe buffer on each stream at once. Draining one fully before
    // touching the other would wedge on whichever filled first.
    let result = try Shell.run(
      URL(fileURLWithPath: "/bin/sh"),
      ["-c", "yes out | head -c 200000; yes err | head -c 200000 1>&2"]
    )
    #expect(result.succeeded)
    #expect(result.standardOutput.count >= 200_000)
    #expect(result.standardError.count >= 200_000)
  }

}
