import AppKit
import ApplicationServices
import CoreGraphics
import Dependencies
import DependenciesMacros
import Foundation

/// Live AX read of the frontmost app's focused window. Reducers access it
/// through `WindowSnapshotClient.focusedWindowKey`, keeping AppKit/AX reads
/// behind the dependency boundary.
@MainActor
private func liveFocusedWindowKey() -> WindowKey? {
  guard
    let app = NSWorkspace.shared.frontmostApplication,
    let bundleId = app.bundleIdentifier
  else { return nil }
  return resolveFocusedWindowKey(
    pid: app.processIdentifier,
    bundleId: bundleId,
  )
}

/// Performs only the synchronous AX messaging portion of focused-window
/// resolution. The async dependency runs this on a per-process serial worker
/// so the main event loop and unrelated apps remain available when one app is
/// busy.
private func resolveFocusedWindowKey(pid: pid_t, bundleId: String) -> WindowKey? {
  let axApp = AXUIElementCreateApplication(pid)
  AXUIElementSetMessagingTimeout(axApp, 0.25)
  var raw: CFTypeRef?
  guard
    AXUIElementCopyAttributeValue(
      axApp,
      kAXFocusedWindowAttribute as CFString,
      &raw,
    ) == .success,
    let value = raw,
    CFGetTypeID(value) == AXUIElementGetTypeID()
  else { return nil }
  let window = value as! AXUIElement
  AXUIElementSetMessagingTimeout(window, 0.25)
  return WindowKey(
    axWindow: window,
    pid: pid,
    bundleId: bundleId,
  )
}

// MARK: - FrontmostAppIdentity

private struct FrontmostAppIdentity: Sendable {
  var pid: pid_t
  var bundleId: String
}

private let windowReadAXQueues = AXPIDSerialQueueRegistry(
  label: "dev.PangMo5.Tatami.ax-window-read"
)

private let windowMetadataAXQueue = DispatchQueue(
  label: "dev.PangMo5.Tatami.ax-window-metadata",
  qos: .userInitiated,
)

// MARK: - WindowDiscoveryRequest

struct WindowDiscoveryRequest: Sendable {
  struct Process: Hashable, Sendable {
    var bundleId: String
    var pid: pid_t
  }

  var processes: [Process]
  /// Global epoch used only to filter the result at commit.
  var scanStartEpoch: UInt64
  /// Per-bundle generations distinguish a real state change from another
  /// consumer joining the same PID scan. Only the former requests a trailing
  /// refresh.
  var invalidationGenerations: [String: UInt64]

  func invalidationGeneration(for process: Process) -> UInt64 {
    invalidationGenerations[process.bundleId, default: 0]
  }
}

// MARK: - WindowDiscoveryCoordinator

/// Each target PID executes at most one capability-complete AX scan at a time.
/// Requests for different eligibility views or overlapping bundle groups share
/// that process flight, while unrelated PIDs remain free to progress in
/// parallel. A newer invalidation queues one trailing scan; merely adding
/// another waiter does not.
actor WindowDiscoveryCoordinator {

  // MARK: Lifecycle

  init(scan: Scan? = nil) {
    self.scan = scan ?? { process, _, sls, cancellation in
      await withCheckedContinuation { continuation in
        windowReadAXQueues.queue(for: process.pid).async {
          continuation.resume(
            returning: cancellation.isCancelled
              ? WindowCapabilityDiscovery()
              : discoverWindowCapabilities(
                forBundleIds: [process.bundleId],
                pidsByBundle: [process.bundleId: [process.pid]],
                sls: sls,
                isCancelled: { cancellation.isCancelled },
              )
          )
        }
      }
    }
  }

  // MARK: Internal

  typealias Scan = @Sendable (
    _ process: WindowDiscoveryRequest.Process,
    _ invalidationGeneration: UInt64,
    _ sls: SLSClient,
    _ cancellation: WindowDiscoveryCancellation,
  ) async -> WindowCapabilityDiscovery

  func discover(
    _ request: WindowDiscoveryRequest,
    sls: SLSClient,
  ) async throws -> WindowCapabilityDiscovery {
    guard !request.processes.isEmpty else {
      return WindowCapabilityDiscovery()
    }

    return try await withThrowingTaskGroup(
      of: (Int, WindowCapabilityDiscovery).self
    ) { group in
      for (index, process) in request.processes.enumerated() {
        group.addTask {
          let discovery = try await self.discover(
            process,
            invalidationGeneration: request.invalidationGeneration(for: process),
            sls: sls,
          )
          return (index, discovery)
        }
      }

      var ordered = [WindowCapabilityDiscovery?](
        repeating: nil,
        count: request.processes.count,
      )
      for try await (index, discovery) in group {
        ordered[index] = discovery
      }
      return Self.merge(ordered.compactMap { $0 })
    }
  }

  func inFlightWaiterCount(
    for process: WindowDiscoveryRequest.Process
  ) -> Int {
    inFlight[process]?.waiters.count ?? 0
  }

  // MARK: Private

  private struct PendingRefresh {
    var invalidationGeneration: UInt64
    var sls: SLSClient
  }

  private struct InFlight {
    var generation: UInt64
    var invalidationGeneration: UInt64
    var task: Task<WindowCapabilityDiscovery, Never>
    var cancellation: AXReadCancellationFlag
    var pendingRefresh: PendingRefresh?
    var waiters = [UUID: CheckedContinuation<WindowCapabilityDiscovery, any Error>]()
  }

  private let scan: Scan
  private var generation: UInt64 = 0
  private var inFlight = [WindowDiscoveryRequest.Process: InFlight]()

  private nonisolated static func merge(
    _ discoveries: [WindowCapabilityDiscovery]
  ) -> WindowCapabilityDiscovery {
    var merged = WindowCapabilityDiscovery()
    for discovery in discoveries {
      merged.movableKeys += discovery.movableKeys
      merged.resizableKeys += discovery.resizableKeys
      merged.unreachable.formUnion(discovery.unreachable)
      merged.retained.formUnion(discovery.retained)
    }
    if !merged.unreachable.isEmpty {
      merged.movableKeys.removeAll {
        merged.unreachable.contains($0.bundleId)
      }
      merged.resizableKeys.removeAll {
        merged.unreachable.contains($0.bundleId)
      }
    }
    merged.retained.subtract(merged.movableKeys.map(\.windowID))
    return merged
  }

  private func discover(
    _ process: WindowDiscoveryRequest.Process,
    invalidationGeneration: UInt64,
    sls: SLSClient,
  ) async throws -> WindowCapabilityDiscovery {
    let waiterID = UUID()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        register(
          continuation,
          id: waiterID,
          process: process,
          invalidationGeneration: invalidationGeneration,
          sls: sls,
        )
      }
    } onCancel: {
      Task {
        await self.cancelWaiter(id: waiterID, process: process)
      }
    }
  }

  private func makeInFlight(
    _ process: WindowDiscoveryRequest.Process,
    invalidationGeneration: UInt64,
    sls: SLSClient,
    waiters: [UUID: CheckedContinuation<WindowCapabilityDiscovery, any Error>] = [:],
  ) -> InFlight {
    generation &+= 1
    let currentGeneration = generation
    let cancellation = AXReadCancellationFlag()
    let scan = scan
    let task = Task {
      await scan(
        process,
        invalidationGeneration,
        sls,
        WindowDiscoveryCancellation {
          cancellation.isCancelled || Task.isCancelled
        },
      )
    }
    return InFlight(
      generation: currentGeneration,
      invalidationGeneration: invalidationGeneration,
      task: task,
      cancellation: cancellation,
      pendingRefresh: nil,
      waiters: waiters,
    )
  }

  private func register(
    _ continuation: CheckedContinuation<WindowCapabilityDiscovery, any Error>,
    id: UUID,
    process: WindowDiscoveryRequest.Process,
    invalidationGeneration: UInt64,
    sls: SLSClient,
  ) {
    if var existing = inFlight[process] {
      if invalidationGeneration > existing.invalidationGeneration {
        if let pending = existing.pendingRefresh {
          if invalidationGeneration > pending.invalidationGeneration {
            existing.pendingRefresh = PendingRefresh(
              invalidationGeneration: invalidationGeneration,
              sls: sls,
            )
          }
        } else {
          existing.pendingRefresh = PendingRefresh(
            invalidationGeneration: invalidationGeneration,
            sls: sls,
          )
        }
      }
      existing.waiters[id] = continuation
      inFlight[process] = existing
      return
    }

    var entry = makeInFlight(
      process,
      invalidationGeneration: invalidationGeneration,
      sls: sls,
    )
    entry.waiters[id] = continuation
    inFlight[process] = entry
    observeCompletion(
      process: process,
      generation: entry.generation,
      task: entry.task,
    )
  }

  private func observeCompletion(
    process: WindowDiscoveryRequest.Process,
    generation: UInt64,
    task: Task<WindowCapabilityDiscovery, Never>,
  ) {
    Task {
      let result = await task.value
      scanCompleted(
        process: process,
        generation: generation,
        result: result,
      )
    }
  }

  private func scanCompleted(
    process: WindowDiscoveryRequest.Process,
    generation: UInt64,
    result: WindowCapabilityDiscovery,
  ) {
    guard let current = inFlight[process], current.generation == generation
    else { return }

    if let pending = current.pendingRefresh, !current.waiters.isEmpty {
      let trailing = makeInFlight(
        process,
        invalidationGeneration: pending.invalidationGeneration,
        sls: pending.sls,
        waiters: current.waiters,
      )
      inFlight[process] = trailing
      observeCompletion(
        process: process,
        generation: trailing.generation,
        task: trailing.task,
      )
      return
    }

    inFlight[process] = nil
    for continuation in current.waiters.values {
      continuation.resume(returning: result)
    }
  }

  private func cancelWaiter(
    id: UUID,
    process: WindowDiscoveryRequest.Process,
  ) {
    guard
      var current = inFlight[process],
      let continuation = current.waiters.removeValue(forKey: id)
    else { return }

    continuation.resume(throwing: CancellationError())
    if current.waiters.isEmpty {
      current.cancellation.cancel()
      current.task.cancel()
      inFlight[process] = nil
    } else {
      inFlight[process] = current
    }
  }

}

@MainActor
private func makeWindowDiscoveryRequest(
  bundleIds: [String],
  scanStartEpoch: UInt64,
  invalidationGenerations: [String: UInt64],
) -> WindowDiscoveryRequest {
  let pids = runningPIDsByBundle(bundleIds)
  var seen = Set<WindowDiscoveryRequest.Process>()
  return WindowDiscoveryRequest(
    processes: bundleIds.flatMap { bundleId in
      (pids[bundleId] ?? []).map {
        WindowDiscoveryRequest.Process(bundleId: bundleId, pid: $0)
      }
    }.filter {
      seen.insert($0).inserted
    },
    scanStartEpoch: scanStartEpoch,
    invalidationGenerations: invalidationGenerations,
  )
}

private func liveFocusedWindowKeyAsync() async -> WindowKey? {
  let identity = await MainActor.run {
    NSWorkspace.shared.frontmostApplication.flatMap { app -> FrontmostAppIdentity? in
      guard let bundleId = app.bundleIdentifier else { return nil }
      return FrontmostAppIdentity(pid: app.processIdentifier, bundleId: bundleId)
    }
  }
  guard let identity else { return nil }
  return await resolveFocusedWindowKeyAsync(identity)
}

private func resolveFocusedWindowKeyAsync(
  _ identity: FrontmostAppIdentity
) async -> WindowKey? {
  let cancellation = AXReadCancellationFlag()
  return await withTaskCancellationHandler {
    await withCheckedContinuation { continuation in
      windowReadAXQueues.queue(for: identity.pid).async {
        let resolved =
          cancellation.isCancelled
            ? nil
            : resolveFocusedWindowKey(
              pid: identity.pid,
              bundleId: identity.bundleId,
            )
        continuation.resume(
          returning: cancellation.isCancelled ? nil : resolved
        )
      }
    }
  } onCancel: {
    cancellation.cancel()
  }
}

/// Resolve one exact window's current AX frame. Unlike the tiled frame map,
/// this also covers workspace-owned floating and unmanaged windows selected by
/// MRU restoration.
private func liveWindowFrame(_ key: WindowKey) -> CGRect? {
  let axApp = AXUIElementCreateApplication(key.pid)
  AXUIElementSetMessagingTimeout(axApp, 0.25)
  var raw: CFTypeRef?
  guard
    AXUIElementCopyAttributeValue(
      axApp,
      kAXWindowsAttribute as CFString,
      &raw,
    ) == .success,
    let windows = raw as? [AXUIElement]
  else { return nil }
  for window in windows {
    var wid: CGWindowID = 0
    guard _AXUIElementGetWindow(window, &wid) == .success, wid == key.windowID else { continue }
    AXUIElementSetMessagingTimeout(window, 0.25)
    return AXWindowGeometry.frame(of: window)
  }
  return nil
}

private func liveWindowFrameAsync(_ key: WindowKey) async -> CGRect? {
  let cancellation = AXReadCancellationFlag()
  return await withTaskCancellationHandler {
    await withCheckedContinuation { continuation in
      windowReadAXQueues.queue(for: key.pid).async {
        let frame = cancellation.isCancelled ? nil : liveWindowFrame(key)
        continuation.resume(returning: cancellation.isCancelled ? nil : frame)
      }
    }
  } onCancel: {
    cancellation.cancel()
  }
}

/// Validate cached/discovered identities against WindowServer without
/// requiring them to be on screen. A hidden window being unhidden is live
/// before `.optionOnScreenOnly` publishes it; checking the exact candidate
/// also avoids materializing dictionaries for every system window.
private func liveExistingWindowKeys(_ keys: [WindowKey]) -> Set<WindowKey> {
  var existing = Set<WindowKey>()
  for key in keys {
    guard
      let windows = CGWindowListCopyWindowInfo(
        [.optionIncludingWindow, .excludeDesktopElements],
        key.windowID,
      ) as? [[String: Any]],
      windows.contains(where: { window in
        (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
          == key.windowID
          && (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
          == key.pid
      })
    else { continue }
    existing.insert(key)
  }
  return existing
}

private func liveWindowTitles(
  _ keys: [WindowKey],
  isCancelled: @Sendable () -> Bool = { false },
) -> [WindowKey: String] {
  guard !keys.isEmpty, !isCancelled() else { return [:] }
  var out = [WindowKey: String]()
  for (pid, group) in Dictionary(grouping: keys, by: \.pid) {
    if isCancelled() { break }
    let axApp = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(axApp, 0.25)
    var raw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &raw) == .success,
      let windows = raw as? [AXUIElement]
    else { continue }
    var titleByWindowID = [CGWindowID: String]()
    for window in windows {
      if isCancelled() { break }
      AXUIElementSetMessagingTimeout(window, 0.25)
      var wid: CGWindowID = 0
      guard _AXUIElementGetWindow(window, &wid) == .success, wid != 0 else { continue }
      var titleRaw: CFTypeRef?
      if
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRaw) == .success,
        let title = titleRaw as? String, !title.isEmpty
      {
        titleByWindowID[wid] = title
      }
    }
    for key in group where titleByWindowID[key.windowID] != nil {
      out[key] = titleByWindowID[key.windowID]
    }
  }
  return out
}

private func liveWindowTitlesAsync(_ keys: [WindowKey]) async -> [WindowKey: String] {
  let cancellation = AXReadCancellationFlag()
  return await withTaskCancellationHandler {
    await withCheckedContinuation { continuation in
      windowMetadataAXQueue.async {
        continuation.resume(
          returning: cancellation.isCancelled
            ? [:]
            : liveWindowTitles(keys, isCancelled: { cancellation.isCancelled })
        )
      }
    }
  } onCancel: {
    cancellation.cancel()
  }
}

// MARK: - FrontmostApp

/// The frontmost regular app, as the activation reducer cares about it.
struct FrontmostApp: Equatable, Sendable {
  var pid: pid_t = 0
  var bundleId: String
  var name: String
}

// MARK: - AsyncWindowSnapshot

/// Async live endpoints are unavailable in lightweight dependency tests unless
/// explicitly stubbed. This wrapper distinguishes that from a real optional
/// result such as "there is no focused window".
enum AsyncWindowSnapshot<Value: Sendable>: Sendable {
  case unavailable
  case value(Value)
}

// MARK: - WindowKeyCacheLookup

/// Cache-only result that preserves the difference between an entry that has
/// never been scanned and an authoritative scan that found no eligible windows.
///
/// For a multi-bundle request, `.hit` means every requested bundle is warm;
/// one or more missing entries produce `.miss`.
enum WindowKeyCacheLookup: Equatable, Sendable {
  case miss
  case hit([WindowKey])
}

// MARK: - WindowCapabilitySnapshot

/// Keys derived from one AX capability enumeration. Resizable windows are
/// always a subset of movable windows, but both views are kept because tiled
/// and unmanaged workspace members use different eligibility rules.
struct WindowCapabilitySnapshot: Equatable, Sendable {
  var movableKeys: [WindowKey]
  var resizableKeys: [WindowKey]
}

// MARK: - WindowSnapshotClient

/// Live window/app state behind a testable dependency boundary. The synchronous
/// endpoints remain for lightweight tests and cache-only reducer reads; live
/// AX discovery, focus, frame, and title IPC use the async worker endpoints so
/// target apps can never block Tatami's main event loop.
@DependencyClient
struct WindowSnapshotClient: Sendable {
  /// All visible, regular, tile-able windows of the given bundle ids
  /// (see `discoverWindowKeys` for the filtering rules). A fresh AX scan
  /// that also refreshes `WindowKeyCache`, so every event-driven sync
  /// doubles as cache maintenance. Bundles whose app didn't answer (AX
  /// timeout) report their last-known keys instead of nothing.
  var discoverKeys:
    @Sendable (_ bundleIds: [String], _ requireResizable: Bool) -> [WindowKey] = { _, _ in [] }
  /// Async discovery for event-driven reconciliation. Only the AppKit process
  /// snapshot and cache commit touch `MainActor`; timeout-prone AX IPC runs on
  /// user-initiated per-PID workers and is single-flight per target process.
  var discoverKeysAsync:
    @Sendable (_ bundleIds: [String], _ requireResizable: Bool) async
    -> AsyncWindowSnapshot<[WindowKey]> = { _, _ in .unavailable }
  /// Combined discovery for a caller that needs both eligibility views. The
  /// live implementation performs one AX enumeration and refreshes both cache
  /// variants from that same snapshot.
  var discoverCapabilitiesAsync:
    @Sendable (_ bundleIds: [String]) async
    -> AsyncWindowSnapshot<WindowCapabilitySnapshot> = { _ in .unavailable }
  /// Synchronous cache-only snapshot for reducer computations. A miss returns
  /// no key and never falls through to AX IPC on the main actor; callers that
  /// require a warm-or-discover result use `cachedKeysAsync`.
  var cachedKeys:
    @Sendable (_ bundleIds: [String], _ requireResizable: Bool) -> [WindowKey] = { _, _ in [] }
  /// Async cache-only lookup. Unlike `cachedKeysAsync`, this endpoint never
  /// discovers through AX: `.miss` and `.hit([])` remain distinct so the caller
  /// explicitly owns any follow-up discovery policy.
  var cachedKeysOnlyAsync:
    @Sendable (_ bundleIds: [String], _ requireResizable: Bool) async
    -> WindowKeyCacheLookup = { _, _ in .miss }
  /// Async cache-first discovery for activation. Warm hits return immediately;
  /// only missing bundles cross to the AX worker.
  var cachedKeysAsync:
    @Sendable (_ bundleIds: [String], _ requireResizable: Bool) async
    -> AsyncWindowSnapshot<[WindowKey]> = { _, _ in .unavailable }
  /// Remove every cached window for a process that has terminated. This is an
  /// authoritative lifecycle signal, so activation must not serve its stale
  /// window ids while a later discovery catches up.
  var invalidateBundle: @Sendable (_ bundleId: String) -> Void = { _ in }
  /// Advance one bundle's discovery generation without discarding its
  /// last-known keys. Visibility edges use this to force an in-flight stale
  /// scan to run one trailing pass while preserving timeout fallback.
  var markBundleDirty: @Sendable (_ bundleId: String) -> Void = { _ in }
  /// Remove exact WindowServer ids confirmed destroyed or pruned off-screen.
  /// Keeps cache-first activation from briefly laying out a dead tile.
  var invalidateWindowIDs: @Sendable (_ windowIDs: Set<CGWindowID>) -> Void = { _ in }
  /// The `WindowKey` of the focused window of the frontmost app.
  var focusedWindowKey: @Sendable () -> WindowKey?
  /// Async focused-window resolution for effects and user-input paths. AppKit
  /// identity is captured briefly on `MainActor`; synchronous AX IPC runs on a
  /// per-process serial user-initiated worker.
  var focusedWindowKeyAsync:
    @Sendable () async -> AsyncWindowSnapshot<WindowKey?> = { .unavailable }
  var focusedWindowKeyForAppAsync:
    @Sendable (_ pid: pid_t, _ bundleId: String) async
    -> AsyncWindowSnapshot<WindowKey?> = { _, _ in .unavailable }
  /// Current AX frame for one exact window, including floating/unmanaged
  /// windows that have no entry in the BSP frame map.
  var windowFrame: @Sendable (_ key: WindowKey) -> CGRect? = { _ in nil }
  var windowFrameAsync:
    @Sendable (_ key: WindowKey) async -> AsyncWindowSnapshot<CGRect?> = { _ in .unavailable }
  /// Fresh geometry for every on-screen window from one WindowServer snapshot.
  /// This is local IPC rather than a per-app AX round trip.
  var onScreenWindowFrames: @Sendable () -> [CGWindowID: CGRect] = { [:] }
  /// The frontmost app (bundle id + localized name), if any.
  var frontmostApp: @Sendable () -> FrontmostApp?
  /// Window numbers of every window currently on screen.
  var onScreenWindowIDs: @Sendable () -> Set<CGWindowID> = { [] }
  /// Which exact cached/discovered identities still exist in WindowServer,
  /// including live hidden windows not yet published as on-screen.
  var existingWindowKeys:
    @Sendable (_ keys: [WindowKey]) -> Set<WindowKey> = { _ in [] }
  /// Bundle ids of every running app (any activation policy — the
  /// skip-empty cycle counts background-only members too).
  var runningBundleIds: @Sendable () -> Set<String> = { [] }
  /// AX window titles for the given keys, for the GUI layout preview to
  /// disambiguate several windows of the same app. Best-effort: windows that
  /// don't answer / have no title are simply absent from the result.
  var windowTitles: @Sendable (_ keys: [WindowKey]) -> [WindowKey: String] = { _ in [:] }
  var windowTitlesAsync:
    @Sendable (_ keys: [WindowKey]) async
    -> AsyncWindowSnapshot<[WindowKey: String]> = { _ in .unavailable }
}

extension WindowSnapshotClient {
  func discoverCapabilitiesOffMain(
    _ bundleIds: [String]
  ) async -> WindowCapabilitySnapshot {
    switch await discoverCapabilitiesAsync(bundleIds) {
    case .value(let snapshot):
      return snapshot
    case .unavailable:
      // Lightweight dependency tests commonly override only the established
      // per-mode API. Preserve that fallback contract for them.
      async let movableDiscovery = discoverKeysOffMain(bundleIds, false)
      async let resizableDiscovery = discoverKeysOffMain(bundleIds, true)
      let (movableKeys, resizableKeys) = await (
        movableDiscovery,
        resizableDiscovery,
      )
      return WindowCapabilitySnapshot(
        movableKeys: movableKeys,
        resizableKeys: resizableKeys,
      )
    }
  }

  func discoverKeysOffMain(
    _ bundleIds: [String],
    _ requireResizable: Bool,
  ) async -> [WindowKey] {
    switch await discoverKeysAsync(bundleIds, requireResizable) {
    case .value(let keys):
      keys
    case .unavailable:
      await MainActor.run {
        discoverKeys(bundleIds, requireResizable)
      }
    }
  }

  func cachedKeysOffMain(
    _ bundleIds: [String],
    _ requireResizable: Bool,
  ) async -> [WindowKey] {
    switch await cachedKeysAsync(bundleIds, requireResizable) {
    case .value(let keys):
      keys
    case .unavailable:
      await MainActor.run {
        cachedKeys(bundleIds, requireResizable)
      }
    }
  }

  func cachedKeysOnlyOffMain(
    _ bundleIds: [String],
    _ requireResizable: Bool,
  ) async -> WindowKeyCacheLookup {
    await cachedKeysOnlyAsync(bundleIds, requireResizable)
  }

  func focusedWindowKeyOffMain() async -> WindowKey? {
    switch await focusedWindowKeyAsync() {
    case .value(let key):
      key
    case .unavailable:
      await MainActor.run {
        focusedWindowKey()
      }
    }
  }

  func focusedWindowKeyOffMain(_ app: FrontmostApp) async -> WindowKey? {
    switch await focusedWindowKeyForAppAsync(app.pid, app.bundleId) {
    case .value(let key):
      key
    case .unavailable:
      await MainActor.run {
        focusedWindowKey()
      }
    }
  }

  func windowFrameOffMain(_ key: WindowKey) async -> CGRect? {
    switch await windowFrameAsync(key) {
    case .value(let frame):
      frame
    case .unavailable:
      await MainActor.run {
        windowFrame(key)
      }
    }
  }

  func windowTitlesOffMain(_ keys: [WindowKey]) async -> [WindowKey: String] {
    switch await windowTitlesAsync(keys) {
    case .value(let titles):
      titles
    case .unavailable:
      await MainActor.run {
        windowTitles(keys)
      }
    }
  }
}

// MARK: DependencyKey

extension WindowSnapshotClient: DependencyKey {
  static let liveValue: WindowSnapshotClient = {
    let cache = MainActor.assumeIsolated { WindowKeyCache() }
    let discoveryCoordinator = WindowDiscoveryCoordinator()
    return WindowSnapshotClient(
      discoverKeys: { bundleIds, requireResizable in
        MainActor.assumeIsolated {
          @Dependency(\.sls) var sls
          let discovery = discoverWindowCapabilities(
            forBundleIds: bundleIds,
            sls: sls,
          )
          let snapshot = cache.storeAndResolve(
            discovery,
            bundleIds: bundleIds,
          )
          return requireResizable ? snapshot.resizableKeys : snapshot.movableKeys
        }
      },
      discoverKeysAsync: { bundleIds, requireResizable in
        let request = await MainActor.run {
          let scanStartEpoch = cache.currentInvalidationEpoch
          return makeWindowDiscoveryRequest(
            bundleIds: bundleIds,
            scanStartEpoch: scanStartEpoch,
            invalidationGenerations: cache.invalidationGenerations(
              for: bundleIds
            ),
          )
        }
        @Dependency(\.sls) var sls
        let capabilityDiscovery: WindowCapabilityDiscovery
        do {
          capabilityDiscovery = try await discoveryCoordinator.discover(
            request,
            sls: sls,
          )
        } catch {
          return await MainActor.run {
            .value(cache.resolvedCachedKeys(
              bundleIds,
              requireResizable: requireResizable,
            ))
          }
        }
        return await MainActor.run {
          let snapshot = cache.storeAndResolve(
            capabilityDiscovery,
            bundleIds: bundleIds,
            ifUnchangedSince: request.scanStartEpoch,
          )
          return .value(
            requireResizable ? snapshot.resizableKeys : snapshot.movableKeys
          )
        }
      },
      discoverCapabilitiesAsync: { bundleIds in
        let request = await MainActor.run {
          let scanStartEpoch = cache.currentInvalidationEpoch
          return makeWindowDiscoveryRequest(
            bundleIds: bundleIds,
            scanStartEpoch: scanStartEpoch,
            invalidationGenerations: cache.invalidationGenerations(
              for: bundleIds
            ),
          )
        }
        @Dependency(\.sls) var sls
        let capabilityDiscovery: WindowCapabilityDiscovery
        do {
          capabilityDiscovery = try await discoveryCoordinator.discover(
            request,
            sls: sls,
          )
        } catch {
          return await MainActor.run {
            .value(WindowCapabilitySnapshot(
              movableKeys: cache.resolvedCachedKeys(
                bundleIds,
                requireResizable: false,
              ),
              resizableKeys: cache.resolvedCachedKeys(
                bundleIds,
                requireResizable: true,
              ),
            ))
          }
        }
        return await MainActor.run {
          .value(cache.storeAndResolve(
            capabilityDiscovery,
            bundleIds: bundleIds,
            ifUnchangedSince: request.scanStartEpoch,
          ))
        }
      },
      cachedKeys: { bundleIds, requireResizable in
        MainActor.assumeIsolated {
          cache.resolvedCachedKeys(
            bundleIds,
            requireResizable: requireResizable,
          )
        }
      },
      cachedKeysOnlyAsync: { bundleIds, requireResizable in
        await MainActor.run {
          guard
            let keys = cache.cached(
              bundleIds,
              requireResizable: requireResizable,
            )
          else { return .miss }
          return .hit(keys)
        }
      },
      cachedKeysAsync: { bundleIds, requireResizable in
        let missing = await MainActor.run {
          cache.missingBundleIds(
            bundleIds,
            requireResizable: requireResizable,
          )
        }
        if missing.isEmpty {
          return await MainActor.run {
            .value(cache.resolvedCachedKeys(
              bundleIds,
              requireResizable: requireResizable,
            ))
          }
        }

        let request = await MainActor.run {
          let scanStartEpoch = cache.currentInvalidationEpoch
          return makeWindowDiscoveryRequest(
            bundleIds: missing,
            scanStartEpoch: scanStartEpoch,
            invalidationGenerations: cache.invalidationGenerations(
              for: missing
            ),
          )
        }
        @Dependency(\.sls) var sls
        let capabilityDiscovery: WindowCapabilityDiscovery
        do {
          capabilityDiscovery = try await discoveryCoordinator.discover(
            request,
            sls: sls,
          )
        } catch {
          return await MainActor.run {
            .value(cache.resolvedCachedKeys(
              bundleIds,
              requireResizable: requireResizable,
            ))
          }
        }
        return await MainActor.run {
          _ = cache.storeAndResolve(
            capabilityDiscovery,
            bundleIds: missing,
            ifUnchangedSince: request.scanStartEpoch,
          )
          return .value(cache.resolvedCachedKeys(
            bundleIds,
            requireResizable: requireResizable,
          ))
        }
      },
      invalidateBundle: { bundleId in
        MainActor.assumeIsolated { cache.invalidate(bundleId: bundleId) }
      },
      markBundleDirty: { bundleId in
        MainActor.assumeIsolated { cache.markDirty(bundleId: bundleId) }
      },
      invalidateWindowIDs: { windowIDs in
        MainActor.assumeIsolated { cache.invalidate(windowIDs: windowIDs) }
      },
      focusedWindowKey: {
        MainActor.assumeIsolated { liveFocusedWindowKey() }
      },
      focusedWindowKeyAsync: {
        .value(await liveFocusedWindowKeyAsync())
      },
      focusedWindowKeyForAppAsync: { pid, bundleId in
        .value(await resolveFocusedWindowKeyAsync(
          FrontmostAppIdentity(pid: pid, bundleId: bundleId)
        ))
      },
      windowFrame: { key in
        MainActor.assumeIsolated { liveWindowFrame(key) }
      },
      windowFrameAsync: { key in
        .value(await liveWindowFrameAsync(key))
      },
      onScreenWindowFrames: {
        currentOnScreenWindowFrames()
      },
      frontmostApp: {
        MainActor.assumeIsolated {
          NSWorkspace.shared.frontmostApplication.flatMap { app in
            guard let bundleId = app.bundleIdentifier, !bundleId.isEmpty else { return nil }
            return FrontmostApp(
              pid: app.processIdentifier,
              bundleId: bundleId,
              name: app.localizedName ?? "",
            )
          }
        }
      },
      onScreenWindowIDs: {
        let raw = CGWindowListCopyWindowInfo(
          [.optionOnScreenOnly, .excludeDesktopElements],
          kCGNullWindowID,
        ) as? [[String: Any]] ?? []
        var ids = Set<CGWindowID>()
        for entry in raw {
          if let n = entry[kCGWindowNumber as String] as? CGWindowID { ids.insert(n) }
        }
        return ids
      },
      existingWindowKeys: { keys in
        liveExistingWindowKeys(keys)
      },
      runningBundleIds: {
        MainActor.assumeIsolated {
          Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        }
      },
      windowTitles: { keys in
        MainActor.assumeIsolated { liveWindowTitles(keys) }
      },
      windowTitlesAsync: { keys in
        .value(await liveWindowTitlesAsync(keys))
      },
    )
  }()

  static let testValue = WindowSnapshotClient(
    discoverKeys: { _, _ in [] },
    discoverKeysAsync: { _, _ in .unavailable },
    discoverCapabilitiesAsync: { _ in .unavailable },
    cachedKeys: { _, _ in [] },
    cachedKeysOnlyAsync: { _, _ in .miss },
    cachedKeysAsync: { _, _ in .unavailable },
    invalidateBundle: { _ in },
    markBundleDirty: { _ in },
    invalidateWindowIDs: { _ in },
    focusedWindowKey: { nil },
    focusedWindowKeyAsync: { .unavailable },
    focusedWindowKeyForAppAsync: { _, _ in .unavailable },
    windowFrame: { _ in nil },
    windowFrameAsync: { _ in .unavailable },
    onScreenWindowFrames: { [:] },
    frontmostApp: { nil },
    onScreenWindowIDs: { [] },
    existingWindowKeys: { _ in [] },
    runningBundleIds: { [] },
    windowTitles: { _ in [:] },
    windowTitlesAsync: { _ in .unavailable },
  )
  static let previewValue = testValue
}

// MARK: - WindowKeyCache

/// Last-known `discoverWindowKeys` result per (bundle id, resizability).
///
/// Every AX discovery call is a synchronous IPC round trip serviced by
/// the *target app's* run loop — there is no async AX API — so under
/// system load a single rescan of all registered apps costs hundreds of
/// milliseconds on the main thread (measured: 50–120 ms idle, 1.2 s+
/// spikes). The cache removes that scan from the activation hot path.
///
/// Freshness is maintained by the paths that already learn about window
/// changes: every observer-driven reconciliation (window create/destroy,
/// miniaturize, app lifecycle, Space change, wake) refreshes this cache, while
/// observer installation emits one synthetic reconcile to close the arming
/// race. Activation serves warm entries immediately and resolves only misses
/// on the AX worker. An app whose bundle was never scanned is a miss, never a
/// stale hit.
@MainActor
final class WindowKeyCache {

  // MARK: Internal

  /// Async discovery captures this monotonic epoch. Commit checks are scoped
  /// to the bundle and exact window ids that changed, so an unrelated app's
  /// invalidation cannot discard an otherwise valid scan.
  private(set) var currentInvalidationEpoch: UInt64 = 0

  func cached(_ bundleId: String, requireResizable: Bool) -> [WindowKey]? {
    entries[Key(bundleId: bundleId, requireResizable: requireResizable)]
  }

  /// Return the requested bundles in caller order only when every entry is
  /// warm. A single miss stays distinguishable from a cached empty result.
  func cached(
    _ bundleIds: [String],
    requireResizable: Bool,
  ) -> [WindowKey]? {
    var result = [WindowKey]()
    for bundleId in bundleIds {
      guard let keys = cached(bundleId, requireResizable: requireResizable)
      else { return nil }
      result += keys
    }
    return result
  }

  func missingBundleIds(
    _ bundleIds: [String],
    requireResizable: Bool,
  ) -> [String] {
    bundleIds.filter {
      cached($0, requireResizable: requireResizable) == nil
    }
  }

  func resolvedCachedKeys(
    _ bundleIds: [String],
    requireResizable: Bool,
  ) -> [WindowKey] {
    bundleIds.flatMap {
      cached($0, requireResizable: requireResizable) ?? []
    }
  }

  func invalidationGeneration(for bundleIds: [String]) -> UInt64 {
    bundleIds.reduce(unknownWindowInvalidationEpoch) {
      max($0, bundleInvalidationEpoch[$1, default: 0])
    }
  }

  func invalidationGenerations(
    for bundleIds: [String]
  ) -> [String: UInt64] {
    var generations = [String: UInt64]()
    for bundleId in bundleIds {
      generations[bundleId] = invalidationGeneration(for: [bundleId])
    }
    return generations
  }

  func invalidate(bundleId: String) {
    currentInvalidationEpoch &+= 1
    bundleInvalidationEpoch[bundleId] = currentInvalidationEpoch
    let keys = entries.keys.filter { $0.bundleId == bundleId }
    guard !keys.isEmpty else { return }
    for key in keys { entries[key] = nil }
    publishManagedWindows()
  }

  /// Record a visibility/membership edge without throwing away last-known
  /// identities. An AX timeout after unhide can then still serve the cache,
  /// while scans that began before this edge are rejected and refreshed.
  func markDirty(bundleId: String) {
    currentInvalidationEpoch &+= 1
    bundleInvalidationEpoch[bundleId] = currentInvalidationEpoch
  }

  func invalidate(windowIDs: Set<CGWindowID>) {
    guard !windowIDs.isEmpty else { return }
    currentInvalidationEpoch &+= 1
    var matchedWindowIDs = Set<CGWindowID>()
    var affectedBundleIds = Set<String>()
    for (key, cachedKeys) in entries {
      let matches = cachedKeys.filter { windowIDs.contains($0.windowID) }
      if !matches.isEmpty {
        affectedBundleIds.insert(key.bundleId)
        matchedWindowIDs.formUnion(matches.map(\.windowID))
      }
    }
    for bundleId in affectedBundleIds {
      bundleInvalidationEpoch[bundleId] = currentInvalidationEpoch
    }
    if !windowIDs.isSubset(of: matchedWindowIDs) {
      // An id that was never cached may still belong to an in-flight scan.
      // Treat only that ambiguous case as relevant to every request.
      unknownWindowInvalidationEpoch = currentInvalidationEpoch
    }
    for windowID in windowIDs {
      windowInvalidationEpoch[windowID] = currentInvalidationEpoch
    }
    if windowInvalidationEpoch.count > 4_096 {
      let oldest = windowInvalidationEpoch
        .sorted { $0.value < $1.value }
        .prefix(windowInvalidationEpoch.count - 4_096)
      for (windowID, epoch) in oldest {
        evictedWindowInvalidationFloor = max(evictedWindowInvalidationFloor, epoch)
        windowInvalidationEpoch[windowID] = nil
      }
    }
    var changed = false
    for key in Array(entries.keys) {
      let cached = entries[key] ?? []
      let filtered = cached.filter { !windowIDs.contains($0.windowID) }
      guard filtered.count != cached.count else { continue }
      // Destroying the last known surface is not an authoritative answer that
      // the app has no windows forever. Apps such as KakaoTalk replace their
      // WindowServer surface while hidden; leaving `[]` warm here prevents the
      // next cache-first Borrow from ever discovering the replacement.
      entries[key] = filtered.isEmpty ? nil : filtered
      changed = true
    }
    if changed { publishManagedWindows() }
  }

  /// Store a fresh scan's result for every *requested* bundle id — a
  /// bundle that returned no windows (not running, all minimized) caches
  /// an empty list, so the next read doesn't rescan it. Unreachable
  /// bundles (AX timeout) keep their previous entry: a timeout is not an
  /// answer, and overwriting with nothing would poison every consumer
  /// until the app recovers.
  func store(_ discovery: WindowDiscovery, bundleIds: [String], requireResizable: Bool) {
    let grouped = Dictionary(grouping: discovery.keys, by: \.bundleId)
    for bundleId in bundleIds where !discovery.unreachable.contains(bundleId) {
      let cacheKey = Key(bundleId: bundleId, requireResizable: requireResizable)
      var fresh = grouped[bundleId] ?? []
      // A window that only flapped its subrole this pass is still enumerated,
      // so keep its last-known key rather than overwriting it away — the same
      // "couldn't classify ≠ closed" guarantee `unreachable` gives a whole
      // bundle, applied per window. It re-validates on the next clean scan.
      if !discovery.retained.isEmpty {
        let freshIDs = Set(fresh.map(\.windowID))
        fresh += (entries[cacheKey] ?? []).filter {
          discovery.retained.contains($0.windowID) && !freshIDs.contains($0.windowID)
        }
      }
      entries[cacheKey] = fresh
    }
    publishManagedWindows()
  }

  /// Commit a discovery and read the resulting authoritative cache entries.
  /// `store` preserves prior keys for unreachable bundles and transient
  /// subrole flaps, so resolving from the cache avoids duplicating that
  /// correctness policy in the synchronous and async call paths.
  func storeAndResolve(
    _ discovery: WindowDiscovery,
    bundleIds: [String],
    requireResizable: Bool,
    ifUnchangedSince expectedInvalidationEpoch: UInt64? = nil,
  ) -> [WindowKey] {
    var eligibleDiscovery = discovery
    var eligibleBundleIds = bundleIds
    if let expectedInvalidationEpoch {
      eligibleBundleIds = bundleIds.filter {
        bundleInvalidationEpoch[$0, default: 0] <= expectedInvalidationEpoch
      }
      let eligibleBundles = Set(eligibleBundleIds)
      eligibleDiscovery.keys = discovery.keys.filter {
        eligibleBundles.contains($0.bundleId)
          && invalidationEpoch(for: $0.windowID) <= expectedInvalidationEpoch
      }
      eligibleDiscovery.unreachable = discovery.unreachable.intersection(eligibleBundles)
      eligibleDiscovery.retained = Set(discovery.retained.filter {
        invalidationEpoch(for: $0) <= expectedInvalidationEpoch
      })
    }
    if
      eligibleBundleIds.count != bundleIds.count
      || eligibleDiscovery.keys.count != discovery.keys.count
    {
      @Dependency(\.debugLog) var debugLog
      debugLog.log(
        "Tiler",
        "filtered stale discovery after cache invalidation: \(bundleIds)",
      )
    }
    store(
      eligibleDiscovery,
      bundleIds: eligibleBundleIds,
      requireResizable: requireResizable,
    )
    if !eligibleDiscovery.unreachable.isEmpty {
      @Dependency(\.debugLog) var debugLog
      for bundleId in eligibleDiscovery.unreachable {
        let stale = cached(bundleId, requireResizable: requireResizable) ?? []
        debugLog.log(
          "Tiler",
          "\(bundleId) unreachable (AX timeout) — serving \(stale.count) cached keys",
        )
      }
    }
    return resolvedCachedKeys(
      bundleIds,
      requireResizable: requireResizable,
    )
  }

  /// Commit both eligibility views from one capability-complete scan. Applying
  /// the same invalidation epoch to each view keeps them coherent while still
  /// returning the exact per-mode cache result (including retained/unreachable
  /// preservation).
  func storeAndResolve(
    _ discovery: WindowCapabilityDiscovery,
    bundleIds: [String],
    ifUnchangedSince expectedInvalidationEpoch: UInt64? = nil,
  ) -> WindowCapabilitySnapshot {
    let movableKeys = storeAndResolve(
      discovery.discovery(requireResizable: false),
      bundleIds: bundleIds,
      requireResizable: false,
      ifUnchangedSince: expectedInvalidationEpoch,
    )
    let resizableKeys = storeAndResolve(
      discovery.discovery(requireResizable: true),
      bundleIds: bundleIds,
      requireResizable: true,
      ifUnchangedSince: expectedInvalidationEpoch,
    )
    return WindowCapabilitySnapshot(
      movableKeys: movableKeys,
      resizableKeys: resizableKeys,
    )
  }

  // MARK: Private

  private struct Key: Hashable {
    var bundleId: String
    var requireResizable: Bool
  }

  private var entries = [Key: [WindowKey]]()
  private var bundleInvalidationEpoch = [String: UInt64]()
  private var windowInvalidationEpoch = [CGWindowID: UInt64]()
  /// Exact tombstones are capped, but an old in-flight scan must not resurrect
  /// an id whose tombstone was evicted. For scans older than this conservative
  /// floor, an unknown id is rejected; scans started afterwards remain valid.
  private var evictedWindowInvalidationFloor: UInt64 = 0
  private var unknownWindowInvalidationEpoch: UInt64 = 0
  /// Last id set handed to `setManaged` / `sls.watchWindows`. An unchanged
  /// window population — the common case, since most discoveries (focus
  /// change, resize, front-switch reconcile) add or remove nothing — skips
  /// the redundant Set copy under lock and the SLS re-subscribe.
  private var lastPublishedIDs = Set<CGWindowID>()

  private func invalidationEpoch(for windowID: CGWindowID) -> UInt64 {
    windowInvalidationEpoch[windowID] ?? evictedWindowInvalidationFloor
  }

  /// Republish the managed-window id set for the FFM hit-test. Every
  /// discovery funnels through `store`, keeping the snapshot in step.
  private func publishManagedWindows() {
    let ids = Set(entries.values.flatMap { $0 }.map(\.windowID))
    // Both sinks are idempotent "set state to this" calls; when the id set is
    // unchanged the previous publish already left them in this exact state.
    guard ids != lastPublishedIDs else { return }
    lastPublishedIDs = ids
    @Dependency(\.managedWindows) var managedWindows
    @Dependency(\.sls) var sls
    managedWindows.setManaged(ids)
    // Subscribe the same set to WindowServer destruction events so a
    // hide-on-close window (no AX destroy, e.g. KakaoTalk) still gets
    // reclaimed.
    sls.watchWindows(Array(ids))
  }

}

// MARK: - WindowDiscoveryCancellation

struct WindowDiscoveryCancellation: Sendable {

  // MARK: Lifecycle

  init(_ isCancelled: @escaping @Sendable () -> Bool) {
    checkCancellation = isCancelled
  }

  // MARK: Internal

  var isCancelled: Bool {
    checkCancellation()
  }

  // MARK: Private

  private let checkCancellation: @Sendable () -> Bool

}

// MARK: - AXReadCancellationFlag

private final class AXReadCancellationFlag: @unchecked Sendable {

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

extension DependencyValues {
  var windowSnapshot: WindowSnapshotClient {
    get { self[WindowSnapshotClient.self] }
    set { self[WindowSnapshotClient.self] = newValue }
  }
}
