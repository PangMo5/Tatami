import ComposableArchitecture
import CoreGraphics
import Dependencies
import Testing
@testable import TatamiKit

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

      #expect(cache.cached(ghostty.bundleId, requireResizable: true) == [])
      #expect(cache.cached(ghostty.bundleId, requireResizable: false) == [])
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

  // MARK: Private

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
