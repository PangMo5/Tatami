// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

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
  init(colorHex: String?, alwaysVisible: Bool = false, symbol: String? = nil, sharedColorHex: String? = nil) {
    self.colorHex = colorHex
    self.alwaysVisible = alwaysVisible
    self.symbol = symbol
    self.sharedColorHex = sharedColorHex
  }

  var colorHex: String?
  var sharedColorHex: String?
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
  var windowPresentationChanged: @Sendable (_ windowID: CGWindowID?) async -> Void = { _ in }
}

// MARK: DependencyKey

extension MarkerClient: DependencyKey {
  static let liveValue: MarkerClient = {
    let controller = MainActor.assumeIsolated { MarkerController() }
    let geometry = MarkerGeometryWorker { [weak controller] update in
      controller?.applyGeometryUpdate(update)
    }
    MainActor.assumeIsolated {
      MirrorWindowRegistry.shared.setMarkerPresentationHandler { [weak controller] target in
        controller?.mirrorPresentationChanged(target, geometry: geometry)
      }
      controller.observeActiveSpaceChanges { [weak controller] in
        guard let request = controller?.preparePlacementRefresh() else { return }
        Task { @MainActor in
          let surfaces = await geometry.snapshot(request.keys, generation: request.generation)
          controller?.applyFocusSnapshot(surfaces, generation: request.generation)
        }
      }
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
      windowPresentationChanged: { windowID in
        await MainActor.run { controller.windowPresentationChanged(windowID: windowID, geometry: geometry) }
      },
    )
  }()

  /// Without this, a `TestStore` that forgets to override `\.marker`
  /// constructs the real `MarkerController` (NSPanels) on the test host.
  static let testValue = MarkerClient(
    setTargets: { _, _, _, _ in },
    setFocused: { _ in },
    windowPresentationChanged: { _ in },
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

// MARK: - MarkerWindowStack

/// Front-to-back WindowServer order. The badge's own rank is never evidence
/// that its owner is exposed; cross-process ordering can separate those two.
struct MarkerWindowStack: Sendable {

  // MARK: Lifecycle

  init(_ windows: [WindowServerWindow]) {
    self.windows = windows
    order = Dictionary(uniqueKeysWithValues: windows.enumerated().map { ($0.element.id, $0.offset) })
  }

  // MARK: Internal

  var order: [CGWindowID: Int]

  func exposes(_ frame: CGRect, on owner: CGWindowID, ignoring markers: Set<CGWindowID>) -> Bool {
    guard
      !frame.isEmpty,
      let rank = order[owner],
      windows[rank].alpha > 0,
      windows[rank].surface.frame.contains(frame)
    else { return false }
    let layer = windows[rank].surface.layer
    // The compositor already places higher layers above both the owner and
    // its badge. Their bounds can include clear areas, such as the Dock canvas.
    return !windows[..<rank].contains { window in
      window.surface.layer == layer && window.alpha > 0 && !markers.contains(window.id)
        && !window.surface.frame.intersection(frame).isEmpty
    }
  }

  // MARK: Private

  private let windows: [WindowServerWindow]

}

// MARK: - MarkerGeometryUpdate

private struct MarkerGeometryUpdate: Sendable {
  var snapshot: MarkerNativeSnapshot
  var targetGeneration: UInt64
}

// MARK: - MarkerNativeSnapshot

/// WindowServer orders surfaces, but WindowManager may report Mission Control
/// thumbnails under the original window IDs. These placements carry AX frames.
private struct MarkerNativeSnapshot: Sendable {
  var surfaces: [WindowKey: WindowServerSurface]
  var stack: MarkerWindowStack
  var sequence: UInt64
  var unsettledFrames = Set<WindowKey>()
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
/// dedicated serial run loop. `MarkerController` receives value snapshots
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
  }

  // MARK: Internal

  typealias GeometrySink = @MainActor @Sendable (MarkerGeometryUpdate) -> Void

  func updateTargets(
    _ keys: [WindowKey],
    generation: UInt64,
  ) async -> MarkerNativeSnapshot? {
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
  ) async -> MarkerNativeSnapshot? {
    let cancellation = MarkerGeometryCancellationFlag()
    let shouldRun = focusLock.withLock { () -> Bool in
      guard generation >= latestFocusSnapshotGeneration else { return false }
      latestFocusSnapshotGeneration = generation
      currentFocusSnapshot?.cancellation.cancel()
      currentFocusSnapshot = (generation, cancellation)
      return true
    }
    guard shouldRun else { return nil }
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

  func snapshotOrder(_ keys: Set<WindowKey>) async -> MarkerNativeSnapshot? {
    await perform {
      self.snapshotSurfaces(keys.intersection(self.targetKeys), isCancelled: { false })
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
    pendingGeometryKeys.insert(key)
    scheduleGeometryDeliveryIfNeeded()
  }

  // MARK: Private

  private let sink: GeometrySink
  private let schedulingLock = NSLock()
  private var pendingOperations = [@Sendable () -> Void]()
  private var thread: Thread?
  private var runLoop: CFRunLoop?

  /// State below is confined to `runLoop`.
  private var targetGeneration: UInt64 = 0
  private var snapshotSequence: UInt64 = 0
  private var targetKeys = Set<WindowKey>()
  private var elements = [WindowKey: AXUIElement]()
  private var nativeFrames = [WindowKey: CGRect]()
  private var keyByWindowID = [CGWindowID: WindowKey]()
  private var observers = [pid_t: AXObserver]()
  private var subscribed = Set<WindowKey>()
  /// At most one MainActor delivery is outstanding. Geometry callbacks
  /// arriving behind it coalesce into the next shared WindowServer snapshot.
  private var pendingGeometryKeys = Set<WindowKey>()
  private var isGeometryDeliveryInFlight = false
  private var overviewWindowIDs = Set<CGWindowID>()
  private var overviewObserver: Timer?
  private var nativeFrameMatches = Set<WindowKey>()
  private var overviewAnimatedWindows = Set<WindowKey>()

  private let focusLock = NSLock()
  private var latestFocusSnapshotGeneration: UInt64 = 0
  private var currentFocusSnapshot: (
    generation: UInt64,
    cancellation: MarkerGeometryCancellationFlag,
  )?

  private static func overviewWindowID(_ window: WindowServerWindow) -> CGWindowID? {
    let application: String
    switch window.surface.layer {
    case 18: application = "com.apple.dock"
    case 19: application = "com.apple.WindowManager"
    default: return nil
    }
    guard
      window.alpha > 0,
      NSRunningApplication(processIdentifier: window.surface.ownerPID)?.bundleIdentifier == application
    else { return nil }
    return window.id
  }

  private static func framesAgree(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.minX - rhs.minX) <= 1 && abs(lhs.minY - rhs.minY) <= 1
      && abs(lhs.width - rhs.width) <= 1 && abs(lhs.height - rhs.height) <= 1
  }

  private func run() {
    let workerRunLoop = CFRunLoopGetCurrent()
    RunLoop.current.add(NSMachPort(), forMode: .common)
    schedulingLock.withLock {
      for operation in pendingOperations {
        CFRunLoopPerformBlock(workerRunLoop, CFRunLoopMode.commonModes.rawValue, operation)
      }
      pendingOperations.removeAll(keepingCapacity: true)
      runLoop = workerRunLoop
    }
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
      enqueue { continuation.resume(returning: operation()) }
    }
  }

  private func enqueue(_ operation: @escaping @Sendable () -> Void) {
    let workerRunLoop = schedulingLock.withLock { () -> CFRunLoop? in
      guard let runLoop else {
        pendingOperations.append(operation)
        return nil
      }
      CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, operation)
      return runLoop
    }
    if let workerRunLoop {
      CFRunLoopWakeUp(workerRunLoop)
    }
  }

  private func updateTargetsOnThread(
    _ keys: Set<WindowKey>,
    generation: UInt64,
    isCancelled: @Sendable () -> Bool,
  ) -> MarkerNativeSnapshot? {
    guard generation >= targetGeneration, !isCancelled() else { return nil }
    targetGeneration = generation
    targetKeys = keys
    removeStaleElements()
    resolveMissingElements(isCancelled: isCancelled)
    ensureSubscriptions(isCancelled: isCancelled)
    return snapshotSurfaces(keys, isCancelled: isCancelled)
  }

  private func snapshotOnThread(
    _ keys: Set<WindowKey>,
    isCancelled: @Sendable () -> Bool,
  ) -> MarkerNativeSnapshot? {
    guard !isCancelled() else { return nil }
    // A target may have been temporarily unreachable during its initial
    // reconcile. Focus is a useful retry signal; resolve only still-missing
    // current targets before taking the fresh frame snapshot.
    resolveMissingElements(isCancelled: isCancelled)
    ensureSubscriptions(isCancelled: isCancelled)
    return snapshotSurfaces(keys.intersection(targetKeys), isCancelled: isCancelled)
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
        if isCancelled() {
          return
        }
        continue
      }
      subscribed.insert(key)
    }
  }

  private func observer(for pid: pid_t) -> AXObserver? {
    if let observer = observers[pid] {
      return observer
    }
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

  private func snapshotSurfaces(
    _ keys: Set<WindowKey>,
    forceFrameReadFor: Set<WindowKey> = [],
    isCancelled: @Sendable () -> Bool,
  ) -> MarkerNativeSnapshot? {
    guard !keys.isEmpty else {
      if targetKeys.isEmpty {
        stopObservingOverview()
      }
      snapshotSequence &+= 1
      return MarkerNativeSnapshot(surfaces: [:], stack: MarkerWindowStack([]), sequence: snapshotSequence)
    }
    guard
      !isCancelled(),
      let windows = readWindowServerWindowsIfAvailable([.optionOnScreenOnly, .excludeDesktopElements])
    else { return nil }
    let stack = MarkerWindowStack(windows)
    let order = stack.order
    let overviewIDs = Set(windows.compactMap(Self.overviewWindowID))
    if !overviewIDs.isEmpty {
      for key in nativeFrameMatches.intersection(targetKeys) {
        if
          let index = order[key.windowID],
          let frame = nativeFrames[key],
          windows[index].surface.ownerPID == key.pid,
          !Self.framesAgree(frame, windows[index].surface.frame)
        {
          overviewAnimatedWindows.insert(key)
        }
      }
      observeOverview(overviewIDs)
      // Mission Control owns this stack until its last surface is gone.
      // Keep the placed panels transient and don't commit preview ordering.
      return nil
    }
    var surfaces = [WindowKey: WindowServerSurface]()
    var unsettledFrames = Set<WindowKey>()
    for key in keys {
      guard !isCancelled() else { return nil }
      guard
        let index = order[key.windowID],
        windows[index].surface.ownerPID == key.pid,
        windows[index].alpha > 0
      else { continue }
      var surface = windows[index].surface
      // A matching server frame needs no IPC. Otherwise ask the actual AX
      // window, including when the server is showing a transformed thumbnail.
      if forceFrameReadFor.contains(key) || nativeFrames[key] != surface.frame {
        if let element = elements[key], let frame = AXWindowGeometry.frame(of: element), !frame.isEmpty {
          nativeFrames[key] = frame
        }
      }
      // A temporary AX failure during a transition cannot authorize a new
      // marker location. Retain the last verified frame for this live key.
      guard let frame = nativeFrames[key] else { continue }
      if !Self.framesAgree(frame, surface.frame) {
        unsettledFrames.insert(key)
      }
      surface.frame = frame
      surfaces[key] = surface
    }
    if overviewObserver == nil {
      nativeFrameMatches.subtract(keys)
      nativeFrameMatches.formUnion(Set(surfaces.keys).subtracting(unsettledFrames))
    }
    snapshotSequence &+= 1
    return MarkerNativeSnapshot(surfaces: surfaces, stack: stack, sequence: snapshotSequence, unsettledFrames: unsettledFrames)
  }

  private func observeOverview(_ ids: Set<CGWindowID>) {
    overviewWindowIDs = ids
    guard overviewObserver == nil else { return }
    // Sample only the observed system surfaces while the overview exists.
    // AX focus and WindowServer visibility can both arrive during its exit
    // animation, before the native stack is authoritative again.
    let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
      self?.reconcileAfterOverview()
    }
    overviewObserver = timer
    RunLoop.current.add(timer, forMode: .common)
  }

  private func reconcileAfterOverview() {
    guard !targetKeys.isEmpty else {
      stopObservingOverview()
      return
    }
    for id in overviewWindowIDs {
      guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] else { return }
      if rows.contains(where: { ($0[kCGWindowIsOnscreen as String] as? Bool) == true }) {
        return
      }
    }
    let keys = targetKeys
    guard let snapshot = snapshotSurfaces(keys, isCancelled: { false }) else { return }
    // The overview background can order out while its thumbnails are still
    // being restored. Only wait for windows observed animating away from a
    // previously matching native frame, and permit windows that left screen.
    guard snapshot.unsettledFrames.isDisjoint(with: overviewAnimatedWindows) else { return }
    stopObservingOverview()
    nativeFrameMatches = Set(snapshot.surfaces.keys).subtracting(snapshot.unsettledFrames)
    let update = MarkerGeometryUpdate(snapshot: snapshot, targetGeneration: targetGeneration)
    let sink = sink
    Task { @MainActor in sink(update) }
  }

  private func stopObservingOverview() {
    overviewObserver?.invalidate()
    overviewObserver = nil
    overviewWindowIDs.removeAll()
    overviewAnimatedWindows.removeAll()
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
      nativeFrames[key] = nil
      nativeFrameMatches.remove(key)
      keyByWindowID[key.windowID] = nil
      pendingGeometryKeys.remove(key)
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
      !pendingGeometryKeys.isEmpty
    else { return }
    let keys = pendingGeometryKeys
    pendingGeometryKeys.removeAll(keepingCapacity: true)
    isGeometryDeliveryInFlight = true
    let snapshot = snapshotSurfaces(targetKeys, forceFrameReadFor: keys, isCancelled: { false })
    let generation = targetGeneration
    let sink = sink
    Task { @MainActor [weak self] in
      if let snapshot {
        sink(MarkerGeometryUpdate(snapshot: snapshot, targetGeneration: generation))
      }
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
      let style = Style(
        hex: target.colorHex,
        size: markSize,
        symbol: target.symbol,
        sharedHex: target.sharedColorHex,
        sharedSize: size * 1.4,
      )
      if panels[key] == nil {
        panels[key] = makePanel(style: style)
      } else if
        styles[key] != style,
        let hosting = panels[key]?.contentView as? NSHostingView<MarkerView>
      {
        hosting.rootView = makeView(style: style)
        lastFrame.removeValue(forKey: key)
      }
      if styles[key] != style {
        primaryVisibility[key] = nil
      }
      styles[key] = style
    }
    MirrorWindowRegistry.shared.setMarkerWindows(Set(panels.values.compactMap { CGWindowID(exactly: $0.windowNumber) }))
    refreshHoverMonitor()
    return MarkerTargetRefreshRequest(
      generation: targetRefreshGeneration,
      keys: Array(targets.keys),
    )
  }

  func applyTargetSnapshot(
    _ snapshot: MarkerNativeSnapshot?,
    generation: UInt64,
  ) {
    guard generation == targetRefreshGeneration, let snapshot else { return }
    appliedTargetRefreshGeneration = generation
    applySnapshot(snapshot)
  }

  func applyGeometryUpdate(_ update: MarkerGeometryUpdate) {
    guard update.targetGeneration == targetRefreshGeneration else { return }
    applySnapshot(update.snapshot)
  }

  /// Focus eligibility and exposure are applied together from a fresh stack.
  func prepareFocusedWindow(_ key: WindowKey?) -> MarkerFocusRefreshRequest? {
    focused = key.map { ($0.pid, $0.windowID) }
    return preparePlacementRefresh()
  }

  func preparePlacementRefresh() -> MarkerFocusRefreshRequest? {
    guard !panels.isEmpty else { return nil }
    focusRefreshGeneration &+= 1
    return MarkerFocusRefreshRequest(generation: focusRefreshGeneration, keys: Array(panels.keys))
  }

  func applyFocusSnapshot(
    _ snapshot: MarkerNativeSnapshot?,
    generation: UInt64,
  ) {
    guard generation == focusRefreshGeneration, let snapshot else { return }
    applySnapshot(snapshot)
  }

  func observeActiveSpaceChanges(_ refresh: @escaping @MainActor @Sendable () -> Void) {
    activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil,
      queue: .main,
    ) { _ in
      MainActor.assumeIsolated { refresh() }
    }
  }

  func mirrorPresentationChanged(_ target: MirrorWindowRegistry.Target, geometry: MarkerGeometryWorker) {
    guard let key = panels.keys.first(where: { $0.pid == target.pid && $0.windowID == target.windowID }) else { return }
    // Wait for a stack that contains the new presenting surface before
    // showing its badge. Old native visibility cannot authorize a mirror.
    exposedKeys.remove(key)
    updateAlpha(for: key, cursor: NSEvent.mouseLocation)
    windowPresentationChanged(windowID: target.windowID, geometry: geometry)
  }

  func windowPresentationChanged(windowID: CGWindowID?, geometry: MarkerGeometryWorker) {
    if let windowID, MirrorWindowRegistry.shared.markerWindowIDs().contains(windowID) {
      return
    }
    guard !panels.isEmpty else { return }
    needsStackRefresh = true
    guard stackRefreshTask == nil else { return }
    stackRefreshTask = Task { @MainActor [weak self] in
      guard let self else { return }
      while needsStackRefresh {
        needsStackRefresh = false
        let generation = targetRefreshGeneration
        guard
          let snapshot = await geometry.snapshotOrder(Set(panels.keys)),
          generation == targetRefreshGeneration
        else { continue }
        applySnapshot(snapshot)
      }
      stackRefreshTask = nil
    }
  }

  // MARK: Private

  private struct Style: Equatable {
    var hex: String?
    var size: Double
    var symbol: String?
    var sharedHex: String?
    var sharedSize: Double

    var contentSize: CGSize {
      let status = hex == nil ? 0 : size
      let shared = sharedHex == nil ? 0 : sharedSize
      return CGSize(width: status + shared + (status > 0 && shared > 0 ? 4 : 0), height: max(status, shared))
    }
  }

  private struct Configuration: Equatable {
    var targets: [WindowKey: MarkerTarget]
    var size: Double
    var corner: MarkerCorner
    var hideOnHover: Bool
  }

  private var panels = [WindowKey: NSPanel]()
  private var styles = [WindowKey: Style]()
  private var primaryVisibility = [WindowKey: Bool]()
  /// Windows whose dot ignores the focus gate (floating windows).
  private var alwaysVisible = Set<WindowKey>()
  private var lastFrame = [WindowKey: NSRect]()
  private var nativeSurfaces = [WindowKey: WindowServerSurface]()
  private var activeSpaceObserver: any NSObjectProtocol?
  private var stackRefreshTask: Task<Void, Never>?
  private var needsStackRefresh = false
  private var stack = MarkerWindowStack([])
  private var appliedSnapshotSequence: UInt64 = 0
  private var exposedKeys = Set<WindowKey>()
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

  private func applySnapshot(_ snapshot: MarkerNativeSnapshot) {
    guard snapshot.sequence >= appliedSnapshotSequence else { return }
    appliedSnapshotSequence = snapshot.sequence
    stack = snapshot.stack
    nativeSurfaces = snapshot.surfaces
    let cursor = NSEvent.mouseLocation
    let markerIDs = Set(panels.values.compactMap { CGWindowID(exactly: $0.windowNumber) })
    for key in panels.keys {
      refresh(key, cursor: cursor, ignoring: markerIDs)
    }
    MirrorWindowRegistry.shared.setMarkerWindows(Set(panels.values.compactMap { CGWindowID(exactly: $0.windowNumber) }))
    refreshHoverMonitor()
  }

  private func refresh(_ key: WindowKey, cursor: NSPoint, ignoring markerIDs: Set<CGWindowID>) {
    guard let style = styles[key], let panel = panels[key] else { return }
    let mirrorID = MirrorWindowRegistry.shared.mirrorWindowID(for: .init(pid: key.pid, windowID: key.windowID))
    let mirror = mirrorID.flatMap { NSApp.window(withWindowNumber: Int($0)) }
      .flatMap { $0.isVisible && $0.alphaValue > 0 ? $0 : nil }
    if panel.parent !== mirror {
      // A frame from the previous parent is not evidence of exposure.
      exposedKeys.remove(key)
      updateAlpha(for: key, cursor: cursor)
      panel.parent?.removeChildWindow(panel)
    }
    let bounds: CGRect
    let sourceID: CGWindowID
    let level: NSWindow.Level
    if let mirror, let mirrorID {
      bounds = AXWindowGeometry.flipToCG(mirror.frame)
      sourceID = mirrorID
      level = mirror.level
    } else if let native = nativeSurfaces[key] {
      bounds = native.frame
      sourceID = key.windowID
      level = NSWindow.Level(rawValue: native.layer)
    } else {
      panel.orderOut(nil)
      exposedKeys.remove(key)
      lastFrame[key] = nil
      return
    }
    let content = dotRect(in: bounds, size: style.contentSize, corner: corner).insetBy(dx: glowPadding, dy: glowPadding)
    let exposed = stack.exposes(content, on: sourceID, ignoring: markerIDs)
    if exposed {
      exposedKeys.insert(key)
    } else {
      exposedKeys.remove(key)
      hideImmediately(panel)
    }
    place(panel, key: key, style: style, windowFrame: bounds)
    let levelChanged = panel.level != level
    if levelChanged {
      panel.level = level
    }
    if let mirror {
      if panel.parent == nil {
        mirror.addChildWindow(panel, ordered: .above)
      }
    } else {
      let markerRank = CGWindowID(exactly: panel.windowNumber).flatMap { stack.order[$0] }
      let ownerRank = stack.order[sourceID]
      if levelChanged || !panel.isVisible || (ownerRank.map { $0 < (markerRank ?? .max) } ?? false) {
        panel.order(.above, relativeTo: Int(sourceID))
      }
    }
    updateAlpha(for: key, cursor: cursor)
  }

  private func hideImmediately(_ panel: NSPanel) {
    guard panel.alphaValue != 0 else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      panel.animator().alphaValue = 0
    }
    panel.alphaValue = 0
  }

  private func place(_ panel: NSPanel, key: WindowKey, style: Style, windowFrame: CGRect) {
    let cocoa = AXWindowGeometry.flipToCocoa(dotRect(in: windowFrame, size: style.contentSize, corner: corner))
    if panel.frame != cocoa {
      panel.setFrame(cocoa, display: true, animate: false)
    }
    lastFrame[key] = cocoa
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
    let primaryShown = isFocused || alwaysVisible.contains(key)
    if
      let style = styles[key],
      primaryVisibility[key] != primaryShown,
      let hosting = panel.contentView as? NSHostingView<MarkerView>
    {
      hosting.rootView = makeView(style: style, showsStatus: primaryShown)
      primaryVisibility[key] = primaryShown
    }
    guard exposedKeys.contains(key) else {
      hideImmediately(panel)
      return
    }
    let shown = primaryShown || styles[key]?.sharedHex != nil
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
    if let panel = panels.removeValue(forKey: key) {
      panel.parent?.removeChildWindow(panel)
      panel.orderOut(nil)
    }
    nativeSurfaces[key] = nil
    exposedKeys.remove(key)
    styles.removeValue(forKey: key)
    primaryVisibility.removeValue(forKey: key)
    lastFrame.removeValue(forKey: key)
  }

  /// Install the global mouse-moved monitor only while at least one dot can
  /// be visible; remove it otherwise so an idle marker set costs nothing.
  private func refreshHoverMonitor() {
    let needed = hideOnHover && !panels.isEmpty
      && (focused != nil || !alwaysVisible.isEmpty || styles.values.contains(where: { $0.sharedHex != nil }))
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
  private func dotRect(in windowFrame: CGRect, size: CGSize, corner: MarkerCorner) -> CGRect {
    let pad = glowPadding
    let panelSize = CGSize(width: size.width + pad * 2, height: size.height + pad * 2)
    let x: CGFloat
    let y: CGFloat
    switch corner {
    case .topLeading:
      x = windowFrame.minX + inset - pad
      y = windowFrame.minY + inset - pad

    case .topTrailing:
      x = windowFrame.maxX - inset - size.width - pad
      y = windowFrame.minY + inset - pad

    case .bottomLeading:
      x = windowFrame.minX + inset - pad
      y = windowFrame.maxY - inset - size.height - pad

    case .bottomTrailing:
      x = windowFrame.maxX - inset - size.width - pad
      y = windowFrame.maxY - inset - size.height - pad
    }
    return CGRect(x: x, y: y, width: panelSize.width, height: panelSize.height)
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
    panel.alphaValue = 0
    // `.transient` makes macOS hide the panel during Exposé / Mission
    // Control / App Switcher overlays automatically — without it the
    // dots float on top of the scaled window thumbnails.
    panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
    panel.contentView = NSHostingView(rootView: makeView(style: style))
    return panel
  }

  private func makeView(style: Style, showsStatus: Bool = true) -> MarkerView {
    MarkerView(
      color: style.hex.flatMap { Color(hex: $0) },
      size: CGFloat(style.size),
      padding: glowPadding,
      symbol: style.symbol,
      sharedColor: style.sharedHex.flatMap { Color(hex: $0) },
      sharedSize: CGFloat(style.sharedSize),
      showsStatus: showsStatus,
    )
  }

  /// AX/CG frames use top-left origin against the primary screen.
  /// `NSWindow.setFrame` wants bottom-left Cocoa coordinates.

}

// MARK: - MarkerView

private struct MarkerView: View {
  let color: Color?
  let size: CGFloat
  let padding: CGFloat
  var symbol: String?
  var sharedColor: Color?
  var sharedSize: CGFloat
  var showsStatus: Bool

  var body: some View {
    HStack(spacing: 4) {
      if let color {
        MarkerBadge(color: color, size: size, symbol: symbol)
          .opacity(showsStatus ? 1 : 0)
      }
      if let sharedColor {
        MarkerBadge(color: sharedColor, size: sharedSize, symbol: "square.stack.fill")
          .accessibilityLabel("Shared App")
      }
    }
    .padding(padding)
  }
}

// MARK: - MarkerBadge

private struct MarkerBadge: View {

  // MARK: Internal

  let color: Color
  let size: CGFloat
  var symbol: String?

  var body: some View {
    Circle()
      .fill(color)
      .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.75))
      .overlay {
        if let symbol {
          Image(systemName: symbol)
            .font(.system(size: size * 0.58, weight: .semibold))
            .foregroundStyle(foreground)
        }
      }
      .frame(width: size, height: size)
      .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
  }

  // MARK: Private

  private var foreground: Color {
    let rgb = NSColor(color).usingColorSpace(.sRGB)
    func linear(_ value: CGFloat) -> Double {
      let value = Double(value)
      return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    guard let rgb else { return .primary }
    let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    return (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05) ? .black : .white
  }

}

extension Color {

  // MARK: Lifecycle

  /// Parse `#RRGGBB` or `#RRGGBBAA`. Returns nil on malformed input.
  public init?(hex: String) {
    var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.hasPrefix("#") {
      raw.removeFirst()
    }
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
      let components = cg.components,
      components.count >= 3
    else { return nil }
    let r = Int((components[0] * 255).rounded())
    let g = Int((components[1] * 255).rounded())
    let b = Int((components[2] * 255).rounded())
    return String(format: "#%02X%02X%02X", r, g, b)
  }

}
