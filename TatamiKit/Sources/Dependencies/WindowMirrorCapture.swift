import AVFoundation
import CoreImage
import CoreMedia
import OSLog
import ScreenCaptureKit

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "FloatingOverlay")

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
/// thread-safe) and the lock-guarded `lastBuffer` box.
final class WindowMirrorCapture: NSObject, @unchecked Sendable {
  /// The layer the controller installs into the mirror panel's view.
  let videoLayer = AVSampleBufferDisplayLayer()

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

  /// Whether a stream is currently live. Read from the controller (main
  /// actor) to decide when a stopped mirror needs a prefetch resume.
  @MainActor var isRunning: Bool { stream != nil }

  override init() {
    super.init()
    // The panel matches the window's aspect ratio, so a straight resize
    // (no letterboxing) fills the mirror exactly.
    videoLayer.videoGravity = .resize
  }

  /// Begin capturing `window`. No-op if already streaming or starting.
  @MainActor
  func start(window: SCWindow, maxFPS: Int) async {
    guard stream == nil, !isStarting else { return }
    isStarting = true
    defer { isStarting = false }
    let filter = SCContentFilter(desktopIndependentWindow: window)
    self.filter = filter
    configure(for: filter, maxFPS: maxFPS)
    let stream = SCStream(filter: filter, configuration: config, delegate: self)
    let startedGeneration = generation
    do {
      try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
      try await stream.startCapture()
      guard generation == startedGeneration else {
        // A stop won the race while `startCapture` was in flight — the
        // mirror is no longer wanted; don't publish the stream.
        try? await stream.stopCapture()
        return
      }
      self.stream = stream
    } catch {
      logger.error("mirror start failed: \(error.localizedDescription, privacy: .public)")
      self.stream = nil
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
    guard let stream else { return }
    self.stream = nil
    stream.stopCapture { _ in }
  }

  /// Restart capture from the stored filter after a `stop()` (the mirror
  /// is becoming visible again). `onFirstFrame` fires on the main thread
  /// when the first fresh frame lands in the layer — the controller defers
  /// un-hiding until then so the mirror never pops in with a stale image.
  @MainActor
  func resume(maxFPS: Int, onFirstFrame: (@MainActor () -> Void)? = nil) async {
    if isStarting {
      // A start/resume is already in flight; its frames will arrive.
      if let onFirstFrame {
        pendingFirstFrame = onFirstFrame
        firstFramePending.set(true)
      }
      return
    }
    guard stream == nil, let filter else {
      if let onFirstFrame { onFirstFrame() }
      return
    }
    isStarting = true
    defer { isStarting = false }
    if let onFirstFrame {
      pendingFirstFrame = onFirstFrame
      firstFramePending.set(true)
    }
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, maxFPS)))
    let stream = SCStream(filter: filter, configuration: config, delegate: self)
    let startedGeneration = generation
    do {
      try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
      try await stream.startCapture()
      guard generation == startedGeneration else {
        try? await stream.stopCapture()
        flushPendingFirstFrame()
        return
      }
      self.stream = stream
    } catch {
      logger.error("mirror resume failed: \(error.localizedDescription, privacy: .public)")
      self.stream = nil
      flushPendingFirstFrame()
    }
  }

  /// Run-and-clear the first-frame callback when no frame will arrive
  /// (failed or aborted resume) so the caller's un-hide isn't stranded.
  @MainActor
  private func flushPendingFirstFrame() {
    firstFramePending.set(false)
    let pending = pendingFirstFrame
    pendingFirstFrame = nil
    pending?()
  }

  /// One-shot "first frame after resume" callback. Stored/consumed on the
  /// main actor; `firstFramePending` is its capture-queue-visible flag.
  @MainActor private var pendingFirstFrame: (@MainActor () -> Void)?
  private let firstFramePending = AtomicFlag()

  /// Most recent frame, kept for `stillImage()`. Written from the capture
  /// queue, read from the main thread — hence the lock box.
  private let lastBuffer = BufferBox()
  private static let ciContext = CIContext()

  /// CGImage of the most recent frame (call on the main thread). Backs the
  /// mirror with a still while the stream is stopped: a focus change can
  /// force the panel visible *before* the stream restarts, and without the
  /// still the layer is empty — the panel sits on top but is transparent,
  /// so whatever raised behind it shows through (the FFM "window A pops
  /// over the floating area" flash).
  @MainActor
  func stillImage() -> CGImage? {
    guard let buffer = lastBuffer.load(),
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

/// Lock-guarded one-shot flag, settable from the main actor and consumed
/// from the capture queue.
private final class AtomicFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  func set(_ newValue: Bool) {
    lock.lock()
    value = newValue
    lock.unlock()
  }
  /// Returns the current value and clears it.
  func take() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let current = value
    value = false
    return current
  }
}

/// Lock-guarded slot for the most recent sample buffer (capture queue
/// writes, main thread reads).
private final class BufferBox: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer: CMSampleBuffer?
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
}

extension WindowMirrorCapture: SCStreamOutput, SCStreamDelegate {
  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .screen, sampleBuffer.isValid else { return }
    // Enqueue straight from the capture queue —
    // `AVSampleBufferDisplayLayer.enqueue` is thread-safe, and hopping
    // every frame through the main queue cost N mirrors × up-to-120 Hz of
    // main-queue blocks that piled up behind long AX passes.
    if videoLayer.status == .failed { videoLayer.flush() }
    videoLayer.enqueue(sampleBuffer)
    lastBuffer.store(sampleBuffer)
    guard firstFramePending.take() else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      MainActor.assumeIsolated {
        let pending = self.pendingFirstFrame
        self.pendingFirstFrame = nil
        pending?()
      }
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    logger.error("mirror stream stopped: \(error.localizedDescription, privacy: .public)")
  }
}

/// AppKit view that hosts a mirror's `AVSampleBufferDisplayLayer` and
/// reports hover / click so the controller can swap to the real window
/// when the user wants to interact with it.
@MainActor
final class MirrorView: NSView {
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

  private let videoLayer: AVSampleBufferDisplayLayer
  /// Last-known-frame still, kept *under* the video layer so the mirror is
  /// never transparent while the stream is stopped or restarting.
  private let stillLayer = CALayer()
  private var tracking: NSTrackingArea?

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
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
      userInfo: nil
    )
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
  override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
  override func mouseDown(with event: NSEvent) {
    onClick?()
    onForwardEvent?(event)
  }
  override func mouseDragged(with event: NSEvent) { onForwardEvent?(event) }
  override func mouseUp(with event: NSEvent) { onForwardEvent?(event) }
  override func rightMouseDown(with event: NSEvent) { onForwardEvent?(event) }
  override func rightMouseDragged(with event: NSEvent) { onForwardEvent?(event) }
  override func rightMouseUp(with event: NSEvent) { onForwardEvent?(event) }
  override func otherMouseDown(with event: NSEvent) { onForwardEvent?(event) }
  override func otherMouseDragged(with event: NSEvent) { onForwardEvent?(event) }
  override func otherMouseUp(with event: NSEvent) { onForwardEvent?(event) }
  override func scrollWheel(with event: NSEvent) {
    guard let onForwardEvent else { return super.scrollWheel(with: event) }
    onForwardEvent(event)
  }
}
