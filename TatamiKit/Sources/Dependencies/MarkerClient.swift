import AppKit
import ApplicationServices
import Dependencies
import DependenciesMacros
import Foundation
import SwiftUI

// MARK: - MarkerTarget

/// Draws a tiny colored dot on a configurable corner of selected windows
/// (zoomed + floating) as a passive identifier. Fades out while the
/// cursor hovers over it so it never blocks clicks.
/// What to draw on one marked window: the dot color, plus whether the dot
/// shows regardless of focus. Floating windows keep their dot up always —
/// the mark is what tells a mirrored window apart from a tiled one — while
/// fullscreen-zoom dots only show on the focused window.
struct MarkerTarget: Sendable, Equatable {
  init(colorHex: String, alwaysVisible: Bool = false, symbol: String? = nil) {
    self.colorHex = colorHex
    self.alwaysVisible = alwaysVisible
    self.symbol = symbol
  }

  var colorHex: String
  var alwaysVisible: Bool
  /// SF Symbol drawn inside the marker badge instead of a plain dot — borrow
  /// markers use it to show the borrowed workspace's icon. nil = plain dot.
  var symbol: String?
}

// MARK: - MarkerClient

@DependencyClient
struct MarkerClient: Sendable {
  /// Replace the set of marked windows. Pass `[:]` to clear all.
  var setTargets: @Sendable (
    _ targets: [WindowKey: MarkerTarget],
    _ size: Double,
    _ corner: MarkerCorner,
    _ hideOnHover: Bool,
  ) async -> Void
  /// Tell the marker controller which window is currently frontmost so
  /// it can render a dot only on that window. Pushed from the AX
  /// observer's `windowFocused` events + the workspace app-activation
  /// flow — cheaper and more responsive than polling AX every 50 ms.
  /// Pass `nil` to clear (no focused window).
  var setFocused: @Sendable (_ key: WindowKey?) async -> Void
}

// MARK: DependencyKey

extension MarkerClient: DependencyKey {
  static let liveValue: MarkerClient = {
    let controller = MainActor.assumeIsolated { MarkerController() }
    let geometry = MarkerGeometryWorker { [weak controller] update in
      controller?.applyGeometryUpdate(update)
    }
    return MarkerClient(
      setTargets: { targets, size, corner, hideOnHover in
        let request = await MainActor.run {
          controller.prepareTargets(
            targets,
            size: size,
            corner: corner,
            hideOnHover: hideOnHover,
          )
        }
        guard let request else { return }
        let frames = await geometry.updateTargets(
          request.keys,
          generation: request.generation,
        )
        guard !Task.isCancelled else { return }
        await MainActor.run {
          controller.applyTargetSnapshot(
            frames,
            generation: request.generation,
          )
        }
      },
      setFocused: { key in
        let request = await MainActor.run {
          controller.prepareFocusedWindow(key)
        }
        guard let request else { return }
        let frames = await geometry.snapshot(
          request.keys,
          generation: request.generation,
        )
        guard !Task.isCancelled else { return }
        await MainActor.run {
          controller.applyFocusSnapshot(
            frames,
            generation: request.generation,
          )
        }
      },
    )
  }()

  /// Without this, a `TestStore` that forgets to override `\.marker`
  /// constructs the real `MarkerController` (NSPanels) on the test host.
  static let testValue = MarkerClient(
    setTargets: { _, _, _, _ in },
    setFocused: { _ in },
  )
  static let previewValue = testValue
}

extension DependencyValues {
  var marker: MarkerClient {
    get { self[MarkerClient.self] }
    set { self[MarkerClient.self] = newValue }
  }
}

// MARK: - MarkerTargetRefreshRequest

private struct MarkerTargetRefreshRequest: Sendable {
  var generation: UInt64
  var keys: [WindowKey]
}

// MARK: - MarkerFocusRefreshRequest

private struct MarkerFocusRefreshRequest: Sendable {
  var generation: UInt64
  var keys: [WindowKey]
}

// MARK: - MarkerGeometryUpdate

private struct MarkerGeometryUpdate: Sendable {
  var frames: [WindowKey: CGRect]
  var keys: Set<WindowKey>
  var replacesSnapshot: Bool
}

// MARK: - MarkerGeometryCancellationFlag

private final class MarkerGeometryCancellationFlag: @unchecked Sendable {

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

// MARK: - MarkerGeometryWorker

/// Owns every marker AX element, subscription, and geometry read on a
/// dedicated serial run loop. `MarkerController` receives CGRect snapshots
/// only, so target changes, programmatic tiling callbacks, and focus refreshes
/// never perform cross-process AX messaging on the main actor.
private final class MarkerGeometryWorker: @unchecked Sendable {

  // MARK: Lifecycle

  init(sink: @escaping GeometrySink) {
    self.sink = sink
    let thread = Thread { [weak self] in
      self?.run()
    }
    thread.name = "dev.PangMo5.Tatami.ax-marker-geometry"
    thread.qualityOfService = .userInitiated
    self.thread = thread
    thread.start()
    ready.wait()
  }

  // MARK: Internal

  typealias GeometrySink = @MainActor @Sendable (MarkerGeometryUpdate) -> Void

  func updateTargets(
    _ keys: [WindowKey],
    generation: UInt64,
  ) async -> [WindowKey: CGRect] {
    let cancellation = MarkerGeometryCancellationFlag()
    return await withTaskCancellationHandler {
      await perform {
        self.updateTargetsOnThread(
          Set(keys),
          generation: generation,
          isCancelled: { cancellation.isCancelled },
        )
      }
    } onCancel: {
      cancellation.cancel()
    }
  }

  /// Latest-focus-wins: cancel an older queued/in-flight full snapshot before
  /// enqueuing the new one. A blocking AX call itself cannot be interrupted,
  /// but the old pass exits before the next message or UI commit.
  func snapshot(
    _ keys: [WindowKey],
    generation: UInt64,
  ) async -> [WindowKey: CGRect] {
    let cancellation = MarkerGeometryCancellationFlag()
    let shouldRun = focusLock.withLock { () -> Bool in
      guard generation >= latestFocusSnapshotGeneration else { return false }
      latestFocusSnapshotGeneration = generation
      currentFocusSnapshot?.cancellation.cancel()
      currentFocusSnapshot = (generation, cancellation)
      return true
    }
    guard shouldRun else { return [:] }
    let frames = await withTaskCancellationHandler {
      await perform {
        self.snapshotOnThread(
          Set(keys),
          isCancelled: { cancellation.isCancelled },
        )
      }
    } onCancel: {
      cancellation.cancel()
    }
    focusLock.withLock {
      if currentFocusSnapshot?.cancellation === cancellation {
        currentFocusSnapshot = nil
      }
    }
    return frames
  }

  // MARK: Fileprivate

  fileprivate func handleGeometryChange(_ element: AXUIElement) {
    var windowID: CGWindowID = 0
    guard
      _AXUIElementGetWindow(element, &windowID) == .success,
      let key = keyByWindowID[windowID],
      targetKeys.contains(key)
    else { return }
    AXUIElementSetMessagingTimeout(element, 0.25)
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

  private let sink: GeometrySink
  private let ready = DispatchSemaphore(value: 0)
  private var thread: Thread?
  private nonisolated(unsafe) var runLoop: CFRunLoop!

  /// State below is confined to `runLoop`.
  private var targetGeneration: UInt64 = 0
  private var targetKeys = Set<WindowKey>()
  private var elements = [WindowKey: AXUIElement]()
  private var keyByWindowID = [CGWindowID: WindowKey]()
  private var observers = [pid_t: AXObserver]()
  private var subscribed = Set<WindowKey>()
  /// Key-wise latest geometry waiting for the UI. At most one MainActor
  /// delivery task exists; callbacks arriving behind it overwrite their key's
  /// pending frame instead of creating an unbounded task backlog.
  private var pendingGeometryFrames = [WindowKey: CGRect]()
  /// A failed final geometry read invalidates the old panel placement. Kept
  /// separately so a later successful callback for the same key can replace
  /// the failure before the coalesced batch reaches the main actor.
  private var pendingGeometryFailures = Set<WindowKey>()
  private var isGeometryDeliveryInFlight = false

  private let focusLock = NSLock()
  private var latestFocusSnapshotGeneration: UInt64 = 0
  private var currentFocusSnapshot: (
    generation: UInt64,
    cancellation: MarkerGeometryCancellationFlag,
  )?

  private func run() {
    runLoop = CFRunLoopGetCurrent()
    RunLoop.current.add(NSMachPort(), forMode: .common)
    ready.signal()
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
      CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
        continuation.resume(returning: operation())
      }
      CFRunLoopWakeUp(runLoop)
    }
  }

  private func enqueue(_ operation: @escaping @Sendable () -> Void) {
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, operation)
    CFRunLoopWakeUp(runLoop)
  }

  private func updateTargetsOnThread(
    _ keys: Set<WindowKey>,
    generation: UInt64,
    isCancelled: @Sendable () -> Bool,
  ) -> [WindowKey: CGRect] {
    guard generation >= targetGeneration, !isCancelled() else { return [:] }
    targetGeneration = generation
    targetKeys = keys
    removeStaleElements()
    resolveMissingElements(isCancelled: isCancelled)
    ensureSubscriptions(isCancelled: isCancelled)
    return snapshotFrames(keys, isCancelled: isCancelled)
  }

  private func snapshotOnThread(
    _ keys: Set<WindowKey>,
    isCancelled: @Sendable () -> Bool,
  ) -> [WindowKey: CGRect] {
    guard !isCancelled() else { return [:] }
    // A target may have been temporarily unreachable during its initial
    // reconcile. Focus is a useful retry signal; resolve only still-missing
    // current targets before taking the fresh frame snapshot.
    resolveMissingElements(isCancelled: isCancelled)
    ensureSubscriptions(isCancelled: isCancelled)
    return snapshotFrames(keys.intersection(targetKeys), isCancelled: isCancelled)
  }

  private func resolveMissingElements(
    isCancelled: @Sendable () -> Bool
  ) {
    let missing = targetKeys.filter { elements[$0] == nil }
    for (pid, keys) in Dictionary(grouping: missing, by: \.pid) {
      guard !isCancelled() else { return }
      let app = AXUIElementCreateApplication(pid)
      AXUIElementSetMessagingTimeout(app, 0.25)
      var raw: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(
          app,
          kAXWindowsAttribute as CFString,
          &raw,
        ) == .success,
        let windows = raw as? [AXUIElement]
      else { continue }
      let requested = Dictionary(uniqueKeysWithValues: keys.map { ($0.windowID, $0) })
      for window in windows {
        guard !isCancelled() else { return }
        var windowID: CGWindowID = 0
        guard
          _AXUIElementGetWindow(window, &windowID) == .success,
          let key = requested[windowID]
        else { continue }
        AXUIElementSetMessagingTimeout(window, 0.25)
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
      AXObserverCreate(pid, markerGeometryWorkerCallback, &observer) == .success,
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
      AXUIElementSetMessagingTimeout(element, 0.25)
      if let frame = AXWindowGeometry.frame(of: element) {
        frames[key] = frame
      }
    }
    return frames
  }

  private func removeStaleElements() {
    for key in Array(elements.keys) where !targetKeys.contains(key) {
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
      guard let observer = observers.removeValue(forKey: pid) else { continue }
      CFRunLoopRemoveSource(
        runLoop,
        AXObserverGetRunLoopSource(observer),
        .commonModes,
      )
    }
  }

  private func scheduleGeometryDeliveryIfNeeded() {
    guard
      !isGeometryDeliveryInFlight,
      !pendingGeometryFrames.isEmpty || !pendingGeometryFailures.isEmpty
    else { return }
    let frames = pendingGeometryFrames
    let failures = pendingGeometryFailures
    pendingGeometryFrames.removeAll(keepingCapacity: true)
    pendingGeometryFailures.removeAll(keepingCapacity: true)
    isGeometryDeliveryInFlight = true
    let sink = sink
    Task { @MainActor [weak self] in
      sink(
        MarkerGeometryUpdate(
          frames: frames,
          keys: Set(frames.keys).union(failures),
          replacesSnapshot: true,
        )
      )
      self?.enqueue { [weak self] in
        guard let self else { return }
        isGeometryDeliveryInFlight = false
        scheduleGeometryDeliveryIfNeeded()
      }
    }
  }

}

private func markerGeometryWorkerCallback(
  observer _: AXObserver,
  element: AXUIElement,
  notification _: CFString,
  refcon: UnsafeMutableRawPointer?,
) {
  guard let refcon else { return }
  let worker = Unmanaged<MarkerGeometryWorker>.fromOpaque(refcon).takeUnretainedValue()
  worker.handleGeometryChange(element)
}

// MARK: - MarkerController

@MainActor
private final class MarkerController {

  // MARK: Internal

  func prepareTargets(
    _ targets: [WindowKey: MarkerTarget],
    size: Double,
    corner: MarkerCorner,
    hideOnHover: Bool,
  ) -> MarkerTargetRefreshRequest? {
    let next = Configuration(
      targets: targets,
      size: size,
      corner: corner,
      hideOnHover: hideOnHover,
    )
    // Worker-owned geometry notifications keep positioned markers current.
    // Replaying an identical, complete target would only request the same
    // worker snapshot; a missing frame remains a retry signal.
    if
      configuration == next,
      appliedTargetRefreshGeneration == targetRefreshGeneration,
      targets.keys.allSatisfy({ lastFrame[$0] != nil })
    {
      return nil
    }
    focusRefreshGeneration &+= 1
    targetRefreshGeneration &+= 1
    configuration = next
    self.hideOnHover = hideOnHover
    if self.corner != corner {
      self.corner = corner
      // Force every panel to reposition from the next worker snapshot — the
      // dot's anchor changed, so cached frames are stale.
      lastFrame.removeAll()
    }
    // The reducer owns the target set, so this is the authoritative point at
    // which a dot's UI lifecycle ends. The worker reconciles AX subscriptions
    // from the returned key snapshot.
    for key in panels.keys.filter({ targets[$0] == nil }) {
      removeWindow(key)
    }
    alwaysVisible = Set(targets.filter(\.value.alwaysVisible).keys)
    // Add or update panels for each target.
    for (key, target) in targets {
      let markSize = target.symbol == nil ? size : size * symbolScale
      let style = Style(hex: target.colorHex, size: markSize, symbol: target.symbol)
      if panels[key] == nil {
        panels[key] = makePanel(style: style)
      } else if
        styles[key] != style,
        let hosting = panels[key]?.contentView as? NSHostingView<MarkerView>
      {
        hosting.rootView = makeView(style: style)
        lastFrame.removeValue(forKey: key)
      }
      styles[key] = style
    }
    refreshHoverMonitor()
    return MarkerTargetRefreshRequest(
      generation: targetRefreshGeneration,
      keys: Array(targets.keys),
    )
  }

  func applyTargetSnapshot(
    _ frames: [WindowKey: CGRect],
    generation: UInt64,
  ) {
    guard generation == targetRefreshGeneration else { return }
    appliedTargetRefreshGeneration = generation
    applyFrames(
      MarkerGeometryUpdate(
        frames: frames,
        keys: Set(panels.keys),
        replacesSnapshot: true,
      )
    )
  }

  func applyGeometryUpdate(_ update: MarkerGeometryUpdate) {
    applyFrames(update)
  }

  /// Record the currently-frontmost window and update visibility immediately
  /// from cached panel geometry. Fresh AX frames are resolved by the marker
  /// worker; the generation prevents an older focus request from committing
  /// after a newer one.
  func prepareFocusedWindow(_ key: WindowKey?) -> MarkerFocusRefreshRequest? {
    let next: (pid: pid_t, windowID: CGWindowID)? = key.map { ($0.pid, $0.windowID) }
    if let new = next, let old = focused, new == old { return nil }
    if next == nil, focused == nil { return nil }
    focused = next
    focusRefreshGeneration &+= 1
    let cursor = NSEvent.mouseLocation
    for key in panels.keys {
      updateAlpha(for: key, cursor: cursor)
    }
    guard !panels.isEmpty else { return nil }
    return MarkerFocusRefreshRequest(
      generation: focusRefreshGeneration,
      keys: Array(panels.keys),
    )
  }

  /// Commit only the newest worker snapshot. Missing frames preserve the
  /// existing transient-failure behavior: hide the dot and allow the next
  /// target/focus/geometry event to retry.
  func applyFocusSnapshot(
    _ frames: [WindowKey: CGRect],
    generation: UInt64,
  ) {
    guard generation == focusRefreshGeneration else { return }
    let cursor = NSEvent.mouseLocation
    for key in Array(panels.keys) {
      guard let frame = frames[key] else {
        hideAfterFrameReadFailure(key)
        continue
      }
      refresh(key, windowFrame: frame, cursor: cursor)
    }
    refreshHoverMonitor()
  }

  // MARK: Private

  private struct Style: Equatable {
    var hex: String
    var size: Double
    var symbol: String?
  }

  private struct Configuration: Equatable {
    var targets: [WindowKey: MarkerTarget]
    var size: Double
    var corner: MarkerCorner
    var hideOnHover: Bool
  }

  private var panels = [WindowKey: NSPanel]()
  private var styles = [WindowKey: Style]()
  /// Windows whose dot ignores the focus gate (floating windows).
  private var alwaysVisible = Set<WindowKey>()
  private var lastFrame = [WindowKey: NSRect]()
  /// Global mouse-moved monitor, installed only while a dot can be visible,
  /// so the hover-fade reacts without a polling timer. Hover needs the
  /// cursor position — a mouse event — which SwiftUI `.onHover` can't give
  /// us here: the panels are `ignoresMouseEvents` (click-through), so they
  /// receive no tracking events at all. A global monitor sees movement in
  /// *other* apps, which is exactly where the dots live.
  private var hoverMonitor: Any?

  private var hideOnHover = true
  /// A symbol marker is a badge, not a dot — render it this much larger than
  /// the shared dot size so the glyph inside stays legible.
  private let symbolScale = 2.0
  private var corner = MarkerCorner.bottomTrailing
  /// Last focused window pushed in via `setFocused`. nil = no focus
  /// (or unknown — markers stay hidden, which is the safe default).
  private var focused: (pid: pid_t, windowID: CGWindowID)?
  /// Distance from the chosen window corner to the dot's edge.
  private let inset: CGFloat = 10
  /// Small panel padding so the dot's faint drop shadow isn't clipped
  /// at the panel edge.
  private let glowPadding: CGFloat = 2

  private var configuration: Configuration?
  private var focusRefreshGeneration: UInt64 = 0
  private var targetRefreshGeneration: UInt64 = 0
  /// An async target reconcile may be cancelled after the UI configuration
  /// changes but before the worker updates its AX subscriptions. Only skip an
  /// identical request once that generation has actually completed.
  private var appliedTargetRefreshGeneration: UInt64?

  private func applyFrames(_ update: MarkerGeometryUpdate) {
    let cursor = NSEvent.mouseLocation
    for key in update.keys where panels[key] != nil {
      guard let frame = update.frames[key] else {
        if update.replacesSnapshot {
          hideAfterFrameReadFailure(key)
        }
        continue
      }
      refresh(key, windowFrame: frame, cursor: cursor)
    }
    refreshHoverMonitor()
  }

  private func refresh(
    _ key: WindowKey,
    windowFrame: CGRect,
    cursor: NSPoint,
  ) {
    guard let style = styles[key], let panel = panels[key] else { return }
    let cocoa = AXWindowGeometry.flipToCocoa(dotRect(in: windowFrame, size: CGFloat(style.size), corner: corner))
    if lastFrame[key] != cocoa {
      if lastFrame[key] == nil {
        // First placement: land directly, no glide in from nowhere.
        panel.setFrame(cocoa, display: true, animate: false)
      } else {
        // AX geometry events arrive sparsely during a drag; a short
        // ease-out glide between them reads as the dot following the
        // window instead of teleporting event-to-event.
        NSAnimationContext.runAnimationGroup { ctx in
          ctx.duration = 0.12
          ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
          panel.animator().setFrame(cocoa, display: true)
        }
      }
      lastFrame[key] = cocoa
    }
    if !panel.isVisible { panel.orderFrontRegardless() }
    updateAlpha(for: key, cursor: cursor)
  }

  private func hideAfterFrameReadFailure(_ key: WindowKey) {
    guard let panel = panels[key] else { return }
    if panel.alphaValue > 0.01 { panel.alphaValue = 0 }
    // A failed read invalidates the cached placement. Otherwise an identical
    // subsequent `setTargets` sees a non-nil lastFrame and returns early
    // forever, leaving the marker hidden even after AX recovers.
    lastFrame.removeValue(forKey: key)
  }

  /// Visibility only, from the *cached* dot rect — no AX round trip. Used by
  /// the hover monitor so moving the cursor never triggers AX IPC.
  private func updateAlpha(for key: WindowKey, cursor: NSPoint) {
    guard let panel = panels[key], let cocoa = lastFrame[key] else { return }
    // Focus gate: hide when this window isn't the user's current window —
    // except always-visible marks (floating windows), which stay up so the
    // mark identifies the mirror at a glance. Matched on (pid, wid) so two
    // windows of the same app don't share a dot.
    let isFocused = focused.map { $0.pid == key.pid && $0.windowID == key.windowID } ?? false
    let shown = isFocused || alwaysVisible.contains(key)
    // Hover fade: only react when the cursor sits over the dot's visible
    // circle, not the surrounding glow padding.
    let hovering = hideOnHover && cocoa.insetBy(dx: glowPadding, dy: glowPadding).contains(cursor)
    let target: CGFloat = (shown && !hovering) ? 1 : 0
    if abs(panel.alphaValue - target) > 0.01 {
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.15
        panel.animator().alphaValue = target
      }
    }
  }

  private func removeWindow(_ key: WindowKey) {
    panels[key]?.orderOut(nil)
    panels.removeValue(forKey: key)
    styles.removeValue(forKey: key)
    lastFrame.removeValue(forKey: key)
  }

  /// Install the global mouse-moved monitor only while at least one dot can
  /// be visible; remove it otherwise so an idle marker set costs nothing.
  private func refreshHoverMonitor() {
    let needed = hideOnHover && !panels.isEmpty
      && (focused != nil || !alwaysVisible.isEmpty)
    if needed, hoverMonitor == nil {
      hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.handleHover(cursor: NSEvent.mouseLocation)
        }
      }
    } else if !needed, let monitor = hoverMonitor {
      NSEvent.removeMonitor(monitor)
      hoverMonitor = nil
    }
  }

  private func handleHover(cursor: NSPoint) {
    for key in panels.keys { updateAlpha(for: key, cursor: cursor) }
  }

  /// Place the panel near the chosen window corner in top-left CG coords.
  /// The panel is sized to include `glowPadding` so the colored shadow
  /// can bloom outside the dot without being clipped.
  private func dotRect(in windowFrame: CGRect, size: CGFloat, corner: MarkerCorner) -> CGRect {
    let pad = glowPadding
    let panelSize = size + pad * 2
    let x: CGFloat
    let y: CGFloat
    switch corner {
    case .topLeading:
      x = windowFrame.minX + inset - pad
      y = windowFrame.minY + inset - pad

    case .topTrailing:
      x = windowFrame.maxX - inset - size - pad
      y = windowFrame.minY + inset - pad

    case .bottomLeading:
      x = windowFrame.minX + inset - pad
      y = windowFrame.maxY - inset - size - pad

    case .bottomTrailing:
      x = windowFrame.maxX - inset - size - pad
      y = windowFrame.maxY - inset - size - pad
    }
    return CGRect(x: x, y: y, width: panelSize, height: panelSize)
  }

  private func makePanel(style: Style) -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false,
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    // One notch above the floating-mirror panels (also `.floating`), so a
    // floating window's dot draws on top of its mirror instead of under it.
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    // `.transient` makes macOS hide the panel during Exposé / Mission
    // Control / App Switcher overlays automatically — without it the
    // dots float on top of the scaled window thumbnails.
    panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
    panel.contentView = NSHostingView(rootView: makeView(style: style))
    return panel
  }

  private func makeView(style: Style) -> MarkerView {
    MarkerView(
      color: Color(hex: style.hex) ?? .blue,
      size: CGFloat(style.size),
      padding: glowPadding,
      symbol: style.symbol,
    )
  }

  /// AX/CG frames use top-left origin against the primary screen.
  /// `NSWindow.setFrame` wants bottom-left Cocoa coordinates.

}

// MARK: - MarkerView

private struct MarkerView: View {
  let color: Color
  let size: CGFloat
  let padding: CGFloat
  var symbol: String?

  var body: some View {
    Circle()
      .fill(color)
      .overlay(
        Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
      )
      // A borrow marker carries the borrowed workspace's glyph inside the
      // dot, turning the plain dot into an identifying badge.
      .overlay {
        if let symbol {
          Image(systemName: symbol)
            .font(.system(size: size * 0.62, weight: .semibold))
            .foregroundStyle(.white)
        }
      }
      .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
      .padding(padding)
  }
}

extension Color {

  // MARK: Lifecycle

  /// Parse `#RRGGBB` or `#RRGGBBAA`. Returns nil on malformed input.
  public init?(hex: String) {
    var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.hasPrefix("#") { raw.removeFirst() }
    guard raw.count == 6 || raw.count == 8 else { return nil }
    var value: UInt64 = 0
    guard Scanner(string: raw).scanHexInt64(&value) else { return nil }
    let r: Double
    let g: Double
    let b: Double
    let a: Double
    if raw.count == 6 {
      r = Double((value >> 16) & 0xFF) / 255
      g = Double((value >> 8) & 0xFF) / 255
      b = Double(value & 0xFF) / 255
      a = 1
    } else {
      r = Double((value >> 24) & 0xFF) / 255
      g = Double((value >> 16) & 0xFF) / 255
      b = Double((value >> 8) & 0xFF) / 255
      a = Double(value & 0xFF) / 255
    }
    self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
  }

  // MARK: Public

  /// Serialize back to `#RRGGBB`. Returns nil if the color isn't in an
  /// RGB-convertible color space (e.g. dynamic system colors).
  public func toHex() -> String? {
    guard
      let cg = NSColor(self).usingColorSpace(.sRGB)?.cgColor,
      let components = cg.components, components.count >= 3
    else { return nil }
    let r = Int((components[0] * 255).rounded())
    let g = Int((components[1] * 255).rounded())
    let b = Int((components[2] * 255).rounded())
    return String(format: "#%02X%02X%02X", r, g, b)
  }

}
