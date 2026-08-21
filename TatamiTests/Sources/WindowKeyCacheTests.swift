// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import CoreGraphics
import Dependencies
import Testing
@testable import TatamiKit

// MARK: - WindowKeyCacheTests

@MainActor
struct WindowKeyCacheTests {

  // MARK: Internal

  @Test
  func `authoritative invalidation removes stale windows from every cache variant`() {
    let ghostty = WindowKey(pid: 1, windowID: 101, bundleId: "com.mitchellh.ghostty")
    let alacritty = WindowKey(pid: 2, windowID: 202, bundleId: "org.alacritty")
    let published = LockIsolated<[Set<CGWindowID>]>([])

    withDependencies {
      $0.managedWindows.setManaged = { ids in
        published.withValue { $0.append(ids) }
      }
      $0.sls.watchWindows = { _ in }
    } operation: {
      let cache = WindowKeyCache()
      let discovery = WindowDiscovery(keys: [ghostty, alacritty])
      let bundleIds = [ghostty.bundleId, alacritty.bundleId]
      cache.store(discovery, bundleIds: bundleIds, requireResizable: true)
      cache.store(discovery, bundleIds: bundleIds, requireResizable: false)

      cache.invalidate(windowIDs: [ghostty.windowID])

      #expect(cache.cached(ghostty.bundleId, requireResizable: true) == nil)
      #expect(cache.cached(ghostty.bundleId, requireResizable: false) == nil)
      #expect(cache.cached(alacritty.bundleId, requireResizable: true) == [alacritty])
      #expect(published.value.last == [alacritty.windowID])

      cache.invalidate(bundleId: alacritty.bundleId)

      #expect(cache.cached(alacritty.bundleId, requireResizable: true) == nil)
      #expect(cache.cached(alacritty.bundleId, requireResizable: false) == nil)
      #expect(published.value.last == [])
    }
  }

  @Test
  func `unrelated bundle invalidation does not discard valid discovery`() {
    withNoopPublicationDependencies {
      let cache = WindowKeyCache()
      let fresh = WindowKey(pid: 1, windowID: 101, bundleId: "app.a")
      let scanEpoch = cache.currentInvalidationEpoch
      let generation = cache.invalidationGeneration(for: [fresh.bundleId])

      cache.invalidate(bundleId: "app.b")
      #expect(cache.invalidationGeneration(for: [fresh.bundleId]) == generation)
      let resolved = cache.storeAndResolve(
        WindowDiscovery(keys: [fresh]),
        bundleIds: [fresh.bundleId],
        requireResizable: true,
        ifUnchangedSince: scanEpoch,
      )

      #expect(resolved == [fresh])
      #expect(cache.cached(fresh.bundleId, requireResizable: true) == [fresh])
    }
  }

  @Test
  func `capability discovery populates both variants with the same invalidation epoch`() {
    withNoopPublicationDependencies {
      let cache = WindowKeyCache()
      let bundleId = "app.capabilities"
      let stale = WindowKey(pid: 1, windowID: 101, bundleId: bundleId)
      let fixedSize = WindowKey(pid: 1, windowID: 102, bundleId: bundleId)
      let flexible = WindowKey(pid: 1, windowID: 103, bundleId: bundleId)
      let scanEpoch = cache.currentInvalidationEpoch

      cache.invalidate(windowIDs: [stale.windowID])
      let resolved = cache.storeAndResolve(
        WindowCapabilityDiscovery(
          movableKeys: [stale, fixedSize, flexible],
          resizableKeys: [stale, flexible],
        ),
        bundleIds: [bundleId],
        ifUnchangedSince: scanEpoch,
      )

      #expect(resolved.movableKeys == [fixedSize, flexible])
      #expect(resolved.resizableKeys == [flexible])
      #expect(cache.cached(bundleId, requireResizable: false) == [fixedSize, flexible])
      #expect(cache.cached(bundleId, requireResizable: true) == [flexible])
    }
  }

  @Test
  func `matching invalidations win over older discovery`() {
    withNoopPublicationDependencies {
      let cache = WindowKeyCache()
      let destroyed = WindowKey(pid: 1, windowID: 101, bundleId: "app.a")
      let survivor = WindowKey(pid: 1, windowID: 102, bundleId: "app.a")
      let scanEpoch = cache.currentInvalidationEpoch
      let generation = cache.invalidationGeneration(for: [destroyed.bundleId])

      cache.invalidate(windowIDs: [destroyed.windowID])
      #expect(cache.invalidationGeneration(for: [destroyed.bundleId]) > generation)
      let resolved = cache.storeAndResolve(
        WindowDiscovery(keys: [destroyed, survivor]),
        bundleIds: [destroyed.bundleId],
        requireResizable: true,
        ifUnchangedSince: scanEpoch,
      )

      #expect(resolved == [survivor])

      let laterScanEpoch = cache.currentInvalidationEpoch
      cache.invalidate(bundleId: destroyed.bundleId)
      let staleBundleResult = cache.storeAndResolve(
        WindowDiscovery(keys: [survivor]),
        bundleIds: [destroyed.bundleId],
        requireResizable: true,
        ifUnchangedSince: laterScanEpoch,
      )

      #expect(staleBundleResult.isEmpty)
      #expect(cache.cached(destroyed.bundleId, requireResizable: true) == nil)
    }
  }

  @Test
  func `visibility dirty mark preserves fallback and rejects an older scan`() {
    withNoopPublicationDependencies {
      let cache = WindowKeyCache()
      let bundleId = "com.kakao.KakaoTalkMac"
      let cached = WindowKey(pid: 1, windowID: 101, bundleId: bundleId)
      let replacement = WindowKey(pid: 1, windowID: 102, bundleId: bundleId)
      cache.store(
        WindowDiscovery(keys: [cached]),
        bundleIds: [bundleId],
        requireResizable: true,
      )
      let staleScanEpoch = cache.currentInvalidationEpoch
      let oldGeneration = cache.invalidationGeneration(for: [bundleId])

      cache.markDirty(bundleId: bundleId)

      #expect(cache.invalidationGeneration(for: [bundleId]) > oldGeneration)
      #expect(cache.cached(bundleId, requireResizable: true) == [cached])
      let staleResult = cache.storeAndResolve(
        WindowDiscovery(keys: [replacement]),
        bundleIds: [bundleId],
        requireResizable: true,
        ifUnchangedSince: staleScanEpoch,
      )
      #expect(staleResult == [cached])
      #expect(cache.cached(bundleId, requireResizable: true) == [cached])

      let freshResult = cache.storeAndResolve(
        WindowDiscovery(keys: [replacement]),
        bundleIds: [bundleId],
        requireResizable: true,
        ifUnchangedSince: cache.currentInvalidationEpoch,
      )
      #expect(freshResult == [replacement])
    }
  }

  @Test
  func `window id lookup preserves the owner needed by a visible edge`() {
    withNoopPublicationDependencies {
      let cache = WindowKeyCache()
      let key = WindowKey(
        pid: 1,
        windowID: 101,
        bundleId: "com.cron.electron",
      )

      cache.store(
        WindowDiscovery(keys: [key]),
        bundleIds: [key.bundleId],
        requireResizable: true,
      )

      #expect(cache.cachedKey(windowID: key.windowID) == key)
      #expect(cache.cachedKey(windowID: 999) == nil)
    }
  }

  @Test
  func `evicted exact tombstone still blocks an older discovery`() {
    withNoopPublicationDependencies {
      let cache = WindowKeyCache()
      let stale = WindowKey(pid: 1, windowID: 101, bundleId: "app.a")
      let scanEpoch = cache.currentInvalidationEpoch

      cache.invalidate(windowIDs: [stale.windowID])
      for windowID in CGWindowID(1_000)...CGWindowID(5_096) {
        cache.invalidate(windowIDs: [windowID])
      }

      let resolved = cache.storeAndResolve(
        WindowDiscovery(keys: [stale]),
        bundleIds: [stale.bundleId],
        requireResizable: true,
        ifUnchangedSince: scanEpoch,
      )

      #expect(resolved.isEmpty)
      #expect(cache.cached(stale.bundleId, requireResizable: true) == [])
    }
  }

  @Test
  func `cache lookup distinguishes a miss from a warm empty entry`() {
    withNoopPublicationDependencies {
      let cache = WindowKeyCache()
      let bundleId = "app.cache-only"

      #expect(cache.cached([bundleId], requireResizable: true) == nil)

      cache.store(
        WindowDiscovery(),
        bundleIds: [bundleId],
        requireResizable: true,
      )

      #expect(cache.cached([bundleId], requireResizable: true) == [])
      #expect(cache.cached([bundleId, "app.missing"], requireResizable: true) == nil)
    }
  }

  @Test
  func `async cache-only helper preserves warm empty without discovery fallback`() async {
    var client = WindowSnapshotClient.testValue
    client.cachedKeysOnlyAsync = { bundleIds, requireResizable in
      #expect(requireResizable)
      return bundleIds == ["app.warm-empty"] ? .hit([]) : .miss
    }

    let warm = await client.cachedKeysOnlyOffMain(["app.warm-empty"], true)
    let miss = await client.cachedKeysOnlyOffMain(["app.missing"], true)

    #expect(warm == .hit([]))
    #expect(miss == .miss)
  }

  @Test
  func `stable cache-first helper retries only an invalidated cold scan`() async {
    let recovered = WindowKey(pid: 42, windowID: 101, bundleId: "app.invalidated")
    let freshDiscoveries = LockIsolated(0)
    var invalidatedClient = WindowSnapshotClient.testValue
    invalidatedClient.cachedKeysAsync = { _, _ in .value([]) }
    invalidatedClient.cachedKeysOnlyAsync = { _, _ in .miss }
    invalidatedClient.discoverKeysAsync = { _, requireResizable in
      #expect(requireResizable)
      freshDiscoveries.withValue { $0 += 1 }
      return .value([recovered])
    }

    let keys = await invalidatedClient.stableCachedKeysOffMain(
      [recovered.bundleId],
      true,
    )

    #expect(keys == [recovered])
    #expect(freshDiscoveries.value == 1)

    var warmEmptyClient = WindowSnapshotClient.testValue
    warmEmptyClient.cachedKeysAsync = { _, _ in .value([]) }
    warmEmptyClient.cachedKeysOnlyAsync = { _, _ in .hit([]) }
    warmEmptyClient.discoverKeysAsync = { _, _ in
      freshDiscoveries.withValue { $0 += 1 }
      return .value([recovered])
    }

    let empty = await warmEmptyClient.stableCachedKeysOffMain(
      ["app.warm-empty"],
      true,
    )

    #expect(empty.isEmpty)
    #expect(freshDiscoveries.value == 1)
  }

  @Test
  func `capability consumers share one PID scan without an automatic trailing refresh`() async
    throws
  {
    let process = WindowDiscoveryRequest.Process(
      bundleId: "app.shared",
      pid: 42,
    )
    let probe = WindowDiscoveryScanProbe()
    let coordinator = makeDiscoveryCoordinator(probe)
    let request = discoveryRequest([process], invalidationGeneration: 7)

    let movableTask = Task {
      try await coordinator.discover(request, sls: .testValue)
    }
    await probe.waitForCallCount(1)

    let resizableTask = Task {
      try await coordinator.discover(request, sls: .testValue)
    }
    let joined = await waitForWaiters(
      2,
      process: process,
      coordinator: coordinator,
    )
    await probe.releaseFirstScan()

    let movable = try await movableTask.value
      .discovery(requireResizable: false)
      .keys
    let resizable = try await resizableTask.value
      .discovery(requireResizable: true)
      .keys

    #expect(joined)
    #expect(await probe.recordedCalls() == [
      WindowDiscoveryScanProbe.Call(
        process: process,
        invalidationGeneration: 7,
      )
    ])
    #expect(movable.count == 2)
    #expect(resizable.count == 1)
  }

  @Test
  func `new PID invalidation queues exactly one trailing scan`() async throws {
    let process = WindowDiscoveryRequest.Process(
      bundleId: "app.invalidated",
      pid: 43,
    )
    let probe = WindowDiscoveryScanProbe()
    let coordinator = makeDiscoveryCoordinator(probe)
    let firstRequest = discoveryRequest(
      [process],
      invalidationGeneration: 10,
    )
    let refreshedRequest = discoveryRequest(
      [process],
      invalidationGeneration: 11,
    )

    let firstTask = Task {
      try await coordinator.discover(firstRequest, sls: .testValue)
    }
    await probe.waitForCallCount(1)

    let refreshedTask = Task {
      try await coordinator.discover(refreshedRequest, sls: .testValue)
    }
    let joined = await waitForWaiters(
      2,
      process: process,
      coordinator: coordinator,
    )
    await probe.releaseFirstScan()
    await probe.waitForCallCount(2)

    let firstResult = try await firstTask.value
    let refreshedResult = try await refreshedTask.value
    let expectedWindowID = CGWindowID(111)

    #expect(joined)
    #expect(await probe.recordedCalls().map(\.invalidationGeneration) == [10, 11])
    #expect(firstResult.movableKeys.first?.windowID == expectedWindowID)
    #expect(refreshedResult.movableKeys.first?.windowID == expectedWindowID)
  }

  @Test
  func `overlapping bundle requests share only the common PID flight`() async throws {
    let shared = WindowDiscoveryRequest.Process(
      bundleId: "app.shared",
      pid: 44,
    )
    let independent = WindowDiscoveryRequest.Process(
      bundleId: "app.independent",
      pid: 45,
    )
    let probe = WindowDiscoveryScanProbe()
    let coordinator = makeDiscoveryCoordinator(probe)
    let sharedRequest = discoveryRequest(
      [shared],
      invalidationGeneration: 20,
    )
    let overlappingRequest = discoveryRequest(
      [shared, independent],
      invalidationGeneration: 20,
    )

    let sharedTask = Task {
      try await coordinator.discover(sharedRequest, sls: .testValue)
    }
    await probe.waitForCallCount(1)

    let overlappingTask = Task {
      try await coordinator.discover(overlappingRequest, sls: .testValue)
    }
    let joined = await waitForWaiters(
      2,
      process: shared,
      coordinator: coordinator,
    )
    await probe.releaseFirstScan()

    _ = try await sharedTask.value
    let overlapping = try await overlappingTask.value
    let calls = await probe.recordedCalls()

    #expect(joined)
    #expect(calls.count(where: { $0.process == shared }) == 1)
    #expect(calls.count(where: { $0.process == independent }) == 1)
    #expect(Set(overlapping.movableKeys.map(\.bundleId)) == [
      shared.bundleId,
      independent.bundleId,
    ])
  }

  // MARK: Private

  private func discoveryRequest(
    _ processes: [WindowDiscoveryRequest.Process],
    invalidationGeneration: UInt64,
  ) -> WindowDiscoveryRequest {
    var generations = [String: UInt64]()
    for process in processes {
      generations[process.bundleId] = invalidationGeneration
    }
    return WindowDiscoveryRequest(
      processes: processes,
      scanStartEpoch: invalidationGeneration,
      invalidationGenerations: generations,
    )
  }

  private func makeDiscoveryCoordinator(
    _ probe: WindowDiscoveryScanProbe
  ) -> WindowDiscoveryCoordinator {
    WindowDiscoveryCoordinator {
      process,
      invalidationGeneration,
      _,
      cancellation in
      await probe.scan(
        process: process,
        invalidationGeneration: invalidationGeneration,
        cancellation: cancellation,
      )
    }
  }

  private func waitForWaiters(
    _ expectedCount: Int,
    process: WindowDiscoveryRequest.Process,
    coordinator: WindowDiscoveryCoordinator,
  ) async -> Bool {
    for _ in 0..<10_000 {
      if await coordinator.inFlightWaiterCount(for: process) >= expectedCount {
        return true
      }
      await Task.yield()
    }
    return false
  }

  private func withNoopPublicationDependencies(
    _ operation: () -> Void
  ) {
    withDependencies {
      $0.managedWindows.setManaged = { _ in }
      $0.sls.watchWindows = { _ in }
    } operation: {
      operation()
    }
  }

}

// MARK: - WindowDiscoveryScanProbe

private actor WindowDiscoveryScanProbe {

  // MARK: Internal

  struct Call: Equatable, Sendable {
    var process: WindowDiscoveryRequest.Process
    var invalidationGeneration: UInt64
  }

  func scan(
    process: WindowDiscoveryRequest.Process,
    invalidationGeneration: UInt64,
    cancellation: WindowDiscoveryCancellation,
  ) async -> WindowCapabilityDiscovery {
    let callIndex = calls.count
    calls.append(Call(
      process: process,
      invalidationGeneration: invalidationGeneration,
    ))
    resumeCallCountWaiters()

    if callIndex == 0, !firstScanReleased {
      await withCheckedContinuation {
        firstScanContinuation = $0
      }
    }
    guard !cancellation.isCancelled else {
      return WindowCapabilityDiscovery()
    }

    let movable = WindowKey(
      pid: process.pid,
      windowID: CGWindowID(truncatingIfNeeded: invalidationGeneration + 100),
      bundleId: process.bundleId,
    )
    let resizable = WindowKey(
      pid: process.pid,
      windowID: CGWindowID(truncatingIfNeeded: invalidationGeneration + 200),
      bundleId: process.bundleId,
    )
    return WindowCapabilityDiscovery(
      movableKeys: [movable, resizable],
      resizableKeys: [resizable],
    )
  }

  func waitForCallCount(_ expectedCount: Int) async {
    guard calls.count < expectedCount else { return }
    await withCheckedContinuation {
      callCountWaiters.append(CallCountWaiter(
        expectedCount: expectedCount,
        continuation: $0,
      ))
    }
  }

  func releaseFirstScan() {
    firstScanReleased = true
    firstScanContinuation?.resume()
    firstScanContinuation = nil
  }

  func recordedCalls() -> [Call] {
    calls
  }

  // MARK: Private

  private struct CallCountWaiter {
    var expectedCount: Int
    var continuation: CheckedContinuation<Void, Never>
  }

  private var calls = [Call]()
  private var callCountWaiters = [CallCountWaiter]()
  private var firstScanReleased = false
  private var firstScanContinuation: CheckedContinuation<Void, Never>?

  private func resumeCallCountWaiters() {
    var pending = [CallCountWaiter]()
    for waiter in callCountWaiters {
      if calls.count >= waiter.expectedCount {
        waiter.continuation.resume()
      } else {
        pending.append(waiter)
      }
    }
    callCountWaiters = pending
  }

}
