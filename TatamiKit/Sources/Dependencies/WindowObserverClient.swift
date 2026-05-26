import AppKit
import ApplicationServices
import CoreGraphics
import Dependencies
import Foundation
import OSLog

/// Watches the windows of a fixed set of bundle identifiers via
/// `AXObserver`. Emits an event whenever a window is created or
/// destroyed in any of those apps, so the reducer can re-tile the
/// workspace in real time — matching yabai's "windows are always
/// laid out" behavior.
public struct WindowObserverClient: Sendable {
  /// Replace the set of observed bundle identifiers. Pass empty to
  /// stop observing entirely.
  public var observe: @Sendable ([String]) async -> Void
  public var events: @Sendable () -> AsyncStream<WindowChangeEvent>

  public init(
    observe: @escaping @Sendable ([String]) async -> Void,
    events: @escaping @Sendable () -> AsyncStream<WindowChangeEvent>
  ) {
    self.observe = observe
    self.events = events
  }
}

public enum WindowChangeEvent: Sendable, Hashable {
  case windowCreated(bundleId: String)
  case windowDestroyed(bundleId: String)
  /// User finished a manual resize. Carries the new frame in AX
  /// top-origin coordinates so the reducer can sync the BSP tree's
  /// split ratio.
  case windowResized(key: WindowKey, frame: CGRect)
  /// User finished dragging a window. Reducer uses this to detect
  /// drag-to-swap.
  case windowMoved(key: WindowKey, frame: CGRect)
}

extension WindowObserverClient: DependencyKey {
  public static let liveValue: WindowObserverClient = {
    let center = WindowObserverCenter()
    return WindowObserverClient(
      observe: { bundleIds in
        await center.observe(bundleIds: bundleIds)
      },
      events: { center.events }
    )
  }()

  public static let testValue = WindowObserverClient(
    observe: { _ in },
    events: { AsyncStream { _ in } }
  )

  public static let previewValue = testValue
}

extension DependencyValues {
  public var windowObserver: WindowObserverClient {
    get { self[WindowObserverClient.self] }
    set { self[WindowObserverClient.self] = newValue }
  }
}

/// Lives for the lifetime of the process. All AX work hops to the main
/// thread because the observer runs on the main run loop.
private final class WindowObserverCenter: @unchecked Sendable {
  let events: AsyncStream<WindowChangeEvent>
  private let continuation: AsyncStream<WindowChangeEvent>.Continuation
  private var observed: [pid_t: ObservedApp] = [:]

  init() {
    var c: AsyncStream<WindowChangeEvent>.Continuation!
    self.events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
    self.continuation = c
  }

  func observe(bundleIds: [String]) async {
    await MainActor.run {
      self.installOrUpdate(bundleIds: bundleIds)
    }
  }

  @MainActor
  private func installOrUpdate(bundleIds: [String]) {
    let targets = bundleIds.compactMap { bundleId -> (String, pid_t)? in
      guard let app = NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleId)
        .first(where: { !$0.isTerminated && $0.activationPolicy == .regular })
      else { return nil }
      return (bundleId, app.processIdentifier)
    }

    let nextPIDs = Set(targets.map(\.1))

    // Tear down observers no longer needed.
    for (pid, obs) in observed where !nextPIDs.contains(pid) {
      obs.tearDown()
    }
    observed = observed.filter { nextPIDs.contains($0.key) }

    for (bundleId, pid) in targets where observed[pid] == nil {
      if let obs = ObservedApp.install(
        pid: pid,
        bundleId: bundleId,
        continuation: continuation
      ) {
        observed[pid] = obs
      }
    }
  }
}

/// One AXObserver wired to a single app, listening for window
/// created/destroyed events on the app element + on each existing
/// window (destruction is reported on the window element itself, not
/// the app).
@MainActor
private final class ObservedApp {
  let pid: pid_t
  let bundleId: String
  let observer: AXObserver
  let appElement: AXUIElement
  let continuation: AsyncStream<WindowChangeEvent>.Continuation

  fileprivate static func install(
    pid: pid_t,
    bundleId: String,
    continuation: AsyncStream<WindowChangeEvent>.Continuation
  ) -> ObservedApp? {
    var observer: AXObserver?
    let createResult = AXObserverCreate(pid, axObserverCallback, &observer)
    guard createResult == .success, let observer else {
      logger.debug("AXObserverCreate failed for \(bundleId): \(createResult.rawValue)")
      return nil
    }
    let appElement = AXUIElementCreateApplication(pid)
    let observed = ObservedApp(
      pid: pid,
      bundleId: bundleId,
      observer: observer,
      appElement: appElement,
      continuation: continuation
    )

    let info = Unmanaged.passUnretained(observed).toOpaque()
    AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, info)

    // Existing windows: subscribe to destruction + resize + move.
    observed.refreshWindowSubscriptions()

    CFRunLoopAddSource(
      CFRunLoopGetMain(),
      AXObserverGetRunLoopSource(observer),
      .defaultMode
    )

    return observed
  }

  fileprivate init(
    pid: pid_t,
    bundleId: String,
    observer: AXObserver,
    appElement: AXUIElement,
    continuation: AsyncStream<WindowChangeEvent>.Continuation
  ) {
    self.pid = pid
    self.bundleId = bundleId
    self.observer = observer
    self.appElement = appElement
    self.continuation = continuation
  }

  fileprivate func tearDown() {
    CFRunLoopRemoveSource(
      CFRunLoopGetMain(),
      AXObserverGetRunLoopSource(observer),
      .defaultMode
    )
  }

  fileprivate func refreshWindowSubscriptions() {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      appElement,
      kAXWindowsAttribute as CFString,
      &raw
    ) == .success,
          let windows = raw as? [AXUIElement]
    else { return }
    let info = Unmanaged.passUnretained(self).toOpaque()
    for window in windows {
      AXObserverAddNotification(
        observer,
        window,
        kAXUIElementDestroyedNotification as CFString,
        info
      )
      AXObserverAddNotification(
        observer,
        window,
        kAXWindowResizedNotification as CFString,
        info
      )
      AXObserverAddNotification(
        observer,
        window,
        kAXWindowMovedNotification as CFString,
        info
      )
    }
  }
}

/// AXObserver callbacks run on the main run loop, which is the same
/// run loop we already use for AX work, so we can call into the
/// MainActor-isolated `ObservedApp` directly. We deliberately avoid
/// carrying the `AXUIElement` across an `await` to keep strict
/// concurrency happy — for window-created we only need to subscribe
/// destruction on the new element, which the callback does in place.
private func axObserverCallback(
  observer: AXObserver,
  element: AXUIElement,
  notification: CFString,
  refcon: UnsafeMutableRawPointer?
) {
  guard let refcon else { return }
  let app = Unmanaged<ObservedApp>.fromOpaque(refcon).takeUnretainedValue()
  let name = notification as String
  let boxed = UnsafeAXElement(value: element)
  MainActor.assumeIsolated {
    let element = boxed.value
    switch name {
    case kAXWindowCreatedNotification as String:
      app.refreshWindowSubscriptions()
      app.continuation.yield(.windowCreated(bundleId: app.bundleId))
    case kAXUIElementDestroyedNotification as String:
      app.continuation.yield(.windowDestroyed(bundleId: app.bundleId))
    case kAXWindowResizedNotification as String:
      if let key = WindowKey.from(axWindow: element, pid: app.pid, bundleId: app.bundleId),
         let frame = axFrame(of: element),
         !WindowTilerSuppression.shared.shouldIgnore(key: key, frame: frame)
      {
        app.continuation.yield(.windowResized(key: key, frame: frame))
      }
    case kAXWindowMovedNotification as String:
      if let key = WindowKey.from(axWindow: element, pid: app.pid, bundleId: app.bundleId),
         let frame = axFrame(of: element),
         !WindowTilerSuppression.shared.shouldIgnore(key: key, frame: frame)
      {
        app.continuation.yield(.windowMoved(key: key, frame: frame))
      }
    default:
      break
    }
  }
}

/// AX C-callback parameters are non-Sendable but the AX run loop
/// already executes on the main thread, so the element is safe to use
/// from a `MainActor.assumeIsolated` block. This box silences Swift 6
/// strict-concurrency without changing semantics.
private struct UnsafeAXElement: @unchecked Sendable {
  let value: AXUIElement
}

@MainActor
private func axFrame(of window: AXUIElement) -> CGRect? {
  var posRaw: CFTypeRef?
  var sizeRaw: CFTypeRef?
  guard
    AXUIElementCopyAttributeValue(
      window, kAXPositionAttribute as CFString, &posRaw
    ) == .success,
    AXUIElementCopyAttributeValue(
      window, kAXSizeAttribute as CFString, &sizeRaw
    ) == .success,
    let posValue = posRaw,
    let sizeValue = sizeRaw,
    CFGetTypeID(posValue) == AXValueGetTypeID(),
    CFGetTypeID(sizeValue) == AXValueGetTypeID()
  else { return nil }
  var position = CGPoint.zero
  var size = CGSize.zero
  AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
  AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
  return CGRect(origin: position, size: size)
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "WindowObserver")
