// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ApplicationServices
import Dependencies
import OSLog
import ScreenCaptureKit

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "FloatingOverlay")

// MARK: - FloatingOverlayGeometryUpdate

private struct FloatingOverlayGeometryUpdate: Sendable {
  var generation: UInt64
  var frames: [WindowKey: CGRect]
  var invalidated: Set<WindowKey>
  var replacesSnapshot: Bool
}

// MARK: - FloatingOverlayVisibilityInput

private struct FloatingOverlayVisibilityInput: Sendable {
  var key: WindowKey
  var frame: CGRect
  var floatingPIDs: Set<pid_t>
  var sourceWindowIDs: Set<CGWindowID>?
  var mirrorWindowIDs: Set<CGWindowID>
}

func areFloatingMirrorsPresented(
  _ frames: [CGWindowID: CGRect],
  ownerPID: pid_t,
  windows: [WindowServerWindow],
) -> Bool {
  frames.allSatisfy { id, frame in
    windows.contains { window in
      window.id == id && window.surface.ownerPID == ownerPID
        && window.surface.layer > 0 && window.alpha >= 0.999
        && abs(window.surface.frame.minX - frame.minX) <= 1
        && abs(window.surface.frame.minY - frame.minY) <= 1
        && abs(window.surface.frame.width - frame.width) <= 1
        && abs(window.surface.frame.height - frame.height) <= 1
    }
  }
}

func isFloatingMirrorSourceExposed(
  _ key: WindowKey,
  frame: CGRect,
  ignoringPIDs: Set<pid_t>,
  windows: [WindowServerWindow],
  sourceWindowIDs: Set<CGWindowID>? = nil,
  mirrorWindowIDs: Set<CGWindowID> = [],
) -> Bool {
  guard
    let index = windows.firstIndex(where: { $0.id == key.windowID && $0.surface.ownerPID == key.pid }),
    windows[index].surface.layer == 0,
    windows[index].alpha > 0
  else { return false }
  let liveFrame = windows[index].surface.frame
  guard
    abs(liveFrame.minX - frame.minX) <= 1,
    abs(liveFrame.minY - frame.minY) <= 1,
    abs(liveFrame.width - frame.width) <= 1,
    abs(liveFrame.height - frame.height) <= 1
  else { return false }
  return !windows[..<index].contains { candidate in
    guard
      candidate.surface.layer == 0, candidate.alpha > 0,
      !ignoringPIDs.contains(candidate.surface.ownerPID),
      !mirrorWindowIDs.contains(candidate.id),
      candidate.surface.frame.intersects(frame)
    else { return false }
    // Titlebar/tool surfaces belong to the same native window interaction.
    // Only another native work window of this app can occlude its source.
    if candidate.surface.ownerPID == key.pid, let sourceWindowIDs {
      return sourceWindowIDs.contains(candidate.id)
    }
    return true
  }
}

func isFloatingMirrorOccludingSubrole(_ subrole: String?) -> Bool {
  subrole != kAXDialogSubrole
}

// MARK: - FloatingOverlayAXCancellationFlag

private final class FloatingOverlayAXCancellationFlag: @unchecked Sendable {

  // MARK: Internal

  var isCancelled: Bool {
    lock.withLock { cancelled }
  }

  func cancel() {
    lock.withLock { cancelled = true }
  }

  // MARK: Private

  private let lock = NSLock()
  private var cancelled = false

}

// MARK: - FloatingOverlayVisibilityWorker

/// Serializes the repeated WindowServer z-order probes used by suppression.
/// Pre-focus preparation and repeated verification both keep WindowServer IPC
/// off the main actor; presentation is committed only after fresh evidence.
private final class FloatingOverlayVisibilityWorker: @unchecked Sendable {

  // MARK: Internal

  static func isVisuallyOnTop(_ input: FloatingOverlayVisibilityInput) -> Bool {
    isFloatingMirrorSourceExposed(
      input.key,
      frame: input.frame,
      ignoringPIDs: input.floatingPIDs,
      windows: readWindowServerWindows([.optionOnScreenOnly, .excludeDesktopElements]),
      sourceWindowIDs: input.sourceWindowIDs,
      mirrorWindowIDs: input.mirrorWindowIDs,
    )
  }

  func isVisuallyOnTop(_ input: FloatingOverlayVisibilityInput) async -> Bool {
    let cancellation = FloatingOverlayAXCancellationFlag()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        queue.async {
          continuation.resume(
            returning: cancellation.isCancelled
              ? false
              : Self.isVisuallyOnTop(input)
          )
        }
      }
    } onCancel: {
      cancellation.cancel()
    }
  }

  func isNativeInputReady(_ input: FloatingOverlayVisibilityInput, mirrorID: CGWindowID) async -> Bool {
    await withCheckedContinuation { continuation in
      queue.async {
        let windows = readWindowServerWindows([.optionOnScreenOnly, .excludeDesktopElements])
        let mirrorGone = !windows.contains { $0.id == mirrorID && $0.alpha > 0 }
        continuation.resume(returning: mirrorGone && isFloatingMirrorSourceExposed(
          input.key,
          frame: input.frame,
          ignoringPIDs: input.floatingPIDs,
          windows: windows,
          sourceWindowIDs: input.sourceWindowIDs,
          mirrorWindowIDs: input.mirrorWindowIDs,
        ))
      }
    }
  }

  func windowExists(_ key: WindowKey) async -> Bool {
    await withCheckedContinuation { continuation in
      queue.async {
        let entries = CGWindowListCopyWindowInfo(.optionIncludingWindow, key.windowID)
          as? [[String: Any]] ?? []
        continuation.resume(returning: entries.contains {
          ($0[kCGWindowNumber as String] as? CGWindowID) == key.windowID
            && ($0[kCGWindowOwnerPID as String] as? pid_t) == key.pid
        })
      }
    }
  }

  func windowFrame(_ key: WindowKey) async -> CGRect? {
    await withCheckedContinuation { continuation in
      queue.async {
        let frame = readWindowServerWindows([.optionOnScreenOnly, .excludeDesktopElements])
          .first { $0.id == key.windowID && $0.surface.ownerPID == key.pid }?.surface.frame
        continuation.resume(returning: frame)
      }
    }
  }

  func mirrorsArePresented(_ frames: [CGWindowID: CGRect], ownerPID: pid_t) async -> Bool {
    await withCheckedContinuation { continuation in
      queue.async {
        continuation.resume(returning: areFloatingMirrorsPresented(
          frames,
          ownerPID: ownerPID,
          windows: readWindowServerWindows([.optionOnScreenOnly, .excludeDesktopElements]),
        ))
      }
    }
  }

  // MARK: Private

  private let queue = DispatchQueue(
    label: "dev.PangMo5.Tatami.floating-overlay-visibility",
    qos: .userInitiated,
  )

}

// MARK: - FloatingOverlayAXWorker

/// Owns every floating-mirror AX element, observer, frame read/write, and
/// raise on one user-initiated run-loop thread. AppKit panels and capture
/// surfaces remain exclusively on `MainActor`.
private final class FloatingOverlayAXWorker: @unchecked Sendable {

  // MARK: Lifecycle

  init(sink: @escaping GeometrySink) {
    self.sink = sink
    let thread = Thread { [weak self] in
      self?.run()
    }
    thread.name = "dev.PangMo5.Tatami.ax-floating-overlay"
    thread.qualityOfService = .userInitiated
    self.thread = thread
    thread.start()
  }

  // MARK: Internal

  typealias GeometrySink = @MainActor @Sendable (FloatingOverlayGeometryUpdate) -> Void

  /// Replace the worker-owned target set. A lock-backed cancellation flag
  /// lets a newer MainActor generation stop an older AX pass between bounded
  /// cross-process messages even before the worker run loop reaches the newer
  /// reconcile block.
  func reconcile(
    _ keys: Set<WindowKey>,
    generation: UInt64,
  ) {
    let cancellation = FloatingOverlayAXCancellationFlag()
    let shouldEnqueue = reconcileLock.withLock { () -> Bool in
      guard generation >= latestReconcileGeneration else { return false }
      latestReconcileGeneration = generation
      latestReconcileRequest = (keys, generation)
      currentReconcile?.cancellation.cancel()
      currentReconcile = (generation, cancellation)
      return true
    }
    guard shouldEnqueue else { return }
    enqueueReconcile(
      keys,
      generation: generation,
      cancellation: cancellation,
    )
  }

  /// Align the real window before the shared native focus pipeline runs.
  func prepareForFocus(
    _ key: WindowKey,
    targetFrame: CGRect?,
  ) async -> Bool {
    let cancellation = FloatingOverlayAXCancellationFlag()
    let interruptedReconcile = reconcileLock.withLock { () -> Bool in
      guard let currentReconcile else { return false }
      currentReconcile.cancellation.cancel()
      return true
    }
    return await withTaskCancellationHandler {
      await perform {
        let shouldActivate = self.prepareForFocusOnThread(
          key,
          targetFrame: targetFrame,
          isValid: {
            !cancellation.isCancelled
              && self.isLatestRequestedTarget(key)
          },
        )
        if interruptedReconcile {
          self.restartLatestReconcileIfNeeded()
        }
        return shouldActivate
      }
    } onCancel: {
      cancellation.cancel()
    }
  }

  func workWindowIDs(pid: pid_t) async -> Set<CGWindowID>? {
    await perform {
      let app = AXUIElementCreateApplication(pid)
      AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
      var raw: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
        let windows = raw as? [AXUIElement]
      else { return nil }
      return Set(windows.compactMap { window in
        var subrole: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
        // Notes exposes its capture control as a non-document AXDialog.
        // Native dialogs must remain part of the source interaction, never
        // a reason to paint the parent mirror above them indefinitely.
        if !isFloatingMirrorOccludingSubrole(status == .success ? subrole as? String : nil) { return nil }
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(window, &id) == .success && id != 0 ? id : nil
      })
    }
  }

  // MARK: Fileprivate

  fileprivate func handleGeometryChange(_ element: AXUIElement) {
    var windowID: CGWindowID = 0
    guard
      _AXUIElementGetWindow(element, &windowID) == .success,
      let key = keyByWindowID[windowID],
      targetKeys.contains(key)
    else { return }
    AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
    if let frame = AXWindowGeometry.frame(of: element) {
      pendingGeometryFrames[key] = frame
      pendingGeometryFailures.remove(key)
    } else {
      pendingGeometryFrames[key] = nil
      pendingGeometryFailures.insert(key)
    }
    scheduleGeometryDeliveryIfNeeded()
  }

  // MARK: Private

  private static let messagingTimeout: Float = 0.25

  private let sink: GeometrySink
  private var thread: Thread?
  private let schedulingLock = NSLock()
  private nonisolated(unsafe) var runLoop: CFRunLoop!
  private var pendingOperations = [@Sendable () -> Void]()

  /// State below is confined to `runLoop`.
  private var targetGeneration: UInt64 = 0
  private var targetKeys = Set<WindowKey>()
  private var elements = [WindowKey: AXUIElement]()
  private var keyByWindowID = [CGWindowID: WindowKey]()
  private var observers = [pid_t: AXObserver]()
  private var subscribed = Set<WindowKey>()
  private var pendingGeometryFrames = [WindowKey: CGRect]()
  private var pendingGeometryFailures = Set<WindowKey>()
  private var isGeometryDeliveryInFlight = false

  /// Admission state is accessed from the MainActor caller and worker thread.
  private let reconcileLock = NSLock()
  private var latestReconcileGeneration: UInt64 = 0
  private var latestReconcileRequest: (
    keys: Set<WindowKey>,
    generation: UInt64,
  )?
  private var currentReconcile: (
    generation: UInt64,
    cancellation: FloatingOverlayAXCancellationFlag,
  )?

  private func run() {
    let workerRunLoop = CFRunLoopGetCurrent()
    RunLoop.current.add(NSMachPort(), forMode: .common)
    // Starting this worker must never park MainActor waiting for a new
    // thread to be scheduled under system load. Queue early work locally,
    // then publish the run loop and drain it in original admission order.
    schedulingLock.withLock {
      for operation in pendingOperations {
        CFRunLoopPerformBlock(
          workerRunLoop,
          CFRunLoopMode.commonModes.rawValue,
          operation,
        )
      }
      pendingOperations.removeAll(keepingCapacity: true)
      runLoop = workerRunLoop
    }
    CFRunLoopWakeUp(workerRunLoop)
    while true {
      autoreleasepool {
        _ = CFRunLoopRunInMode(.defaultMode, 60, true)
      }
    }
  }

  private func perform<T: Sendable>(
    _ operation: @escaping @Sendable () -> T
  ) async -> T {
    await withCheckedContinuation { continuation in
      enqueue {
        continuation.resume(returning: operation())
      }
    }
  }

  private func enqueue(_ operation: @escaping @Sendable () -> Void) {
    let workerRunLoop = schedulingLock.withLock { () -> CFRunLoop? in
      guard let runLoop else {
        pendingOperations.append(operation)
        return nil
      }
      // Schedule while holding the admission lock so an operation queued
      // during startup cannot overtake the buffered operations above.
      CFRunLoopPerformBlock(
        runLoop,
        CFRunLoopMode.commonModes.rawValue,
        operation,
      )
      return runLoop
    }
    if let workerRunLoop {
      CFRunLoopWakeUp(workerRunLoop)
    }
  }

  private func enqueueReconcile(
    _ keys: Set<WindowKey>,
    generation: UInt64,
    cancellation: FloatingOverlayAXCancellationFlag,
  ) {
    enqueue { [self] in
      let update = reconcileOnThread(
        keys,
        generation: generation,
        isCancelled: { cancellation.isCancelled },
      )
      let isLatest = reconcileLock.withLock { () -> Bool in
        let latest = latestReconcileGeneration == generation
        if currentReconcile?.cancellation === cancellation {
          currentReconcile = nil
        }
        return latest
      }
      guard
        let update,
        isLatest,
        !cancellation.isCancelled
      else { return }
      deliver(update)
    }
  }

  /// Interactive raise work may interrupt a multi-window reconcile so it
  /// waits behind at most the currently-blocking 250 ms AX message. Resume
  /// the newest target snapshot as trailing work after the raise returns.
  private func restartLatestReconcileIfNeeded() {
    let request = reconcileLock.withLock {
      () -> (
        keys: Set<WindowKey>,
        generation: UInt64,
        cancellation: FloatingOverlayAXCancellationFlag
      )? in
      if
        let currentReconcile,
        !currentReconcile.cancellation.isCancelled
      {
        return nil
      }
      guard let latestReconcileRequest else { return nil }
      let cancellation = FloatingOverlayAXCancellationFlag()
      currentReconcile = (latestReconcileRequest.generation, cancellation)
      return (
        latestReconcileRequest.keys,
        latestReconcileRequest.generation,
        cancellation,
      )
    }
    guard let request else { return }
    enqueueReconcile(
      request.keys,
      generation: request.generation,
      cancellation: request.cancellation,
    )
  }

  private func isLatestRequestedTarget(_ key: WindowKey) -> Bool {
    reconcileLock.withLock {
      latestReconcileRequest?.keys.contains(key) == true
    }
  }

  private func reconcileOnThread(
    _ keys: Set<WindowKey>,
    generation: UInt64,
    isCancelled: @Sendable () -> Bool,
  ) -> FloatingOverlayGeometryUpdate? {
    guard generation >= targetGeneration, !isCancelled() else { return nil }
    targetGeneration = generation
    targetKeys = keys
    pendingGeometryFrames.removeAll(keepingCapacity: true)
    pendingGeometryFailures.removeAll(keepingCapacity: true)
    removeStaleElements(isCancelled: isCancelled)
    guard !isCancelled() else { return nil }
    resolveMissingElements(keys, isCancelled: isCancelled)
    ensureSubscriptions(isCancelled: isCancelled)
    let frames = snapshotFrames(keys, isCancelled: isCancelled)
    guard !isCancelled() else { return nil }
    return FloatingOverlayGeometryUpdate(
      generation: generation,
      frames: frames,
      invalidated: keys.subtracting(frames.keys),
      replacesSnapshot: true,
    )
  }

  private func resolveMissingElements(
    _ keys: Set<WindowKey>,
    isCancelled: @Sendable () -> Bool,
  ) {
    let missing = keys.filter { elements[$0] == nil }
    for (pid, groupedKeys) in Dictionary(grouping: missing, by: \.pid) {
      guard !isCancelled() else { return }
      let app = AXUIElementCreateApplication(pid)
      AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
      var raw: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(
          app,
          kAXWindowsAttribute as CFString,
          &raw,
        ) == .success,
        let windows = raw as? [AXUIElement]
      else { continue }
      var requested = [CGWindowID: WindowKey]()
      for key in groupedKeys {
        requested[key.windowID] = key
      }
      for window in windows {
        guard !isCancelled() else { return }
        AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)
        var windowID: CGWindowID = 0
        guard
          _AXUIElementGetWindow(window, &windowID) == .success,
          let key = requested[windowID]
        else { continue }
        elements[key] = window
        keyByWindowID[windowID] = key
      }
    }
  }

  private func ensureSubscriptions(
    isCancelled: @Sendable () -> Bool
  ) {
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    let movedName = kAXWindowMovedNotification as CFString
    let resizedName = kAXWindowResizedNotification as CFString
    let accepted: (AXError) -> Bool = {
      $0 == .success || $0 == .notificationAlreadyRegistered
    }
    for (key, element) in elements where targetKeys.contains(key) && !subscribed.contains(key) {
      guard !isCancelled() else { return }
      guard let observer = observer(for: key.pid) else { continue }
      let moved = AXObserverAddNotification(
        observer,
        element,
        movedName,
        refcon,
      )
      guard accepted(moved) else { continue }
      guard !isCancelled() else {
        AXObserverRemoveNotification(observer, element, movedName)
        return
      }
      let resized = AXObserverAddNotification(
        observer,
        element,
        resizedName,
        refcon,
      )
      guard accepted(resized), !isCancelled() else {
        AXObserverRemoveNotification(observer, element, movedName)
        if accepted(resized) {
          AXObserverRemoveNotification(observer, element, resizedName)
        }
        if isCancelled() { return }
        continue
      }
      subscribed.insert(key)
    }
  }

  private func observer(for pid: pid_t) -> AXObserver? {
    if let observer = observers[pid] { return observer }
    var observer: AXObserver?
    guard
      AXObserverCreate(pid, floatingOverlayAXWorkerCallback, &observer) == .success,
      let observer
    else { return nil }
    CFRunLoopAddSource(
      runLoop,
      AXObserverGetRunLoopSource(observer),
      .commonModes,
    )
    observers[pid] = observer
    return observer
  }

  private func snapshotFrames(
    _ keys: Set<WindowKey>,
    isCancelled: @Sendable () -> Bool,
  ) -> [WindowKey: CGRect] {
    var frames = [WindowKey: CGRect]()
    for key in keys {
      guard !isCancelled() else { break }
      guard let element = elements[key] else { continue }
      AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
      if let frame = AXWindowGeometry.frame(of: element) {
        frames[key] = frame
      }
    }
    return frames
  }

  private func removeStaleElements(
    isCancelled: @Sendable () -> Bool
  ) {
    for key in Array(elements.keys) where !targetKeys.contains(key) {
      guard !isCancelled() else { return }
      if
        subscribed.remove(key) != nil,
        let element = elements[key],
        let observer = observers[key.pid]
      {
        AXObserverRemoveNotification(
          observer,
          element,
          kAXWindowMovedNotification as CFString,
        )
        AXObserverRemoveNotification(
          observer,
          element,
          kAXWindowResizedNotification as CFString,
        )
      }
      elements[key] = nil
      keyByWindowID[key.windowID] = nil
      pendingGeometryFrames[key] = nil
      pendingGeometryFailures.remove(key)
    }
    let activePIDs = Set(targetKeys.map(\.pid))
    for pid in Array(observers.keys) where !activePIDs.contains(pid) {
      guard !isCancelled() else { return }
      guard let observer = observers.removeValue(forKey: pid) else { continue }
      CFRunLoopRemoveSource(
        runLoop,
        AXObserverGetRunLoopSource(observer),
        .commonModes,
      )
    }
  }

  private func prepareForFocusOnThread(
    _ key: WindowKey,
    targetFrame: CGRect?,
    isValid: @Sendable () -> Bool,
  ) -> Bool {
    guard isValid() else { return false }
    if elements[key] == nil {
      resolveMissingElements([key], isCancelled: { !isValid() })
    }
    guard isValid() else { return false }
    guard let element = elements[key] else { return false }
    AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
    if let targetFrame {
      let current = AXWindowGeometry.frame(of: element)
      guard isValid() else { return false }
      let drifted = current.map {
        abs($0.minX - targetFrame.minX) > 1
          || abs($0.minY - targetFrame.minY) > 1
          || abs($0.width - targetFrame.width) > 1
          || abs($0.height - targetFrame.height) > 1
      } ?? true
      if drifted {
        guard isValid() else { return false }
        // Position + size are one logical mutation. Once the first write
        // begins, finish the pair so cancellation cannot leave a half-frame.
        AXWindowGeometry.setFrame(element, to: targetFrame)
      }
    }
    guard isValid() else { return false }
    return isValid()
  }

  private func scheduleGeometryDeliveryIfNeeded() {
    guard
      !isGeometryDeliveryInFlight,
      !pendingGeometryFrames.isEmpty || !pendingGeometryFailures.isEmpty
    else { return }
    let frames = pendingGeometryFrames
    let failures = pendingGeometryFailures
    let generation = targetGeneration
    pendingGeometryFrames.removeAll(keepingCapacity: true)
    pendingGeometryFailures.removeAll(keepingCapacity: true)
    isGeometryDeliveryInFlight = true
    let sink = sink
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        sink(
          FloatingOverlayGeometryUpdate(
            generation: generation,
            frames: frames,
            invalidated: failures,
            replacesSnapshot: false,
          )
        )
      }
      self?.enqueue { [weak self] in
        guard let self else { return }
        isGeometryDeliveryInFlight = false
        scheduleGeometryDeliveryIfNeeded()
      }
    }
  }

  private func deliver(_ update: FloatingOverlayGeometryUpdate) {
    let sink = sink
    // Both full snapshots and observer deltas originate on this one worker
    // thread. The main queue preserves their submission order, unlike
    // independent unstructured MainActor tasks.
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        sink(update)
      }
    }
  }

}

private func floatingOverlayAXWorkerCallback(
  observer _: AXObserver,
  element: AXUIElement,
  notification _: CFString,
  refcon: UnsafeMutableRawPointer?,
) {
  guard let refcon else { return }
  let worker = Unmanaged<FloatingOverlayAXWorker>.fromOpaque(refcon).takeUnretainedValue()
  worker.handleGeometryChange(element)
}

// MARK: - FloatingOverlayController

@MainActor
final class FloatingOverlayController {

  // MARK: Lifecycle

  init(debugLog: DebugLogClient) {
    self.debugLog = debugLog
    @Dependency(\.sls) var sls
    clickTap = MirrorClickTap(
      hitTestWindow: sls.windowAtPoint,
      prepareNativeWindow: { [weak self] id, target in
        await self?.prepareNativeInput(id: id, target: target) ?? false
      },
      finishNativeInput: { [weak self] id in
        Task { @MainActor [weak self] in await self?.finishNativeInput(id: id) }
      },
      onAccessRevoked: { [weak self] in
        // A mirror cannot retain presentation after its input route disappears.
        // This also cancels capture discovery and pending native preparations.
        Task { @MainActor [weak self] in self?.setFloating([]) }
      },
      onFailure: { [weak self] reason in
        Task { @MainActor [weak self] in self?.reportNativeInputFailure(reason) }
      },
      onOutsideClick: { [weak self] in
        Task { @MainActor [weak self] in await self?.handleOutsideClick() }
      },
    )
    permissionObservers.tokens = [NotificationCenter.default.addObserver(
      forName: ScreenRecordingAccess.didCloseNotification,
      object: nil,
      queue: nil,
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let hadMirrors = !desired.isEmpty
        setFloating([])
        if hadMirrors {
          @Dependency(\.errorReporter) var reporter
          reporter.report(
            "Floating",
            String(localized: "Always-on-top mirrors are unavailable — check Screen Recording"),
            "Screen Recording access was lost. Relaunch Tatami after granting access.",
          )
        }
      }
    }]
  }

  // MARK: Internal

  func setFloating(_ windows: Set<WindowKey>) {
    // Reducer updates can arrive after revocation cleanup. Keep the closed
    // session empty instead of repeatedly starting and stopping capture streams.
    let windows = EventTapAccess.shared.isClosed || ScreenRecordingAccess.shared.isClosed ? [] : windows
    let changed = desired != windows
    if !changed {
      if
        addTask != nil
        || (
          appliedGeometryGeneration == geometryGeneration
            && windows.allSatisfy {
              panels[$0] != nil && lastFrame[$0] != nil
            }
        )
      {
        return
      }
    } else {
      desired = windows
      // A replacement set supersedes expensive ScreenCaptureKit discovery
      // even when it is empty or every new window already has a panel.
      addGeneration += 1
      addTask?.cancel()
      addTask = nil
    }
    for key in Array(panels.keys) where !windows.contains(key) {
      removeWindow(key, reconcileAX: false)
    }
    let toAdd = windows.filter { panels[$0] == nil }
    if !toAdd.isEmpty {
      if !changed { addGeneration += 1 }
      let generation = addGeneration
      addTask = Task { @MainActor [weak self] in
        guard let self else { return }
        // A cancelled generation may have acquired input before discovery.
        // Keep it only when current panels or a newer add still own it.
        defer { disableInputIfIdle() }
        await addMirrors(for: toAdd)
        guard addGeneration == generation else { return }
        addTask = nil
      }
    }
    requestGeometryReconcile()
    // Retained panels may have been created by the task we just cancelled.
    // Keep their global lifecycle hooks valid; a fresh add task owns hooks for
    // panels that do not exist yet.
    if !panels.isEmpty {
      ensureActivationObserver()
      ensureCursorMonitor()
    }
  }

  /// Includes same-app FFM handovers, which do not emit didActivateApplication.
  func handleDidFocus(_ target: MirrorWindowRegistry.Target) {
    guard
      isFrontmostApplication(pid: target.pid),
      let key = panels.keys.first(where: { $0.pid == target.pid && $0.windowID == target.windowID })
    else { return }
    suppressMirror(key)
  }

  /// Drop every mirror whose app isn't floating in the incoming workspace.
  func retainOnly(_ bundleIds: Set<String>) {
    let retained = desired.filter { bundleIds.contains($0.bundleId) }
    if retained != desired {
      desired = retained
      addGeneration += 1
      addTask?.cancel()
      addTask = nil
    }
    let removedKeys = panels.keys.filter { !bundleIds.contains($0.bundleId) }
    for key in removedKeys {
      removeWindow(key, reconcileAX: false)
    }
    if !removedKeys.isEmpty {
      requestGeometryReconcile()
    }
  }

  /// Tatami is about to move focus to `pid`'s window (`focusWindow` hook).
  /// Restore the mirrors that need to be up *now*, before the activation,
  /// so they're already painted when the floating window drops behind the
  /// new focus — the didActivate notification alone arrives one beat too
  /// late. Returns only after WindowServer confirms any restored mirrors.
  func handleWillFocus(_ pid: pid_t) async -> Bool? {
    noteFocus(pid)
    let generation = focusPresentationGeneration
    let targetIsFloating = panels.keys.contains { $0.pid == pid }
    var needsCommit = false
    var restoredFrames = [CGWindowID: CGRect]()
    for key in Array(panels.keys) where key.pid != pid {
      // Same dead-window rule as didActivate.
      let exists = await visibilityWorker.windowExists(key)
      guard !Task.isCancelled, generation == focusPresentationGeneration else { return nil }
      guard panels[key] != nil else { continue }
      guard exists else {
        removeWindow(key)
        continue
      }
      // Same occlusion rule as didActivate: when focus moves to a float,
      // an unoccluded sibling float keeps showing its real window — no
      // mirror needed.
      let isOnTop = targetIsFloating ? await isVisuallyOnTop(key) : false
      guard !Task.isCancelled, generation == focusPresentationGeneration else { return nil }
      if isOnTop {
        suppressMirror(key)
        continue
      }
      // Include a cursor-exit restore that is still waiting for its frame.
      // Checking `suppressed` here is NOT equivalent: the cursor-exit
      // restore un-suppresses first and then waits for a fresh frame with
      // the panel still transparent — exactly the window in which the
      // focus change races us.
      if let panel = panels[key], panel.alphaValue < 1 { needsCommit = true }
      restoreMirror(key)
      showPanel(key)
      if let panel = panels[key], panel.alphaValue == 1 {
        restoredFrames[CGWindowID(panel.windowNumber)] = AXWindowGeometry.flipToCG(panel.frame)
      }
    }
    applyStackOrder(liftDemoted: !targetIsFloating)
    if needsCommit, !restoredFrames.isEmpty {
      for _ in 0..<Timing.verifyMaxSteps {
        guard !Task.isCancelled, generation == focusPresentationGeneration else { return nil }
        let presented = await visibilityWorker.mirrorsArePresented(restoredFrames, ownerPID: getpid())
        guard !Task.isCancelled, generation == focusPresentationGeneration else { return nil }
        if presented { return true }
        do { try await Task.sleep(for: Timing.verifyStep) }
        catch { return nil }
      }
      debugLog.log("Mirror", "focus preparation rejected: restored mirror presentation not confirmed")
      return nil
    }
    return needsCommit
  }

  // MARK: Private

  /// The only time-based values in the overlay — everything else is
  /// event- or verification-driven.
  private enum Timing {
    /// Sample raise completion at display-frame cadence because the window
    /// server does not publish a composited-z-order notification.
    static let verifyStep = Duration.milliseconds(16)
    /// Give up verifying after ~640 ms and keep the mirror up (truthful
    /// fallback) instead of exposing whatever sits behind it.
    static let verifyMaxSteps = 40
    /// Failure-only retry cadence for a moved/resized frame that timed out.
    /// Successful geometry never waits on this path.
    static let geometryRetryStep = Duration.milliseconds(250)
    static let geometryRetryMaxSteps = 4
    /// Capture startup failures use the same bounded, failure-only cadence.
    static let captureRetryStep = Duration.milliseconds(250)
    static let captureRetryMaxSteps = 4
  }

  private var panels = [WindowKey: NSPanel]()
  private var captures = [WindowKey: WindowMirrorCapture]()
  /// The set the reducer currently wants mirrored, updated synchronously
  /// by `setFloating` / `retainOnly` so `addMirrors` can re-validate each
  /// key after its `SCShareableContent` await gap. Without this, a key
  /// un-floated mid-await had no panel yet (removal no-oped) and came back
  /// as a ghost mirror with a live stream.
  private var desired = Set<WindowKey>()
  /// `SCShareableContent.current` is comparatively expensive. Rapid workspace
  /// switches replace one missing-mirror request with the newest desired set
  /// instead of letting several captures enumerate shareable content in parallel.
  private var addTask: Task<Void, Never>?
  private var addGeneration = 0
  /// Cross-process Accessibility ownership lives entirely on this worker.
  /// Its sink carries immutable CGRect snapshots back to the UI actor.
  private lazy var axWorker = FloatingOverlayAXWorker { [weak self] update in
    self?.applyGeometryUpdate(update)
  }

  private let visibilityWorker = FloatingOverlayVisibilityWorker()

  private var geometryGeneration: UInt64 = 0
  private var appliedGeometryGeneration: UInt64?
  private var lastFrame = [WindowKey: NSRect]()
  /// A moved/resized notification arrived but the final AX frame read failed.
  /// Keep that panel out of the event path until a fresh snapshot succeeds.
  private var geometryUnavailable = Set<WindowKey>()
  private var geometryRetryTasks = [WindowKey: Task<Void, Never>]()
  /// A capture restart failed or was aborted while this mirror still needed
  /// to be visible. Keep it out of both z-order and event routing until an
  /// exact-stream fresh-frame callback succeeds.
  private var captureUnavailable = Set<WindowKey>()
  private var captureRetryTasks = [WindowKey: Task<Void, Never>]()
  private var captureResumeTokens = [WindowKey: UUID]()
  private var captureRetryAttempts = [WindowKey: Int]()
  /// Reject stale visibility work after a newer focus transition.
  private var focusPresentationGeneration: UInt64 = 0
  /// Mirrors currently hidden (click-through, stream stopped): the
  /// focused floating app's own windows, plus — while a float holds
  /// focus — sibling floats whose real window isn't covered by any tile,
  /// which therefore show themselves and need no mirror.
  private var suppressed = Set<WindowKey>()
  /// Owns the full first input sequence, even if the physical mouse-up arrives
  /// before asynchronous focus or replay finishes.
  private var nativeInputLeases = [WindowKey: UUID]()
  private var nativeWindowIDsByPID = [pid_t: Set<CGWindowID>]()
  private var localCursorMonitor: Any?
  /// Native windows awaiting a fresh capture after cursor exit.
  private var pendingCursorRestores = Set<WindowKey>()
  private var interactionOrder = [WindowKey]()
  /// Sibling mirrors dropped to `.normal` level just below the focused
  /// float's real window (tile-occluded siblings that must keep their
  /// mirror while a float holds focus). Demotion happens only *after*
  /// the focused window's raise is verified — ordering a panel against
  /// an unverified raise was the source of the old demotion blinks.
  private var demoted = Set<WindowKey>()
  /// The real focused window each demoted sibling is ordered beneath.
  /// Geometry recovery uses the same anchor instead of accidentally lifting
  /// the recovered sibling into the floating band.
  private var demotionAnchors = [WindowKey: WindowKey]()
  /// In-flight native handover verification per window.
  private var hideTasks = [WindowKey: Task<Void, Never>]()
  /// `NSWorkspace.didActivateApplicationNotification` subscription — the
  /// single signal that flips mirrors between shown and suppressed.
  private var appActivationObserver: NSObjectProtocol?
  /// Global pointer monitor, installed while floating panels exist, including
  /// the gap between cursor exit and the first resumed capture frame.
  /// The cursor leaving the floating window is the race-free
  /// restore moment (Topit's timing): the window is still frontmost, so
  /// the mirror comes back over identical pixels, long before any focus
  /// change can drop the window behind something else.
  private var cursorMonitor: Any?
  /// Cursor-inside state per suppressed window — the restore acts on the
  /// inside→outside *edge*, not the level.
  private var cursorInside = [WindowKey: Bool]()
  /// Native input tap (created in `init`, enabled while panels exist).
  /// A click outside every suppressed floating window restores the
  /// mirrors *before* the clicked app raises. Covers the focus changes
  /// Tatami doesn't drive — the `focusWindow` hook can't see direct clicks,
  /// and the didActivate notification arrives after the z-order already
  /// changed (the intermittent "floating dips behind, then pops back up").
  private var clickTap: MirrorClickTap?
  private let permissionObservers = PermissionObserverTokens(local: .default)
  private let debugLog: DebugLogClient

  /// Floating pids by focus recency, most recent first. Mirrors stack in
  /// this order: the focused floating app on top, then the last-focused
  /// floating app, and so on.
  private var floatingMRU = [pid_t]()

  /// pid of the floating app that currently holds focus, if any. Gates
  /// the cursor-exit restore: only the focused float's mirror returns
  /// when the cursor leaves it — a hidden unoccluded sibling must not
  /// pop its mirror back just because the cursor brushed across it.
  private var focusedFloatPid: pid_t?

  private var maxFPS: Int {
    NSScreen.main?.maximumFramesPerSecond ?? 60
  }

  private func addMirrors(for keys: Set<WindowKey>) async {
    guard await ScreenRecordingAccess.shared.prepare(), !Task.isCancelled else { return }
    // Acquire the input lifetime before starting capture. Revocation now owns
    // cancellation even while ScreenCaptureKit discovery/startup is suspended.
    guard await clickTap?.enable() == true, !Task.isCancelled else { return }
    let content: SCShareableContent
    @Dependency(\.errorReporter) var reporter
    do {
      content = try await SCShareableContent.current
    } catch {
      guard !Task.isCancelled else { return }
      ScreenRecordingAccess.shared.captureFailed(error)
      logger.error(
        "SCShareableContent failed (screen-recording permission?): \(error.localizedDescription, privacy: .public)"
      )
      reporter.report(
        "Floating",
        String(localized: "Always-on-top mirrors are unavailable — check Screen Recording"),
        ErrorReportClient.describe(error),
      )
      return
    }
    guard !Task.isCancelled, !ScreenRecordingAccess.shared.isClosed else { return }
    reporter.resolve("Floating")
    var byID = [CGWindowID: SCWindow]()
    for window in content.windows { byID[window.windowID] = window }

    for key in keys {
      // Re-check across the await gap: "already added" via `panels`, and
      // "no longer wanted" via `desired` (a `setFloating`/`retainOnly`
      // that ran mid-await couldn't remove a panel that didn't exist yet).
      guard !Task.isCancelled else { return }
      guard desired.contains(key), panels[key] == nil else { continue }
      guard
        let scWindow = byID[key.windowID],
        scWindow.owningApplication?.processID == key.pid
      else {
        debugLog.log(
          "Mirror",
          "no owner-matched SCWindow for \(key.bundleId)#\(key.windowID) — mirror skipped",
        )
        continue
      }
      let capture = WindowMirrorCapture()
      let panel = makePanel(for: key, capture: capture)
      guard await capture.start(window: scWindow, maxFPS: maxFPS) else {
        debugLog.log(
          "Mirror",
          "capture start failed \(key.bundleId)#\(key.windowID) — mirror skipped",
        )
        panel.orderOut(nil)
        continue
      }
      guard !Task.isCancelled, desired.contains(key) else {
        capture.stop()
        panel.orderOut(nil)
        continue
      }
      // The proxy has no separate mouse-button route. Establish both native
      // event taps before publishing it to geometry and presentation workers.
      guard await clickTap?.enable() == true else {
        capture.stop()
        panel.orderOut(nil)
        return
      }
      // Commit the panel only after capture startup succeeds and this request
      // is still current. Publishing it before the await let a replacement
      // set observe a half-created panel, cancel its owner, and then skip
      // creating a replacement because `panels[key]` was already non-nil.
      guard !Task.isCancelled, desired.contains(key), panels[key] == nil else {
        capture.stop()
        panel.orderOut(nil)
        disableInputIfIdle()
        if Task.isCancelled { return }
        continue
      }
      captures[key] = capture
      panels[key] = panel
      debugLog.log("Mirror", "created \(key.bundleId)#\(key.windowID)")
      // The mirrored app may already be frontmost (e.g. the user floated
      // the focused window) — start suppressed so the mirror doesn't cover
      // the live window they're using.
      if isFrontmostApplication(pid: key.pid) {
        suppressMirror(key)
      }
    }
    guard !Task.isCancelled else { return }
    ensureActivationObserver()
    ensureCursorMonitor()
    requestGeometryReconcile()
  }

  private func makePanel(for key: WindowKey, capture: WindowMirrorCapture) -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false,
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    // A proxy must never publish its whole image as a draggable window region.
    // Only the real window owns movement and resize gestures.
    panel.isMovable = false
    panel.isMovableByWindowBackground = false
    // Above the tiles. `.nonactivatingPanel` + this level is what makes the
    // mirror sit on top without ever becoming the key window.
    panel.level = .floating
    // While shown, the mirror receives hover / click so it can hand off to
    // the real window — unlike the click-through marker dots.
    panel.ignoresMouseEvents = false
    // `.transient` keeps the mirror out of Mission Control / the app
    // switcher, where a fake duplicate window would look wrong.
    panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
    let view = MirrorView(videoLayer: capture.videoLayer)
    // Mirror interaction uses the same verified focus handover as workspace
    // and window switching, including transfer of keyboard focus across apps.
    //
    // Background scrolling follows native macOS semantics: it does not need
    // keyboard focus. Button gestures belong exclusively to MirrorClickTap.
    view.onScroll = { [weak self] event in
      guard
        let self,
        !geometryUnavailable.contains(key),
        !captureUnavailable.contains(key),
        let cg = event.cgEvent?.copy()
      else { return }
      cg.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(key.windowID))
      cg.postToPid(key.pid)
    }
    panel.contentView = view
    return panel
  }

  /// Drop a window's mirror panel and capture stream. AX resources are owned
  /// by the worker and reconcile asynchronously from the remaining panel set.
  private func removeWindow(
    _ key: WindowKey,
    reconcileAX: Bool = true,
  ) {
    interactionOrder.removeAll { $0 == key }
    if panels.keys.count(where: { $0.pid == key.pid }) == 1 { nativeWindowIDsByPID[key.pid] = nil }
    if panels[key] != nil {
      debugLog.log("Mirror", "removed \(key.bundleId)#\(key.windowID)")
    }
    nativeInputLeases[key] = nil
    captures[key]?.stop()
    captures.removeValue(forKey: key)
    if let panel = panels[key] {
      MirrorWindowRegistry.shared.set(mirror: CGWindowID(panel.windowNumber), target: nil)
      panel.orderOut(nil)
    }
    panels.removeValue(forKey: key)
    lastFrame.removeValue(forKey: key)
    geometryUnavailable.remove(key)
    geometryRetryTasks.removeValue(forKey: key)?.cancel()
    captureUnavailable.remove(key)
    captureRetryTasks.removeValue(forKey: key)?.cancel()
    captureResumeTokens[key] = nil
    captureRetryAttempts.removeValue(forKey: key)
    hideTasks.removeValue(forKey: key)?.cancel()
    suppressed.remove(key)
    pendingCursorRestores.remove(key)
    demoted.remove(key)
    demotionAnchors.removeValue(forKey: key)
    let orphanedDemotions = demotionAnchors.compactMap { entry in
      entry.value == key ? entry.key : nil
    }
    for sibling in orphanedDemotions {
      demoted.remove(sibling)
      demotionAnchors.removeValue(forKey: sibling)
    }
    cursorInside.removeValue(forKey: key)
    syncSuppressedFrames()
    removeCursorMonitorIfIdle()
    // Don't let a stale focused-float pid (whose panels just went away,
    // e.g. on a workspace switch) gate the next workspace's mirrors.
    if let pid = focusedFloatPid, !panels.keys.contains(where: { $0.pid == pid }) {
      focusedFloatPid = nil
    }
    disableInputIfIdle()
    if panels.isEmpty { removeActivationObserver() }
    if reconcileAX { requestGeometryReconcile() }
  }

  private func disableInputIfIdle() {
    // A pending add may already have received readiness from EventTapThread
    // but not resumed on MainActor yet. Removing the last old panel must not
    // tear down the taps before that add publishes its replacement.
    guard panels.isEmpty, addTask == nil else { return }
    clickTap?.disable()
  }

  private func ensureActivationObserver() {
    guard appActivationObserver == nil, !panels.isEmpty else { return }
    appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main,
    ) { [weak self] note in
      guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
      Task { @MainActor [weak self] in
        guard
          let pid = await applicationProcessIdentifier(app),
          NSWorkspace.shared.frontmostApplication?.isEqual(app) == true
        else { return }
        await self?.handleAppActivated(pid)
      }
    }
  }

  private func removeActivationObserver() {
    if let observer = appActivationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
      appActivationObserver = nil
    }
  }

  /// The active app changed — mirrors of the now-active app hide. What
  /// happens to the *other* mirrors depends on who took focus:
  ///
  ///   * a non-floating app → it raises above everything at the normal
  ///     level, so every float needs its mirror back.
  ///   * a floating app → sibling floats whose real window isn't covered
  ///     by a tile need no mirror either: the real windows show
  ///     themselves and stack natively by activation recency. With every
  ///     mirror hidden there is no stream (recording indicator clears),
  ///     no ghost panel trailing a drag, and no hidden panel for hover
  ///     events to fall through to. Only a sibling genuinely covered by
  ///     a tile keeps its mirror.
  private func handleAppActivated(_ pid: pid_t) async {
    debugLog.log("FocusDiag", "didActivate pid=\(pid)")
    noteFocus(pid)
    let generation = focusPresentationGeneration
    let targetIsFloating = panels.keys.contains { $0.pid == pid }
    for key in Array(panels.keys) where key.pid != pid {
      // A dead window's mirror is torn down, never shown: quitting a
      // floating app fires this activation (macOS focuses the next app)
      // *before* the reducer's terminate-sync removes the panel, which
      // used to resurrect the mirror as a frozen ghost.
      let exists = await visibilityWorker.windowExists(key)
      guard !Task.isCancelled, generation == focusPresentationGeneration else { return }
      guard panels[key] != nil else { continue }
      guard exists else {
        removeWindow(key)
        continue
      }
      let isOnTop = targetIsFloating ? await isVisuallyOnTop(key) : false
      guard !Task.isCancelled, generation == focusPresentationGeneration else { return }
      if isOnTop {
        suppressMirror(key)
      } else {
        restoreMirror(key)
        // Focus has moved — force the panel opaque even if a cursor-exit
        // restore is still waiting on its first frame.
        showPanel(key)
      }
    }
    for key in Array(panels.keys) where key.pid == pid {
      suppressMirror(key)
    }
    applyStackOrder(liftDemoted: !targetIsFloating)
  }

  /// Record `pid` as the focus target: track whether a float holds focus
  /// and bump it in the floating recency order.
  private func noteFocus(_ pid: pid_t) {
    focusPresentationGeneration &+= 1
    let isFloating = panels.keys.contains { $0.pid == pid }
    focusedFloatPid = isFloating ? pid : nil
    guard isFloating else { return }
    floatingMRU.removeAll { $0 == pid }
    floatingMRU.insert(pid, at: 0)
  }

  /// Stack the floating band by focus recency — most recently focused on
  /// top. `liftDemoted` controls whether previously demoted mirrors come
  /// back up to the floating band: true when a non-floating app takes
  /// focus (every mirror must cover its window again), false while a
  /// float keeps focus (demoted siblings stay tucked under it; lifting
  /// them here only to re-demote after the next raise verification would
  /// flap them across levels).
  private func applyStackOrder(liftDemoted: Bool = true) {
    if liftDemoted {
      demoted.removeAll()
      demotionAnchors.removeAll()
    }
    let ordered = panels.keys.sorted(by: orderedBefore)
    var previousNumber: Int?
    for key in ordered {
      guard
        let panel = panels[key],
        !suppressed.contains(key),
        !geometryUnavailable.contains(key),
        !captureUnavailable.contains(key)
      else { continue }
      if demoted.contains(key) { continue }
      panel.level = .floating
      if let previousNumber {
        panel.order(.below, relativeTo: previousNumber)
      } else if !panel.isVisible {
        panel.orderFrontRegardless()
      }
      previousNumber = panel.windowNumber
    }
  }

  /// Slot every still-visible sibling mirror at `.normal` level directly
  /// below `key`'s real window, in focus-recency order: focused float >
  /// tile-occluded sibling mirrors > tiles. Called only after `key`'s
  /// raise has been verified (`order(.below relativeTo:)` accepts another
  /// app's window number). Also takes these mirrors out of the hover
  /// path: sitting below the focused window, they no longer swallow the
  /// cursor at overlaps.
  private func demoteVisibleSiblings(below key: WindowKey) {
    let siblings = panels.keys
      .filter {
        $0 != key
          && !suppressed.contains($0)
          && !geometryUnavailable.contains($0)
          && !captureUnavailable.contains($0)
      }
      .sorted(by: orderedBefore)
    var previousNumber: Int?
    for sibling in siblings {
      guard let panel = panels[sibling] else { continue }
      demoted.insert(sibling)
      demotionAnchors[sibling] = key
      panel.level = .normal
      panel.order(.below, relativeTo: previousNumber ?? Int(key.windowID))
      previousNumber = panel.windowNumber
    }
  }

  private func orderedBefore(_ lhs: WindowKey, _ rhs: WindowKey) -> Bool {
    let left = interactionOrder.firstIndex(of: lhs) ?? .max
    let right = interactionOrder.firstIndex(of: rhs) ?? .max
    if left != right { return left < right }
    let leftApp = mruIndex(lhs.pid)
    let rightApp = mruIndex(rhs.pid)
    return leftApp != rightApp ? leftApp < rightApp : lhs.windowID < rhs.windowID
  }

  private func canReveal(_ key: WindowKey, at point: CGPoint) -> Bool {
    guard
      demoted.contains(key), let anchor = demotionAnchors[key], suppressed.contains(anchor),
      let anchorFrame = lastFrame[anchor]
    else { return true }
    return !anchorFrame.contains(point)
  }

  private func mruIndex(_ pid: pid_t) -> Int {
    floatingMRU.firstIndex(of: pid) ?? .max
  }

  /// Per-window maintenance used by geometry refreshes and the cursor-exit
  /// restore; full recency stacking happens in `applyStackOrder`. Demoted
  /// mirrors are left alone — a geometry event must not lift them back
  /// over the focused float — and hidden (suppressed) panels have nothing
  /// to order.
  private func applyOrdering(_ key: WindowKey) {
    guard
      let panel = panels[key],
      !demoted.contains(key),
      !suppressed.contains(key),
      !geometryUnavailable.contains(key),
      !captureUnavailable.contains(key)
    else { return }
    panel.level = .floating
    if !panel.isVisible { panel.orderFrontRegardless() }
  }

  /// Hide `key`'s mirror: its real window is (or is about to be) showing
  /// itself — either its app took focus, or a sibling float took focus
  /// while this window sits unoccluded above the tiles. Goes
  /// click-through when the real window is
  /// *verifiably* not covered by any tile. There is no notification for
  /// "raise composited" — a blind timer raced slow apps' raises (Xcode)
  /// and let the tile underneath flash through; the bounded per-frame
  /// z-order check is the only reliable gate.
  private func suppressMirror(_ key: WindowKey) {
    guard !suppressed.contains(key), let panel = panels[key] else { return }
    debugLog.log("Mirror", "suppress \(key.bundleId)#\(key.windowID)")
    suppressed.insert(key)
    pendingCursorRestores.remove(key)
    captureResumeTokens[key] = nil
    cursorInside[key] = panel.frame.contains(NSEvent.mouseLocation)
    syncSuppressedFrames()
    ensureCursorMonitor()
    captureRetryTasks.removeValue(forKey: key)?.cancel()
    captureRetryAttempts.removeValue(forKey: key)
    hideTasks.removeValue(forKey: key)?.cancel()
    hideTasks[key] = Task { @MainActor [weak self] in
      guard let self else { return }
      let windowIDs = await axWorker.workWindowIDs(pid: key.pid)
      guard !Task.isCancelled, suppressed.contains(key) else { return }
      if let windowIDs { nativeWindowIDsByPID[key.pid] = windowIDs }
      // Wait for the raise to land (almost always 0–2 iterations). Bail
      // out — mirror stays up, truthfully — if it never does.
      var raised = false
      for _ in 0..<Timing.verifyMaxSteps {
        guard !Task.isCancelled, suppressed.contains(key) else { return }
        let input = visibilityInput(
          for: key,
          ignoringFloatingWindows: !isFrontmostApplication(pid: key.pid),
        )
        let isOnTop =
          if let input {
            await visibilityWorker.isVisuallyOnTop(input)
          } else {
            false
          }
        guard !Task.isCancelled, suppressed.contains(key) else { return }
        if isOnTop {
          raised = true
          break
        }
        try? await Task.sleep(for: Timing.verifyStep)
      }
      guard !Task.isCancelled, suppressed.contains(key) else { return }
      if !raised {
        debugLog.log(
          "Mirror",
          "suppress \(key.bundleId)#\(key.windowID): raise not verified — restore interaction",
        )
        restoreMirror(key)
        return
      }
      panel.ignoresMouseEvents = true
      // The focused window is verifiably above the tiles — now (and only
      // now) it's safe to slot still-mirrored siblings underneath it.
      if key.pid == focusedFloatPid {
        demoteVisibleSiblings(below: key)
      }
      // Relinquish the actual window before another mouse-down. A transparent
      // proxy is not an OS drag target; remove it and stop capture immediately.
      panel.alphaValue = 0
      panel.orderOut(nil)
      MirrorWindowRegistry.shared.set(mirror: CGWindowID(panel.windowNumber), target: nil)
      captures[key]?.stop()
      debugLog.log(
        "Mirror",
        "native handover \(key.bundleId)#\(key.windowID); panel hidden, capture stop requested; frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)",
      )
      // Back the layer with a still of the last frame first: a focus
      // change can force this panel visible before the stream restarts,
      // and an imageless layer would let whatever raised behind it show
      // through.
      if
        let capture = captures[key],
        let still = await capture.stillImage(),
        let view = panel.contentView as? MirrorView
      {
        guard !Task.isCancelled, suppressed.contains(key), captures[key] === capture else { return }
        view.setStill(still)
      }
    }
  }

  /// No *non-floating* window of another app overlaps `key` above it —
  /// i.e. hiding the mirror would reveal the real window, not a tile.
  /// Floating apps' own windows are deliberately excluded: while a float
  /// holds focus, the floats sort themselves through native activation
  /// z-order, so a sibling float above is never a reason to keep a mirror.
  private func isVisuallyOnTop(_ key: WindowKey) async -> Bool {
    guard let input = visibilityInput(for: key) else { return false }
    return await visibilityWorker.isVisuallyOnTop(input)
  }

  private func visibilityInput(
    for key: WindowKey,
    ignoringFloatingWindows: Bool = true,
  ) -> FloatingOverlayVisibilityInput? {
    // Missing geometry is "unknown", never verified-on-top. Keeping the
    // mirror is the truthful fallback; hiding it could expose a tile.
    guard let frame = lastFrame[key].map(AXWindowGeometry.flipToCG) else { return nil }
    return FloatingOverlayVisibilityInput(
      key: key,
      frame: frame,
      floatingPIDs: ignoringFloatingWindows ? Set(panels.keys.map(\.pid)) : [],
      sourceWindowIDs: nativeWindowIDsByPID[key.pid],
      mirrorWindowIDs: Set(panels.values.map { CGWindowID($0.windowNumber) }),
    )
  }

  /// Show `key`'s mirror again.
  ///
  /// `waitForFrame` is for the cursor-exit restore, where the real window
  /// is still frontmost: nothing is racing, so hold the panel until the
  /// resumed stream delivers a fresh frame and the swap is invisible. The
  /// focus-driven paths (hook / notification / click tap) pass `false` —
  /// there a stale frame beats a missing mirror.
  /// `onShown` (if given) runs right after the panel turns opaque — i.e.
  /// after the first fresh frame on the `waitForFrame` path — so callers
  /// can sequence z-order work against the moment the mirror is visible.
  private func restoreMirror(
    _ key: WindowKey,
    waitForFrame: Bool = false,
    onShown: (() -> Void)? = nil,
  ) {
    guard suppressed.contains(key), nativeInputLeases[key] == nil else { return }
    // A pending verification still has a visible proxy and owns no native
    // gesture. Only protect a drag after the real window was actually exposed.
    guard NSEvent.pressedMouseButtons == 0 || cursorInside[key] != true || panels[key]?.isVisible == true else { return }
    // Callers have verified existence off-main and revalidated their focus
    // generation before reaching this synchronous presentation commit.
    debugLog.log(
      "Mirror",
      "restore \(key.bundleId)#\(key.windowID) waitForFrame=\(waitForFrame)",
    )
    suppressed.remove(key)
    pendingCursorRestores.remove(key)
    cursorInside.removeValue(forKey: key)
    syncSuppressedFrames()
    hideTasks.removeValue(forKey: key)?.cancel()
    removeCursorMonitorIfIdle()
    guard let panel = panels[key] else {
      onShown?()
      return
    }
    guard !geometryUnavailable.contains(key), lastFrame[key] != nil else {
      panel.ignoresMouseEvents = true
      scheduleGeometryRecovery(for: key)
      return
    }
    guard !captureUnavailable.contains(key) else {
      panel.ignoresMouseEvents = true
      scheduleCaptureRecovery(for: key)
      return
    }
    panel.ignoresMouseEvents = false
    let capture = captures[key]
    if waitForFrame, let capture, !capture.isRunning {
      pendingCursorRestores.insert(key)
      resumeCapture(key, capture: capture) { [weak self] in
        guard let self else { return }
        if reclaimPendingNativeWindow(key, at: NSEvent.mouseLocation) { return }
        pendingCursorRestores.remove(key)
        showPanel(key)
        onShown?()
      }
    } else {
      showPanel(key)
      if let capture, !capture.isRunning {
        resumeCapture(key, capture: capture)
      }
      onShown?()
    }
  }

  /// Make `key`'s panel opaque now. Direct model write — no animator — so
  /// it lands within the same frame as the pre-focus hook; the
  /// zero-duration animator pass stomps a possibly in-flight fade-out so it
  /// can't finish later and strand the mirror invisible. No-op while the
  /// key is (re-)suppressed.
  private func showPanel(_ key: WindowKey) {
    guard
      !ScreenRecordingAccess.shared.isClosed,
      nativeInputLeases[key] == nil,
      !suppressed.contains(key),
      !geometryUnavailable.contains(key),
      !captureUnavailable.contains(key),
      lastFrame[key] != nil,
      let panel = panels[key]
    else { return }
    panel.alphaValue = 1
    panel.ignoresMouseEvents = false
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0
      panel.animator().alphaValue = 1
    }
    publishMirrorPanel(for: key)
  }

  private func ensureCursorMonitor() {
    guard cursorMonitor == nil, !panels.isEmpty else { return }
    let mask: NSEvent.EventTypeMask = [
      .mouseMoved,
      .leftMouseDown,
      .rightMouseDown,
      .otherMouseDown,
      .leftMouseDragged,
      .rightMouseDragged,
      .otherMouseDragged,
      .leftMouseUp,
      .rightMouseUp,
      .otherMouseUp,
    ]
    cursorMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
      Task { @MainActor [weak self] in await self?.handleCursorMoved(NSEvent.mouseLocation) }
    }
    localCursorMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      Task { @MainActor [weak self] in await self?.handleCursorMoved(NSEvent.mouseLocation) }
      return event
    }
  }

  private func removeCursorMonitorIfIdle() {
    guard panels.isEmpty else { return }
    if let cursorMonitor { NSEvent.removeMonitor(cursorMonitor) }
    if let localCursorMonitor { NSEvent.removeMonitor(localCursorMonitor) }
    cursorMonitor = nil
    localCursorMonitor = nil
  }

  private func reclaimPendingNativeWindow(_ key: WindowKey, at cursor: NSPoint) -> Bool {
    guard
      pendingCursorRestores.contains(key), isFrontmostApplication(pid: key.pid),
      let panel = panels[key], panel.frame.contains(cursor),
      canReveal(key, at: cursor)
    else { return false }
    // Revoke the presentation token synchronously, before another frame can
    // cover the native window or intercept an in-progress mouse gesture.
    suppressMirror(key)
    return true
  }

  /// The cursor left a suppressed (focused) floating window. Its real
  /// window is still frontmost at this instant, so restoring the mirror
  /// now is invisible — and by the time the focus actually moves (FFM, a
  /// click, a hotkey) the mirror is already up. This is what removes the
  /// "floating dips behind for a moment" race: focus-time restores can
  /// never beat the z-order change; cursor-exit restores don't have to.
  private func handleCursorMoved(_ cursor: NSPoint) async {
    guard nativeInputLeases.isEmpty else { return }
    for key in Array(pendingCursorRestores) {
      _ = reclaimPendingNativeWindow(key, at: cursor)
    }
    guard NSEvent.pressedMouseButtons == 0 else { return }
    let generation = focusPresentationGeneration
    for key in Array(suppressed) {
      // Only the *focused* float swaps back to its mirror when the cursor
      // leaves it. A hidden unoccluded sibling stays hidden — its real
      // window shows itself, and brushing the cursor across it must not
      // pop a mirror.
      guard
        key.pid == focusedFloatPid,
        !geometryUnavailable.contains(key),
        !captureUnavailable.contains(key),
        let panel = panels[key]
      else { continue }
      let inside = panel.frame.contains(cursor)
      let wasInside = cursorInside[key] ?? true
      cursorInside[key] = inside
      if wasInside, !inside {
        debugLog.log("FocusDiag", "cursor-exit restore \(key.bundleId)#\(key.windowID)")
        // Lift demoted siblings back to the floating band on cursor exit —
        // the last race-free moment before a possible native click-focus
        // on a tile: a demoted (.normal) mirror left below would get
        // raised over by the clicked window before the mouse-down tap's
        // main-actor hop lands (the "sibling dips behind, pops back up"
        // flicker with focus-follows-mouse off). But only *after* this
        // mirror is opaque: lifting in the same beat puts a sibling's
        // .floating mirror above the still-uncovered real window
        // (.normal), visibly dropping the focused float behind the
        // sibling at their overlap until the first fresh frame lands.
        let frame = await visibilityWorker.windowFrame(key)
        guard !Task.isCancelled, generation == focusPresentationGeneration else { return }
        guard suppressed.contains(key), panels[key] != nil else { continue }
        guard let frame else { removeWindow(key)
          continue
        }
        refresh(key, windowFrame: frame)
        if NSEvent.pressedMouseButtons != 0 || AXWindowGeometry.flipToCocoa(frame).contains(NSEvent.mouseLocation) {
          cursorInside[key] = true
          continue
        }
        restoreMirror(key, waitForFrame: true) { [weak self] in
          self?.applyStackOrder()
        }
      }
    }
  }

  /// Called after the tap has retained the original mouse-down. The same lease
  /// protects preparation, replay, and a native drag until the final mouse-up.
  private func prepareNativeInput(id: UUID, target: MirrorWindowRegistry.Target) async -> Bool {
    guard
      let key = panels.keys.first(where: { $0.pid == target.pid && $0.windowID == target.windowID }),
      let panel = panels[key], !geometryUnavailable.contains(key), !captureUnavailable.contains(key)
    else { return false }
    nativeInputLeases[key] = id
    interactionOrder.removeAll { $0 == key }
    interactionOrder.insert(key, at: 0)
    let prepared = await axWorker.prepareForFocus(key, targetFrame: lastFrame[key].map(AXWindowGeometry.flipToCG))
    guard prepared, !Task.isCancelled, nativeInputLeases[key] == id, panels[key] === panel else { return false }
    @Dependency(\.focusEventOrigin) var focusEventOrigin
    @Dependency(\.focusManager) var focusManager
    focusEventOrigin.recordPointerDrivenFocus(key.windowID)
    await focusManager.focusWindow(key)
    guard
      !Task.isCancelled, nativeInputLeases[key] == id, panels[key] === panel,
      isFrontmostApplication(pid: key.pid)
    else { return false }
    // didActivate may already have started this task. Join that exact handover
    // instead of replaying against an activation notification alone.
    suppressMirror(key)
    if let task = hideTasks[key] { await task.value }
    // ScreenCaptureKit's titlebar control belongs to the source process. It
    // must retire before replay, particularly for a click near the traffic lights.
    if let capture = captures[key], !(await capture.waitUntilStopped()) { return false }
    guard
      !Task.isCancelled, nativeInputLeases[key] == id, panels[key] === panel,
      suppressed.contains(key), !panel.isVisible,
      isFrontmostApplication(pid: key.pid)
    else { return false }
    for _ in 0..<Timing.verifyMaxSteps {
      guard let input = visibilityInput(for: key, ignoringFloatingWindows: false) else { return false }
      let ready = await visibilityWorker.isNativeInputReady(input, mirrorID: CGWindowID(panel.windowNumber))
      guard
        !Task.isCancelled, nativeInputLeases[key] == id, panels[key] === panel,
        isFrontmostApplication(pid: key.pid)
      else { return false }
      if ready {
        @Dependency(\.errorReporter) var reporter
        reporter.resolve("FloatingInput")
        return true
      }
      do { try await Task.sleep(for: Timing.verifyStep) }
      catch { return false }
    }
    return false
  }

  private func finishNativeInput(id: UUID) async {
    guard let key = nativeInputLeases.first(where: { $0.value == id })?.key else { return }
    nativeInputLeases[key] = nil
    if panels[key]?.isVisible == true, suppressed.contains(key) {
      restoreMirror(key)
    }
    // A queued shortcut or a second click may have moved focus during replay.
    // The activation observer could not restore this leased window at that time.
    if !isFrontmostApplication(pid: key.pid) {
      let generation = focusPresentationGeneration
      let exposed = await isVisuallyOnTop(key)
      guard generation == focusPresentationGeneration, nativeInputLeases[key] == nil, panels[key] != nil else { return }
      if !exposed {
        restoreMirror(key)
        applyStackOrder()
      }
    }
    // The physical pointer may have left the original frame before focus
    // completed. Force a fresh geometry check at the end of the native gesture.
    if suppressed.contains(key) { cursorInside[key] = true }
    await handleCursorMoved(NSEvent.mouseLocation)
  }

  private func reportNativeInputFailure(_ reason: String) {
    @Dependency(\.errorReporter) var reporter
    reporter.report("FloatingInput", String(localized: "Could not deliver input to the floating window"), reason)
  }

  /// A mouse-down landed outside every suppressed floating window — focus
  /// is about to move to whatever was clicked. Put the mirrors back up
  /// ahead of the raise; the didActivate notification settles final state.
  private func handleOutsideClick() async {
    focusPresentationGeneration &+= 1
    let generation = focusPresentationGeneration
    guard !suppressed.isEmpty else { return }
    focusedFloatPid = nil
    for key in Array(panels.keys) {
      let exists = await visibilityWorker.windowExists(key)
      guard !Task.isCancelled, generation == focusPresentationGeneration else { return }
      guard panels[key] != nil else { continue }
      guard exists else {
        removeWindow(key)
        continue
      }
      restoreMirror(key)
      showPanel(key)
    }
    applyStackOrder()
  }

  /// Publish the suppressed windows' frames (CG coordinates) for the
  /// mouse-down tap, which runs off the main thread.
  private func syncSuppressedFrames() {
    var frames = [CGWindowID: CGRect]()
    for key in suppressed {
      if let cocoa = lastFrame[key] { frames[key.windowID] = AXWindowGeometry.flipToCG(cocoa) }
    }
    MirrorWindowRegistry.shared.setSuppressedFrames(frames)
  }

  private func requestGeometryReconcile() {
    geometryGeneration &+= 1
    axWorker.reconcile(
      Set(panels.keys),
      generation: geometryGeneration,
    )
  }

  private func applyGeometryUpdate(_ update: FloatingOverlayGeometryUpdate) {
    guard update.generation == geometryGeneration else { return }
    if update.replacesSnapshot {
      appliedGeometryGeneration = update.generation
    }
    let keys = update.replacesSnapshot
      ? Set(panels.keys)
      : Set(update.frames.keys).union(update.invalidated)
    for key in keys where panels[key] != nil {
      if let frame = update.frames[key] {
        refresh(key, windowFrame: frame)
      } else if update.replacesSnapshot || update.invalidated.contains(key) {
        invalidateGeometry(for: key)
      }
    }
  }

  /// Position + (re)size one mirror from a worker-resolved AX frame.
  private func refresh(
    _ key: WindowKey,
    windowFrame: CGRect,
  ) {
    guard let panel = panels[key] else { return }
    if geometryUnavailable.remove(key) != nil {
      geometryRetryTasks.removeValue(forKey: key)?.cancel()
    }
    let cg = windowFrame
    let cocoa = AXWindowGeometry.flipToCocoa(cg)
    if lastFrame[key] != cocoa {
      let previous = lastFrame[key]
      let sizeChanged = previous == nil
        || abs(previous!.width - cocoa.width) > 0.5
        || abs(previous!.height - cocoa.height) > 0.5
      panel.setFrame(cocoa, display: true, animate: false)
      lastFrame[key] = cocoa
      if suppressed.contains(key) { syncSuppressedFrames() }
      // Keep the capture surface in sync even while suppressed, so the
      // mirror is pixel-correct the moment it comes back.
      if sizeChanged, let capture = captures[key] {
        capture.updateSize(
          width: cg.width,
          height: cg.height,
          scale: panel.backingScaleFactor,
          maxFPS: maxFPS,
        )
      }
    }
    guard !suppressed.contains(key) else { return }
    if let capture = captures[key], !capture.isRunning {
      panel.ignoresMouseEvents = true
      panel.orderOut(nil)
      resumeCaptureAfterGeometryRecovery(
        key,
        capture: capture,
      )
      return
    }
    publishMirrorPanel(for: key)
  }

  /// A geometry notification says the window changed, but its final frame
  /// could not be read within the bounded AX timeout. Leaving the old panel
  /// in place would create a stale, event-eating mirror at the wrong location.
  private func invalidateGeometry(for key: WindowKey) {
    guard let panel = panels[key] else { return }
    let newlyUnavailable = geometryUnavailable.insert(key).inserted
    captureResumeTokens[key] = nil
    if newlyUnavailable {
      debugLog.log(
        "Mirror",
        "geometry unavailable \(key.bundleId)#\(key.windowID) — mirror hidden",
      )
    }
    let hadFrame = lastFrame.removeValue(forKey: key) != nil
    if hadFrame, suppressed.contains(key) {
      syncSuppressedFrames()
    }
    MirrorWindowRegistry.shared.set(
      mirror: CGWindowID(panel.windowNumber),
      target: nil,
    )
    panel.ignoresMouseEvents = true
    panel.orderOut(nil)
    captureRetryTasks.removeValue(forKey: key)?.cancel()
    captureRetryAttempts.removeValue(forKey: key)
    if newlyUnavailable {
      scheduleGeometryRecovery(for: key)
    }
  }

  private func publishMirrorPanel(for key: WindowKey) {
    guard
      nativeInputLeases[key] == nil,
      panels[key] != nil,
      lastFrame[key] != nil,
      !geometryUnavailable.contains(key),
      !captureUnavailable.contains(key),
      !suppressed.contains(key)
    else { return }
    if demoted.contains(key) {
      if
        let anchor = demotionAnchors[key],
        panels[anchor] != nil,
        suppressed.contains(anchor)
      {
        demoteVisibleSiblings(below: anchor)
      } else {
        // The focus transition that justified this demotion is gone.
        demoted.remove(key)
        demotionAnchors.removeValue(forKey: key)
        applyOrdering(key)
      }
    } else {
      applyOrdering(key)
    }
    registerMirrorTarget(for: key)
  }

  private func registerMirrorTarget(for key: WindowKey) {
    guard
      let panel = panels[key],
      panel.isVisible,
      lastFrame[key] != nil,
      !geometryUnavailable.contains(key),
      !captureUnavailable.contains(key)
    else { return }
    // Window number is only valid once ordered in; (re)registering is
    // idempotent. Focus-follows-mouse uses this to focus the mirrored
    // window when the cursor sits on the mirror.
    MirrorWindowRegistry.shared.set(
      mirror: CGWindowID(panel.windowNumber),
      target: .init(pid: key.pid, windowID: key.windowID),
      frame: AXWindowGeometry.flipToCG(panel.frame),
    )
  }

  private func resumeCaptureAfterGeometryRecovery(
    _ key: WindowKey,
    capture: WindowMirrorCapture,
  ) {
    resumeCapture(key, capture: capture) { [weak self] in
      self?.showPanel(key)
      self?.publishMirrorPanel(for: key)
    }
  }

  /// Every restart completion belongs to one capture instance and request.
  /// A retired stream must not hide/show a replacement panel with the same key.
  private func resumeCapture(
    _ key: WindowKey,
    capture: WindowMirrorCapture,
    onFreshFrame: (() -> Void)? = nil,
  ) {
    let token = UUID()
    captureResumeTokens[key] = token
    let framesPerSecond = maxFPS
    Task { @MainActor [weak self, capture] in
      guard await ScreenRecordingAccess.shared.prepare(), !Task.isCancelled else { return }
      guard
        let self,
        captures[key] === capture,
        captureResumeTokens[key] == token,
        !suppressed.contains(key),
        !geometryUnavailable.contains(key)
      else { return }
      await capture.resume(maxFPS: framesPerSecond) { [weak self, weak capture] outcome in
        guard
          let self, let capture,
          captures[key] === capture,
          captureResumeTokens[key] == token
        else { return }
        captureResumeTokens[key] = nil
        captureRetryTasks[key] = nil
        guard acceptCaptureOutcome(outcome, for: key) else { return }
        onFreshFrame?()
      }
    }
  }

  /// Accept only an exact-stream fresh frame as a successful restart.
  /// Failure/cancellation while the mirror still needs to be visible keeps
  /// the panel hidden and event-inert, then enters a bounded retry path.
  @discardableResult
  private func acceptCaptureOutcome(
    _ outcome: WindowMirrorCapture.FirstFrameOutcome,
    for key: WindowKey,
  ) -> Bool {
    switch outcome {
    case .freshFrame:
      captureRetryTasks.removeValue(forKey: key)?.cancel()
      guard panels[key] != nil else { return false }
      if captureUnavailable.remove(key) != nil {
        debugLog.log(
          "Mirror",
          "capture recovered \(key.bundleId)#\(key.windowID)",
        )
      }
      captureRetryAttempts.removeValue(forKey: key)
      return true

    case .failed,
         .cancelled:
      if
        captureUnavailable.contains(key),
        captureRetryTasks[key] != nil
      {
        return false
      }
      guard
        panels[key] != nil,
        !suppressed.contains(key),
        !geometryUnavailable.contains(key)
      else {
        captureRetryAttempts.removeValue(forKey: key)
        return false
      }
      invalidateCapture(for: key, outcome: outcome)
      return false
    }
  }

  private func invalidateCapture(
    for key: WindowKey,
    outcome: WindowMirrorCapture.FirstFrameOutcome,
  ) {
    guard let panel = panels[key] else { return }
    let newlyUnavailable = captureUnavailable.insert(key).inserted
    if newlyUnavailable {
      let reason =
        switch outcome {
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .freshFrame: "recovered"
        }
      debugLog.log(
        "Mirror",
        "capture \(reason) "
          + "\(key.bundleId)#\(key.windowID) — mirror hidden",
      )
    }
    MirrorWindowRegistry.shared.set(
      mirror: CGWindowID(panel.windowNumber),
      target: nil,
    )
    panel.ignoresMouseEvents = true
    panel.orderOut(nil)
    scheduleCaptureRecovery(for: key)
  }

  private func scheduleCaptureRecovery(for key: WindowKey) {
    guard
      !ScreenRecordingAccess.shared.isClosed,
      panels[key] != nil,
      captureUnavailable.contains(key),
      !suppressed.contains(key),
      !geometryUnavailable.contains(key),
      let capture = captures[key],
      captureRetryTasks[key] == nil
    else { return }
    let attempt = (captureRetryAttempts[key] ?? 0) + 1
    guard attempt <= Timing.captureRetryMaxSteps else {
      debugLog.log(
        "Mirror",
        "capture retry exhausted \(key.bundleId)#\(key.windowID) — mirror remains hidden",
      )
      return
    }
    captureRetryAttempts[key] = attempt
    captureRetryTasks[key] = Task { @MainActor [weak self, capture] in
      do {
        try await Task.sleep(for: Timing.captureRetryStep)
      } catch {
        return
      }
      guard
        let self,
        !Task.isCancelled,
        panels[key] != nil,
        captureUnavailable.contains(key),
        !suppressed.contains(key),
        !geometryUnavailable.contains(key)
      else { return }
      resumeCapture(key, capture: capture) { [weak self] in
        guard let self else { return }
        showPanel(key)
        publishMirrorPanel(for: key)
      }
    }
  }

  private func scheduleGeometryRecovery(for key: WindowKey) {
    guard panels[key] != nil, geometryRetryTasks[key] == nil else { return }
    geometryRetryTasks[key] = Task { @concurrent [weak self] in
      for _ in 0..<Timing.geometryRetryMaxSteps {
        do {
          try await Task.sleep(for: Timing.geometryRetryStep)
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        let shouldContinue = await MainActor.run {
          guard
            let self,
            self.panels[key] != nil,
            self.geometryUnavailable.contains(key)
          else { return false }
          // Never cancel a still-running retry with another retry. Once the
          // latest full snapshot commits, a continued failure may try again.
          if self.appliedGeometryGeneration == self.geometryGeneration {
            self.requestGeometryReconcile()
          }
          return true
        }
        guard shouldContinue else { return }
      }
      do {
        try await Task.sleep(for: Timing.geometryRetryStep)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard
          let self,
          self.panels[key] != nil,
          self.geometryUnavailable.contains(key)
        else { return }
        // No successful frame arrived within the bounded retry window.
        // Stop the invisible stream so the recording indicator cannot stay
        // lit indefinitely; a later geometry/target signal resumes it.
        self.captures[key]?.stop()
        self.geometryRetryTasks[key] = nil
      }
    }
  }

}
