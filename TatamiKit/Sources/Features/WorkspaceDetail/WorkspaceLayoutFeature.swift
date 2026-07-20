import ComposableArchitecture
import CoreGraphics
import Foundation
import Sharing

/// The tapped tile — target for the toolbar's split-orientation + fullscreen
/// actions. Captured from the leaf so it doesn't depend on tree structure.
public struct SelectedTile: Equatable {
  public var path: [BSPSide]
  public var bundleId: String
  public var liveKey: WindowKey?
  /// Slot occurrence of the tile's window (nil when live) — lets the toolbar
  /// fullscreen a specific same-app window in an inactive preview.
  public var occurrence: Int?
  public init(path: [BSPSide], bundleId: String, liveKey: WindowKey?, occurrence: Int?) {
    self.path = path
    self.bundleId = bundleId
    self.liveKey = liveKey
    self.occurrence = occurrence
  }
}

/// A workspace member that isn't tiled — floating (mirrored above the tiles) or
/// ignored (left alone). Shown in a band, not the BSP canvas.
public struct NonTiledApp: Identifiable, Equatable {
  public var bundleId: String
  public var name: String
  public var iconPath: String?
  public var mode: LayoutMode
  public var isShared: Bool
  public var id: String { bundleId }
}

/// Owns the layout-preview business logic for one workspace: resolving the
/// render tree, mapping trimmed→full edit paths, and applying edits — to the
/// live tree of the *active* workspace (routed to `WorkspaceActivationFeature`
/// via `delegate`) or to the saved snapshot otherwise. A child of
/// `WorkspaceDetailFeature`; the view is a pure renderer over this store.
@Reducer
public struct WorkspaceLayoutFeature {
  @ObservableState
  public struct State: Equatable {
    @Shared(.tatamiConfig) public var config = AppConfig()
    public var workspaceId: Workspace.ID

    /// Persisted layout template, loaded on appear; drives the preview when the
    /// workspace isn't active, and edits write back through here.
    public var layoutSnapshot: LayoutSnapshot?
    /// AX titles for the workspace's apps' live windows (disambiguates several
    /// windows of one app), even when the workspace isn't active.
    public var windowTitles: [WindowKey: String] = [:]
    /// Bundle ids with a currently-discoverable window. A shared app absent here
    /// is hidden and wouldn't tile on switch, so the preview omits it.
    public var presentBundleIds: Set<String> = []
    public var snapshotLoadedFor: Workspace.ID?
    public var windowInfoLoadedFor: Workspace.ID?

    /// The active workspace's live state, mirrored in from the view (the
    /// activation store lives in a sibling subtree).
    public var liveTree: BSPNode<WindowKey>?
    public var liveZoomed: Set<WindowKey> = []
    public var isActive = false

    /// Tapped tile (drives toolbar orientation/fullscreen). Transient drag is
    /// view-local; this survives renders and is cleared by structural edits.
    public var selectedTile: SelectedTile?

    public init(workspaceId: Workspace.ID) {
      self.workspaceId = workspaceId
    }

    public var workspace: Workspace? {
      config.workspace(id: workspaceId)
    }

    /// Both async preview loads (snapshot + window info) done for this
    /// workspace → render once, settled, instead of flickering through the
    /// load burst. No timer.
    public var previewReady: Bool {
      snapshotLoadedFor == workspaceId && windowInfoLoadedFor == workspaceId
    }

    public var tiledBundleIds: [String] {
      guard let workspace else { return [] }
      return tiledLayoutBundleIds(workspace: workspace, sharedApps: config.sharedApps)
    }

    /// Tiled shared apps with no live window — omitted from the rendered tiles
    /// (kept in the template so edit paths still resolve).
    public var hiddenSharedBundleIds: Set<String> {
      Set(config.sharedApps.filter { $0.layout == .tiled }.map(\.bundleIdentifier))
        .subtracting(presentBundleIds)
    }

    /// Non-tiled members (floating / ignored) shown in the band. Scratchpads
    /// exclude shared apps (they borrow only their own apps into a host).
    public var nonTiledApps: [NonTiledApp] {
      guard let workspace else { return [] }
      var out: [NonTiledApp] = []
      for app in workspace.apps where app.layout != .tiled {
        out.append(NonTiledApp(bundleId: app.bundleIdentifier, name: app.name,
                               iconPath: app.iconPath, mode: app.layout, isShared: false))
      }
      if workspace.kind != .scratchpad {
        for app in config.sharedApps where app.layout != .tiled {
          out.append(NonTiledApp(bundleId: app.bundleIdentifier, name: app.name,
                                 iconPath: app.iconPath, mode: app.layout, isShared: true))
        }
      }
      return out
    }

    /// Live window titles grouped by bundle id (sorted by window id) so the
    /// view can label several windows of one app distinctly.
    public var titlesByBundle: [String: [String]] {
      var grouped: [String: [(CGWindowID, String)]] = [:]
      for (key, title) in windowTitles {
        grouped[key.bundleId, default: []].append((key.windowID, title))
      }
      return grouped.mapValues { $0.sorted { $0.0 < $1.0 }.map(\.1) }
    }

    /// The single render + edit source of truth: the live tree when active,
    /// else the saved/synthesized template. The view renders it; the reducer
    /// maps edit paths against it.
    public var resolved: ResolvedLayout? {
      guard let workspace else { return nil }
      return ResolvedLayout.resolve(
        workspace: workspace,
        sharedApps: config.sharedApps,
        presentBundleIds: presentBundleIds,
        isActive: isActive,
        liveTree: liveTree,
        liveZoomed: liveZoomed,
        snapshot: layoutSnapshot,
        autoBalance: config.settings.layout.autoBalance
      )
    }
  }

  public enum Action {
    case onAppear
    case startObservingAppActivity
    case activationObserved(liveTree: BSPNode<WindowKey>?, liveZoomed: Set<WindowKey>, isActive: Bool)

    // Selection
    case tileTapped(path: [BSPSide], bundleId: String, liveKey: WindowKey?, occurrence: Int?)
    case backgroundTapped

    /// A non-tiled chip's "configure" action — bubble up so the parent reveals
    /// the app's settings (Shared Apps section for shared, else this workspace's
    /// Apps section).
    case revealApp(bundleId: String, isShared: Bool)

    // Structural-edit intents (carry TRIMMED paths; the reducer maps → full)
    case dividerResized(trimmedBranchPath: [BSPSide], ratio: CGFloat)
    case tileMoved(sourceTrimmedPath: [BSPSide], targetTrimmedPath: [BSPSide], zone: DropZone)
    case rotate
    case mirror(axis: BSPSplitAxis)
    case balance
    case toggleOrientation
    /// `occurrence` targets a specific same-app window when inactive (the slot's
    /// windowID rank); nil/ignored when live (the exact `liveKey` is used).
    case toggleFullscreen(bundleId: String, liveKey: WindowKey?, occurrence: Int?, zoomIn: Bool)

    // Effect results
    case layoutSnapshotLoaded(LayoutSnapshot?)
    case loadWindowTitles(bundleIds: [String])
    case windowInfoLoaded(titles: [WindowKey: String], present: Set<String>)
    case appActivityTick

    case delegate(Delegate)
    public enum Delegate: Equatable {
      /// Apply a structural op to the *active* workspace's live tree.
      case activeLayoutEdited(workspaceId: Workspace.ID, op: LayoutEditOp)
      /// Toggle fullscreen-zoom on a specific live window of the active workspace.
      case activeFullscreenToggled(windowKey: WindowKey)
      /// Drop the resident in-memory tree so the next activation rebuilds from
      /// the edited snapshot.
      case residentLayoutInvalidated(workspaceId: Workspace.ID)
      /// Reveal an app's settings: `isShared` → the Shared Apps section, else
      /// this workspace's Apps section.
      case revealAppSettings(bundleId: String, isShared: Bool)
    }
  }

  @Dependency(\.layoutStore) var layoutStore
  @Dependency(\.windowSnapshot) var windowSnapshot
  @Dependency(\.appLaunch) var appLaunch
  @Dependency(\.windowObserver) var windowObserver

  private enum CancelID { case appActivity, windowTitles }

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        let id = state.workspaceId
        return .run { [layoutStore] send in
          await send(.layoutSnapshotLoaded(layoutStore.load(id)))
        }

      case .startObservingAppActivity:
        // Two subscriptions, both reused multicast streams (not polling):
        //  1. NSWorkspace app events — launch/activate/unhide/terminate/space
        //     change may alter a title or which shared apps are present.
        //  2. AX title changes — catches in-app renames (terminal cwd, browser
        //     tab) while the app stays frontmost, which (1) can't see. Only
        //     fires for observed apps (the active workspace + tracked).
        return .merge(
          .run { [appLaunch] send in
            for await _ in appLaunch.events() { await send(.appActivityTick) }
          }
          .cancellable(id: CancelID.appActivity, cancelInFlight: true),
          .run { [windowObserver] send in
            for await event in windowObserver.events() {
              if case .windowTitleChanged = event { await send(.appActivityTick) }
            }
          }
          .cancellable(id: CancelID.windowTitles, cancelInFlight: true)
        )

      case .appActivityTick:
        return .send(.loadWindowTitles(bundleIds: state.tiledBundleIds))

      case .activationObserved(let liveTree, let liveZoomed, let isActive):
        state.liveTree = liveTree
        state.liveZoomed = liveZoomed
        state.isActive = isActive
        return .none

      case .layoutSnapshotLoaded(let snapshot):
        state.layoutSnapshot = snapshot
        state.snapshotLoadedFor = state.workspaceId
        return .none

      case .loadWindowTitles(let bundleIds):
        guard !bundleIds.isEmpty else {
          state.windowTitles = [:]
          state.presentBundleIds = []
          state.windowInfoLoadedFor = state.workspaceId
          return .none
        }
        // Discover live windows by bundle id — works even when this workspace
        // isn't active. The discovered set doubles as shared-app presence.
        return .run { [windowSnapshot] send in
          let (titles, present) = await MainActor.run {
            () -> ([WindowKey: String], Set<String>) in
            let keys = windowSnapshot.cachedKeys(bundleIds, true)
            return (windowSnapshot.windowTitles(keys), Set(keys.map(\.bundleId)))
          }
          await send(.windowInfoLoaded(titles: titles, present: present))
        }

      case .windowInfoLoaded(let titles, let present):
        state.windowTitles = titles
        state.presentBundleIds = present
        state.windowInfoLoadedFor = state.workspaceId
        return .none

      case .tileTapped(let path, let bundleId, let liveKey, let occurrence):
        state.selectedTile = state.selectedTile?.path == path
          ? nil
          : SelectedTile(path: path, bundleId: bundleId, liveKey: liveKey, occurrence: occurrence)
        return .none

      case .backgroundTapped:
        state.selectedTile = nil
        return .none

      case .revealApp(let bundleId, let isShared):
        return .send(.delegate(.revealAppSettings(bundleId: bundleId, isShared: isShared)))

      case .dividerResized(let trimmedBranchPath, let ratio):
        guard let full = state.resolved?.fullBranchPath(
          trimmedBranchPath: trimmedBranchPath, hidden: state.hiddenSharedBundleIds
        ) else { return .none }
        return route(.setRatio(path: full, ratio: ratio), state: &state)

      case .tileMoved(let source, let target, let zone):
        let hidden = state.hiddenSharedBundleIds
        guard let sourceFull = state.resolved?.fullLeafPath(trimmedLeafPath: source, hidden: hidden),
              let targetFull = state.resolved?.fullLeafPath(trimmedLeafPath: target, hidden: hidden)
        else { return .none }
        state.selectedTile = nil
        return route(.relocate(source: sourceFull, target: targetFull, zone: zone), state: &state)

      case .rotate:
        state.selectedTile = nil
        return route(.rotate(degrees: 90), state: &state)

      case .mirror(let axis):
        state.selectedTile = nil
        return route(.mirror(axis: axis), state: &state)

      case .balance:
        state.selectedTile = nil
        return route(.balance, state: &state)

      case .toggleOrientation:
        guard let sel = state.selectedTile,
              let full = state.resolved?.fullLeafPath(
                trimmedLeafPath: sel.path, hidden: state.hiddenSharedBundleIds
              )
        else { return .none }
        state.selectedTile = nil
        return route(.toggleOrientation(leafPath: full), state: &state)

      case .toggleFullscreen(let bundleId, let liveKey, let occurrence, let zoomIn):
        state.selectedTile = nil
        // Active: per-window toggle against the live tree (state decides in/out).
        if state.resolved?.isLive == true, let key = liveKey {
          return .send(.delegate(.activeFullscreenToggled(windowKey: key)))
        }
        let slot = SlotID(bundleId: bundleId, occurrence: occurrence ?? 0)
        return toggleInactiveFullscreen(slot: slot, zoomIn: zoomIn, state: &state)

      case .delegate:
        return .none
      }
    }
  }

  // MARK: - Edit routing

  /// Apply a structural op: active → delegate to activation; inactive → edit the
  /// snapshot, persist, and invalidate the stale resident tree.
  private func route(_ op: LayoutEditOp, state: inout State) -> Effect<Action> {
    let id = state.workspaceId
    if state.resolved?.isLive == true {
      return .send(.delegate(.activeLayoutEdited(workspaceId: id, op: op)))
    }
    guard let workspace = state.workspace,
          let template = previewLayoutTemplate(
            snapshot: state.layoutSnapshot?.tree,
            workspace: workspace,
            sharedApps: state.config.sharedApps,
            presentBundleIds: state.presentBundleIds
          )
    else { return .none }
    // `SlotID` leaves are unique, so the op applies directly — a same-app swap
    // now produces a distinct tree (and persists) instead of collapsing to a
    // no-op the way a bundle-id template did.
    let newTemplate = template.applying(op)
    guard newTemplate != template else { return .none }
    let snapshot = LayoutSnapshot(
      tree: newTemplate,
      fullscreenZoomedSlots: state.layoutSnapshot?.fullscreenZoomedSlots ?? []
    )
    state.layoutSnapshot = snapshot
    return .merge(
      .run { [layoutStore] _ in await layoutStore.save(id, snapshot) },
      .send(.delegate(.residentLayoutInvalidated(workspaceId: id)))
    )
  }

  private func toggleInactiveFullscreen(
    slot: SlotID, zoomIn: Bool, state: inout State
  ) -> Effect<Action> {
    let id = state.workspaceId
    guard let workspace = state.workspace,
          let template = previewLayoutTemplate(
            snapshot: state.layoutSnapshot?.tree,
            workspace: workspace,
            sharedApps: state.config.sharedApps,
            presentBundleIds: state.presentBundleIds
          )
    else { return .none }
    var zoomed = Set(state.layoutSnapshot?.fullscreenZoomedSlots ?? [])
    if zoomIn {
      // Only zoom a slot the layout actually holds.
      guard template.windows.contains(slot) else { return .none }
      zoomed.insert(slot)
    } else {
      guard zoomed.remove(slot) != nil else { return .none }
    }
    let sortedZoom = zoomed.sorted { ($0.bundleId, $0.occurrence) < ($1.bundleId, $1.occurrence) }
    let snapshot = LayoutSnapshot(tree: template, fullscreenZoomedSlots: sortedZoom)
    state.layoutSnapshot = snapshot
    return .merge(
      .run { [layoutStore] _ in await layoutStore.save(id, snapshot) },
      .send(.delegate(.residentLayoutInvalidated(workspaceId: id)))
    )
  }
}
