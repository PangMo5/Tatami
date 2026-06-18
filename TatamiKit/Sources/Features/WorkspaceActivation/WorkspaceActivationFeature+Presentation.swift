import AppKit
import ComposableArchitecture
import Foundation
import OrderedCollections

extension WorkspaceActivationFeature {
  // MARK: - Window marker / floating presentation

  /// The active workspace's floating apps + shared floating apps — the
  /// set whose live windows get mirror panels and marker dots.
  static func floatingBundleIds(state: State) -> [String] {
    let perWorkspace = state.primaryActiveWorkspaceID
      .flatMap { id in state.config.activeProfile?.workspaces[id: id] }
      .map { $0.apps.filter { $0.layout == .floating }.map(\.bundleIdentifier) } ?? []
    let shared = state.config.sharedApps.filter { $0.layout == .floating }.map(\.bundleIdentifier)
    return Array(OrderedSet(perWorkspace + shared))
  }

  /// The active workspace's unmanaged apps + shared unmanaged apps —
  /// members that are neither tiled nor mirrored, but still count as
  /// window-cycle targets and (via the discovery cache) FFM hit-test
  /// windows.
  static func unmanagedBundleIds(state: State) -> [String] {
    let perWorkspace = state.primaryActiveWorkspaceID
      .flatMap { id in state.config.activeProfile?.workspaces[id: id] }
      .map { $0.apps.filter { $0.layout == .unmanaged }.map(\.bundleIdentifier) } ?? []
    let shared = state.config.sharedApps.filter { $0.layout == .unmanaged }.map(\.bundleIdentifier)
    return Array(OrderedSet(perWorkspace + shared))
  }

  /// Marker targets: fullscreen-zoom dots (focus-gated) + floating dots
  /// (always visible — the dot is what identifies a floating window / its
  /// mirror at a glance). Callers pass only the keys whose categories are
  /// enabled in `cfg`.
  static func markerTargets(
    fullscreenZoomed: Set<WindowKey>,
    floatingKeys: [WindowKey],
    cfg: AppSettings.Marker
  ) -> [WindowKey: MarkerTarget] {
    var targets: [WindowKey: MarkerTarget] = [:]
    for key in fullscreenZoomed {
      targets[key] = MarkerTarget(colorHex: cfg.fullscreenColorHex)
    }
    for key in floatingKeys {
      targets[key] = MarkerTarget(colorHex: cfg.floatingColorHex, alwaysVisible: true)
    }
    return targets
  }

  /// The fullscreen-zoom marker keys for the active workspace (empty when
  /// the category is disabled) — the marker inputs that need no discovery.
  private static func fullscreenMarkerKeys(state: State) -> Set<WindowKey> {
    guard state.config.settings.marker.fullscreenEnabled,
          let workspaceId = state.primaryActiveWorkspaceID
    else { return [] }
    return state.fullscreenZoomed[workspaceId] ?? []
  }

  /// Show a HUD message when its category (and the master switch) is
  /// enabled in settings — every non-workspace-switch HUD funnels through
  /// here so the per-category toggles stay authoritative.
  func hudEffect(
    _ state: State,
    _ category: KeyPath<AppSettings.HUD, Bool>,
    _ title: String,
    _ icon: String?,
    subtitle: String? = nil
  ) -> Effect<Action> {
    guard state.config.settings.hud.shows(category) else { return .none }
    let durationMs = state.config.settings.hud.durationMs
    return .run { [hud = workspaceHUD] _ in await hud.show(title, icon, subtitle, durationMs) }
  }

  /// Re-resolve floating windows and push fresh marker targets. The AX
  /// discovery happens *inside* the effect — running it synchronously
  /// while building the effect blocked every reduction that refreshed
  /// markers (i.e. nearly every window event) on a full AX enumeration.
  func refreshMarkers(state: State) -> Effect<Action> {
    let cfg = state.config.settings.marker
    let zoomedKeys = Self.fullscreenMarkerKeys(state: state)
    let floatingIds = cfg.floatingEnabled ? Self.floatingBundleIds(state: state) : []
    return .run { [marker, snapshot = windowSnapshot] _ in
      let floatingKeys: [WindowKey] = floatingIds.isEmpty
        ? []
        : await MainActor.run { snapshot.discoverKeys(floatingIds, false) }
      marker.setTargets(
        Self.markerTargets(fullscreenZoomed: zoomedKeys, floatingKeys: floatingKeys, cfg: cfg),
        cfg.size, cfg.corner, cfg.hideOnHover
      )
    }
  }

  /// One floating-window discovery feeding both presentation consumers —
  /// the mirror overlay (replace set; empty tears every mirror down) and
  /// the marker dots — instead of two full AX scans back to back. Used
  /// whenever a floating app's windows change.
  func refreshFloatingPresentation(state: State) -> Effect<Action> {
    let bundleIds = Self.floatingBundleIds(state: state)
    let cfg = state.config.settings.marker
    let zoomedKeys = Self.fullscreenMarkerKeys(state: state)
    let overlay = floatingOverlay
    return .run { [marker, snapshot = windowSnapshot] _ in
      let keys = await MainActor.run { snapshot.discoverKeys(bundleIds, false) }
      overlay.setFloating(Set(keys))
      marker.setTargets(
        Self.markerTargets(
          fullscreenZoomed: zoomedKeys,
          floatingKeys: cfg.floatingEnabled ? keys : [],
          cfg: cfg
        ),
        cfg.size, cfg.corner, cfg.hideOnHover
      )
    }
  }
}
