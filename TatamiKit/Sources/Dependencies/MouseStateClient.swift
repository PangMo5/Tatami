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
public struct MouseStateClient: Sendable {
  public var configure: @Sendable (MouseStateConfig) async -> Void
  public var events: @Sendable () -> AsyncStream<MouseDragEvent> = { AsyncStream { _ in } }
  /// Was the primary mouse button down when this client last sampled
  /// `NSEvent.pressedMouseButtons`? Cheap query used by the AX observer
  /// to gate echo events — true while the user is dragging some window.
  public var isPrimaryButtonDown: @Sendable () -> Bool = { false }
}

public struct MouseStateConfig: Sendable, Equatable {
  public var modifier: NSEvent.ModifierFlags
  public var action: MouseAction
  public var dropAction: MouseDropAction

  public init(
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
public enum MouseAction: String, Sendable, Hashable, Codable {
  case move, resize
}

/// What dropping the window onto the center quadrant of another tile
/// does. Triangles (top/right/bottom/left) always warp; the center is
/// configurable.
public enum MouseDropAction: String, Sendable, Hashable, Codable {
  case swap, stack
}

public enum MouseDragEvent: Sendable, Hashable {
  /// User started a modifier-gated drag on `windowID`. `direction`
  /// encodes which corner of the window the cursor sits in (for
  /// resize). `frame` is the window frame at drag start.
  case began(windowID: CGWindowID, frame: CGRect, point: CGPoint, direction: ResizeEdge)
  case dragged(point: CGPoint)
  case ended(point: CGPoint)
}

/// Bitmask of edges being dragged for a resize.
public struct ResizeEdge: OptionSet, Sendable, Hashable, Codable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }
  public static let left   = ResizeEdge(rawValue: 1 << 0)
  public static let right  = ResizeEdge(rawValue: 1 << 1)
  public static let top    = ResizeEdge(rawValue: 1 << 2)
  public static let bottom = ResizeEdge(rawValue: 1 << 3)
}

extension MouseStateClient: DependencyKey {
  public static let liveValue: MouseStateClient = {
    let controller = MouseStateController()
    return MouseStateClient(
      configure: { config in await controller.configure(config) },
      events: { controller.events },
      isPrimaryButtonDown: { (NSEvent.pressedMouseButtons & 0x1) != 0 }
    )
  }()

  public static let testValue = MouseStateClient(
    configure: { _ in },
    events: { AsyncStream { _ in } },
    isPrimaryButtonDown: { false }
  )

  public static let previewValue = testValue
}

extension DependencyValues {
  public var mouseState: MouseStateClient {
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
    await MainActor.run { self.installTap(modifier: config.modifier) }
  }

  @MainActor
  private func installTap(modifier: NSEvent.ModifierFlags) {
    self.modifier = modifier
    guard tap == nil else { return }

    let mask = (1 << CGEventType.leftMouseDown.rawValue)
             | (1 << CGEventType.leftMouseUp.rawValue)
             | (1 << CGEventType.leftMouseDragged.rawValue)
    let context = Unmanaged.passUnretained(self).toOpaque()
    guard let port = CGEvent.tapCreate(
      tap: .cghidEventTap,
      place: .headInsertEventTap,
      options: .listenOnly,
      eventsOfInterest: CGEventMask(mask),
      callback: { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let ctrl = Unmanaged<MouseStateController>.fromOpaque(refcon)
          .takeUnretainedValue()
        let location = event.location
        let flags = event.flags
        MainActor.assumeIsolated {
          ctrl.handle(type: type, location: location, flags: flags)
        }
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
      CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    }
    CGEvent.tapEnable(tap: port, enable: true)
  }

  @MainActor
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
