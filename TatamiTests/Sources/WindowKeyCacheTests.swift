import ComposableArchitecture
import CoreGraphics
import Dependencies
import Testing
@testable import TatamiKit

@MainActor
struct WindowKeyCacheTests {
  @Test
  func authoritativeInvalidationRemovesStaleWindowsFromEveryCacheVariant() {
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
}
