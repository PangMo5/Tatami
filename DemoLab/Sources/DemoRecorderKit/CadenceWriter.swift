// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

// MARK: - RecordingSummary

/// What one finished file turned out to be.
public struct RecordingSummary: Sendable {

  // MARK: Lifecycle

  public init(
    outputURL: URL,
    width: Int,
    height: Int,
    codec: String,
    frameCount: Int,
    capturedFrameCount: Int,
    droppedFrameCount: Int,
    duration: Double
  ) {
    self.outputURL = outputURL
    self.width = width
    self.height = height
    self.codec = codec
    self.frameCount = frameCount
    self.capturedFrameCount = capturedFrameCount
    self.droppedFrameCount = droppedFrameCount
    self.duration = duration
  }

  // MARK: Public

  public let outputURL: URL
  public let width: Int
  public let height: Int
  public let codec: String
  /// Frames written to the file: cadence ticks, not capture callbacks.
  public let frameCount: Int
  /// Frames ScreenCaptureKit actually delivered. Lower than `frameCount` on a
  /// still screen, which is the cadence doing its job.
  public let capturedFrameCount: Int
  public let droppedFrameCount: Int
  public let duration: Double

}

// MARK: - CadenceWriter

/// A fixed-rate encoder placed in front of an event-driven capture source.
///
/// This is the load-bearing decision of the recorder. ScreenCaptureKit only
/// delivers a frame when something on screen changes, so appending capture
/// buffers as they arrive turns a ten second take of a still desktop into a
/// thirty millisecond file. This class inverts the relationship: a
/// `DispatchSourceTimer` ticks at exactly `fps` Hz on its own serial queue and,
/// on every tick, appends a *retimed copy* of the most recent capture buffer at
/// `startPTS + n/fps`. A still screen therefore encodes as repeated frames and
/// the file's duration matches the wall clock of the take.
///
/// The capture callback only swaps the latest-buffer slot under a lock and
/// returns. Encoding on ScreenCaptureKit's own sample handler queue drains the
/// IOSurface pool and stalls capture, so no work beyond the swap happens there.
///
/// The trade-off of holding the newest frame only: exactly one buffer out of the
/// stream's `queueDepth` of 6 is retained at a time, and every frame produced
/// between two ticks is discarded. That is deliberate — the cadence, not the
/// capture source, defines the output frame rate, and holding more surfaces
/// would starve the pool for no benefit.
public final class CadenceWriter: @unchecked Sendable {

  // MARK: Lifecycle

  public init(
    outputURL: URL,
    width: Int,
    height: Int,
    fps: Int,
    bitrateMbps: Double?,
    label: String
  ) throws {
    self.outputURL = outputURL
    self.width = width
    self.height = height
    self.fps = fps
    frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
    cadenceQueue = DispatchQueue(label: "dev.pangmo5.demolab.recorder.cadence.\(label)", qos: .userInitiated)

    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try FileManager.default.removeItem(at: outputURL)
    }

    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
    writer.movieTimeScale = CMTimeScale(fps * 1000)

    var chosenCodec = AVVideoCodecType.hevc
    var settings = CadenceWriter.videoSettings(
      codec: .hevc,
      width: width,
      height: height,
      fps: fps,
      bitrateMbps: bitrateMbps
    )
    if !writer.canApply(outputSettings: settings, forMediaType: .video) {
      // A machine without a hardware HEVC encoder — a VM, typically — rejects
      // these settings outright. Fall back, but say so: a silently different
      // codec turns into a surprise three takes later.
      StandardError.write("DemoRecorder: HEVC rejected for \(width)x\(height); falling back to H.264")
      chosenCodec = .h264
      settings = CadenceWriter.videoSettings(
        codec: .h264,
        width: width,
        height: height,
        fps: fps,
        bitrateMbps: bitrateMbps
      )
      guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
        throw RecorderError.noApplicableEncoder(width: width, height: height)
      }
    }

    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    // Set before `startWriting()`: it tells the writer the source is live and
    // must not be waited on. macOS 26 deprecates this in favour of a 26-only
    // replacement; we target macOS 14, so the deprecation warning stays.
    input.expectsMediaDataInRealTime = true
    guard writer.canAdd(input) else {
      throw RecorderError.writerSetupFailed("AVAssetWriter refused the video input for \(width)x\(height)")
    }
    writer.add(input)

    self.writer = writer
    self.input = input
    codec = CadenceWriter.name(for: chosenCodec)
  }

  // MARK: Public

  public let outputURL: URL
  public let width: Int
  public let height: Int
  /// `hevc` or `h264`, whichever the writer accepted.
  public let codec: String

  /// Starts the writer and the cadence clock. Call once, after capture is live.
  public func start() throws {
    guard writer.startWriting() else {
      throw RecorderError.writerSetupFailed(CadenceWriter.reason(writer.error))
    }
    // `.strict` keeps the timer out of dispatch's coalescing window; a leeway of
    // zero is what makes the cadence a clock rather than a hint.
    let timer = DispatchSource.makeTimerSource(flags: [.strict], queue: cadenceQueue)
    timer.schedule(
      deadline: .now(),
      repeating: .nanoseconds(1_000_000_000 / fps),
      leeway: .nanoseconds(0)
    )
    timer.setEventHandler { [weak self] in
      self?.tick()
    }
    lock.lock()
    cadenceTimer = timer
    lock.unlock()
    timer.resume()
  }

  /// Called on ScreenCaptureKit's sample handler queue. Stays O(1) by design.
  public func submit(_ sampleBuffer: CMSampleBuffer) {
    lock.lock()
    latestBuffer = sampleBuffer
    capturedFrameCount += 1
    lock.unlock()
  }

  /// Startup succeeds only after the first encoded frame. The bounded wait
  /// turns a stalled capture stream into an explicit failure before any action.
  public var firstFrameUptime: UInt64? { lock.withLock { startUptime } }

  public func awaitFirstFrame(timeout: Duration = .seconds(3)) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while true {
      if lock.withLock({ appendedFrameCount > 0 }) { return true }
      guard ContinuousClock.now < deadline else { return false }
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  /// Step 1 of the shutdown sequence. Idempotent.
  public func stopCadence() {
    lock.lock()
    let timer = cadenceTimer
    cadenceTimer = nil
    lock.unlock()
    timer?.cancel()
    // A tick may be mid-append; the barrier waits it out so nothing appends
    // after `markAsFinished()`.
    cadenceQueue.sync(flags: .barrier) { }
  }

  /// Steps 4 to 7 of the shutdown sequence: finish the input, end the session,
  /// finalize the file, and verify the writer actually completed.
  public func finish() async throws -> RecordingSummary {
    stopCadence()

    // `withLock`, not lock/unlock: `NSLock.lock()` is unavailable from an
    // async context.
    let (frames, captured, dropped, start, last) = lock.withLock {
      isFinished = true
      latestBuffer = nil
      return (appendedFrameCount, capturedFrameCount, droppedFrameCount, startPTS, lastPresentationTime)
    }

    guard let start, frames > 0 else {
      // Finalizing here would write a .mov with no video samples, which reads as
      // a successful take until someone opens it. Fail loudly instead.
      writer.cancelWriting()
      throw RecorderError.noFramesCaptured(outputURL)
    }

    input.markAsFinished()
    let end = CMTimeAdd(last, frameDuration)
    writer.endSession(atSourceTime: end)
    await finishWriting()

    guard writer.status == .completed else {
      throw RecorderError.writerFailed(CadenceWriter.reason(writer.error))
    }
    return RecordingSummary(
      outputURL: outputURL,
      width: width,
      height: height,
      codec: codec,
      frameCount: frames,
      capturedFrameCount: captured,
      droppedFrameCount: dropped,
      duration: CMTimeGetSeconds(CMTimeSubtract(end, start))
    )
  }

  // MARK: Private

  private let fps: Int
  private let frameDuration: CMTime
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private let cadenceQueue: DispatchQueue

  private let lock = NSLock()
  /// The single retained capture buffer. Replaced, never consumed: a still
  /// screen keeps re-encoding the last frame it produced.
  private var latestBuffer: CMSampleBuffer?
  private var cadenceTimer: DispatchSourceTimer?
  private var startPTS: CMTime?
  private var startUptime: UInt64?
  private var lastPresentationTime = CMTime.zero
  private var frameIndex = 0
  private var appendedFrameCount = 0
  private var droppedFrameCount = 0
  private var capturedFrameCount = 0
  private var hasStartedSession = false
  private var isFinished = false
  private var hasFailed = false

  private static func videoSettings(
    codec: AVVideoCodecType,
    width: Int,
    height: Int,
    fps: Int,
    bitrateMbps: Double?
  ) -> [String: Any] {
    let bitrate = bitrateMbps.map { Int($0 * 1_000_000) }
      ?? defaultBitrate(width: width, height: height, fps: fps, codec: codec)
    var compression: [String: Any] = [
      AVVideoAverageBitRateKey: bitrate,
      AVVideoExpectedSourceFrameRateKey: fps,
      AVVideoMaxKeyFrameIntervalKey: fps * 2,
      // Screen content is encoded live and scrubbed frame by frame; B-frames buy
      // nothing here and cost latency.
      AVVideoAllowFrameReorderingKey: false,
    ]
    if codec == .h264 {
      compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
    }
    return [
      AVVideoCodecKey: codec,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: compression,
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
      ],
    ]
  }

  /// Bits per pixel per frame, clamped so a 5K panel does not ask for a
  /// gigabit and a small window does not look like a fax.
  private static func defaultBitrate(width: Int, height: Int, fps: Int, codec: AVVideoCodecType) -> Int {
    let bitsPerPixel = codec == .hevc ? 0.09 : 0.16
    let raw = Double(width * height) * Double(fps) * bitsPerPixel
    return Int(min(max(raw, 8_000_000), 120_000_000))
  }

  /// The raw values are the fourcc codes `hvc1` and `avc1`; the log says what a
  /// person would call them.
  private static func name(for codec: AVVideoCodecType) -> String {
    codec == .hevc ? "hevc" : "h264"
  }

  private static func reason(_ error: (any Error)?) -> String {
    guard let error else { return "no error reported" }
    return StandardError.describe(error)
  }

  /// `AVAssetWriter` still exposes the deprecated synchronous `finishWriting()`
  /// next to the completion-handler form, so the bridge is spelled out rather
  /// than left to overload resolution.
  private func finishWriting() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      writer.finishWriting {
        continuation.resume()
      }
    }
  }

  private func tick() {
    lock.lock()
    let source = latestBuffer
    let stopped = isFinished || hasFailed
    lock.unlock()

    // Before the first capture frame there is nothing to duplicate; the session
    // starts at the first frame that actually exists.
    guard !stopped, let source else { return }

    guard input.isReadyForMoreMediaData else {
      // Never block the cadence on the encoder: drop this tick instead.
      countDrop()
      return
    }

    let now = DispatchTime.now().uptimeNanoseconds
    lock.lock()
    if startPTS == nil {
      startPTS = source.presentationTimeStamp
      startUptime = now
    }
    let start = startPTS ?? source.presentationTimeStamp
    let startedAt = startUptime ?? now
    // Missed ticks (a stalled encoder, a busy machine) advance the index by
    // wall-clock time rather than by one, so the file's duration keeps matching
    // the take instead of quietly shrinking.
    let elapsed = Double(now &- startedAt) / 1_000_000_000
    let target = max(frameIndex, Int((elapsed * Double(fps)).rounded()))
    droppedFrameCount += target - frameIndex
    frameIndex = target
    let needsSession = !hasStartedSession
    lock.unlock()

    let presentationTime = CMTimeAdd(start, CMTime(value: CMTimeValue(target), timescale: CMTimeScale(fps)))
    var timing = CMSampleTimingInfo(
      duration: frameDuration,
      presentationTimeStamp: presentationTime,
      decodeTimeStamp: .invalid
    )
    var retimed: CMSampleBuffer?
    let status = CMSampleBufferCreateCopyWithNewTiming(
      allocator: kCFAllocatorDefault,
      sampleBuffer: source,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleBufferOut: &retimed
    )
    guard status == noErr, let retimed else {
      countDrop()
      return
    }

    if needsSession {
      writer.startSession(atSourceTime: presentationTime)
      lock.lock()
      hasStartedSession = true
      lock.unlock()
    }

    guard input.append(retimed) else {
      reportAppendFailure()
      return
    }

    lock.lock()
    frameIndex = target + 1
    appendedFrameCount += 1
    lastPresentationTime = presentationTime
    lock.unlock()
  }

  private func countDrop() {
    lock.lock()
    droppedFrameCount += 1
    lock.unlock()
  }

  /// Once an append fails the writer is `.failed` for good and every later
  /// append is a silent no-op, so stop the clock and report it now.
  private func reportAppendFailure() {
    lock.lock()
    let alreadyFailed = hasFailed
    hasFailed = true
    droppedFrameCount += 1
    lock.unlock()
    guard !alreadyFailed else { return }
    StandardError.write("DemoRecorder: append failed for \(outputURL.path): \(CadenceWriter.reason(writer.error))")
  }

}
