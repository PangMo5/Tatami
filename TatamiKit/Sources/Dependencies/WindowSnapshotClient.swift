import AppKit
import CoreGraphics
import Dependencies
import DependenciesMacros
import Foundation

/// The frontmost regular app, as the activation reducer cares about it.
struct FrontmostApp: Equatable, Sendable {
  var bundleId: String
  var name: String

  init(bundleId: String, name: String) {
    self.bundleId = bundleId
    self.name = name
  }
}

/// Synchronous snapshots of the live window / app state the activation
/// reducer branches on (AX window discovery, focused window, frontmost
/// app, on-screen window ids). Wrapping them in a dependency makes those
/// branches overridable in `TestStore` tests instead of hitting AX and
/// CGWindowList on the test host.
///
/// Call only from the main actor (reducer bodies via a main-actor store,
/// or inside `MainActor.run` in effects): the live implementations are
/// `MainActor.assumeIsolated` over AX/AppKit, same as `DisplayClient`.
@DependencyClient
struct WindowSnapshotClient: Sendable {
  /// All visible, regular, tile-able windows of the given bundle ids
  /// (see `discoverWindowKeys` for the filtering rules). A fresh AX scan
  /// that also refreshes `WindowKeyCache`, so every event-driven sync
  /// doubles as cache maintenance. Bundles whose app didn't answer (AX
  /// timeout) report their last-known keys instead of nothing.
  var discoverKeys:
    @Sendable (_ bundleIds: [String], _ requireResizable: Bool) -> [WindowKey] = { _, _ in [] }
  /// Cache-first variant of `discoverKeys` for latency-critical paths
  /// (workspace activation). A warm entry costs zero AX round trips; a
  /// miss falls back to a fresh per-bundle scan. Callers own the
  /// staleness contract: serve from cache, then revalidate via the
  /// sync path afterwards (stale-while-revalidate).
  var cachedKeys:
    @Sendable (_ bundleIds: [String], _ requireResizable: Bool) -> [WindowKey] = { _, _ in [] }
  /// The `WindowKey` of the focused window of the frontmost app.
  var focusedWindowKey: @Sendable () -> WindowKey?
  /// The frontmost app (bundle id + localized name), if any.
  var frontmostApp: @Sendable () -> FrontmostApp?
  /// Window numbers of every window currently on screen.
  var onScreenWindowIDs: @Sendable () -> Set<CGWindowID> = { [] }
  /// Bundle ids of every running app (any activation policy — the
  /// skip-empty cycle counts background-only members too).
  var runningBundleIds: @Sendable () -> Set<String> = { [] }
}

extension WindowSnapshotClient: DependencyKey {
  static let liveValue: WindowSnapshotClient = {
    return WindowSnapshotClient(
    discoverKeys: { bundleIds, requireResizable in
      MainActor.assumeIsolated {
        @Dependency(\.sls) var sls
        let discovery = discoverWindowKeys(
          forBundleIds: bundleIds, sls: sls, requireResizable: requireResizable
        )
        WindowKeyCache.shared.store(
          discovery, bundleIds: bundleIds, requireResizable: requireResizable
        )
        guard !discovery.unreachable.isEmpty else { return discovery.keys }
        // An unreachable app (AX timeout — busy or hung, not "no windows")
        // answers with its last-known keys, so a slow app under system
        // load doesn't read as "all windows closed" and get dropped from
        // trees, mirrors, and markers. The next reachable scan replaces it.
        @Dependency(\.debugLog) var debugLog
        var keys = discovery.keys
        for bundleId in discovery.unreachable {
          let stale = WindowKeyCache.shared
            .cached(bundleId, requireResizable: requireResizable) ?? []
          debugLog.log(
            "Tiler",
            "\(bundleId) unreachable (AX timeout) — serving "
              + "\(stale.count) cached keys"
          )
          keys += stale
        }
        return keys
      }
    },
    cachedKeys: { bundleIds, requireResizable in
      MainActor.assumeIsolated {
        @Dependency(\.sls) var sls
        var out: [WindowKey] = []
        for bundleId in bundleIds {
          if let hit = WindowKeyCache.shared
            .cached(bundleId, requireResizable: requireResizable)
          {
            out += hit
          } else {
            let fresh = discoverWindowKeys(
              forBundleIds: [bundleId], sls: sls, requireResizable: requireResizable
            )
            WindowKeyCache.shared.store(
              fresh, bundleIds: [bundleId], requireResizable: requireResizable
            )
            out += fresh.keys
          }
        }
        return out
      }
    },
    focusedWindowKey: {
      MainActor.assumeIsolated { liveFocusedWindowKey() }
    },
    frontmostApp: {
      MainActor.assumeIsolated {
        NSWorkspace.shared.frontmostApplication.flatMap { app in
          guard let bundleId = app.bundleIdentifier, !bundleId.isEmpty else { return nil }
          return FrontmostApp(bundleId: bundleId, name: app.localizedName ?? "")
        }
      }
    },
    onScreenWindowIDs: {
      let raw = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
      ) as? [[String: Any]] ?? []
      var ids = Set<CGWindowID>()
      for entry in raw {
        if let n = entry[kCGWindowNumber as String] as? CGWindowID { ids.insert(n) }
      }
      return ids
    },
    runningBundleIds: {
      MainActor.assumeIsolated {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
      }
    }
    )
  }()

  static let testValue = WindowSnapshotClient(
    discoverKeys: { _, _ in [] },
    cachedKeys: { _, _ in [] },
    focusedWindowKey: { nil },
    frontmostApp: { nil },
    onScreenWindowIDs: { [] },
    runningBundleIds: { [] }
  )
  static let previewValue = testValue
}

/// Last-known `discoverWindowKeys` result per (bundle id, resizability).
///
/// Every AX discovery call is a synchronous IPC round trip serviced by
/// the *target app's* run loop — there is no async AX API — so under
/// system load a single rescan of all registered apps costs hundreds of
/// milliseconds on the main thread (measured: 50–120 ms idle, 1.2 s+
/// spikes). The cache removes that scan from the activation hot path.
///
/// Freshness is maintained by the paths that already learn about window
/// changes: every event-driven `discoverKeys` call (window created /
/// destroyed / miniaturized, app launch / terminate, space change, wake)
/// stores its fresh result here, and activation schedules a post-switch
/// revalidation sweep. An app whose bundle was never scanned is a miss,
/// never a stale hit.
@MainActor
final class WindowKeyCache {
  static let shared = WindowKeyCache()

  private struct Key: Hashable {
    var bundleId: String
    var requireResizable: Bool
  }

  private var entries: [Key: [WindowKey]] = [:]

  func cached(_ bundleId: String, requireResizable: Bool) -> [WindowKey]? {
    entries[Key(bundleId: bundleId, requireResizable: requireResizable)]
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
      entries[Key(bundleId: bundleId, requireResizable: requireResizable)] =
        grouped[bundleId] ?? []
    }
    publishManagedWindows()
  }

  /// Republish the managed-window id set for the FFM hit-test. Every
  /// discovery funnels through `store`, keeping the snapshot in step.
  private func publishManagedWindows() {
    let ids = Set(entries.values.flatMap { $0 }.map(\.windowID))
    @Dependency(\.managedWindows) var managedWindows
    @Dependency(\.sls) var sls
    managedWindows.setManaged(ids)
    // Subscribe the same set to WindowServer destruction events so a
    // hide-on-close window (no AX destroy, e.g. KakaoTalk) still gets
    // reclaimed.
    sls.watchWindows(Array(ids))
  }
}

extension DependencyValues {
  var windowSnapshot: WindowSnapshotClient {
    get { self[WindowSnapshotClient.self] }
    set { self[WindowSnapshotClient.self] = newValue }
  }
}
