import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Dependencies
import DependenciesMacros
import Foundation

// MARK: - WindowObserverClient

/// Watches the windows of a fixed set of bundle identifiers via
/// `AXObserver`. Emits an event whenever a window is created or
/// destroyed in any of those apps, so the reducer can re-tile the
/// workspace in real time — preserving the always-laid-out invariant.
@DependencyClient
struct WindowObserverClient: Sendable {
  /// Replace the set of observed bundle identifiers. Pass empty to
  /// stop observing entirely.
  var observe: @Sendable ([String]) async -> Void
  var events: @Sendable () -> WindowEventSequence = { .finished }
}

// MARK: - WindowChangeEvent

public enum WindowChangeEvent: Sendable, Hashable {
  case windowCreated(bundleId: String)
  case windowDestroyed(bundleId: String)
  /// A non-pointer geometry change. Apps can restore their remembered frame
  /// after Tatami reveals them; unlike a user drag this should converge back
  /// to the current tile immediately, without waiting on a settlement timer.
  case windowFrameChanged(key: WindowKey, frame: CGRect)
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
  /// The primary mouse button was released. The optional final WindowServer
  /// geometry lets the reducer recover a short drag whose AX callbacks were
  /// delayed or dropped, then flush it exactly at mouse-up without a time
  /// debounce.
  case windowDragEnded(
    trackedWindowID: CGWindowID?,
    key: WindowKey?,
    frame: CGRect?,
    pointerMoved: Bool,
  )
  /// A window's AX title changed. Cosmetic for tiling (activation ignores it),
  /// but lets the layout preview refresh titles live while the app stays
  /// frontmost — no app switch, so `didActivateApplication` never fires.
  case windowTitleChanged(bundleId: String)
}

// MARK: - WindowEventSequence

/// Single-consumer pull sequence backed directly by a coalescing buffer.
///
/// Unlike a producer-side `AsyncStream` pump, `next()` drains only when the
/// downstream consumer asks for another value, so a stalled reducer cannot
/// accumulate a second unbounded stream backlog behind the coalescer.
struct WindowEventSequence: AsyncSequence, Sendable {

  // MARK: Lifecycle

  fileprivate init(
    buffer: CoalescingWindowEventBuffer,
    onTermination: @escaping @Sendable () -> Void = { },
  ) {
    subscription = Subscription(buffer: buffer, onTermination: onTermination)
  }

  // MARK: Internal

  typealias Element = WindowChangeEvent

  final class Iterator: AsyncIteratorProtocol {

    // MARK: Lifecycle

    fileprivate init(subscription: Subscription) {
      self.subscription = subscription
    }

    deinit {
      subscription.cancel()
    }

    // MARK: Internal

    func next() async -> WindowChangeEvent? {
      let subscription = subscription
      return await withTaskCancellationHandler {
        await subscription.next()
      } onCancel: {
        subscription.cancel()
      }
    }

    // MARK: Private

    private let subscription: Subscription

  }

  static var finished: Self {
    let buffer = CoalescingWindowEventBuffer()
    buffer.finish()
    return Self(buffer: buffer)
  }

  func makeAsyncIterator() -> Iterator {
    Iterator(subscription: subscription)
  }

  // MARK: Fileprivate

  fileprivate final class Subscription: @unchecked Sendable {

    // MARK: Lifecycle

    init(
      buffer: CoalescingWindowEventBuffer,
      onTermination: @escaping @Sendable () -> Void,
    ) {
      self.buffer = buffer
      self.onTermination = onTermination
    }

    deinit {
      cancel()
    }

    // MARK: Internal

    func next() async -> WindowChangeEvent? {
      let event = await buffer.next()
      if event == nil { cancel() }
      return event
    }

    func cancel() {
      let shouldTerminate = lock.withLock {
        guard !isTerminated else { return false }
        isTerminated = true
        return true
      }
      guard shouldTerminate else { return }
      buffer.finish()
      onTermination()
    }

    // MARK: Private

    private let buffer: CoalescingWindowEventBuffer
    private let onTermination: @Sendable () -> Void
    private let lock = NSLock()
    private var isTerminated = false

  }

  // MARK: Private

  private let subscription: Subscription

}

// MARK: - CoalescingWindowEventBuffer

/// AX can deliver focus and geometry bursts faster than the main store can
/// consume them under CPU pressure. Preserve ordered drag-end edges, but keep
/// only the latest state event per logical window/app so stale callbacks do not
/// build an unbounded two-stage AsyncStream backlog.
final class CoalescingWindowEventBuffer: @unchecked Sendable {

  // MARK: Internal

  func yield(_ event: WindowChangeEvent) {
    let delivery: Delivery? = lock.withLock {
      guard !isFinished else { return nil }
      sequence &+= 1
      let pending = Pending(sequence: sequence, event: event)
      if event.isCoalescingBarrier {
        eventQueue.append(.ordered(pending))
        pendingEventCount += 1
        segment &+= 1
      } else if let key = event.coalescingKey {
        let slot = StateSlot(segment: segment, key: key)
        if latestStateEvents[slot] == nil {
          pendingEventCount += 1
        }
        latestStateEvents[slot] = pending
        eventQueue.append(
          .state(StateToken(slot: slot, sequence: pending.sequence))
        )
      } else {
        eventQueue.append(.ordered(pending))
        pendingEventCount += 1
      }
      compactEventQueueIfNeeded()
      guard let waiter, let next = takeNextEvent() else { return nil }
      self.waiter = nil
      return Delivery(continuation: waiter, event: next)
    }
    if let delivery {
      delivery.continuation.resume(returning: delivery.event)
    }
  }

  func makeSequence(
    onTermination: @escaping @Sendable () -> Void = { }
  ) -> WindowEventSequence {
    WindowEventSequence(buffer: self, onTermination: onTermination)
  }

  func finish() {
    let waiter: CheckedContinuation<WindowChangeEvent?, Never>? = lock.withLock {
      guard !isFinished else { return nil }
      isFinished = true
      guard pendingEventCount == 0 else { return nil }
      defer { self.waiter = nil }
      return self.waiter
    }
    waiter?.resume(returning: nil)
  }

  func next() async -> WindowChangeEvent? {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let result: NextResult = lock.withLock {
          if let event = takeNextEvent() {
            return .event(event)
          }
          if isFinished {
            return .finished
          }
          precondition(waiter == nil, "CoalescingWindowEventBuffer supports one consumer")
          waiter = continuation
          return .waiting
        }
        switch result {
        case .event(let event):
          continuation.resume(returning: event)
        case .finished:
          continuation.resume(returning: nil)
        case .waiting:
          break
        }
      }
    } onCancel: { [weak self] in
      self?.finish()
    }
  }

  // MARK: Fileprivate

  fileprivate enum Key: Hashable {
    case membership(String)
    case frame(WindowKey)
    case resized(WindowKey)
    case moved(WindowKey)
    case focus(bundleId: String, key: WindowKey?)
    case title(String)
  }

  // MARK: Private

  private struct Delivery {
    var continuation: CheckedContinuation<WindowChangeEvent?, Never>
    var event: WindowChangeEvent
  }

  private struct Pending {
    var sequence: UInt64
    var event: WindowChangeEvent
  }

  private struct StateSlot: Hashable {
    var segment: UInt64
    var key: Key
  }

  private struct StateToken {
    var slot: StateSlot
    var sequence: UInt64
  }

  private enum QueuedEvent {
    case ordered(Pending)
    case state(StateToken)
  }

  private enum NextResult {
    case event(WindowChangeEvent)
    case finished
    case waiting
  }

  private let lock = NSLock()
  private var sequence: UInt64 = 0
  private var segment: UInt64 = 0
  private var latestStateEvents = [StateSlot: Pending]()
  private var eventQueue = [QueuedEvent]()
  private var eventQueueHead = 0
  private var pendingEventCount = 0
  private var waiter: CheckedContinuation<WindowChangeEvent?, Never>?
  private var isFinished = false

  private func takeNextEvent() -> WindowChangeEvent? {
    while eventQueueHead < eventQueue.count {
      let queued = eventQueue[eventQueueHead]
      eventQueueHead += 1
      switch queued {
      case .ordered(let pending):
        pendingEventCount -= 1
        compactEventQueueIfNeeded()
        return pending.event

      case .state(let token):
        guard
          let pending = latestStateEvents[token.slot],
          pending.sequence == token.sequence
        else { continue }
        latestStateEvents.removeValue(forKey: token.slot)
        pendingEventCount -= 1
        compactEventQueueIfNeeded()
        return pending.event
      }
    }
    compactEventQueueIfNeeded()
    return nil
  }

  /// Updating one logical key appends a new token and leaves the old one as a
  /// tombstone. Rebuild only when removed entries can pay for the copy, keeping
  /// both drain time and retained storage linear in the event volume.
  private func compactEventQueueIfNeeded() {
    let queuedCount = eventQueue.count - eventQueueHead
    let tombstoneCount = queuedCount - pendingEventCount
    let consumedCanPayForCopy =
      eventQueueHead >= 1_024 && eventQueueHead >= queuedCount
    let tombstonesCanPayForCopy =
      tombstoneCount >= 1_024 && tombstoneCount >= pendingEventCount
    guard consumedCanPayForCopy || tombstonesCanPayForCopy else { return }

    var compacted = [QueuedEvent]()
    compacted.reserveCapacity(pendingEventCount)
    for queued in eventQueue[eventQueueHead...] {
      switch queued {
      case .ordered:
        compacted.append(queued)

      case .state(let token):
        guard
          latestStateEvents[token.slot]?.sequence == token.sequence
        else { continue }
        compacted.append(queued)
      }
    }
    eventQueue = compacted
    eventQueueHead = 0
  }

}

extension WindowChangeEvent {
  fileprivate var coalescingKey: CoalescingWindowEventBuffer.Key? {
    switch self {
    case .windowCreated(let bundleId),
         .windowDestroyed(let bundleId):
      .membership(bundleId)
    case .windowFrameChanged(let key, _):
      .frame(key)
    case .windowResized(let key, _):
      .resized(key)
    case .windowMoved(let key, _):
      .moved(key)
    case .windowFocused(let bundleId, let key):
      .focus(bundleId: bundleId, key: key)
    case .windowTitleChanged(let bundleId):
      .title(bundleId)
    case .windowDragEnded:
      nil
    }
  }

  fileprivate var isCoalescingBarrier: Bool {
    if case .windowDragEnded = self { true } else { false }
  }
}

// MARK: - WindowFrameWriteTracker

/// Bridges synchronous AX frame writes and AXObserver callbacks.
///
/// Observer callbacks cannot await an actor, so a lock is required for this
/// tiny synchronous contract. The reducer also mirrors its presentation-
/// convergence membership here, allowing an observer callback to skip the
/// timeout-prone AX frame read entirely for an unrelated programmatic change.
///
/// Each write entry lives only until its first post-write geometry notification.
/// In-flight/intermediate notifications and the final target echo are suppressed
/// before pointer state is considered; a different post-write frame is routed
/// according to the current pointer/monitoring state.
final class WindowFrameWriteTracker: @unchecked Sendable {

  // MARK: Lifecycle

  init() { }

  // MARK: Internal

  enum GeometryEventRoute: Equatable, Sendable {
    case ignore
    case pointerDriven
    case presentationChange
  }

  enum GeometryReadDisposition: Equatable, Sendable {
    case ignore
    case suppressOwnWrite
    case read
  }

  static let shared = WindowFrameWriteTracker()

  func begin(_ key: WindowKey, target: CGRect) -> UInt64 {
    lock.withLock {
      generation &+= 1
      entries[key] = Entry(generation: generation, target: target, isWriting: true)
      return generation
    }
  }

  func finish(_ key: WindowKey, generation: UInt64) {
    lock.withLock {
      guard var entry = entries[key], entry.generation == generation else { return }
      entry.isWriting = false
      entries[key] = entry
    }
  }

  /// Keep this registry equal to the reducer's currently armed convergence set.
  /// An exact replacement avoids stale monitored keys after tree replacement or
  /// composition dismissal.
  func setMonitoredKeys(_ keys: Set<WindowKey>) {
    lock.withLock {
      monitoredKeys = keys
    }
  }

  /// Decide whether the callback should pay for an AX geometry read.
  ///
  /// An in-flight Tatami write is known to be an echo without reading its frame.
  /// A completed write still needs one frame to distinguish its final target
  /// echo from an app-owned restore. Outside that write window, only a genuine
  /// pointer drag or a reducer-armed key needs geometry.
  func geometryReadDisposition(
    for key: WindowKey,
    pointerDriven: Bool,
  ) -> GeometryReadDisposition {
    lock.withLock {
      if entries[key]?.isWriting == true {
        return .suppressOwnWrite
      }
      if entries[key] != nil || pointerDriven || monitoredKeys.contains(key) {
        return .read
      }
      return .ignore
    }
  }

  /// Classify one geometry notification after its frame has been read.
  ///
  /// Own-write suppression deliberately precedes the pointer branch. A global
  /// left-button state can overlap a hotkey-driven tile pass; treating that echo
  /// as a manual drag mutates the BSP tree on the following mouse-up.
  func routeGeometryEvent(
    for key: WindowKey,
    frame: CGRect,
    pointerDriven: Bool,
    tolerance: CGFloat = 1.5,
  ) -> GeometryEventRoute {
    lock.withLock {
      if let entry = entries[key] {
        if entry.isWriting { return .ignore }
        entries[key] = nil
        let matchesTarget =
          abs(entry.target.minX - frame.minX) <= tolerance
            && abs(entry.target.minY - frame.minY) <= tolerance
            && abs(entry.target.width - frame.width) <= tolerance
            && abs(entry.target.height - frame.height) <= tolerance
        if matchesTarget { return .ignore }
      }
      if pointerDriven { return .pointerDriven }
      if monitoredKeys.contains(key) { return .presentationChange }
      return .ignore
    }
  }

  // MARK: Private

  private struct Entry {
    var generation: UInt64
    var target: CGRect
    var isWriting: Bool
  }

  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var entries = [WindowKey: Entry]()
  private var monitoredKeys = Set<WindowKey>()

}

// MARK: - WindowObserverClient + DependencyKey

extension WindowObserverClient: DependencyKey {
  static let liveValue: WindowObserverClient = {
    let center = WindowObserverCenter()
    return WindowObserverClient(
      observe: { bundleIds in
        await center.observe(bundleIds: bundleIds)
      },
      events: { center.makeStream() },
    )
  }()

  static let testValue = WindowObserverClient(
    observe: { _ in },
    events: { .finished },
  )

  static let previewValue = testValue
}

extension DependencyValues {
  var windowObserver: WindowObserverClient {
    get { self[WindowObserverClient.self] }
    set { self[WindowObserverClient.self] = newValue }
  }
}

// MARK: - WindowObserverCenter

/// Lives for the lifetime of the process. AppKit discovery and the global
/// mouse monitor stay on the main actor, but every app's AX observer lives on
/// its own run-loop thread. A slow target app can therefore delay only its own
/// AX stream, never Tatami's menu/hotkey event loop or another app's observer.
///
/// Observers are kept for the process lifetime of each observed app:
/// `observe(bundleIds:)` is purely additive, never tears anything down
/// just because a bundle id disappeared from the caller's "interesting"
/// set. Once an `AXObserver` is wired up for a pid we keep it until the
/// pid actually exits. Tearing the observer down and rebuilding it on
/// every sync would lose any `kAXWindowCreated` that fired in the gap
/// (a known source of the "Notification-Center-opened KakaoTalk window
/// is invisible" bug).
/// Termination cleanup runs whenever the observed bundle set is refreshed.
private final class WindowObserverCenter: @unchecked Sendable {

  // MARK: Lifecycle

  init() {
    let fanIn = CoalescingWindowEventBuffer()
    eventSink = fanIn
    registry = WindowObserverRegistry(eventSink: fanIn)
    // Process-lifetime pump: coalesced fan-in → each subscriber's own
    // coalesced stream.
    Task { [weak self, fanIn] in
      for await event in fanIn.makeSequence() { self?.broadcast(event) }
    }
  }

  // MARK: Internal

  /// A fresh multicast stream per caller. Registered under the lock and
  /// dropped on termination (subscriber cancels its `for await`).
  func makeStream() -> WindowEventSequence {
    let id = UUID()
    let subscriber = CoalescingWindowEventBuffer()
    lock.withLock { subscribers[id] = subscriber }
    return subscriber.makeSequence { [weak self] in
      self?.lock.withLock { _ = self?.subscribers.removeValue(forKey: id) }
    }
  }

  func observe(bundleIds: [String]) async {
    let snapshot = await MainActor.run {
      self.captureRunningAppsSnapshot(requestedBundleIds: bundleIds)
    }
    await registry.installOrUpdate(
      snapshotGeneration: snapshot.generation,
      bundleIds: bundleIds,
      candidates: snapshot.candidates,
      livePids: snapshot.livePids,
    )
  }

  // MARK: Private

  /// Fan-in: every `ObservedApp` and the drag monitor yield here. A pump task
  /// forwards each event to all live subscribers, so multiple consumers
  /// (activation + the layout preview) each get their own stream without
  /// stealing events from one another.
  private let eventSink: CoalescingWindowEventBuffer
  private let registry: WindowObserverRegistry
  /// WindowServer snapshots can stall briefly when the system is saturated.
  /// Keep them off AppKit's global-monitor callback while preserving exact
  /// mouse-down/up ordering on one serial lane.
  private let dragCaptureQueue = DispatchQueue(
    label: "dev.PangMo5.Tatami.pointer-drag-capture",
    qos: .userInteractive,
  )
  private let lock = NSLock()
  private var subscribers = [UUID: CoalescingWindowEventBuffer]()
  /// Global mouse monitor; captures the exact window under mouse-down and
  /// emits `.windowDragEnded` so the reducer commits at the true drag end.
  private var dragMonitor: Any?
  /// Assigned on the main actor when the running-app snapshot is captured, not
  /// when its async caller eventually reaches the registry actor. This lets the
  /// registry reject an older capture that resumes out of order.
  @MainActor private var runningAppsSnapshotGeneration: UInt64 = 0

  private func broadcast(_ event: WindowChangeEvent) {
    let live = lock.withLock { Array(subscribers.values) }
    for subscriber in live { subscriber.yield(event) }
  }

  @MainActor
  private func captureRunningAppsSnapshot(
    requestedBundleIds: [String]
  ) -> RunningAppsSnapshot {
    installDragEndMonitorIfNeeded()
    runningAppsSnapshotGeneration &+= 1
    return RunningAppsSnapshot.capture(
      generation: runningAppsSnapshotGeneration,
      requestedBundleIds: requestedBundleIds,
    )
  }

  @MainActor
  private func installDragEndMonitorIfNeeded() {
    // Install the global mouse-up monitor once. The reducer flushes a pending
    // manual move/resize on `.windowDragEnded`, so the commit lands at the
    // real end of the drag rather than on a time guess. Global monitors only
    // see other apps' events — exactly where window drags happen.
    if dragMonitor == nil {
      let dragCaptureQueue = dragCaptureQueue
      let eventSink = eventSink
      dragMonitor = NSEvent.addGlobalMonitorForEvents(
        matching: [.leftMouseDown, .leftMouseUp]
      ) { event in
        switch event.type {
        case .leftMouseDown:
          let cgEvent = event.cgEvent
          let rawWindowID = cgEvent?.getIntegerValueField(
            .mouseEventWindowUnderMousePointer
          )
          let windowID = rawWindowID.flatMap {
            $0 > 0 ? CGWindowID(truncatingIfNeeded: $0) : nil
          }
          let location = cgEvent?.location
          // Publish the cheap identity immediately. The WindowServer snapshot
          // below may be delayed under load, but AX callbacks must never keep
          // treating the previous drag's window as pointer-driven meanwhile.
          WindowPointerDragTracker.shared.pointerDown(
            windowID: windowID,
            location: location,
          )

        case .leftMouseUp:
          let session = WindowPointerDragTracker.shared.pointerUp(
            location: event.cgEvent?.location
          )
          dragCaptureQueue.async {
            guard
              let session,
              let completion = WindowPointerDragTracker.shared.complete(session)
            else { return }
            WindowPointerDragTracker.shared.yieldIfCurrent(
              completion,
              for: session,
              to: eventSink,
            )
          }

        default:
          break
        }
      }
    }
  }

}

// MARK: - RunningAppSnapshot

struct RunningAppSnapshot: Sendable {
  var pid: pid_t
  var bundleId: String
}

// MARK: - WindowObservedAppHandle

/// Type-erased observer lifetime used by the registry. Keeping installation
/// behind a handle makes the actor's suspend/revalidate contract testable
/// without constructing real Accessibility objects or run-loop threads.
struct WindowObservedAppHandle: Sendable {
  var pid: pid_t
  var bundleId: String
  var install: @Sendable () async -> Int?
  var tearDown: @Sendable () async -> Void
  var stopThread: @Sendable () -> Void
}

// MARK: - RunningAppsSnapshot

private struct RunningAppsSnapshot: Sendable {
  var generation: UInt64
  var candidates: [RunningAppSnapshot]
  var livePids: Set<pid_t>

  @MainActor
  static func capture(
    generation: UInt64,
    requestedBundleIds: [String],
  ) -> RunningAppsSnapshot {
    let requested = Set(requestedBundleIds)
    let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
    return RunningAppsSnapshot(
      generation: generation,
      candidates: running.compactMap { app in
        guard
          app.activationPolicy == .regular,
          let bundleId = app.bundleIdentifier,
          requested.contains(bundleId)
        else { return nil }
        return RunningAppSnapshot(pid: app.processIdentifier, bundleId: bundleId)
      },
      livePids: Set(running.map(\.processIdentifier)),
    )
  }
}

// MARK: - WindowObserverRegistry

/// Serializes registry mutations while each `ObservedApp` owns its AX state on
/// a dedicated run-loop thread. The actor may suspend during installation
/// without allowing duplicate installs because `installing` reserves the pid.
actor WindowObserverRegistry {

  // MARK: Lifecycle

  init(
    eventSink: CoalescingWindowEventBuffer,
    makeObservedApp: (@Sendable (
      _ pid: pid_t,
      _ bundleId: String,
      _ eventSink: CoalescingWindowEventBuffer,
    ) -> WindowObservedAppHandle)? = nil,
  ) {
    self.eventSink = eventSink
    self.makeObservedApp = makeObservedApp ?? { pid, bundleId, eventSink in
      let app = ObservedApp(
        pid: pid,
        bundleId: bundleId,
        eventSink: eventSink,
      )
      return WindowObservedAppHandle(
        pid: pid,
        bundleId: bundleId,
        install: { await app.install() },
        tearDown: { await app.tearDown() },
        stopThread: { app.stopThread() },
      )
    }
  }

  // MARK: Internal

  func installOrUpdate(
    snapshotGeneration: UInt64,
    bundleIds: [String],
    candidates: [RunningAppSnapshot],
    livePids: Set<pid_t>,
  ) async {
    @Dependency(\.debugLog) var debugLog
    let advancesLiveness = snapshotGeneration > latestLivePidsGeneration
    if advancesLiveness {
      latestLivePidsGeneration = snapshotGeneration
      latestLivePids = livePids
    } else {
      debugLog.log(
        "Observer",
        "retain latest liveness for stale observer interest "
          + "generation=\(snapshotGeneration) latest=\(latestLivePidsGeneration)",
      )
    }

    // Drop observers whose pid has died. Anything still running stays
    // observed even if it's no longer in the caller's interest set —
    // the next focus/launch event will surface it again, and we'd
    // otherwise have to rebuild the AXObserver from scratch (losing
    // any window-created event in flight).
    if advancesLiveness {
      let deadPids = observed.keys.filter { !latestLivePids.contains($0) }
      for pid in deadPids {
        guard let obs = observed.removeValue(forKey: pid) else { continue }
        debugLog.log("Observer", "teardown pid=\(pid) bundle=\(obs.bundleId): pid dead")
        await obs.tearDown()
      }
    }

    // Add observers for any new (pid, bundleId) pair we haven't seen
    // yet. Apps with multiple processes (e.g. helper instances) each
    // get their own AXObserver.
    for bundleId in bundleIds {
      let apps = candidates.filter { $0.bundleId == bundleId }
      if apps.isEmpty {
        debugLog.log("Observer", "skip \(bundleId): no running .regular app")
        continue
      }
      for app in apps {
        // This loop may resume after installing an earlier app. Avoid starting
        // another observer from the old candidate list when a newer liveness
        // snapshot already reported this pid dead.
        guard latestLivePids.contains(app.pid) else {
          debugLog.log(
            "Observer",
            "skip stale candidate pid=\(app.pid) bundle=\(bundleId)",
          )
          continue
        }
        if observed[app.pid] != nil || installing.contains(app.pid) {
          debugLog.log(
            "Observer",
            "already-observed pid=\(app.pid) bundle=\(bundleId)",
          )
          continue
        }
        installing.insert(app.pid)
        let obs = makeObservedApp(app.pid, bundleId, eventSink)
        let initialWindowCount = await obs.install()
        installing.remove(app.pid)

        // `await obs.install()` is an actor reentrancy point. A newer running-app
        // snapshot can report this pid dead while the AX thread is still arming.
        // Never publish that stale observer after resumption: the newer call
        // could not remove it from `observed` because it did not exist there yet.
        guard latestLivePids.contains(app.pid) else {
          debugLog.log(
            "Observer",
            "discard stale install pid=\(app.pid) bundle=\(bundleId) "
              + "requestGeneration=\(snapshotGeneration) "
              + "latestGeneration=\(latestLivePidsGeneration)",
          )
          if initialWindowCount != nil {
            await obs.tearDown()
          } else {
            obs.stopThread()
          }
          continue
        }

        if let initialWindowCount {
          observed[app.pid] = obs
          debugLog.log(
            "Observer",
            "installed pid=\(app.pid) bundle=\(bundleId) initialWindows=\(initialWindowCount)",
          )
          // Installation itself is a state edge: a window can be created,
          // destroyed, or restored between the caller's cache read and the
          // moment notifications become armed. Replay one bundle-level
          // reconcile after the source is installed; subsequent changes are
          // carried by real notifications.
          eventSink.yield(.windowCreated(bundleId: bundleId))
        } else {
          debugLog.log(
            "Observer",
            "install FAILED pid=\(app.pid) bundle=\(bundleId)",
          )
          obs.stopThread()
        }
      }
    }
  }

  // MARK: Private

  private let eventSink: CoalescingWindowEventBuffer
  private let makeObservedApp: @Sendable (
    _ pid: pid_t,
    _ bundleId: String,
    _ eventSink: CoalescingWindowEventBuffer,
  ) -> WindowObservedAppHandle
  private var observed = [pid_t: WindowObservedAppHandle]()
  private var installing = Set<pid_t>()
  /// Latest process-liveness snapshot accepted by this actor. Installation
  /// captures its generation before suspension and revalidates against this
  /// authoritative set before publishing the observer.
  private var latestLivePidsGeneration: UInt64 = 0
  private var latestLivePids = Set<pid_t>()

}

// MARK: - ObservedApp

/// One AXObserver wired to a single app, listening for window
/// created/destroyed events on the app element + on each existing
/// window (destruction is reported on the window element itself, not
/// the app).
///
/// All mutable properties are confined to `thread`. `@unchecked Sendable` is
/// the bridge required by the C callback and retry task; neither accesses the
/// state directly from another executor.
private final class ObservedApp: @unchecked Sendable {

  // MARK: Lifecycle

  fileprivate init(
    pid: pid_t,
    bundleId: String,
    eventSink: CoalescingWindowEventBuffer,
  ) {
    self.pid = pid
    self.bundleId = bundleId
    self.eventSink = eventSink
    thread = AXObserverThread(pid: pid)
  }

  // MARK: Internal

  let pid: pid_t
  let bundleId: String
  let eventSink: CoalescingWindowEventBuffer

  // MARK: Fileprivate

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
    Darwin.kill(pid, 0) == 0 || errno == EPERM
  }

  /// Creates the observer and all AX references on their owning run-loop
  /// thread. Returns the initial subscribed-window count on success.
  fileprivate func install() async -> Int? {
    try? await thread.perform { [self] in installOnThread() }
  }

  /// Register every app-level notification we care about. Returns true
  /// when every call succeeded; sets `needsAXRetry` otherwise so the
  /// caller can schedule a retry.
  @discardableResult
  fileprivate func registerNotifications(info: UnsafeMutableRawPointer) -> Bool {
    guard let observer, let appElement else { return false }
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
      if r != .success, r != .notificationAlreadyRegistered {
        allOK = false
        if r == .cannotComplete {
          needsAXRetry = true
        }
        debugLog.log(
          "Observer",
          "addNotification \(label) FAILED pid=\(pid) bundle=\(bundleId) err=\(r.rawValue)",
        )
      }
    }
    return allOK
  }

  /// Delayed retry of the AX notification setup. Matches the upstream
  /// `ax_retry` loop: 200 ms between attempts, capped at `attemptsRemaining`.
  fileprivate func scheduleAXRetry(attemptsRemaining: Int) {
    retryTask?.cancel()
    retryGeneration &+= 1
    let generation = retryGeneration
    let thread = thread
    retryTask = Task { [weak self, thread] in
      try? await Task.sleep(for: .milliseconds(200))
      guard !Task.isCancelled, let self else { return }
      thread.enqueue { [weak self] in
        self?.performAXRetry(
          generation: generation,
          attemptsRemaining: attemptsRemaining,
        )
      }
    }
  }

  fileprivate func tearDown() async {
    _ = try? await thread.perform { [self] in tearDownOnThread() }
    thread.stop()
  }

  fileprivate func stopThread() {
    thread.stop()
  }

  /// Keep the C callback bounded: subscription refresh can synchronously wait
  /// on the target app, so run it as the next turn on this app's own run loop
  /// after the callback has returned.
  fileprivate func refreshAfterWindowCreated() {
    thread.enqueue { [weak self] in
      guard let self else { return }
      refreshWindowSubscriptions()
      if needsAXRetry {
        scheduleAXRetry(attemptsRemaining: 10)
      }
    }
  }

  @discardableResult
  fileprivate func refreshWindowSubscriptions() -> Bool {
    guard let observer, let appElement else { return false }
    @Dependency(\.debugLog) var debugLog
    var raw: CFTypeRef?
    let windowsError = AXUIElementCopyAttributeValue(
      appElement,
      kAXWindowsAttribute as CFString,
      &raw,
    )
    guard windowsError == .success, let windows = raw as? [AXUIElement]
    else {
      debugLog.log(
        "Observer",
        "refreshSubs pid=\(pid) bundle=\(bundleId): "
          + "kAXWindowsAttribute err=\(windowsError.rawValue)",
      )
      lastSubscribedWindowCount = 0
      let isAnsweredEmpty =
        windowsError == .noValue || windowsError == .attributeUnsupported
      if !isAnsweredEmpty { needsAXRetry = true }
      return isAnsweredEmpty
    }
    lastSubscribedWindowCount = windows.count
    debugLog.log(
      "Observer",
      "refreshSubs pid=\(pid) bundle=\(bundleId) windows=\(windows.count)",
    )
    let info = Unmanaged.passUnretained(self).toOpaque()
    let windowNotifications: [(CFString, String)] = [
      (kAXUIElementDestroyedNotification as CFString, "kAXUIElementDestroyed"),
      (kAXWindowResizedNotification as CFString, "kAXWindowResized"),
      (kAXWindowMovedNotification as CFString, "kAXWindowMoved"),
    ]
    var allOK = true
    for window in windows {
      for (name, label) in windowNotifications {
        let r = AXObserverAddNotification(observer, window, name, info)
        // Same policy as the app-level registrations: a freshly-launched
        // Electron app can answer CannotComplete (-25204) here too, and
        // macOS never re-attempts on its own — without the flag the
        // window's destroy/resize/move events were permanently missing.
        if r != .success, r != .notificationAlreadyRegistered {
          allOK = false
          needsAXRetry = true
          debugLog.log(
            "Observer",
            "addNotification \(label) FAILED pid=\(pid) bundle=\(bundleId) err=\(r.rawValue)",
          )
        }
      }
    }
    return allOK
  }

  // MARK: Private

  private let thread: AXObserverThread
  private var observer: AXObserver?
  private var appElement: AXUIElement?
  /// Invalidates a retry that already woke but has not reached the AX thread
  /// yet. Cancellation alone cannot retract a queued CFRunLoop block.
  private var retryGeneration: UInt64 = 0

  private func installOnThread() -> Int? {
    @Dependency(\.debugLog) var debugLog
    var observer: AXObserver?
    let createResult = AXObserverCreate(pid, axObserverCallback, &observer)
    guard createResult == .success, let observer else {
      debugLog.log(
        "Observer",
        "AXObserverCreate FAILED pid=\(pid) bundle=\(bundleId) err=\(createResult.rawValue)",
      )
      return nil
    }
    let appElement = AXUIElementCreateApplication(pid)
    self.observer = observer
    self.appElement = appElement

    let info = Unmanaged.passUnretained(self).toOpaque()
    needsAXRetry = false
    let appNotificationsReady = registerNotifications(info: info)

    // Existing windows: subscribe to destruction + resize + move.
    let windowNotificationsReady = refreshWindowSubscriptions()
    needsAXRetry = !(appNotificationsReady && windowNotificationsReady)
    thread.addSource(AXObserverGetRunLoopSource(observer))

    if needsAXRetry {
      // A heavy app's cold launch can take many seconds before its AX layer
      // answers (Electron especially). Retry generously: yabai re-arms every
      // 100 ms with no cap until the app is observable. We cap at 150 × 200 ms
      // (~30 s) plus a pid-alive guard so a slow app's kAXWindowCreated still
      // gets armed instead of giving up after a few seconds and missing the
      // first lazily-opened window. An app whose AX comes up sooner stops early
      // (the retry returns the moment registration succeeds); a workspace
      // switch's re-scan is the final safety net.
      scheduleAXRetry(attemptsRemaining: 150)
    }

    return lastSubscribedWindowCount
  }

  private func performAXRetry(generation: UInt64, attemptsRemaining: Int) {
    guard generation == retryGeneration else { return }
    @Dependency(\.debugLog) var debugLog
    let id = Unmanaged.passUnretained(self).toOpaque()
    debugLog.log(
      "Observer",
      "ax retry pid=\(pid) bundle=\(bundleId) remaining=\(attemptsRemaining)",
    )
    needsAXRetry = false
    let appNotificationsReady = registerNotifications(info: id)
    let windowNotificationsReady = refreshWindowSubscriptions()
    let ok = appNotificationsReady && windowNotificationsReady
    needsAXRetry = !ok
    if ok {
      // AX is ready: kAXWindowCreated is now armed, so a window that appears
      // from here on fires a real event on its own — arming the subscription
      // was the retry's whole job. Replay any window that slipped in while AX
      // was not ready; the live subscription covers the rest.
      debugLog.log(
        "Observer",
        "ax retry SUCCEEDED pid=\(pid) bundle=\(bundleId) windows=\(lastSubscribedWindowCount)",
      )
      retryTask = nil
      if lastSubscribedWindowCount > 0 {
        eventSink.yield(.windowCreated(bundleId: bundleId))
      }
      return
    }
    // Keep retrying only while the app is alive and AX still isn't ready.
    if attemptsRemaining > 1, ObservedApp.isPidAlive(pid) {
      scheduleAXRetry(attemptsRemaining: attemptsRemaining - 1)
    } else {
      debugLog.log(
        "Observer",
        "ax retry GAVE UP pid=\(pid) bundle=\(bundleId) (ax never became ready)",
      )
      retryTask = nil
    }
  }

  private func tearDownOnThread() {
    retryTask?.cancel()
    retryTask = nil
    retryGeneration &+= 1
    if let observer {
      thread.removeSource(AXObserverGetRunLoopSource(observer))
    }
    observer = nil
    appElement = nil
  }

}

/// AXObserver callbacks execute on the owning app's `AXObserverThread`.
/// Synchronous AX messaging is therefore isolated from Tatami's main run loop
/// and from every other observed app.
private func axObserverCallback(
  observer _: AXObserver,
  element: AXUIElement,
  notification: CFString,
  refcon: UnsafeMutableRawPointer?,
) {
  guard let refcon else { return }
  let app = Unmanaged<ObservedApp>.fromOpaque(refcon).takeUnretainedValue()
  let name = notification as String
  @Dependency(\.debugLog) var debugLog
  switch name {
  case AXNotificationName.windowCreated:
    debugLog.log(
      "AX",
      "windowCreated pid=\(app.pid) bundle=\(app.bundleId)",
    )
    app.eventSink.yield(.windowCreated(bundleId: app.bundleId))
    // A brand-new window can answer CannotComplete just like a brand-new
    // app. Subscribe on the next run-loop turn so the C callback returns
    // before any timeout-prone AX refresh.
    app.refreshAfterWindowCreated()

  case AXNotificationName.elementDestroyed:
    debugLog.log(
      "AX",
      "windowDestroyed pid=\(app.pid) bundle=\(app.bundleId)",
    )
    app.eventSink.yield(.windowDestroyed(bundleId: app.bundleId))

  case AXNotificationName.windowResized:
    routeGeometryNotification(element, app: app, kind: .resized)

  case AXNotificationName.windowMoved:
    routeGeometryNotification(element, app: app, kind: .moved)

  case AXNotificationName.focusedWindowChanged,
       AXNotificationName.mainWindowChanged:
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
      "windowFocused pid=\(app.pid) bundle=\(app.bundleId) key=\(key?.windowID.description ?? "nil")",
    )
    app.eventSink.yield(.windowFocused(bundleId: app.bundleId, key: key))

  case AXNotificationName.windowMiniaturized,
       AXNotificationName.windowDeminiaturized:
    // Treat both as a reason to reconcile — minimized windows drop
    // out of `discoverWindowKeys` (subrole filter), restored ones
    // need to come back into the tree.
    debugLog.log(
      "AX",
      "miniaturizeChange pid=\(app.pid) bundle=\(app.bundleId) name=\(name)",
    )
    app.eventSink.yield(.windowCreated(bundleId: app.bundleId))

  case AXNotificationName.menuOpened:
    app.isMenuOpen = true

  case AXNotificationName.menuClosed:
    app.isMenuOpen = false

  case AXNotificationName.titleChanged:
    // Cosmetic for tiling; forwarded so the layout preview can refresh
    // titles live. The activation reducer ignores it.
    app.eventSink.yield(.windowTitleChanged(bundleId: app.bundleId))

  default:
    break
  }
}

// MARK: - WindowGeometryNotificationKind

private enum WindowGeometryNotificationKind {
  case moved
  case resized
}

/// Route an AX geometry callback without reading its frame unless the exact key
/// is part of a Tatami write, a pointer drag, or the reducer's convergence set.
private func routeGeometryNotification(
  _ element: AXUIElement,
  app: ObservedApp,
  kind: WindowGeometryNotificationKind,
) {
  guard let key = WindowKey(axWindow: element, pid: app.pid, bundleId: app.bundleId)
  else { return }
  let tracker = WindowFrameWriteTracker.shared
  // Reject an in-flight Tatami write before consulting global pointer state.
  // A notification click can hold the left button while KakaoTalk restores an
  // unrelated window; only the exact WindowServer surface captured at
  // mouse-down is a manual drag.
  let preflight = tracker.geometryReadDisposition(for: key, pointerDriven: false)
  if preflight == .suppressOwnWrite { return }
  let pointerDriven = WindowPointerDragTracker.shared.isDragging(key.windowID)
  switch (preflight, pointerDriven) {
  case (.ignore, false):
    return

  case (.ignore, true),
       (.read, _):
    break

  case (.suppressOwnWrite, _):
    return
  }
  guard let frame = AXWindowGeometry.frame(of: element) else { return }
  switch tracker.routeGeometryEvent(
    for: key,
    frame: frame,
    pointerDriven: pointerDriven,
  ) {
  case .ignore:
    return

  case .pointerDriven:
    switch kind {
    case .moved:
      app.eventSink.yield(.windowMoved(key: key, frame: frame))
    case .resized:
      app.eventSink.yield(.windowResized(key: key, frame: frame))
    }

  case .presentationChange:
    app.eventSink.yield(.windowFrameChanged(key: key, frame: frame))
  }
}

// MARK: - AXNotificationName

/// `AXObserver` delivers notification names as `CFString`. Converting the
/// constants once keeps the switch an ordinary `String` value comparison;
/// writing `case constant as String` is parsed as a cast pattern and emits an
/// "'as' test is always true" warning for every case.
private enum AXNotificationName {
  static let windowCreated = kAXWindowCreatedNotification as String
  static let elementDestroyed = kAXUIElementDestroyedNotification as String
  static let windowResized = kAXWindowResizedNotification as String
  static let windowMoved = kAXWindowMovedNotification as String
  static let focusedWindowChanged = kAXFocusedWindowChangedNotification as String
  static let mainWindowChanged = kAXMainWindowChangedNotification as String
  static let windowMiniaturized = kAXWindowMiniaturizedNotification as String
  static let windowDeminiaturized = kAXWindowDeminiaturizedNotification as String
  static let menuOpened = kAXMenuOpenedNotification as String
  static let menuClosed = kAXMenuClosedNotification as String
  static let titleChanged = kAXTitleChangedNotification as String
}

// MARK: - WindowPointerDragCompletion

struct WindowPointerDragCompletion: Sendable {
  var trackedWindowID: CGWindowID?
  var key: WindowKey?
  var frame: CGRect?
  var pointerMoved: Bool

  var event: WindowChangeEvent {
    .windowDragEnded(
      trackedWindowID: trackedWindowID,
      key: key,
      frame: frame,
      pointerMoved: pointerMoved,
    )
  }
}

// MARK: - WindowPointerDragTracker

/// Captures the exact WindowServer surface under a left mouse-down.
///
/// Button state alone is not evidence that an AX move/resize belongs to the
/// pointer. Clicking Notification Center can make KakaoTalk restore its saved
/// frame while the same button is held; classifying that unrelated callback as
/// a drag commits the restored frame into the BSP tree on mouse-up.
final class WindowPointerDragTracker: @unchecked Sendable {

  // MARK: Internal

  struct Session: Sendable {
    var generation: UInt64
    var windowID: CGWindowID?
    var startLocation: CGPoint?
    var endLocation: CGPoint?
  }

  static let shared = WindowPointerDragTracker()

  /// Capture only event-native values in the global-monitor callback. This
  /// lock is intentionally tiny; WindowServer work stays on the serial capture
  /// queue and no longer tries to reconstruct the frame from a late "start"
  /// snapshot.
  func pointerDown(windowID: CGWindowID?, location: CGPoint?) {
    lock.withLock {
      generation &+= 1
      activeSession = Session(
        generation: generation,
        windowID: windowID,
        startLocation: location,
        endLocation: nil,
      )
    }
  }

  func pointerUp(location: CGPoint?) -> Session? {
    lock.withLock {
      guard var session = activeSession else { return nil }
      session.endLocation = location
      activeSession = nil
      return session
    }
  }

  func complete(_ session: Session) -> WindowPointerDragCompletion? {
    let distance = session.startLocation.flatMap { start in
      session.endLocation.map { end in
        hypot(end.x - start.x, end.y - start.y)
      }
    }
    let pointerMoved = (distance ?? 0) > 1
    guard pointerMoved else {
      return WindowPointerDragCompletion(
        trackedWindowID: session.windowID,
        key: nil,
        frame: nil,
        pointerMoved: false,
      )
    }
    let fallbackWindowID = session.windowID == nil
      ? session.endLocation.flatMap(Self.topmostWindowID)
      : nil
    let resolvedWindowID = session.windowID ?? fallbackWindowID
    let current = resolvedWindowID
      .flatMap(Self.snapshot)
    return WindowPointerDragCompletion(
      trackedWindowID: resolvedWindowID,
      key: current?.key,
      frame: current?.frame,
      pointerMoved: true,
    )
  }

  /// Validate the session and enqueue its barrier while holding the same lock
  /// used by `pointerDown`. This makes the ordering atomic: either the old
  /// barrier lands before a new drag becomes active, or the new generation is
  /// already visible and the stale barrier is discarded.
  @discardableResult
  func yieldIfCurrent(
    _ completion: WindowPointerDragCompletion,
    for session: Session,
    to eventSink: CoalescingWindowEventBuffer,
  ) -> Bool {
    lock.withLock {
      guard generation == session.generation else { return false }
      eventSink.yield(completion.event)
      return true
    }
  }

  func isDragging(_ candidate: CGWindowID) -> Bool {
    CGEventSource.buttonState(.combinedSessionState, button: .left)
      && lock.withLock { activeSession?.windowID == candidate }
  }

  // MARK: Private

  private struct Snapshot {
    var key: WindowKey
    var frame: CGRect
  }

  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var activeSession: Session?

  private static func snapshot(_ windowID: CGWindowID) -> Snapshot? {
    guard
      let window = (
        CGWindowListCopyWindowInfo(
          [.optionIncludingWindow, .excludeDesktopElements],
          windowID,
        ) as? [[String: Any]]
      )?.first,
      let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
      pid != getpid(),
      let bundleId = NSRunningApplication(
        processIdentifier: pid
      )?.bundleIdentifier,
      let rawBounds = window[kCGWindowBounds as String] as? NSDictionary,
      let frame = CGRect(
        dictionaryRepresentation: rawBounds as CFDictionary
      )
    else { return nil }
    return Snapshot(
      key: WindowKey(pid: pid, windowID: windowID, bundleId: bundleId),
      frame: frame,
    )
  }

  private static func topmostWindowID(at point: CGPoint) -> CGWindowID? {
    guard
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID,
      ) as? [[String: Any]]
    else { return nil }
    for window in windows {
      guard
        (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != getpid(),
        let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
        number != 0,
        let rawBounds = window[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(
          dictionaryRepresentation: rawBounds as CFDictionary
        ),
        bounds.insetBy(dx: -8, dy: -8).contains(point)
      else { continue }
      return number
    }
    return nil
  }

}

// MARK: - AXObserverThread

/// Dedicated run loop for one target process's AX objects. AX references are
/// created, observed, queried, and released on this thread, matching
/// AeroSpace's thread-affinity model while keeping an unresponsive target app
/// away from Tatami's UI and other observers.
private final class AXObserverThread: @unchecked Sendable {

  // MARK: Lifecycle

  init(pid: pid_t) {
    let (readiness, readyContinuation) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    self.readiness = readiness
    let thread = Thread { [self] in
      let currentRunLoop = CFRunLoopGetCurrent()
      RunLoop.current.add(NSMachPort(), forMode: .common)
      let shouldRun = lifecycleLock.withLock {
        runLoop = currentRunLoop
        switch lifecycle {
        case .starting:
          lifecycle = .running
          return true

        case .stopping:
          lifecycle = .stopped
          return false

        case .running,
             .stopped:
          return false
        }
      }
      readyContinuation.yield(())
      readyContinuation.finish()
      guard shouldRun else { return }
      // `RunLoop.run()` starts the run loop again after `CFRunLoopStop`, which
      // leaks one thread per exited app. Run one mode turn at a time so the
      // lifecycle flag is authoritative, and drain autoreleased AX/Foundation
      // bridges after every callback batch.
      while lifecycleLock.withLock({ lifecycle != .stopped }) {
        autoreleasepool {
          _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 60, true)
        }
      }
    }
    thread.name = "dev.PangMo5.Tatami.ax-observer.\(pid)"
    thread.qualityOfService = .userInitiated
    thread.start()
  }

  // MARK: Internal

  func perform<Value: Sendable>(
    _ work: @escaping @Sendable () -> Value
  ) async throws -> Value {
    if lifecycleLock.withLock({ lifecycle == .starting }) {
      for await _ in readiness { break }
    }
    try Task.checkCancellation()
    return try await withCheckedThrowingContinuation { continuation in
      let accepted = scheduleIfRunning {
        continuation.resume(returning: work())
      }
      if !accepted {
        continuation.resume(throwing: ThreadError.stopped)
      }
    }
  }

  func enqueue(_ work: @escaping @Sendable () -> Void) {
    _ = scheduleIfRunning(work)
  }

  func addSource(_ source: CFRunLoopSource) {
    CFRunLoopAddSource(runLoop, source, .commonModes)
    CFRunLoopWakeUp(runLoop)
  }

  func removeSource(_ source: CFRunLoopSource) {
    CFRunLoopRemoveSource(runLoop, source, .commonModes)
    CFRunLoopWakeUp(runLoop)
  }

  func stop() {
    lifecycleLock.withLock {
      switch lifecycle {
      case .starting:
        // The thread publishes readiness even when startup was cancelled, but
        // must not overwrite this request with `.running`.
        lifecycle = .stopping

      case .running:
        // Serialize shutdown behind every already-accepted perform block. A
        // direct CFRunLoopStop can make the loop exit before those blocks run,
        // leaving their checked continuations suspended forever.
        lifecycle = .stopping
        let loop = runLoop!
        CFRunLoopPerformBlock(
          loop,
          CFRunLoopMode.commonModes.rawValue,
        ) { [self] in
          lifecycleLock.withLock { lifecycle = .stopped }
          CFRunLoopStop(loop)
        }
        CFRunLoopWakeUp(loop)

      case .stopping,
           .stopped:
        break
      }
    }
  }

  // MARK: Private

  private enum Lifecycle {
    case starting
    case running
    case stopping
    case stopped
  }

  private enum ThreadError: Error {
    case stopped
  }

  private nonisolated(unsafe) var runLoop: CFRunLoop!
  private let readiness: AsyncStream<Void>
  private let lifecycleLock = NSLock()
  private var lifecycle = Lifecycle.starting

  private func scheduleIfRunning(
    _ work: @escaping @Sendable () -> Void
  ) -> Bool {
    lifecycleLock.withLock {
      guard lifecycle == .running else { return false }
      CFRunLoopPerformBlock(
        runLoop,
        CFRunLoopMode.commonModes.rawValue,
        work,
      )
      CFRunLoopWakeUp(runLoop)
      return true
    }
  }

}
