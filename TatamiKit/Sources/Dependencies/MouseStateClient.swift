import AppKit
import ApplicationServices
import CoreGraphics
import Dependencies
import DependenciesMacros
import Foundation
import OSLog

/// Modifier-gated mouse drag / drop state machine.
///
/// Subscribe to `events()` to receive the lifecycle for each drag
/// session that begins with the configured modifier held. Used by the
/// activation reducer to drive mouse-driven swap / warp / stack +
/// fence-based resize, and to mark "this AX move/resize was the user
/// dragging" without needing a separate suppression cache.
@DependencyClient
struct MouseStateClient: Sendable {
  var configure: @Sendable (MouseStateConfig) async -> Void
  var events: @Sendable () -> AsyncStream<MouseDragEvent> = { AsyncStream { _ in } }
  /// Was the primary mouse button down when this client last sampled
  /// `NSEvent.pressedMouseButtons`? Cheap query used by the AX observer
  /// to gate echo events — true while the user is dragging some window.
  var isPrimaryButtonDown: @Sendable () -> Bool = { false }
}

struct MouseStateConfig: Sendable, Equatable {
  var modifier: NSEvent.ModifierFlags
  var action: MouseAction
  var dropAction: MouseDropAction

  init(
    modifier: NSEvent.ModifierFlags = .option,
    action: MouseAction = .move,
    dropAction: MouseDropAction = .swap
  ) {
    self.modifier = modifier
    self.action = action
    self.dropAction = dropAction
  }
}

/// What the modifier-gated drag does.
enum MouseAction: String, Sendable, Hashable, Codable {
  case move, resize
}

/// What dropping the window onto the center quadrant of another tile
/// does. Triangles (top/right/bottom/left) always warp; the center is
/// configurable.
enum MouseDropAction: String, Sendable, Hashable, Codable {
  case swap, stack
}

enum MouseDragEvent: Sendable, Hashable {
  /// User started a modifier-gated drag on `windowID`. `direction`
  /// encodes which corner of the window the cursor sits in (for
  /// resize). `frame` is the window frame at drag start.
  case began(windowID: CGWindowID, frame: CGRect, point: CGPoint, direction: ResizeEdge)
  case dragged(point: CGPoint)
  case ended(point: CGPoint)
}

/// Bitmask of edges being dragged for a resize.
struct ResizeEdge: OptionSet, Sendable, Hashable, Codable {
  let rawValue: UInt8
  init(rawValue: UInt8) { self.rawValue = rawValue }
  static let left   = ResizeEdge(rawValue: 1 << 0)
  static let right  = ResizeEdge(rawValue: 1 << 1)
  static let top    = ResizeEdge(rawValue: 1 << 2)
  static let bottom = ResizeEdge(rawValue: 1 << 3)
}

extension MouseStateClient: DependencyKey {
  static let liveValue: MouseStateClient = {
    let controller = MouseStateController()
    return MouseStateClient(
      configure: { config in await controller.configure(config) },
      events: { controller.events },
      isPrimaryButtonDown: { (NSEvent.pressedMouseButtons & 0x1) != 0 }
    )
  }()

  static let testValue = MouseStateClient(
    configure: { _ in },
    events: { AsyncStream { _ in } },
    isPrimaryButtonDown: { false }
  )

  static let previewValue = testValue
}

extension DependencyValues {
  var mouseState: MouseStateClient {
    get { self[MouseStateClient.self] }
    set { self[MouseStateClient.self] = newValue }
  }
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "MouseState")

/// CGEventTap-driven drag tracker. Lives for the lifetime of the
/// process; reconfigured (modifier / action) by `configure(_:)`.
private final class MouseStateController: @unchecked Sendable {
  let events: AsyncStream<MouseDragEvent>
  private let emit: AsyncStream<MouseDragEvent>.Continuation

  private var tap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var modifier: NSEvent.ModifierFlags = .option
  private var activeWindowID: CGWindowID = 0

  init() {
    var continuation: AsyncStream<MouseDragEvent>.Continuation!
    self.events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
    self.emit = continuation
  }

  func configure(_ config: MouseStateConfig) async {
    // The tap lives on the shared event-tap thread, not the main run loop,
    // so its callback (a `CGWindowListCopyWindowInfo` hit-test on every
    // mouse-down) stays off the main thread. Install is idempotent and
    // serialized on that thread, so there's nothing to await back.
    EventTapThread.shared.perform { [self] in
      installTap(modifier: config.modifier)
    }
  }

  /// Runs on the event-tap thread (via `configure`). All controller state
  /// below is only ever touched from that thread, so it needs no lock.
  private func installTap(modifier: NSEvent.ModifierFlags) {
    self.modifier = modifier
    guard tap == nil else { return }

    let mask = (1 << CGEventType.leftMouseDown.rawValue)
             | (1 << CGEventType.leftMouseUp.rawValue)
             | (1 << CGEventType.leftMouseDragged.rawValue)
             | (1 << CGEventType.tapDisabledByTimeout.rawValue)
             | (1 << CGEventType.tapDisabledByUserInput.rawValue)
    let context = Unmanaged.passUnretained(self).toOpaque()
    // Session-level `.defaultTap`, not HID/`.listenOnly` — listen-only
    // taps are gated on Input Monitoring and pop the keystroke warning;
    // active taps ride the Accessibility grant (see
    // FocusFollowsMouseClient).
    guard let port = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: CGEventMask(mask),
      callback: { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let ctrl = Unmanaged<MouseStateController>.fromOpaque(refcon)
          .takeUnretainedValue()
        let location = event.location
        let flags = event.flags
        // Already on the event-tap thread — `handle` only emits Sendable
        // drag events into an AsyncStream, so no isolation hop is needed.
        ctrl.handle(type: type, location: location, flags: flags)
        return Unmanaged.passUnretained(event)
      },
      userInfo: context
    ) else {
      logger.warning("MouseStateController: failed to create CGEventTap")
      return
    }
    self.tap = port
    self.runLoopSource = CFMachPortCreateRunLoopSource(nil, port, 0)
    if let src = self.runLoopSource {
      EventTapThread.shared.addSource(src)
    }
    CGEvent.tapEnable(tap: port, enable: true)
  }

  private func handle(type: CGEventType, location: CGPoint, flags: CGEventFlags) {
    switch type {
    case .leftMouseDown:
      let nsFlags = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
        .intersection([.shift, .control, .option, .command])
      let want = modifier.intersection([.shift, .control, .option, .command])
      guard nsFlags == want, !want.isEmpty else { return }
      guard let info = topmostWindow(at: location) else { return }
      activeWindowID = info.windowID
      let direction = direction(for: info.frame, at: location)
      emit.yield(.began(
        windowID: info.windowID,
        frame: info.frame,
        point: location,
        direction: direction
      ))
    case .leftMouseDragged:
      guard activeWindowID != 0 else { return }
      emit.yield(.dragged(point: location))
    case .leftMouseUp:
      guard activeWindowID != 0 else { return }
      emit.yield(.ended(point: location))
      activeWindowID = 0
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      // macOS turns a starved tap off; without re-enabling here the
      // modifier-drag tracking dies silently for the rest of the process
      // (same recovery as the FFM and mirror-click taps).
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    default:
      break
    }
  }

  private func direction(for frame: CGRect, at point: CGPoint) -> ResizeEdge {
    let mid = CGPoint(x: frame.midX, y: frame.midY)
    var d: ResizeEdge = []
    if point.x < mid.x { d.insert(.left) }
    if point.x > mid.x { d.insert(.right) }
    if point.y < mid.y { d.insert(.top) }
    if point.y > mid.y { d.insert(.bottom) }
    return d
  }

  private func topmostWindow(at point: CGPoint)
    -> (windowID: CGWindowID, pid: pid_t, frame: CGRect)?
  {
    let info = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] ?? []
    for entry in info {
      guard (entry[kCGWindowLayer as String] as? Int) == 0,
            let wid = entry[kCGWindowNumber as String] as? CGWindowID,
            let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
            let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
            let x = boundsDict["X"], let y = boundsDict["Y"],
            let w = boundsDict["Width"], let h = boundsDict["Height"]
      else { continue }
      let rect = CGRect(x: x, y: y, width: w, height: h)
      if rect.contains(point) {
        return (wid, pid, rect)
      }
    }
    return nil
  }
}
