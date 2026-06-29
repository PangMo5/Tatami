import AppKit
import ApplicationServices
import CoreGraphics
import Dependencies
import DependenciesMacros
import Foundation

/// Watches the windows of a fixed set of bundle identifiers via
/// `AXObserver`. Emits an event whenever a window is created or
/// destroyed in any of those apps, so the reducer can re-tile the
/// workspace in real time — preserving the always-laid-out invariant.
@DependencyClient
struct WindowObserverClient: Sendable {
  /// Replace the set of observed bundle identifiers. Pass empty to
  /// stop observing entirely.
  var observe: @Sendable ([String]) async -> Void
  var events: @Sendable () -> AsyncStream<WindowChangeEvent> = { AsyncStream { _ in } }
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
  /// The primary mouse button was released. Lets the reducer flush a pending
  /// manual move/resize exactly at drag-end instead of guessing with a time
  /// debounce.
  case windowDragEnded
}

extension WindowObserverClient: DependencyKey {
  static let liveValue: WindowObserverClient = {
    let center = WindowObserverCenter()
    return WindowObserverClient(
      observe: { bundleIds in
        await center.observe(bundleIds: bundleIds)
      },
      events: { center.events }
    )
  }()

  static let testValue = WindowObserverClient(
    observe: { _ in },
    events: { AsyncStream { _ in } }
  )

  static let previewValue = testValue
}

extension DependencyValues {
  var windowObserver: WindowObserverClient {
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
  /// Global mouse-up monitor; emits `.windowDragEnded` so the reducer commits
  /// a manual move/resize at the true end of the drag.
  private var dragEndMonitor: Any?

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
    @Dependency(\.debugLog) var debugLog
    // Install the global mouse-up monitor once. The reducer flushes a pending
    // manual move/resize on `.windowDragEnded`, so the commit lands at the
    // real end of the drag rather than on a time guess. Global monitors only
    // see other apps' events — exactly where window drags happen.
    if dragEndMonitor == nil {
      let cont = continuation
      dragEndMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
        cont.yield(.windowDragEnded)
      }
    }
    // Drop observers whose pid has died. Anything still running stays
    // observed even if it's no longer in the caller's interest set —
    // the next focus/launch event will surface it again, and we'd
    // otherwise have to rebuild the AXObserver from scratch (losing
    // any window-created event in flight).
    for (pid, obs) in observed where !ObservedApp.isPidAlive(pid) {
      debugLog.log("Observer", "teardown pid=\(pid) bundle=\(obs.bundleId): pid dead")
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
      if apps.isEmpty {
        debugLog.log("Observer", "skip \(bundleId): no running .regular app")
        continue
      }
      for app in apps {
        if observed[app.processIdentifier] != nil {
          debugLog.log(
            "Observer",
            "already-observed pid=\(app.processIdentifier) bundle=\(bundleId)"
          )
          continue
        }
        if let obs = ObservedApp.install(
          pid: app.processIdentifier,
          bundleId: bundleId,
          continuation: continuation
        ) {
          observed[app.processIdentifier] = obs
          debugLog.log(
            "Observer",
            "installed pid=\(app.processIdentifier) bundle=\(bundleId) initialWindows=\(obs.lastSubscribedWindowCount)"
          )
        } else {
          debugLog.log(
            "Observer",
            "install FAILED pid=\(app.processIdentifier) bundle=\(bundleId)"
          )
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
  /// Number of AX windows subscribed on the last `refreshWindowSubscriptions`
  /// run. Surfaced through the debug log so we can tell whether an app's
  /// `kAXWindowsAttribute` actually returned the windows we expected.
  fileprivate var lastSubscribedWindowCount = 0
  /// True until every `AXObserverAddNotification` call below has
  /// succeeded. Freshly-launched Electron apps (Notion) return
  /// `kAXErrorCannotComplete (-25204)` because their AX layer isn't
  /// ready yet, and macOS never re-attempts on its own — the
  /// notification is permanently missing until we retry.
  fileprivate var needsAXRetry = false
  /// Cancellation token for the in-flight retry task. Avoids stacking
  /// concurrent retries while one is already running.
  fileprivate var retryTask: Task<Void, Never>?

  fileprivate static func isPidAlive(_ pid: pid_t) -> Bool {
    NSRunningApplication(processIdentifier: pid).map { !$0.isTerminated } ?? false
  }

  fileprivate static func install(
    pid: pid_t,
    bundleId: String,
    continuation: AsyncStream<WindowChangeEvent>.Continuation
  ) -> ObservedApp? {
    @Dependency(\.debugLog) var debugLog
    var observer: AXObserver?
    let createResult = AXObserverCreate(pid, axObserverCallback, &observer)
    guard createResult == .success, let observer else {
      debugLog.log(
        "Observer",
        "AXObserverCreate FAILED pid=\(pid) bundle=\(bundleId) err=\(createResult.rawValue)"
      )
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
    observed.registerNotifications(info: info)

    // Existing windows: subscribe to destruction + resize + move.
    observed.refreshWindowSubscriptions()

    CFRunLoopAddSource(
      CFRunLoopGetMain(),
      AXObserverGetRunLoopSource(observer),
      .defaultMode
    )

    if observed.needsAXRetry {
      // A heavy app's first cold launch can take several seconds before its AX
      // layer answers — 25 × 200 ms gives it room (the old 2 s budget gave up
      // before slow apps were ready, so their kAXWindowCreated was never armed
      // and a lazily-opened window stayed untiled until a workspace switch).
      observed.scheduleAXRetry(attemptsRemaining: 25)
    }

    return observed
  }

  /// Register every app-level notification we care about. Returns true
  /// when every call succeeded; sets `needsAXRetry` otherwise so the
  /// caller can schedule a retry.
  @discardableResult
  fileprivate func registerNotifications(info: UnsafeMutableRawPointer) -> Bool {
    @Dependency(\.debugLog) var debugLog
    let appNotifications: [(CFString, String)] = [
      (kAXWindowCreatedNotification as CFString, "kAXWindowCreated"),
      (kAXFocusedWindowChangedNotification as CFString, "kAXFocusedWindowChanged"),
      (kAXMainWindowChangedNotification as CFString, "kAXMainWindowChanged"),
      (kAXWindowMiniaturizedNotification as CFString, "kAXWindowMiniaturized"),
      (kAXWindowDeminiaturizedNotification as CFString, "kAXWindowDeminiaturized"),
      (kAXMenuOpenedNotification as CFString, "kAXMenuOpened"),
      (kAXMenuClosedNotification as CFString, "kAXMenuClosed"),
      (kAXTitleChangedNotification as CFString, "kAXTitleChanged"),
    ]
    var allOK = true
    for (name, label) in appNotifications {
      let r = AXObserverAddNotification(observer, appElement, name, info)
      // `notificationAlreadyRegistered` is fine — that just means a
      // previous attempt already got this one through.
      if r != .success && r.rawValue != Int32(-25208) /* AlreadyRegistered */ {
        allOK = false
        if r.rawValue == -25204 /* CannotComplete */ {
          needsAXRetry = true
        }
        debugLog.log(
          "Observer",
          "addNotification \(label) FAILED pid=\(pid) bundle=\(bundleId) err=\(r.rawValue)"
        )
      }
    }
    if allOK {
      // Recovered — clear the retry flag in case this was a retry pass.
      needsAXRetry = false
    }
    return allOK
  }

  /// Delayed retry of the AX notification setup. Matches the upstream
  /// `ax_retry` loop: 200 ms between attempts, capped at `attemptsRemaining`.
  fileprivate func scheduleAXRetry(attemptsRemaining: Int) {
    @Dependency(\.debugLog) var debugLog
    retryTask?.cancel()
    let id = Unmanaged.passUnretained(self).toOpaque()
    retryTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(200))
      guard let self else { return }
      debugLog.log(
        "Observer",
        "ax retry pid=\(self.pid) bundle=\(self.bundleId) remaining=\(attemptsRemaining)"
      )
      let ok = self.registerNotifications(info: id)
      self.refreshWindowSubscriptions()
      if ok {
        // AX is ready: kAXWindowCreated is now armed, so a window that appears
        // from here on fires a real event on its own — arming the subscription
        // was the retry's whole job. Replay any window that slipped in while AX
        // was not ready (the OS dropped those notifications); the live
        // subscription covers the rest, so stop retrying even with no window
        // yet (the old `ok && windows > 0` gate kept burning attempts and could
        // give up before a lazy window opened).
        debugLog.log(
          "Observer",
          "ax retry SUCCEEDED pid=\(self.pid) bundle=\(self.bundleId) windows=\(self.lastSubscribedWindowCount)"
        )
        self.retryTask = nil
        if self.lastSubscribedWindowCount > 0 {
          self.continuation.yield(.windowCreated(bundleId: self.bundleId))
        }
        return
      }
      // Keep retrying only while the app is alive and AX still isn't ready —
      // giving up early is what left a slow app's late window unobserved.
      if attemptsRemaining > 1, ObservedApp.isPidAlive(self.pid) {
        self.scheduleAXRetry(attemptsRemaining: attemptsRemaining - 1)
      } else {
        debugLog.log(
          "Observer",
          "ax retry GAVE UP pid=\(self.pid) bundle=\(self.bundleId) (ax never became ready)"
        )
        self.retryTask = nil
      }
    }
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
    retryTask?.cancel()
    retryTask = nil
    CFRunLoopRemoveSource(
      CFRunLoopGetMain(),
      AXObserverGetRunLoopSource(observer),
      .defaultMode
    )
  }

  fileprivate func refreshWindowSubscriptions() {
    @Dependency(\.debugLog) var debugLog
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      appElement,
      kAXWindowsAttribute as CFString,
      &raw
    ) == .success,
          let windows = raw as? [AXUIElement]
    else {
      debugLog.log(
        "Observer",
        "refreshSubs pid=\(pid) bundle=\(bundleId): kAXWindowsAttribute empty/failed"
      )
      lastSubscribedWindowCount = 0
      return
    }
    lastSubscribedWindowCount = windows.count
    debugLog.log(
      "Observer",
      "refreshSubs pid=\(pid) bundle=\(bundleId) windows=\(windows.count)"
    )
    let info = Unmanaged.passUnretained(self).toOpaque()
    let windowNotifications: [(CFString, String)] = [
      (kAXUIElementDestroyedNotification as CFString, "kAXUIElementDestroyed"),
      (kAXWindowResizedNotification as CFString, "kAXWindowResized"),
      (kAXWindowMovedNotification as CFString, "kAXWindowMoved"),
    ]
    for window in windows {
      for (name, label) in windowNotifications {
        let r = AXObserverAddNotification(observer, window, name, info)
        // Same policy as the app-level registrations: a freshly-launched
        // Electron app can answer CannotComplete (-25204) here too, and
        // macOS never re-attempts on its own — without the flag the
        // window's destroy/resize/move events were permanently missing.
        if r != .success, r.rawValue != Int32(-25208) /* AlreadyRegistered */ {
          if r.rawValue == -25204 /* CannotComplete */ {
            needsAXRetry = true
          }
          debugLog.log(
            "Observer",
            "addNotification \(label) FAILED pid=\(pid) bundle=\(bundleId) err=\(r.rawValue)"
          )
        }
      }
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
    @Dependency(\.debugLog) var debugLog
    switch name {
    case kAXWindowCreatedNotification as String:
      app.refreshWindowSubscriptions()
      // A brand-new window can answer CannotComplete just like a
      // brand-new app — re-run the retry loop so its destroy/resize
      // subscriptions aren't permanently missing.
      if app.needsAXRetry {
        app.scheduleAXRetry(attemptsRemaining: 10)
      }
      var wid: CGWindowID = 0
      _ = _AXUIElementGetWindow(element, &wid)
      debugLog.log(
        "AX",
        "windowCreated pid=\(app.pid) bundle=\(app.bundleId) elementWid=\(wid)"
      )
      app.continuation.yield(.windowCreated(bundleId: app.bundleId))
    case kAXUIElementDestroyedNotification as String:
      var wid: CGWindowID = 0
      _ = _AXUIElementGetWindow(element, &wid)
      debugLog.log(
        "AX",
        "windowDestroyed pid=\(app.pid) bundle=\(app.bundleId) elementWid=\(wid)"
      )
      app.continuation.yield(.windowDestroyed(bundleId: app.bundleId))
    case kAXWindowResizedNotification as String:
      // Only treat a resize as user-driven when the left mouse button
      // is held — otherwise this alert is the echo of our own tiling
      // writes (swap / warp / zoom / retile). The reducer applies an
      // additional 1.5 px geometric tolerance check against the tile's
      // expected area before applying the new ratio.
      if isLeftMouseDown(),
         let key = WindowKey(axWindow: element, pid: app.pid, bundleId: app.bundleId),
         let frame = AXWindowGeometry.frame(of: element)
      {
        app.continuation.yield(.windowResized(key: key, frame: frame))
      }
    case kAXWindowMovedNotification as String:
      if isLeftMouseDown(),
         let key = WindowKey(axWindow: element, pid: app.pid, bundleId: app.bundleId),
         let frame = AXWindowGeometry.frame(of: element)
      {
        app.continuation.yield(.windowMoved(key: key, frame: frame))
      }
    case kAXFocusedWindowChangedNotification as String,
         kAXMainWindowChangedNotification as String:
      // `element` is the newly focused/main window. No mouse gate —
      // these are state-only (no AX writes), so they can't feed back
      // into a tiling loop. Emit even when the `WindowKey` bridge fails
      // (some apps' windows are AX-hidden until reconciled with
      // CGWindowList) so the reducer can still trigger a per-app
      // reconcile — the front-switch reconcile pattern.
      // Skip while a menu is open: AX briefly bounces focus to the
      // menu element and back, which would just churn the BSP.
      if app.isMenuOpen { break }
      let key = WindowKey(axWindow: element, pid: app.pid, bundleId: app.bundleId)
      debugLog.log(
        "AX",
        "windowFocused pid=\(app.pid) bundle=\(app.bundleId) key=\(key?.windowID.description ?? "nil")"
      )
      app.continuation.yield(.windowFocused(bundleId: app.bundleId, key: key))
    case kAXWindowMiniaturizedNotification as String,
         kAXWindowDeminiaturizedNotification as String:
      // Treat both as a reason to reconcile — minimized windows drop
      // out of `discoverWindowKeys` (subrole filter), restored ones
      // need to come back into the tree.
      debugLog.log(
        "AX",
        "miniaturizeChange pid=\(app.pid) bundle=\(app.bundleId) name=\(name)"
      )
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


