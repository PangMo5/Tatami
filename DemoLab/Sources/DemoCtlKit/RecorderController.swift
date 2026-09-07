// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Dispatch
import Foundation

// MARK: - RecordingOutcome

/// What a finished take actually produced, as the recorder reported it.
public struct RecordingOutcome: Sendable {

  // MARK: Lifecycle

  public init(outputs: [URL], frames: Int?, droppedFrames: Int?) {
    self.outputs = outputs
    self.frames = frames
    self.droppedFrames = droppedFrames
  }

  // MARK: Public

  /// Every file the recorder finalized. A `--display all` take writes one per
  /// display, so this is a list rather than the single path `democtl` used to
  /// guess before the recording started.
  public let outputs: [URL]
  /// Totals across every output, or nil when the recorder did not report them.
  public let frames: Int?
  public let droppedFrames: Int?

}

// MARK: - RecorderController

/// Starts and stops `DemoRecorder.app`.
///
/// The interesting part is *how* the process is started, which is a correctness
/// question rather than a preference — see ``LaunchPath``. macOS attributes a
/// Screen Recording grant to the responsible process, and the right responsible
/// process differs between a developer's desktop and a VM driven by
/// `tart exec`. Getting it wrong does not fail loudly: the recorder simply
/// reports no access, or records nothing.
@MainActor
public struct RecorderController {

  // MARK: Lifecycle

  public init(paths: LabPaths, recordingName: String = "recorder") {
    self.paths = paths
    self.recordingName = recordingName
  }

  // MARK: Public

  public let paths: LabPaths
  private let recordingName: String
  private var pidFile: URL { paths.runRoot.appendingPathComponent(recordingName + ".pid") }
  private var resultFile: URL { pidFile.deletingPathExtension().appendingPathExtension("json") }

  public var runningPID: Int32? {
    guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
          let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
          pid > 0
    else { return nil }
    // kill(pid, 0) only tests for existence and permission; it sends nothing.
    return kill(pid, 0) == 0 ? pid : nil
  }

  private var readyFile: URL { pidFile.deletingPathExtension().appendingPathExtension("ready.json") }

  public func elapsedSinceFirstFrame() throws -> Double {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: readyFile)) as? [String: Any]
    guard let start = object?["firstFrameUptimeNanoseconds"] as? UInt64 else {
      throw DemoCtlError.usage("recorder did not report its first-frame clock")
    }
    let now = DispatchTime.now().uptimeNanoseconds
    guard now >= start else { throw DemoCtlError.usage("invalid recorder clock") }
    return Double(now - start) / 1_000_000_000
  }

  public func captureMetadata(for movie:URL) throws -> [String:Double] {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: readyFile)) as? [String:Any]
    guard let offsets = object?["outputOffsets"] as? [String:Double], let offset = offsets[movie.lastPathComponent] else {
      throw DemoCtlError.usage("recorder did not report output offsets; rebuild the recorder bundle")
    }
    var metadata = ((object?["displays"] as? [String:[String:Double]])?[movie.lastPathComponent]) ?? [:]
    metadata["captureOffsetSeconds"] = offset
    return metadata
  }
  public func outputStatistics(for movie:URL) throws -> [String:Int] {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: resultFile)) as? [String:Any]
    guard let stats=(object?["outputStatistics"] as? [String:[String:Int]])?[movie.lastPathComponent] else {
      throw DemoCtlError.usage("recorder did not report per-output statistics")
    }
    return stats
  }

  public var bundleExists: Bool {
    FileManager.default.fileExists(atPath: paths.recorderBundle.path)
  }

  public var executable: URL {
    paths.recorderBundle.appendingPathComponent("Contents/MacOS/DemoRecorder")
  }

  /// How the recorder process is started.
  ///
  /// This is not a preference, it is a correctness question. macOS attributes a
  /// Screen Recording grant to the *responsible* process:
  ///
  /// - On an ordinary desktop, `democtl` runs from a terminal that has no such
  ///   grant, so the recorder has to become its own responsible process. That
  ///   means going through LaunchServices, and it is why the recorder ships as
  ///   an `.app` bundle at all.
  /// - Inside a VM driven by `tart exec`, the parent already holds the grant
  ///   (the guest agent is pre-authorized), and a direct child inherits it.
  ///   Going through LaunchServices there would *lose* the grant, because the
  ///   ad-hoc-signed bundle has none of its own.
  public enum LaunchPath: Sendable {
    case auto
    case viaLaunchServices
    case direct
  }

  @discardableResult
  public func start(
    output: URL,
    display: String,
    fps: Int,
    launchPath: LaunchPath = .auto
  ) throws -> URL {
    guard bundleExists else { throw DemoCtlError.bundlesMissing(["DemoRecorder"]) }
    if let pid = runningPID { throw DemoCtlError.recorderAlreadyRunning(pid: pid) }

    try FileManager.default.createDirectory(
      at: output.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    // Both handshake files, and loudly: a result file left by the previous take
    // would be read as this one's verdict, which is the exact silent difference
    // between takes this lab exists to prevent.
    for stale in [pidFile, resultFile, readyFile]
      where FileManager.default.fileExists(atPath: stale.path) {
      try FileManager.default.removeItem(at: stale)
    }

    let arguments = [
      "--output", output.path,
      "--display", display,
      "--fps", String(fps),
      "--pidfile", pidFile.path,
    ]

    // `auto`: if this process can already capture the screen, a direct child
    // inherits that. If it cannot, LaunchServices is the only path that can
    // ever be granted.
    let resolved: LaunchPath = {
      switch launchPath {
      case .auto: CGPreflightScreenCaptureAccess() ? .direct : .viaLaunchServices
      case let explicit: explicit
      }
    }()

    switch resolved {
    case .direct, .auto:
      // Detached for the same reason Tatami is: the recorder runs until it is
      // signalled, and holding the caller's stdout would hang any pipeline
      // `democtl` was started from.
      try Shell.launchDetached(
        executable,
        arguments,
        log: paths.runRoot.appendingPathComponent(recordingName + "-stdout.log")
      )

    case .viaLaunchServices:
      try Shell.require(
        URL(fileURLWithPath: "/usr/bin/open"),
        ["-n", "-a", paths.recorderBundle.path, "--args"] + arguments
      )
    }

    // The pid file says the recorder is signalable, not that ScreenCaptureKit
    // accepted the stream — it is written during startup, so it is not a
    // "capture started" barrier. What it can do is catch a startup that died:
    // the recorder writes its result file before dropping the pid file, so a
    // result during startup means the run is already over. Failing here beats
    // driving a whole scene against a recorder that exited seconds in.
    let started = try Shell.wait(timeout: .seconds(20)) { () throws -> Bool in
      if FileManager.default.fileExists(atPath: resultFile.path) {
        throw DemoCtlError.recorderFailedToStart(detail: try? readResult().failureReason)
      }
      return runningPID != nil
    }
    guard started else {
      throw DemoCtlError.waitTimedOut(what: "the recorder to start capturing", seconds: 20)
    }
    return output
  }

  /// Asks the recorder to finish, then reports what it actually wrote. SIGINT
  /// rather than SIGKILL on purpose: the recorder has to stop the stream, drain
  /// its sample queue, end the writer session and flush the movie atom. Killing
  /// it leaves an unplayable file.
  ///
  /// The recorder's own result file is the verdict. A vanished pid file only
  /// means the process is gone, and it is gone on the failure paths too — that
  /// is how a disk-full take used to be reported as "wrote <path>".
  @discardableResult
  public func stop(timeout: Duration = .seconds(30)) throws -> RecordingOutcome {
    guard let pid = runningPID else { throw DemoCtlError.recorderNotRunning }
    kill(pid, SIGINT)
    let finished = Shell.wait(timeout: timeout) { runningPID == nil }
    guard finished else {
      throw DemoCtlError.waitTimedOut(
        what: "the recorder to finish writing",
        seconds: Shell.seconds(timeout)
      )
    }
    return try verifiedOutcome()
  }

  /// Reports whether the recorder can capture. Runs the binary directly, so the
  /// answer describes *this* launch path; the authoritative check for recording
  /// is the same binary launched through `open`, which is what `start` does.
  public func preflight() throws -> Bool {
    guard bundleExists else { throw DemoCtlError.bundlesMissing(["DemoRecorder"]) }
    let result = try Shell.run(executable, ["--preflight"])
    return result.status == 0
  }

  public func nextOutputURL(scene: String, stamp: String) -> URL {
    paths.recordingsRoot.appendingPathComponent("\(scene)-\(stamp).mov")
  }

  // MARK: Private

  /// A finalized MOV carries a moov atom and at least a few frames of mdat.
  /// Anything smaller is a stub the writer never flushed.
  private static let minimumUsableRecordingBytes = 65_536

  private func verifiedOutcome() throws -> RecordingOutcome {
    let result = try readResult()
    guard result.isOK else { throw DemoCtlError.recordingFailed([result.failureReason]) }
    guard !result.outputs.isEmpty else {
      throw DemoCtlError.recordingFailed(["the recorder reported success but finalized no file"])
    }

    var problems = [String]()
    var outputs = [URL]()
    for path in result.outputs {
      let attributes = try? FileManager.default.attributesOfItem(atPath: path)
      guard let size = attributes?[.size] as? Int else {
        problems.append("\(path) is not on disk, though the recorder reported finalizing it")
        continue
      }
      guard size >= Self.minimumUsableRecordingBytes else {
        problems.append("\(path) is only \(size) bytes, which is a stub with no usable video in it")
        continue
      }
      outputs.append(URL(fileURLWithPath: path))
    }
    guard problems.isEmpty else { throw DemoCtlError.recordingFailed(problems) }
    return RecordingOutcome(outputs: outputs, frames: result.frames, droppedFrames: result.dropped)
  }

  /// The recorder's verdict. Absent or unparseable is a failure, never a
  /// success: an unverified take is exactly the thing that must not pass.
  private func readResult() throws -> RecorderResult {
    let file = resultFile
    guard let data = try? Data(contentsOf: file) else {
      throw DemoCtlError.recordingFailed([
        "the recorder exited without writing \(file.path), so nothing about this take was verified",
      ])
    }
    guard let result = RecorderResult(data: data) else {
      throw DemoCtlError.recordingFailed([
        "\(file.path) is not a result this democtl understands, so the take was not verified",
      ])
    }
    return result
  }

}

// MARK: - RecorderResult

/// Mirrors the payload DemoRecorder writes next to its pid file. DemoCtlKit does
/// not link DemoRecorderKit, so this is a cross-process contract like the exit
/// codes. `status` and `outputs` decide the verdict and are read strictly;
/// `frames`/`dropped` are diagnostics and are read leniently, since a
/// `--display all` take reports them per output and a single-display take
/// reports one number.
private struct RecorderResult {

  // MARK: Lifecycle

  init?(data: Data) {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let status = object["status"] as? String
    else { return nil }
    self.status = status
    outputs = (object["outputs"] as? [String]) ?? []
    error = object["error"] as? String
    frames = Self.total(object["frames"])
    dropped = Self.total(object["dropped"])
  }

  // MARK: Internal

  let status: String
  let outputs: [String]
  let error: String?
  let frames: Int?
  let dropped: Int?

  var isOK: Bool { status == "ok" }

  var failureReason: String {
    guard let error, !error.isEmpty else { return "the recorder reported status \"\(status)\"" }
    return error
  }

  // MARK: Private

  private static func total(_ value: Any?) -> Int? {
    if let number = value as? Int { return number }
    if let numbers = value as? [Int] { return numbers.reduce(0, +) }
    return nil
  }

}
