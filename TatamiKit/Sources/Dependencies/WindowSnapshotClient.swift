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
  /// (see `discoverWindowKeys` for the filtering rules).
  var discoverKeys:
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
        return discoverWindowKeys(
          forBundleIds: bundleIds, sls: sls, requireResizable: requireResizable
        )
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
    focusedWindowKey: { nil },
    frontmostApp: { nil },
    onScreenWindowIDs: { [] },
    runningBundleIds: { [] }
  )
  static let previewValue = testValue
}

extension DependencyValues {
  var windowSnapshot: WindowSnapshotClient {
    get { self[WindowSnapshotClient.self] }
    set { self[WindowSnapshotClient.self] = newValue }
  }
}
