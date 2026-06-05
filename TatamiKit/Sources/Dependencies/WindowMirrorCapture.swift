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
/// `@unchecked Sendable` rationale: `videoLayer` is created on the main
/// actor (the controller owns it there) and only ever enqueued-to via a
/// main-thread hop in the capture callback. `stream` / `config` /
/// `filter` are mutated only from the controller's main-actor methods,
/// which the main actor serializes. The capture callback runs on
/// `captureQueue` and does nothing but forward frames to the layer on
/// main. No stored property is therefore touched concurrently — mirrors
/// the `SLSCenter` pattern elsewhere in this module.
final class WindowMirrorCapture: NSObject, @unchecked Sendable {
  /// The layer the controller installs into the mirror panel's view.
  let videoLayer = AVSampleBufferDisplayLayer()

  private var stream: SCStream?
  private let config = SCStreamConfiguration()
  private var filter: SCContentFilter?
  private let captureQueue = DispatchQueue(label: "dev.PangMo5.Tatami.mirror-capture")

  /// Whether a stream is currently live. Read from the controller (main
  /// actor) to decide when a stopped mirror needs a prefetch resume.
  var isRunning: Bool { stream != nil }

  override init() {
    super.init()
    // The panel matches the window's aspect ratio, so a straight resize
    // (no letterboxing) fills the mirror exactly.
    videoLayer.videoGravity = .resize
  }

  /// Begin capturing `window`. No-op if already streaming.
  func start(window: SCWindow, maxFPS: Int) async {
    guard stream == nil else { return }
    let filter = SCContentFilter(desktopIndependentWindow: window)
    self.filter = filter
    configure(for: filter, maxFPS: maxFPS)
    let stream = SCStream(filter: filter, configuration: config, delegate: self)
    do {
      try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
      try await stream.startCapture()
      self.stream = stream
    } catch {
      logger.error("mirror start failed: \(error.localizedDescription, privacy: .public)")
      self.stream = nil
    }
  }

  /// Stop capturing and release the stream. Safe to call repeatedly.
  ///
  /// Called whenever the mirror is hidden (its app is active): a running
  /// `SCStream` keeps the macOS screen-recording indicator lit, and the
  /// user shouldn't see it while no mirror is actually being painted. The
  /// layer keeps its last frame for the instant the mirror comes back.
  func stop() {
    guard let stream else { return }
    self.stream = nil
    stream.stopCapture { _ in }
  }

  /// Restart capture from the stored filter after a `stop()` (the mirror
  /// is becoming visible again). `onFirstFrame` fires on the main thread
  /// when the first fresh frame lands in the layer — the controller defers
  /// un-hiding until then so the mirror never pops in with a stale image.
  func resume(maxFPS: Int, onFirstFrame: (@MainActor () -> Void)? = nil) async {
    guard stream == nil, let filter else {
      if let onFirstFrame { await MainActor.run { onFirstFrame() } }
      return
    }
    if let onFirstFrame {
      await MainActor.run { self.pendingFirstFrame = onFirstFrame }
    }
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, maxFPS)))
    let stream = SCStream(filter: filter, configuration: config, delegate: self)
    do {
      try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
      try await stream.startCapture()
      self.stream = stream
    } catch {
      logger.error("mirror resume failed: \(error.localizedDescription, privacy: .public)")
      self.stream = nil
      let pending = await MainActor.run { () -> (@MainActor () -> Void)? in
        defer { self.pendingFirstFrame = nil }
        return self.pendingFirstFrame
      }
      if let pending { await MainActor.run { pending() } }
    }
  }

  /// One-shot "first frame after resume" callback. Touched only on the
  /// main thread (set in `resume`, consumed in the enqueue hop).
  private var pendingFirstFrame: (@MainActor () -> Void)?

  /// Most recent frame, kept for `stillImage()`. Main-thread only.
  private var lastBuffer: CMSampleBuffer?
  private static let ciContext = CIContext()

  /// CGImage of the most recent frame (call on the main thread). Backs the
  /// mirror with a still while the stream is stopped: a focus change can
  /// force the panel visible *before* the stream restarts, and without the
  /// still the layer is empty — the panel sits on top but is transparent,
  /// so whatever raised behind it shows through (the FFM "window A pops
  /// over the floating area" flash).
  func stillImage() -> CGImage? {
    guard let buffer = lastBuffer,
          let pixelBuffer = CMSampleBufferGetImageBuffer(buffer)
    else { return nil }
    let image = CIImage(cvPixelBuffer: pixelBuffer)
    return Self.ciContext.createCGImage(image, from: image.extent)
  }


  /// Resize the capture surface after the mirrored window changed size, so
  /// the rendered frames stay pixel-sharp.
  func updateSize(width: CGFloat, height: CGFloat, scale: CGFloat, maxFPS: Int) {
    config.width = max(2, Int(width * scale))
    config.height = max(2, Int(height * scale))
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, maxFPS)))
    stream?.updateConfiguration(config) { error in
      if let error { logger.error("mirror resize failed: \(error.localizedDescription, privacy: .public)") }
    }
  }

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

extension WindowMirrorCapture: SCStreamOutput, SCStreamDelegate {
  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .screen, sampleBuffer.isValid else { return }
    // `CMSampleBuffer` is not `Sendable`. It is only read (enqueued) on the
    // main thread below and never mutated, and `captureQueue` does not touch
    // it again after this returns — so the hand-off is safe.
    nonisolated(unsafe) let buffer = sampleBuffer
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if self.videoLayer.status == .failed { self.videoLayer.flush() }
      self.videoLayer.enqueue(buffer)
      self.lastBuffer = buffer
      if let pending = self.pendingFirstFrame {
        self.pendingFirstFrame = nil
        MainActor.assumeIsolated { pending() }
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
  override func mouseDown(with event: NSEvent) { onClick?() }
}
