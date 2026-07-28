import AVFoundation
import CoreImage
import CoreMedia
import OSLog
import ScreenCaptureKit

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "FloatingOverlay")

// MARK: - WindowMirrorCapture

/// Live ScreenCaptureKit capture of a single window, rendered into an
/// `AVSampleBufferDisplayLayer`. One instance backs one floating-mirror
/// panel.
///
/// This is the no-SIP "always on top" mechanism (same approach as
/// Topit / Floaty): rather than trying to raise a foreign window's level
/// — which only the SIP-injected scripting addition can do — we paint a
/// live mirror of the window into our own `.floating`-level panel. The
/// real window stays where it is; the panel sits above the tiles.
///
/// `@unchecked Sendable` rationale: every method that touches the capture
/// state (`stream` / `config` / `filter` / `generation` / `isStarting` /
/// `pendingFirstFrame`) is `@MainActor`, so the main actor serializes all
/// mutation — including across the `startCapture()` suspensions, which the
/// generation check below makes explicit. The capture callback runs on
/// `captureQueue` and touches only `videoLayer` (whose `enqueue` is
/// thread-safe), the lock-guarded `lastBuffer` box, and the one-shot
/// `firstFrameGate`.
final class WindowMirrorCapture: NSObject, @unchecked Sendable {

  // MARK: Lifecycle

  override init() {
    super.init()
    // The panel matches the window's aspect ratio, so a straight resize
    // (no letterboxing) fills the mirror exactly.
    videoLayer.videoGravity = .resize
  }

  // MARK: Internal

  enum FirstFrameOutcome: Sendable {
    case freshFrame
    case failed
    case cancelled
  }

  /// The layer the controller installs into the mirror panel's view.
  let videoLayer = AVSampleBufferDisplayLayer()

  /// Whether a stream is currently live. Read from the controller (main
  /// actor) to decide when a stopped mirror needs a prefetch resume.
  @MainActor
  var isRunning: Bool {
    stream != nil
  }

  /// Begin capturing `window`. No-op if already streaming or starting.
  @MainActor
  func start(window: SCWindow, maxFPS: Int) async -> Bool {
    guard stream == nil, !isStarting else { return stream != nil }
    isStarting = true
    let filter = SCContentFilter(desktopIndependentWindow: window)
    self.filter = filter
    configure(for: filter, maxFPS: maxFPS)
    let stream = SCStream(filter: filter, configuration: config, delegate: self)
    startingStream = stream
    defer {
      isStarting = false
      if startingStream === stream {
        startingStream = nil
      }
    }
    let startedGeneration = generation
    do {
      try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
      try await stream.startCapture()
      guard generation == startedGeneration else {
        // A stop won the race while `startCapture` was in flight — the
        // mirror is no longer wanted; don't publish the stream.
        try? await stream.stopCapture()
        finishPendingFirstFrame(for: stream, outcome: .cancelled)
        return false
      }
      self.stream = stream
      return true
    } catch {
      logger.error("mirror start failed: \(error.localizedDescription, privacy: .public)")
      self.stream = nil
      finishPendingFirstFrame(for: stream, outcome: .failed)
      return false
    }
  }

  /// Stop capturing and release the stream. Safe to call repeatedly, and
  /// wins against an in-flight `start`/`resume` (see `generation`).
  ///
  /// Called whenever the mirror is hidden (its app is active): a running
  /// `SCStream` keeps the macOS screen-recording indicator lit, and the
  /// user shouldn't see it while no mirror is actually being painted. The
  /// layer keeps its last frame for the instant the mirror comes back.
  @MainActor
  func stop() {
    generation += 1
    let activeStream = stream
    stream = nil
    finishPendingFirstFrame(outcome: .cancelled)
    activeStream?.stopCapture { _ in }
  }

  /// Restart capture from the stored filter after a `stop()` (the mirror
  /// is becoming visible again). `onFirstFrame` fires on the main thread
  /// when the first fresh frame lands in the layer — the controller defers
  /// un-hiding until then so the mirror never pops in with a stale image.
  @MainActor
  func resume(
    maxFPS: Int,
    onFirstFrame: (@MainActor (FirstFrameOutcome) -> Void)? = nil,
  ) async {
    if isStarting {
      // A start/resume is already in flight; its frames will arrive.
      if let onFirstFrame, let startingStream {
        addFirstFrameCallback(onFirstFrame, for: startingStream)
      } else if let onFirstFrame {
        onFirstFrame(.failed)
      }
      return
    }
    if let stream {
      if let onFirstFrame {
        addFirstFrameCallback(onFirstFrame, for: stream)
      }
      return
    }
    guard let filter else {
      onFirstFrame?(.failed)
      return
    }
    isStarting = true
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, maxFPS)))
    let stream = SCStream(filter: filter, configuration: config, delegate: self)
    startingStream = stream
    defer {
      isStarting = false
      if startingStream === stream {
        startingStream = nil
      }
    }
    if let onFirstFrame {
      addFirstFrameCallback(onFirstFrame, for: stream)
    }
    let startedGeneration = generation
    do {
      try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
      try await stream.startCapture()
      guard generation == startedGeneration else {
        try? await stream.stopCapture()
        finishPendingFirstFrame(for: stream, outcome: .cancelled)
        return
      }
      self.stream = stream
    } catch {
      logger.error("mirror resume failed: \(error.localizedDescription, privacy: .public)")
      self.stream = nil
      finishPendingFirstFrame(for: stream, outcome: .failed)
    }
  }

  /// CGImage of the most recent frame (call on the main thread). Backs the
  /// mirror with a still while the stream is stopped: a focus change can
  /// force the panel visible *before* the stream restarts, and without the
  /// still the layer is empty — the panel sits on top but is transparent,
  /// so whatever raised behind it shows through (the FFM "window A pops
  /// over the floating area" flash).
  @MainActor
  func stillImage() -> CGImage? {
    guard
      let buffer = lastBuffer.load(),
      let pixelBuffer = CMSampleBufferGetImageBuffer(buffer)
    else { return nil }
    let image = CIImage(cvPixelBuffer: pixelBuffer)
    return Self.ciContext.createCGImage(image, from: image.extent)
  }

  /// Resize the capture surface after the mirrored window changed size, so
  /// the rendered frames stay pixel-sharp.
  @MainActor
  func updateSize(width: CGFloat, height: CGFloat, scale: CGFloat, maxFPS: Int) {
    config.width = max(2, Int(width * scale))
    config.height = max(2, Int(height * scale))
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, maxFPS)))
    stream?.updateConfiguration(config) { error in
      if let error { logger.error("mirror resize failed: \(error.localizedDescription, privacy: .public)") }
    }
  }

  // MARK: Private

  @MainActor
  private struct PendingFirstFrame {
    var token: UInt64
    var stream: SCStream
    var callbacks: [@MainActor (FirstFrameOutcome) -> Void]
  }

  private static let ciContext = CIContext()

  private var stream: SCStream?
  private let config = SCStreamConfiguration()
  private var filter: SCContentFilter?
  private let captureQueue = DispatchQueue(label: "dev.PangMo5.Tatami.mirror-capture")

  /// Bumped by every `stop()`. `start`/`resume` snapshot it before
  /// suspending in `startCapture()` and re-check after resuming: if a stop
  /// landed mid-flight (workspace switch calling `removeWindow`, a
  /// suppression), the freshly started stream is stopped instead of
  /// published — publishing it would orphan a running stream that nothing
  /// tracks, recording (orange indicator lit) until process exit.
  @MainActor private var generation = 0
  /// Collapses overlapping `start`/`resume` calls (rapid suppress↔restore)
  /// so two streams are never started for one mirror.
  @MainActor private var isStarting = false
  /// The not-yet-published stream while `startCapture()` is suspended.
  /// A concurrent resume can bind its first-frame waiter to this exact
  /// stream instead of accepting a late sample from an older stream.
  @MainActor private var startingStream: SCStream?

  @MainActor private var nextFirstFrameToken: UInt64 = 0
  @MainActor private var pendingFirstFrame: PendingFirstFrame?
  private let firstFrameGate = FirstFrameGate()

  /// Most recent frame, kept for `stillImage()`. Written from the capture
  /// queue, read from the main thread — hence the lock box.
  private let lastBuffer = BufferBox()

  /// Bind every waiter to one concrete stream/token pair. The stream
  /// identity rejects queued samples from a stopped predecessor; the token
  /// also rejects a predecessor's already-enqueued main-queue delivery.
  @MainActor
  private func addFirstFrameCallback(
    _ callback: @escaping @MainActor (FirstFrameOutcome) -> Void,
    for stream: SCStream,
  ) {
    if var pending = pendingFirstFrame, pending.stream === stream {
      pending.callbacks.append(callback)
      pendingFirstFrame = pending
      return
    }
    if pendingFirstFrame != nil {
      finishPendingFirstFrame(outcome: .cancelled)
    }
    nextFirstFrameToken &+= 1
    let token = nextFirstFrameToken
    pendingFirstFrame = PendingFirstFrame(
      token: token,
      stream: stream,
      callbacks: [callback],
    )
    firstFrameGate.arm(stream: stream, token: token)
  }

  @MainActor
  private func finishPendingFirstFrame(
    for stream: SCStream? = nil,
    token: UInt64? = nil,
    outcome: FirstFrameOutcome,
  ) {
    guard let pending = pendingFirstFrame else { return }
    if let stream, pending.stream !== stream { return }
    if let token, pending.token != token { return }
    pendingFirstFrame = nil
    firstFrameGate.cancel(token: pending.token)
    for callback in pending.callbacks {
      callback(outcome)
    }
  }

  @MainActor
  private func configure(for filter: SCContentFilter, maxFPS: Int) {
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.colorSpaceName = CGColorSpace.sRGB
    config.showsCursor = false
    config.capturesAudio = false
    // macOS 14+: contentRect is in points, pointPixelScale converts to the
    // backing-store pixel size the stream should produce.
    let scale = CGFloat(filter.pointPixelScale)
    config.width = max(2, Int(filter.contentRect.width * scale))
    config.height = max(2, Int(filter.contentRect.height * scale))
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, maxFPS)))
  }

}

// MARK: - FirstFrameGate

/// Lock-guarded one-shot stream/token gate, armed from MainActor and
/// consumed by the ScreenCaptureKit output queue.
private final class FirstFrameGate: @unchecked Sendable {

  // MARK: Internal

  func arm(stream: SCStream, token: UInt64) {
    lock.lock()
    self.stream = stream
    self.token = token
    lock.unlock()
  }

  func cancel(token: UInt64) {
    lock.lock()
    if self.token == token {
      stream = nil
      self.token = nil
    }
    lock.unlock()
  }

  /// Return and clear the token only for the exact stream being awaited.
  func take(for candidate: SCStream) -> UInt64? {
    lock.lock()
    defer { lock.unlock() }
    guard stream === candidate else { return nil }
    let current = token
    stream = nil
    token = nil
    return current
  }

  // MARK: Private

  private let lock = NSLock()
  private var stream: SCStream?
  private var token: UInt64?

}

// MARK: - BufferBox

/// Lock-guarded slot for the most recent sample buffer (capture queue
/// writes, main thread reads).
private final class BufferBox: @unchecked Sendable {

  // MARK: Internal

  func store(_ newBuffer: CMSampleBuffer) {
    lock.lock()
    buffer = newBuffer
    lock.unlock()
  }

  func load() -> CMSampleBuffer? {
    lock.lock()
    defer { lock.unlock() }
    return buffer
  }

  // MARK: Private

  private let lock = NSLock()
  private var buffer: CMSampleBuffer?

}

// MARK: - WindowMirrorCapture + SCStreamOutput, SCStreamDelegate

extension WindowMirrorCapture: SCStreamOutput, SCStreamDelegate {
  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType,
  ) {
    guard type == .screen, sampleBuffer.isValid else { return }
    // Enqueue straight from the capture queue —
    // `AVSampleBufferDisplayLayer.enqueue` is thread-safe, and hopping
    // every frame through the main queue cost N mirrors × up-to-120 Hz of
    // main-queue blocks that piled up behind long AX passes.
    if videoLayer.status == .failed { videoLayer.flush() }
    videoLayer.enqueue(sampleBuffer)
    lastBuffer.store(sampleBuffer)
    guard let token = firstFrameGate.take(for: stream) else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      MainActor.assumeIsolated {
        self.finishPendingFirstFrame(
          token: token,
          outcome: .freshFrame,
        )
      }
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    logger.error("mirror stream stopped: \(error.localizedDescription, privacy: .public)")
    let stoppedStreamID = ObjectIdentifier(stream)
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      MainActor.assumeIsolated {
        let active = self.stream.flatMap {
          ObjectIdentifier($0) == stoppedStreamID ? $0 : nil
        }
        let starting = self.startingStream.flatMap {
          ObjectIdentifier($0) == stoppedStreamID ? $0 : nil
        }
        guard active != nil || starting != nil else { return }
        // Invalidate an in-flight start before invoking failure callbacks:
        // a retry may begin reentrantly from a callback, and the failed
        // attempt must not publish itself if its await later returns.
        self.generation += 1
        if let active {
          self.stream = nil
          self.finishPendingFirstFrame(
            for: active,
            outcome: .failed,
          )
        }
        if let starting {
          self.finishPendingFirstFrame(
            for: starting,
            outcome: .failed,
          )
        }
      }
    }
  }
}

// MARK: - MirrorView

/// AppKit view that hosts a mirror's `AVSampleBufferDisplayLayer` and
/// reports hover / click so the controller can swap to the real window
/// when the user wants to interact with it.
@MainActor
final class MirrorView: NSView {

  // MARK: Lifecycle

  init(videoLayer: AVSampleBufferDisplayLayer) {
    self.videoLayer = videoLayer
    super.init(frame: .zero)
    wantsLayer = true
    stillLayer.contentsGravity = .resize
    layer?.addSublayer(stillLayer)
    layer?.addSublayer(videoLayer)
    stillLayer.frame = bounds
    videoLayer.frame = bounds
    videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: Internal

  var onHoverChange: ((Bool) -> Void)?
  var onClick: (() -> Void)?
  /// Mouse and scroll events land on the mirror panel whenever it sits
  /// under the cursor (focus-follows-mouse off keeps it there) — without
  /// forwarding they'd die in the panel: scrolls would never reach the
  /// floating window, a click would need a second tap after the handover,
  /// and a drag begun on the mirror would go nowhere. The drag/up events
  /// of a click stay routed to this panel even after the handover hides
  /// it (the gesture owner doesn't change mid-gesture), so forwarding the
  /// whole sequence keeps single-click and click-drag natural.
  var onForwardEvent: ((NSEvent) -> Void)?

  func setStill(_ image: CGImage?) {
    stillLayer.contents = image
  }

  override func layout() {
    super.layout()
    stillLayer.frame = bounds
    videoLayer.frame = bounds
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil,
    )
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with _: NSEvent) {
    onHoverChange?(true)
  }

  override func mouseExited(with _: NSEvent) {
    onHoverChange?(false)
  }

  override func mouseDown(with event: NSEvent) {
    onClick?()
    onForwardEvent?(event)
  }

  override func mouseDragged(with event: NSEvent) {
    onForwardEvent?(event)
  }

  override func mouseUp(with event: NSEvent) {
    onForwardEvent?(event)
  }

  override func rightMouseDown(with event: NSEvent) {
    onForwardEvent?(event)
  }

  override func rightMouseDragged(with event: NSEvent) {
    onForwardEvent?(event)
  }

  override func rightMouseUp(with event: NSEvent) {
    onForwardEvent?(event)
  }

  override func otherMouseDown(with event: NSEvent) {
    onForwardEvent?(event)
  }

  override func otherMouseDragged(with event: NSEvent) {
    onForwardEvent?(event)
  }

  override func otherMouseUp(with event: NSEvent) {
    onForwardEvent?(event)
  }

  override func scrollWheel(with event: NSEvent) {
    guard let onForwardEvent else { return super.scrollWheel(with: event) }
    onForwardEvent(event)
  }

  // MARK: Private

  private let videoLayer: AVSampleBufferDisplayLayer
  /// Last-known-frame still, kept *under* the video layer so the mirror is
  /// never transparent while the stream is stopped or restarting.
  private let stillLayer = CALayer()
  private var tracking: NSTrackingArea?

}
