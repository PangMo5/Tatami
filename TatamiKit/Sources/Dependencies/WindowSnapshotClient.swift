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
  guard let app = NSWorkspace.shared.frontmostApplication,
        let bundleId = app.bundleIdentifier
  else { return nil }
  let axApp = AXUIElementCreateApplication(app.processIdentifier)
  var raw: CFTypeRef?
  guard AXUIElementCopyAttributeValue(
    axApp,
    kAXFocusedWindowAttribute as CFString,
    &raw
  ) == .success,
    let value = raw,
    CFGetTypeID(value) == AXUIElementGetTypeID()
  else { return nil }
  return WindowKey(
    axWindow: value as! AXUIElement,
    pid: app.processIdentifier,
    bundleId: bundleId
  )
}

/// Resolve one exact window's current AX frame. Unlike the tiled frame map,
/// this also covers workspace-owned floating and unmanaged windows selected by
/// MRU restoration.
@MainActor
private func liveWindowFrame(_ key: WindowKey) -> CGRect? {
  let axApp = AXUIElementCreateApplication(key.pid)
  var raw: CFTypeRef?
  guard AXUIElementCopyAttributeValue(
    axApp, kAXWindowsAttribute as CFString, &raw
  ) == .success,
    let windows = raw as? [AXUIElement]
  else { return nil }
  for window in windows {
    var wid: CGWindowID = 0
    guard _AXUIElementGetWindow(window, &wid) == .success, wid == key.windowID else { continue }
    return AXWindowGeometry.frame(of: window)
  }
  return nil
}

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
  /// Remove every cached window for a process that has terminated. This is an
  /// authoritative lifecycle signal, so activation must not serve its stale
  /// window ids while a later discovery catches up.
  var invalidateBundle: @Sendable (_ bundleId: String) -> Void = { _ in }
  /// Remove exact WindowServer ids confirmed destroyed or pruned off-screen.
  /// Keeps cache-first activation from briefly laying out a dead tile.
  var invalidateWindowIDs: @Sendable (_ windowIDs: Set<CGWindowID>) -> Void = { _ in }
  /// The `WindowKey` of the focused window of the frontmost app.
  var focusedWindowKey: @Sendable () -> WindowKey?
  /// Current AX frame for one exact window, including floating/unmanaged
  /// windows that have no entry in the BSP frame map.
  var windowFrame: @Sendable (_ key: WindowKey) -> CGRect? = { _ in nil }
  /// The frontmost app (bundle id + localized name), if any.
  var frontmostApp: @Sendable () -> FrontmostApp?
  /// Window numbers of every window currently on screen.
  var onScreenWindowIDs: @Sendable () -> Set<CGWindowID> = { [] }
  /// Bundle ids of every running app (any activation policy — the
  /// skip-empty cycle counts background-only members too).
  var runningBundleIds: @Sendable () -> Set<String> = { [] }
  /// AX window titles for the given keys, for the GUI layout preview to
  /// disambiguate several windows of the same app. Best-effort: windows that
  /// don't answer / have no title are simply absent from the result.
  var windowTitles: @Sendable (_ keys: [WindowKey]) -> [WindowKey: String] = { _ in [:] }
}

extension WindowSnapshotClient: DependencyKey {
  static let liveValue: WindowSnapshotClient = {
    let cache = MainActor.assumeIsolated { WindowKeyCache() }
    return WindowSnapshotClient(
      discoverKeys: { bundleIds, requireResizable in
        MainActor.assumeIsolated {
          @Dependency(\.sls) var sls
          let discovery = discoverWindowKeys(
            forBundleIds: bundleIds, sls: sls, requireResizable: requireResizable
          )
          cache.store(
            discovery, bundleIds: bundleIds, requireResizable: requireResizable
          )
          var keys = discovery.keys
          // A subrole flap drops a still-enumerated window from `keys`; restore
          // it from cache (where `store` just preserved it) so a transient
          // misclassification doesn't read as "window closed" to the tree — the
          // poisoning that evicted ChatGPT and left Siri owning the workspace.
          if !discovery.retained.isEmpty {
            var have = Set(keys.map(\.windowID))
            for bundleId in bundleIds {
              let cached = cache.cached(bundleId, requireResizable: requireResizable) ?? []
              for key in cached
                where discovery.retained.contains(key.windowID) && !have.contains(key.windowID) {
                keys.append(key)
                have.insert(key.windowID)
              }
            }
          }
          guard !discovery.unreachable.isEmpty else { return keys }
          // An unreachable app (AX timeout — busy or hung, not "no windows")
          // answers with its last-known keys, so a slow app under system
          // load doesn't read as "all windows closed" and get dropped from
          // trees, mirrors, and markers. The next reachable scan replaces it.
          @Dependency(\.debugLog) var debugLog
          for bundleId in discovery.unreachable {
            let stale = cache.cached(bundleId, requireResizable: requireResizable) ?? []
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
            if let hit = cache.cached(bundleId, requireResizable: requireResizable) {
              out += hit
            } else {
              let fresh = discoverWindowKeys(
                forBundleIds: [bundleId], sls: sls, requireResizable: requireResizable
              )
              cache.store(
                fresh, bundleIds: [bundleId], requireResizable: requireResizable
              )
              out += fresh.keys
            }
          }
          return out
        }
      },
      invalidateBundle: { bundleId in
        MainActor.assumeIsolated { cache.invalidate(bundleId: bundleId) }
      },
      invalidateWindowIDs: { windowIDs in
        MainActor.assumeIsolated { cache.invalidate(windowIDs: windowIDs) }
      },
      focusedWindowKey: {
        MainActor.assumeIsolated { liveFocusedWindowKey() }
      },
      windowFrame: { key in
        MainActor.assumeIsolated { liveWindowFrame(key) }
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
      },
      windowTitles: { keys in
        MainActor.assumeIsolated {
          guard !keys.isEmpty else { return [:] }
          var out: [WindowKey: String] = [:]
          // One AX app handle per pid; map each app's windows by CGWindowID once.
          for (pid, group) in Dictionary(grouping: keys, by: \.pid) {
            let axApp = AXUIElementCreateApplication(pid)
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &raw) == .success,
                  let windows = raw as? [AXUIElement]
            else { continue }
            var titleByWindowID: [CGWindowID: String] = [:]
            for window in windows {
              var wid: CGWindowID = 0
              guard _AXUIElementGetWindow(window, &wid) == .success, wid != 0 else { continue }
              var titleRaw: CFTypeRef?
              if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRaw) == .success,
                 let title = titleRaw as? String, !title.isEmpty {
                titleByWindowID[wid] = title
              }
            }
            for key in group where titleByWindowID[key.windowID] != nil {
              out[key] = titleByWindowID[key.windowID]
            }
          }
          return out
        }
      }
    )
  }()

  static let testValue = WindowSnapshotClient(
    discoverKeys: { _, _ in [] },
    cachedKeys: { _, _ in [] },
    invalidateBundle: { _ in },
    invalidateWindowIDs: { _ in },
    focusedWindowKey: { nil },
    windowFrame: { _ in nil },
    frontmostApp: { nil },
    onScreenWindowIDs: { [] },
    runningBundleIds: { [] },
    windowTitles: { _ in [:] }
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
  private struct Key: Hashable {
    var bundleId: String
    var requireResizable: Bool
  }

  private var entries: [Key: [WindowKey]] = [:]
  /// Last id set handed to `setManaged` / `sls.watchWindows`. An unchanged
  /// window population — the common case, since most discoveries (focus
  /// change, resize, front-switch reconcile) add or remove nothing — skips
  /// the redundant Set copy under lock and the SLS re-subscribe.
  private var lastPublishedIDs: Set<CGWindowID> = []

  func cached(_ bundleId: String, requireResizable: Bool) -> [WindowKey]? {
    entries[Key(bundleId: bundleId, requireResizable: requireResizable)]
  }

  func invalidate(bundleId: String) {
    let keys = entries.keys.filter { $0.bundleId == bundleId }
    guard !keys.isEmpty else { return }
    for key in keys { entries[key] = nil }
    publishManagedWindows()
  }

  func invalidate(windowIDs: Set<CGWindowID>) {
    guard !windowIDs.isEmpty else { return }
    var changed = false
    for key in Array(entries.keys) {
      let cached = entries[key] ?? []
      let filtered = cached.filter { !windowIDs.contains($0.windowID) }
      guard filtered.count != cached.count else { continue }
      entries[key] = filtered
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

extension DependencyValues {
  var windowSnapshot: WindowSnapshotClient {
    get { self[WindowSnapshotClient.self] }
    set { self[WindowSnapshotClient.self] = newValue }
  }
}
