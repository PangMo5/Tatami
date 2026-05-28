import AppKit
import ApplicationServices
import CoreGraphics
import Dependencies
import DependenciesMacros
import Foundation
import OSLog

/// Watches the windows of a fixed set of bundle identifiers via
/// `AXObserver`. Emits an event whenever a window is created or
/// destroyed in any of those apps, so the reducer can re-tile the
/// workspace in real time — preserving the always-laid-out invariant.
@DependencyClient
public struct WindowObserverClient: Sendable {
  /// Replace the set of observed bundle identifiers. Pass empty to
  /// stop observing entirely.
  public var observe: @Sendable ([String]) async -> Void
  public var events: @Sendable () -> AsyncStream<WindowChangeEvent> = { AsyncStream { _ in } }
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
  /// Focus moved to a different window (including between windows of the
  /// same app, which `didActivateApplication` doesn't report). `key` is
  /// nil when the focused AX element couldn't be resolved to a tracked
  /// `WindowKey` (e.g. AX-hidden windows opened via Notification Center
  /// dispatches). The bundle id is still emitted so the reducer can
  /// re-reconcile that app's windows — the front-switch reconcile path.
  case windowFocused(bundleId: String, key: WindowKey?)
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
///
/// Observers are kept for the process lifetime of each observed app:
/// `observe(bundleIds:)` is purely additive, never tears anything down
/// just because a bundle id disappeared from the caller's "interesting"
/// set. Once an `AXObserver` is wired up for a pid we keep it until the
/// pid actually exits. Tearing the observer down and rebuilding it on
/// every sync would lose any `kAXWindowCreated` that fired in the gap
/// (a known source of the "Notification-Center-opened KakaoTalk window
/// is invisible" bug).
/// Termination cleanup runs on each `observe` call and on every event
/// hop.
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
    // Drop observers whose pid has died. Anything still running stays
    // observed even if it's no longer in the caller's interest set —
    // the next focus/launch event will surface it again, and we'd
    // otherwise have to rebuild the AXObserver from scratch (losing
    // any window-created event in flight).
    for (pid, obs) in observed where !ObservedApp.isPidAlive(pid) {
      obs.tearDown()
      observed.removeValue(forKey: pid)
    }

    // Add observers for any new (pid, bundleId) pair we haven't seen
    // yet. Apps with multiple processes (e.g. helper instances) each
    // get their own AXObserver.
    for bundleId in bundleIds {
      let apps = NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleId)
        .filter { !$0.isTerminated && $0.activationPolicy == .regular }
      for app in apps where observed[app.processIdentifier] == nil {
        if let obs = ObservedApp.install(
          pid: app.processIdentifier,
          bundleId: bundleId,
          continuation: continuation
        ) {
          observed[app.processIdentifier] = obs
        }
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
  /// While a menu is open AX briefly hops focus to the menu element
  /// and back, which would otherwise trigger reconciles. Toggled by
  /// `kAXMenuOpened/Closed` to gate focus events.
  fileprivate var isMenuOpen = false

  fileprivate static func isPidAlive(_ pid: pid_t) -> Bool {
    NSRunningApplication(processIdentifier: pid).map { !$0.isTerminated } ?? false
  }

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
    // App-level: which window holds focus (fires on same-app switches).
    AXObserverAddNotification(
      observer, appElement, kAXFocusedWindowChangedNotification as CFString, info
    )
    // App-level: which window is "main" — fires for apps that swap
    // their main window without re-firing focused-window-changed
    // (e.g. Notification-Center dispatches that change which chat
    // window is foreground). Treated the same as focused-changed.
    AXObserverAddNotification(
      observer, appElement, kAXMainWindowChangedNotification as CFString, info
    )
    // App-level miniaturize/deminiaturize — without these, minimizing a
    // window doesn't get noticed until the next focus/launch event and
    // the BSP tree silently holds onto a tile for an invisible window.
    AXObserverAddNotification(
      observer, appElement, kAXWindowMiniaturizedNotification as CFString, info
    )
    AXObserverAddNotification(
      observer, appElement, kAXWindowDeminiaturizedNotification as CFString, info
    )
    // Menu-opened gating: suppress focus reconciles while a menu is
    // open because focus briefly hops to the menu element and back.
    // Title changes are cosmetic but kept as an observer so we can
    // surface them later if needed.
    AXObserverAddNotification(
      observer, appElement, kAXMenuOpenedNotification as CFString, info
    )
    AXObserverAddNotification(
      observer, appElement, kAXMenuClosedNotification as CFString, info
    )
    AXObserverAddNotification(
      observer, appElement, kAXTitleChangedNotification as CFString, info
    )

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
      // Only treat a resize as user-driven when the left mouse button
      // is held — otherwise this alert is the echo of our own tiling
      // writes (swap / warp / zoom / retile). The reducer applies an
      // additional 1.5 px geometric tolerance check against the tile's
      // expected area before applying the new ratio.
      if isLeftMouseDown(),
         let key = WindowKey.from(axWindow: element, pid: app.pid, bundleId: app.bundleId),
         let frame = axFrame(of: element)
      {
        app.continuation.yield(.windowResized(key: key, frame: frame))
      }
    case kAXWindowMovedNotification as String:
      if isLeftMouseDown(),
         let key = WindowKey.from(axWindow: element, pid: app.pid, bundleId: app.bundleId),
         let frame = axFrame(of: element)
      {
        app.continuation.yield(.windowMoved(key: key, frame: frame))
      }
    case kAXFocusedWindowChangedNotification as String,
         kAXMainWindowChangedNotification as String:
      // `element` is the newly focused/main window. No mouse gate —
      // these are state-only (no AX writes), so they can't feed back
      // into a tiling loop. Emit even when `WindowKey.from` fails
      // (some apps' windows are AX-hidden until reconciled with
      // CGWindowList) so the reducer can still trigger a per-app
      // reconcile — the front-switch reconcile pattern.
      // Skip while a menu is open: AX briefly bounces focus to the
      // menu element and back, which would just churn the BSP.
      if app.isMenuOpen { break }
      let key = WindowKey.from(axWindow: element, pid: app.pid, bundleId: app.bundleId)
      app.continuation.yield(.windowFocused(bundleId: app.bundleId, key: key))
    case kAXWindowMiniaturizedNotification as String,
         kAXWindowDeminiaturizedNotification as String:
      // Treat both as a reason to reconcile — minimized windows drop
      // out of `discoverWindowKeys` (subrole filter), restored ones
      // need to come back into the tree.
      app.continuation.yield(.windowCreated(bundleId: app.bundleId))
    case kAXMenuOpenedNotification as String:
      app.isMenuOpen = true
    case kAXMenuClosedNotification as String:
      app.isMenuOpen = false
    case kAXTitleChangedNotification as String:
      // Cosmetic; subscribed for completeness, no reconcile work needed.
      break
    default:
      break
    }
  }
}

/// True while the primary (left) mouse button is held — i.e. the user
/// is actively dragging. Used to distinguish genuine manual resize/move
/// from the AX echoes of our own programmatic tiling writes.
@MainActor
private func isLeftMouseDown() -> Bool {
  (NSEvent.pressedMouseButtons & 0x1) != 0
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
