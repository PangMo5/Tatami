import AppKit
import ApplicationServices
import ComposableArchitecture
import Foundation
import Sharing

/// Tracks the active workspace per display, owns per-workspace BSP
/// trees, and dispatches activation + window-layout side effects.
///
/// The reducer plays the event-loop role: window create/destroy/focus
/// notifications arrive, the BSP tree mutates, and the new layout is
/// flushed through `WindowTilerClient`. Workspace switching is layered
/// on top via `WorkspaceManagerClient` (show/hide policy).
@Reducer
public struct WorkspaceActivationFeature {
  @ObservableState
  public struct State: Equatable {
    @Shared(.tatamiConfig) public var config = AppConfig()
    public var activeWorkspacesByDisplay: [DisplayName: Workspace.ID] = [:]
    /// Per-display "most recent" workspace, for switch-to-recent on the
    /// display the user is currently on (multi-monitor aware).
    public var previousWorkspacesByDisplay: [DisplayName: Workspace.ID] = [:]
    /// Last display each workspace was activated on (including dynamic /
    /// unpinned ones), so cycling can scope dynamic workspaces to the monitor
    /// they were last on.
    public var lastActiveDisplay: [Workspace.ID: DisplayName] = [:]
    /// The display the user is currently acting on (cursor screen), refreshed
    /// before focus-sensitive ops so "the current workspace" resolves to the
    /// right monitor instead of an arbitrary one.
    public var focusedDisplay: DisplayName?
    public var isActivating = false
    /// Runtime-only "pause tiling" flag. Workspace switching keeps
    /// running while tiling is paused; flipped by `togglePaused`.
    public var isTilingPaused = false
    /// Per-workspace BSP tree of window keys, kept in-memory only.
    public var tilingTrees: [Workspace.ID: BSPNode<WindowKey>] = [:]
    /// Sticky per-workspace insertion point. The next window inserted
    /// lands next to this one (and the `insertDirection` set on its
    /// leaf decides north/east/south/west/stack). Updated by focus
    /// events and by the user's `bspSetInsertDirection` action.
    public var insertionPoint: [Workspace.ID: WindowKey] = [:]
    /// Per-workspace set of fullscreen-zoomed windows. Tatami-specific
    /// multi-window fullscreen: each member is trimmed from the tree
    /// before layout and rendered at the workspace's work area. Several
    /// can be active at once; focus determines which sits on top
    /// visually. Persisted via `LayoutSnapshot.fullscreenZoomedBundleIds`.
    /// Parent-zoom is *not* tracked here — that one lives inside the
    /// tree leaves directly.
    public var fullscreenZoomed: [Workspace.ID: Set<WindowKey>] = [:]

    /// Latest manual resize / move geometry, captured while the user drags
    /// and flushed to the tree on mouse-up (`.windowDragEnded`). Committing
    /// at the true drag-end (rather than on a time guess) avoids re-tiling
    /// the siblings under the cursor mid-drag, which made dragging jumpy.
    public struct PendingDrag: Equatable, Sendable {
      public var key: WindowKey
      public var frame: CGRect
    }
    /// The drop decision computed live (cursor-based) during a window drag,
    /// frozen at the last `windowMoved` so the mouse-up commit matches the
    /// previewed overlay exactly.
    public struct PendingDrop: Equatable, Sendable {
      public var dragged: WindowKey
      public var target: WindowKey
      public var zone: DropZone
    }
    public var pendingResize: PendingDrag?
    public var pendingDrop: PendingDrop?
    /// The window currently being dragged (set on `windowMoved`). On drag-end,
    /// if no swap/insert/resize was committed, the workspace re-tiles to snap
    /// it back to its slot.
    public var draggedWindow: WindowKey?

    public init() {}

    /// The active workspace on the display the user is currently on. Falls
    /// back to any active workspace (single-display, or before `focusedDisplay`
    /// is known). Hotkey ops resolve their target through this, so they act on
    /// the focused monitor rather than an arbitrary one.
    public var primaryActiveWorkspaceID: Workspace.ID? {
      if let focusedDisplay, let id = activeWorkspacesByDisplay[focusedDisplay] {
        return id
      }
      return activeWorkspacesByDisplay.values.first
    }
  }

  public enum Action {
    case startObservingWindowEvents
    /// Connected displays changed — drop active/recent state for displays
    /// that are gone so multi-monitor tracking doesn't hold stale entries.
    case displaysReconfigured([DisplayName])
    /// Activate a sensible workspace on launch so tiling starts
    /// immediately instead of waiting for the first manual switch.
    case activateInitial
    case activate(workspaceId: Workspace.ID, setFocus: Bool)
    case activateNext
    case activatePrevious
    case activateRecent
    /// Focus the workspace active on the next (`+1`) / previous (`-1`)
    /// connected display, looping around.
    case focusAdjacentDisplay(direction: Int)
    /// Relocate the focused app to the next (`+1`) / previous (`-1`)
    /// workspace and switch to it — honors loop / skip-empty like cycling.
    case moveFocusedAppToAdjacent(direction: Int)
    case moveFocusedAppTo(workspaceId: Workspace.ID)
    case focusedAppResolved(bundleId: String, name: String, workspaceId: Workspace.ID)
    /// Hotkey entry point: add/remove the focused window's app to the
    /// active workspace (single-membership — adding takes it away from
    /// any other workspace it was registered in).
    case toggleFocusedAppInActiveWorkspace
    case focusedAppMembershipResolved(bundleId: String, name: String)
    /// Hotkey entry point: assign the focused window's app to a *specific*
    /// workspace (single-membership) without switching to it — unlike
    /// `moveFocusedAppTo`, which also activates the target.
    case assignFocusedAppTo(workspaceId: Workspace.ID)
    case assignedAppResolved(bundleId: String, name: String, workspaceId: Workspace.ID)
    case toggleFloatingOnFocusedApp
    case focusedFloatToggleResolved(bundleId: String, name: String)
    case togglePaused
    case bspFocus(BSPDirection)
    case bspFocusResolved(windowKey: WindowKey, direction: BSPDirection)
    case bspSwap(BSPDirection)
    case bspResize(direction: BSPDirection, delta: CGFloat)
    case bspToggleOrientation
    /// Per-leaf zoom: the focused leaf renders at its parent
    /// branch's area, only one active per subtree, tree shape
    /// unchanged.
    case bspToggleZoomParent
    /// Tatami's fullscreen-zoom: multi-window, takes the window out of
    /// the tree's layout and renders it at the work area.
    case bspToggleZoomFullscreen
    case bspBalance
    case bspRotate(degrees: Int)
    case bspMirror(axis: BSPNode<WindowKey>.SplitAxis)
    /// Set the insertion direction on the focused leaf so the next
    /// inserted window lands there. Pass nil to clear.
    case bspSetInsertDirection(BSPNode<WindowKey>.InsertDirection?)
    case bspOpResolved(windowKey: WindowKey, op: BSPOp)
    case windowChanged(WindowChangeEvent)
    /// Incrementally reconcile a single app's windows into the active
    /// tree: add new windows, drop gone ones, touch nothing else.
    case syncAppWindows(bundleId: String)
    /// Drop active-workspace tree windows that are no longer on screen.
    /// Catches apps that *hide* their window on close (Electron apps like
    /// Discord) instead of destroying it — there's no AX destroy event, so a
    /// focus change to another app is the only trigger we get.
    case pruneOffscreenWindows
    /// Wake / native-Space-change / "something on the system shifted":
    /// re-reconcile every tree-resident + registered app.
    case reconcileAllTrackedApps
    case startObservingAppLaunches
    case appLaunched(bundleId: String, name: String)
    case appActivated(bundleId: String)
    case appTerminated(bundleId: String)
    case tilingTreeUpdated(workspaceId: Workspace.ID, tree: BSPNode<WindowKey>?)
    /// Activation discovered fullscreen-zoomed bundle ids on disk and
    /// we resolved them to live `WindowKey`s.
    case persistedFullscreenZoomRestored(workspaceId: Workspace.ID, keys: Set<WindowKey>)
    case activationCompleted(workspaceId: Workspace.ID, display: DisplayName?)
  }

  /// Tag used to dispatch a BSP mutation once we've resolved the
  /// focused window's `WindowKey`.
  public enum BSPOp: Sendable, Hashable {
    case swap(BSPDirection)
    case resize(BSPDirection, delta: CGFloat)
    case toggleOrientation
    case toggleZoomParent
    case toggleZoomFullscreen
    case setInsertDirection(BSPNode<WindowKey>.InsertDirection?)
  }

  /// Cancellation identifiers for debounced window-event handling.
  private enum CancelID: Hashable {
    case sync(String)
    /// Coalesces frame application per workspace: a newer layout
    /// cancels an in-flight apply so a stale one can't land after it.
    case apply(Workspace.ID)
    /// Debounces the off-screen prune so rapid app switches collapse into one.
    case prune
  }

  @Dependency(\.workspaceManager) var workspaceManager
  @Dependency(\.windowTiler) var windowTiler
  @Dependency(\.windowObserver) var windowObserver
  @Dependency(\.appLaunch) var appLaunch
  @Dependency(\.displays) var displays
  @Dependency(\.layoutStore) var layoutStore
  @Dependency(\.workspaceHUD) var workspaceHUD
  @Dependency(\.mouse) var mouse
  @Dependency(\.marker) var marker
  @Dependency(\.dragPreview) var dragPreview
  @Dependency(\.sls) var sls
  @Dependency(\.floatingOverlay) var floatingOverlay
  @Dependency(\.debugLog) var debugLog

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      // Track the display the user is acting on so "the current workspace"
      // resolves to the focused monitor. Skip `windowChanged` (drag / window
      // events) so the dragged window's workspace stays stable even as the
      // cursor crosses monitors mid-drag.
      if case .windowChanged = action {} else {
        state.focusedDisplay = displays.current()
      }

      switch action {
      case .startObservingWindowEvents:
        return .merge(
          .run { [client = windowObserver] send in
            for await event in client.events() {
              await send(.windowChanged(event))
            }
          },
          .run { [displays] send in
            for await names in displays.changes() {
              await send(.displaysReconfigured(names))
            }
          }
        )

      case .displaysReconfigured(let names):
        let connected = Set(names)
        state.activeWorkspacesByDisplay = state.activeWorkspacesByDisplay
          .filter { connected.contains($0.key) }
        state.previousWorkspacesByDisplay = state.previousWorkspacesByDisplay
          .filter { connected.contains($0.key) }
        // Drop last-display records for displays that are gone so dynamic
        // workspaces aren't stranded off-screen in the cycle.
        state.lastActiveDisplay = state.lastActiveDisplay
          .filter { connected.contains($0.value) }
        if let focused = state.focusedDisplay, !connected.contains(focused) {
          state.focusedDisplay = nil
        }
        return .none

      case .windowChanged(let event):
        switch event {
        case .windowResized(let key, let frame):
          // Defer to drag-end: AX fires continuously during the drag, and
          // committing mid-drag re-tiles the siblings under the cursor.
          // Record the latest geometry; `.windowDragEnded` (mouse-up) flushes
          // it once, so the commit lands at the true end of the drag.
          state.pendingResize = State.PendingDrag(key: key, frame: frame)
          return .none
        case .windowMoved(let key, _):
          // Cursor-based drop preview: find the tile + region under the
          // cursor and highlight it. Freeze the decision so the mouse-up
          // commit lands exactly where the overlay showed.
          state.draggedWindow = key
          let decision = dropDecision(dragged: key, state: state)
          state.pendingDrop = decision.map {
            State.PendingDrop(dragged: key, target: $0.target, zone: $0.zone)
          }
          let preview = dragPreview
          return .run { _ in
            if let decision {
              preview.show(decision.targetRect, decision.zone)
            } else {
              preview.hide()
            }
          }
        case .windowDragEnded:
          let preview = dragPreview
          let resize = state.pendingResize
          let drop = state.pendingDrop
          let didMove = state.draggedWindow != nil
          state.pendingResize = nil
          state.pendingDrop = nil
          state.draggedWindow = nil
          var effects: [Effect<Action>] = [.run { _ in preview.hide() }]
          if let resize {
            effects.append(syncTreeRatio(for: resize.key, frame: resize.frame, state: &state))
          } else if let drop {
            effects.append(applyDrop(drop, state: &state))
          } else if didMove {
            // Dragged but nothing committed (dropped on empty space / back on
            // itself) → snap the window back to its tile.
            effects.append(retileActive(state: state))
          }
          return .merge(effects)
        case .windowCreated(let bundleId):
          return debouncedSync(bundleId, delayMs: 0)
        case .windowDestroyed(let bundleId):
          return debouncedSync(bundleId, delayMs: 0)
        case .windowFocused(let bundleId, let key):
          // Keep the per-workspace insertion point current — even for
          // same-app window switches (which don't fire
          // didActivateApplication).
          if let key, let wsId = state.primaryActiveWorkspaceID,
             state.tilingTrees[wsId]?.windows.contains(key) == true
          {
            state.insertionPoint[wsId] = key
          }
          // Forward the focus change to the marker controller so it
          // can render the dot only on the now-focused window.
          let markerClient = marker
          let focusedKey = key
          return .merge(
            debouncedSync(bundleId, delayMs: 0),
            .run { _ in
              if let focusedKey {
                markerClient.setFocused(focusedKey.pid, focusedKey.windowID)
              } else {
                markerClient.setFocused(0, 0)
              }
            }
          )
        }

      case .syncAppWindows(let bundleId):
        return syncAppWindows(bundleId: bundleId, state: &state)

      case .startObservingAppLaunches:
        return .run { [client = appLaunch] send in
          for await event in client.events() {
            switch event {
            case .launched(let bundleId, let name):
              await send(.appLaunched(bundleId: bundleId, name: name))
            case .activated(let bundleId):
              await send(.appActivated(bundleId: bundleId))
            case .terminated(let bundleId):
              await send(.appTerminated(bundleId: bundleId))
            case .activeSpaceChanged, .didWake:
              await send(.reconcileAllTrackedApps)
            }
          }
        }

      case .reconcileAllTrackedApps:
        // Union of tree members + registered apps in the active
        // workspace: refresh every app we currently care about.
        var bundleIds: Set<String> = []
        for tree in state.tilingTrees.values {
          for window in tree.windows { bundleIds.insert(window.bundleId) }
        }
        if let workspaceId = state.primaryActiveWorkspaceID,
           let workspace = state.config.activeProfile?
             .workspaces.first(where: { $0.id == workspaceId })
        {
          for app in workspace.apps { bundleIds.insert(app.bundleIdentifier) }
        }
        guard !bundleIds.isEmpty else { return .none }
        return .merge(bundleIds.map { debouncedSync($0, delayMs: 10) })

      case .appLaunched(let bundleId, _):
        return debouncedSync(bundleId, delayMs: 10)

      case .appActivated(let bundleId):
        if bundleId == "dev.PangMo5.Tatami" || bundleId == "dev.PangMo5.Tatami.dev" {
          return .none
        }
        // Refresh marker focus on every app activation. AX
        // `kAXFocusedWindowChanged` is only fired for the apps we
        // already observe, so a switch *into* a previously-unobserved
        // app wouldn't otherwise wake the marker.
        let markerClient = marker
        let markerEffect = Effect<Action>.run { _ in
          let key = await MainActor.run { focusedWindowKey() }
          if let key {
            markerClient.setFocused(key.pid, key.windowID)
          } else {
            markerClient.setFocused(0, 0)
          }
        }
        if !state.isActivating,
           state.config.settings.switching.followAppFocus,
           !state.config.sharedApps.contains(where: { $0.bundleIdentifier == bundleId }),
           let owner = state.config.activeProfile?.workspaces.first(where: {
             $0.apps.contains { $0.bundleIdentifier == bundleId }
           }),
           state.primaryActiveWorkspaceID != owner.id {
          return .merge(
            markerEffect,
            .send(.activate(workspaceId: owner.id, setFocus: false)),
            debouncedPrune()
          )
        }
        return .merge(markerEffect, debouncedSync(bundleId, delayMs: 10), debouncedPrune())

      case .pruneOffscreenWindows:
        return pruneOffscreenWindows(state: &state)

      case .appTerminated(let bundleId):
        return debouncedSync(bundleId, delayMs: 0)

      case .activateInitial:
        guard let profile = state.config.activeProfile,
              !profile.workspaces.isEmpty
        else { return .none }
        let frontBundle = MainActor.assumeIsolated {
          NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        let target = profile.workspaces.first { ws in
          guard let fb = frontBundle else { return false }
          return ws.apps.contains { $0.bundleIdentifier == fb }
        } ?? profile.workspaces[0]
        return .send(.activate(workspaceId: target.id, setFocus: false))

      case .activate(let workspaceId, let setFocus):
        return performActivate(
          workspaceId: workspaceId,
          setFocus: setFocus,
          state: &state
        )

      case .activateNext:
        return cycle(by: 1, state: &state)

      case .activatePrevious:
        return cycle(by: -1, state: &state)

      case .activateRecent:
        // The recent workspace on the display the user is on (falls back to
        // any recent for single-display / unknown focus).
        let recent = state.focusedDisplay.flatMap { state.previousWorkspacesByDisplay[$0] }
          ?? state.previousWorkspacesByDisplay.values.first
        guard let recent else { return .none }
        return .send(.activate(workspaceId: recent, setFocus: true))

      case .focusAdjacentDisplay(let direction):
        let ordered = displays.all()
        guard ordered.count > 1 else { return .none }
        let startIndex = state.focusedDisplay
          .flatMap { f in ordered.firstIndex { $0.matches(f) } } ?? 0
        let nextDisplay = ordered[(startIndex + direction + ordered.count) % ordered.count]
        // The workspace currently active on that display, if any.
        guard let wsId = state.activeWorkspacesByDisplay
          .first(where: { $0.key.matches(nextDisplay) })?.value
        else { return .none }
        return .send(.activate(workspaceId: wsId, setFocus: true))

      case .moveFocusedAppToAdjacent(let direction):
        guard let id = adjacentWorkspaceId(by: direction, state: state) else { return .none }
        return .send(.moveFocusedAppTo(workspaceId: id))

      case .moveFocusedAppTo(let workspaceId):
        return resolveFrontmostApp { bundleId, name in
          .focusedAppResolved(bundleId: bundleId, name: name, workspaceId: workspaceId)
        }

      case .focusedAppResolved(let bundleId, let name, let workspaceId):
        state.$config.withLock { config in
          config.mutateActiveProfile { profile in
            // Carry the app's existing assignment (display name, icon,
            // auto-open) across the move; fall back to the live name for an
            // app that wasn't assigned to any workspace yet.
            let existing = profile.workspaces
              .flatMap(\.apps)
              .first { $0.bundleIdentifier == bundleId }
            for i in profile.workspaces.indices {
              profile.workspaces[i].apps.removeAll { $0.bundleIdentifier == bundleId }
            }
            if let idx = profile.workspaces.firstIndex(where: { $0.id == workspaceId }) {
              profile.workspaces[idx].apps.append(
                existing
                  ?? AppAssignment(bundleIdentifier: bundleId, name: name.isEmpty ? bundleId : name)
              )
            }
          }
        }
        state.tilingTrees[workspaceId] = nil
        return .send(.activate(workspaceId: workspaceId, setFocus: true))

      case .toggleFocusedAppInActiveWorkspace:
        guard state.primaryActiveWorkspaceID != nil else { return .none }
        return .run { send in
          let resolved = await MainActor.run {
            NSWorkspace.shared.frontmostApplication.map {
              (bundleId: $0.bundleIdentifier ?? "", name: $0.localizedName ?? "")
            }
          }
          guard let resolved, !resolved.bundleId.isEmpty else { return }
          await send(
            .focusedAppMembershipResolved(bundleId: resolved.bundleId, name: resolved.name)
          )
        }

      case .focusedAppMembershipResolved(let bundleId, let name):
        guard let workspaceId = state.primaryActiveWorkspaceID else { return .none }
        // Skip Tatami itself so the user can't accidentally assign it.
        if bundleId == "dev.PangMo5.Tatami" || bundleId == "dev.PangMo5.Tatami.dev" {
          return .none
        }
        var didAdd = false
        state.$config.withLock { config in
          config.mutateActiveProfile { profile in
            guard let idx = profile.workspaces.firstIndex(where: { $0.id == workspaceId })
            else { return }
            let alreadyMember = profile.workspaces[idx].apps
              .contains { $0.bundleIdentifier == bundleId }
            if alreadyMember {
              profile.workspaces[idx].apps.removeAll { $0.bundleIdentifier == bundleId }
            } else {
              // Single-membership: take it away from any other workspace
              // first so an app never lives in two registered sets.
              for i in profile.workspaces.indices {
                profile.workspaces[i].apps.removeAll { $0.bundleIdentifier == bundleId }
              }
              profile.workspaces[idx].apps.append(
                AppAssignment(
                  bundleIdentifier: bundleId,
                  name: name.isEmpty ? bundleId : name
                )
              )
              didAdd = true
            }
          }
        }
        // Re-activate so the hide/show pass + tree rebuild reflect the
        // new membership. setFocus stays false — the user just used a
        // hotkey, no need to steal focus from whatever they had.
        if didAdd {
          state.tilingTrees[workspaceId] = nil
        }
        let workspaceName = state.config.activeProfile?
          .workspaces.first(where: { $0.id == workspaceId })?.name ?? ""
        let displayName = name.isEmpty ? bundleId : name
        let hudTitle = didAdd
          ? "Added \(displayName) → \(workspaceName)"
          : "Removed \(displayName) ← \(workspaceName)"
        let hudIcon = didAdd ? "plus.circle.fill" : "minus.circle.fill"
        let showHUD = state.config.settings.hud.enabled
        return .merge(
          showHUD
            ? .run { [hud = workspaceHUD] _ in await hud.show(hudTitle, hudIcon) }
            : .none,
          .send(.activate(workspaceId: workspaceId, setFocus: false))
        )

      case .assignFocusedAppTo(let workspaceId):
        return .run { send in
          let resolved = await MainActor.run {
            NSWorkspace.shared.frontmostApplication.map {
              (bundleId: $0.bundleIdentifier ?? "", name: $0.localizedName ?? "")
            }
          }
          guard let resolved, !resolved.bundleId.isEmpty else { return }
          await send(
            .assignedAppResolved(
              bundleId: resolved.bundleId, name: resolved.name, workspaceId: workspaceId
            )
          )
        }

      case .assignedAppResolved(let bundleId, let name, let workspaceId):
        // Skip Tatami itself so the user can't accidentally assign it.
        if bundleId == "dev.PangMo5.Tatami" || bundleId == "dev.PangMo5.Tatami.dev" {
          return .none
        }
        state.$config.withLock { config in
          config.mutateActiveProfile { profile in
            guard let idx = profile.workspaces.firstIndex(where: { $0.id == workspaceId })
            else { return }
            // Duplicate assignment: add to the target *without* removing it
            // from any workspace it already belongs to. (Unlike `move`, which
            // relocates the app to a single workspace.)
            guard !profile.workspaces[idx].apps
              .contains(where: { $0.bundleIdentifier == bundleId })
            else { return }
            profile.workspaces[idx].apps.append(
              AppAssignment(bundleIdentifier: bundleId, name: name.isEmpty ? bundleId : name)
            )
          }
        }
        state.tilingTrees[workspaceId] = nil
        // Switch to the target so the just-assigned app is visible there.
        return .send(.activate(workspaceId: workspaceId, setFocus: true))

      case .toggleFloatingOnFocusedApp:
        return .run { send in
          let resolved = await MainActor.run {
            NSWorkspace.shared.frontmostApplication.map {
              (bundleId: $0.bundleIdentifier ?? "", name: $0.localizedName ?? "")
            }
          }
          guard let resolved, !resolved.bundleId.isEmpty else { return }
          await send(
            .focusedFloatToggleResolved(bundleId: resolved.bundleId, name: resolved.name)
          )
        }

      case .focusedFloatToggleResolved(let bundleId, let name):
        guard let workspaceId = state.primaryActiveWorkspaceID else { return .none }
        var nowFloating = false
        state.$config.withLock { config in
          config.mutateWorkspace(workspaceId) { workspace in
            if let idx = workspace.apps.firstIndex(where: { $0.bundleIdentifier == bundleId }) {
              workspace.apps[idx].floating.toggle()
              nowFloating = workspace.apps[idx].floating
            } else {
              // Floating a window that isn't assigned here yet adds it to this
              // workspace as a floating member.
              workspace.apps.append(
                AppAssignment(
                  bundleIdentifier: bundleId, name: name.isEmpty ? bundleId : name, floating: true
                )
              )
              nowFloating = true
            }
          }
        }
        // Rebuild the tree so the window drops out of / back into the layout.
        state.tilingTrees[workspaceId] = nil
        let displayName = name.isEmpty ? bundleId : name
        let hudTitle = nowFloating
          ? "Floating: \(displayName)"
          : "Tiled: \(displayName)"
        // Different glyphs for the two states so the HUD reads at a
        // glance — open frame for floating, filled stack for tiled.
        let hudIcon = nowFloating ? "rectangle.dashed" : "square.stack.3d.up.fill"
        let showHUD = state.config.settings.hud.enabled
        return .merge(
          .send(.activate(workspaceId: workspaceId, setFocus: false)),
          showHUD
            ? .run { [hud = workspaceHUD] _ in await hud.show(hudTitle, hudIcon) }
            : .none
        )

      case .togglePaused:
        let wasPaused = state.isTilingPaused
        state.isTilingPaused.toggle()
        if wasPaused {
          return reflowActiveWorkspace(state: &state)
        }
        return .none

      case .bspFocus(let direction):
        return resolveFocusedWindowKey { key in
          .bspFocusResolved(windowKey: key, direction: direction)
        }

      case .bspFocusResolved(let key, let direction):
        guard let workspaceId = state.primaryActiveWorkspaceID,
              let workspace = state.config.activeProfile?
                .workspaces.first(where: { $0.id == workspaceId }),
              let tree = state.tilingTrees[workspaceId]
        else { return .none }
        let settings = state.config.settings
        let display = workspace.displayHint ?? displays.current()
        let gap = CGFloat(settings.layout.gapInner)
        let workArea = MainActor.assumeIsolated {
          ScreenGeometry.workArea(for: display).insetBy(
            dx: CGFloat(settings.layout.gapOuter),
            dy: CGFloat(settings.layout.gapOuter)
          )
        }
        // Directional focus stays within the tiled set.
        guard let target = tree.directionalNeighbor(
          of: key,
          direction: direction,
          in: workArea,
          gap: gap,
          focusOrder: tree.windows
        ) else { return .none }
        let warpMouse = settings.focus.mouseFollowsFocus
        let zoomed = state.fullscreenZoomed[workspaceId] ?? []
        return .run { [mouse = mouse] _ in
          await MainActor.run {
            focusWindow(pid: target.pid, windowID: target.windowID)
            if warpMouse {
              let frames = Self.computeFrames(
                tree: tree, settings: settings, targetDisplay: display, fullscreenZoomed: zoomed
              )
              if let rect = frames[target] {
                mouse.warp(CGPoint(x: rect.midX, y: rect.midY))
              }
            }
          }
        }

      case .bspSwap(let direction):
        return resolveFocusedWindowKey { key in
          .bspOpResolved(windowKey: key, op: .swap(direction))
        }

      case .bspResize(let direction, let delta):
        return resolveFocusedWindowKey { key in
          .bspOpResolved(windowKey: key, op: .resize(direction, delta: delta))
        }

      case .bspToggleOrientation:
        return resolveFocusedWindowKey { key in
          .bspOpResolved(windowKey: key, op: .toggleOrientation)
        }

      case .bspToggleZoomParent:
        return resolveFocusedWindowKey { key in
          .bspOpResolved(windowKey: key, op: .toggleZoomParent)
        }

      case .bspToggleZoomFullscreen:
        return resolveFocusedWindowKey { key in
          .bspOpResolved(windowKey: key, op: .toggleZoomFullscreen)
        }

      case .bspSetInsertDirection(let direction):
        return resolveFocusedWindowKey { key in
          .bspOpResolved(windowKey: key, op: .setInsertDirection(direction))
        }

      case .bspBalance:
        // The manual balance command always equalizes both axes. The
        // `autoBalance` setting governs only the automatic balancing applied
        // on activation (see `performActivate`); gating the hotkey on it made
        // balance a no-op whenever auto-balance was off — which is the default.
        return applyTreeTransform(state: &state) { $0.balanced(axis: .both) }

      case .bspRotate(let degrees):
        return applyTreeTransform(state: &state) { $0.rotated(by: degrees) }

      case .bspMirror(let axis):
        return applyTreeTransform(state: &state) { $0.mirrored(axis: axis) }

      case .bspOpResolved(let key, let op):
        return applyBSPOp(windowKey: key, op: op, state: &state)

      case .persistedFullscreenZoomRestored(let workspaceId, let keys):
        state.fullscreenZoomed[workspaceId] = keys.isEmpty ? nil : keys
        return .none

      case .tilingTreeUpdated(let workspaceId, let tree):
        state.tilingTrees[workspaceId] = tree
        // Seed the insertion point with the focused leaf's top window
        // (or first leaf's top if focus isn't in the tree), so the
        // very next insert has somewhere to anchor.
        if let tree {
          let firstLeafWindow = tree.windows.first
          state.insertionPoint[workspaceId] = firstLeafWindow
        } else {
          state.insertionPoint[workspaceId] = nil
        }
        return .none

      case .activationCompleted(let id, let display):
        state.isActivating = false
        if let display, let previous = state.activeWorkspacesByDisplay[display], previous != id {
          state.previousWorkspacesByDisplay[display] = previous
        }
        if let display {
          state.activeWorkspacesByDisplay[display] = id
          state.lastActiveDisplay[id] = display
        }
        let treeIds = state.tilingTrees[id]?.windows.map(\.bundleId)
        let registeredIds = state.config.activeProfile?
          .workspaces.first(where: { $0.id == id })?
          .apps.map(\.bundleIdentifier) ?? []
        // Floating apps never enter the tree, and shared ones aren't in the
        // workspace's registered set either — without observing them their
        // windowCreated/Destroyed events never fire, so a newly opened
        // floating window got no mirror until its app was focused once.
        let floatingIds = state.config.sharedApps.map(\.bundleIdentifier)
          + (state.config.activeProfile?.workspaces.first(where: { $0.id == id })?
            .apps.filter(\.floating).map(\.bundleIdentifier) ?? [])
        let observeIds = Array(Set((treeIds ?? registeredIds) + floatingIds))
        debugLog.log(
          "Activate",
          "completed workspaceId=\(id) "
            + "treeWindows=\(state.tilingTrees[id]?.windows.map { $0.windowID } ?? []) "
            + "observe=\(observeIds)"
        )
        return .merge(
          .run { [observer = windowObserver] _ in await observer.observe(observeIds) },
          refreshMarkers(state: state)
        )
      }
    }
  }

  /// Re-tile the active workspace's current windows WITHOUT touching
  /// app visibility. Used on resume so tiling catches up to whatever
  /// changed while paused.
  private func reflowActiveWorkspace(state: inout State) -> Effect<Action> {
    guard !state.isTilingPaused,
          let workspaceId = state.primaryActiveWorkspaceID,
          let workspace = state.config.activeProfile?
            .workspaces.first(where: { $0.id == workspaceId })
    else { return .none }

    let settings = state.config.settings
    let display = workspace.displayHint ?? displays.current()
    let registered = workspace.apps.map(\.bundleIdentifier)
    let existing = state.tilingTrees[workspaceId]
    // On resume from pause we keep any transient (unregistered-anywhere)
    // members the user may have folded in before pausing. Without the
    // existing tree's bundle ids we'd discover only the registered apps
    // and the transient tiles would drop out silently.
    let existingBundles = existing?.windows.map(\.bundleId) ?? []
    let discoverBundles = Array(Set(registered + existingBundles))
    let slsClient = sls

    let snapshot = MainActor.assumeIsolated {
      () -> (targets: [WindowKey], focused: WindowKey?, workArea: CGRect) in
      let keys = discoverWindowKeys(forBundleIds: discoverBundles, sls: slsClient)
      let workArea = ScreenGeometry.workArea(for: display).insetBy(
        dx: CGFloat(settings.layout.gapOuter), dy: CGFloat(settings.layout.gapOuter)
      )
      return (keys, focusedWindowKey(), workArea)
    }

    let merged = Self.mergeTree(
      existing: existing,
      target: snapshot.targets,
      focused: snapshot.focused,
      insertionPoint: state.insertionPoint[workspaceId],
      workArea: snapshot.workArea,
      settings: settings
    )
    let axis = bspAxis(for: settings.layout.autoBalance)
    let balanced = axis == .none ? merged : merged?.balanced(axis: axis)
    state.tilingTrees[workspaceId] = balanced
    guard let tree = balanced else { return .none }
    if state.insertionPoint[workspaceId] == nil {
      state.insertionPoint[workspaceId] = tree.windows.first
    }
    let zoomed = state.fullscreenZoomed[workspaceId] ?? []
    let observeIds = Array(Set(tree.windows.map(\.bundleId)))

    return .merge(
      .run { [tiler = windowTiler] _ in
        let frames = await MainActor.run {
          Self.computeFrames(
            tree: tree, settings: settings, targetDisplay: display, fullscreenZoomed: zoomed
          )
        }
        if !frames.isEmpty {
          await tiler.apply(FrameApplication(windowFrames: frames, targetDisplay: display))
        }
      }
      .cancellable(id: CancelID.apply(workspaceId), cancelInFlight: true),
      .run { [observer = windowObserver] _ in await observer.observe(observeIds) },
      persist(tree, fullscreenZoomed: zoomed, for: workspace, default: settings.layout.defaultTilingMemory)
    )
  }

  private func debouncedSync(_ bundleId: String, delayMs: Int) -> Effect<Action> {
    .run { send in
      if delayMs > 0 {
        try? await Task.sleep(for: .milliseconds(delayMs))
      }
      await send(.syncAppWindows(bundleId: bundleId))
    }
    .cancellable(id: CancelID.sync(bundleId), cancelInFlight: true)
  }

  /// Schedule an off-screen prune after a short delay — a hidden window is
  /// still on screen for an instant after focus moves off it, so let it
  /// settle before snapshotting the on-screen set.
  private func debouncedPrune() -> Effect<Action> {
    .run { send in
      try? await Task.sleep(for: .milliseconds(120))
      await send(.pruneOffscreenWindows)
    }
    .cancellable(id: CancelID.prune, cancelInFlight: true)
  }

  /// Incrementally reconcile a single app's windows into the active
  /// workspace's tree. Insert windows new to the tree (next to the
  /// insertion point), remove vanished ones, leave the rest.
  /// Unassigned visible apps are *not* folded into the tree.
  private func syncAppWindows(bundleId: String, state: inout State) -> Effect<Action> {
    guard !state.isTilingPaused else {
      debugLog.log("Sync", "skip \(bundleId): tiling paused")
      return .none
    }
    if bundleId == "dev.PangMo5.Tatami" || bundleId == "dev.PangMo5.Tatami.dev" {
      return .none
    }
    // performActivate owns the tree during its async build — let it
    // finish, otherwise an incremental sync races it.
    guard !state.isActivating else {
      debugLog.log("Sync", "skip \(bundleId): activation in flight")
      return .none
    }
    guard let workspaceId = state.primaryActiveWorkspaceID,
          let workspace = state.config.activeProfile?
            .workspaces.first(where: { $0.id == workspaceId })
    else {
      debugLog.log("Sync", "skip \(bundleId): no active workspace")
      return .none
    }

    let settings = state.config.settings
    let display = workspace.displayHint ?? displays.current()
    let registeredSet = Set(workspace.apps.map(\.bundleIdentifier))
    // Floating = shown but never tiled (excluded from the tree): this
    // workspace's per-window floating apps + shared floating apps.
    let floatingSet = Set(workspace.apps.filter(\.floating).map(\.bundleIdentifier))
      .union(state.config.sharedApps.filter(\.floating).map(\.bundleIdentifier))
    // Shared tiled apps tile into every workspace's layout.
    let sharedTiledSet = Set(
      state.config.sharedApps.filter { !$0.floating }.map(\.bundleIdentifier)
    )
    let assignedAnywhere = Self.everyAssignedBundleId(in: state.config)
    let existing = state.tilingTrees[workspaceId]
    let inTree = existing?.windows.contains { $0.bundleId == bundleId } ?? false

    // Floating apps never enter the tree. Instead, refresh their mirror
    // overlays so a window opening / closing on a floating app is reflected
    // on top live (not just on the next activation).
    if floatingSet.contains(bundleId) {
      return refreshFloatingOverlay(state: state)
    }
    // Eligibility:
    //   * registered in this workspace → always tile.
    //   * a shared tiled app → tiles into every workspace.
    //   * already in the tree (transient member from an earlier sync)
    //     → keep tiling so the window doesn't suddenly fall out.
    //   * unregistered anywhere → transient: gets folded into the
    //     active workspace's tree because the user just opened/raised
    //     it after activation. The next activation rebuilds the tree
    //     from the registered set alone, so the transient drops out
    //     automatically.
    //   * registered in some *other* workspace → not tiled here;
    //     followAppFocus (if enabled) jumps to its owning workspace
    //     instead.
    let isUnregisteredAnywhere = !assignedAnywhere.contains(bundleId)
    let eligibleToAdd = registeredSet.contains(bundleId)
      || sharedTiledSet.contains(bundleId)
      || inTree
      || isUnregisteredAnywhere

    let slsClient = sls
    let (current, focused, workArea) = MainActor.assumeIsolated {
      () -> (current: [WindowKey], focused: WindowKey?, workArea: CGRect) in
      let cur = discoverWindowKeys(forBundleIds: [bundleId], sls: slsClient)
      let foc = focusedWindowKey()
      let wa = ScreenGeometry.workArea(for: display).insetBy(
        dx: CGFloat(settings.layout.gapOuter),
        dy: CGFloat(settings.layout.gapOuter)
      )
      return (cur, foc, wa)
    }
    if let focused, existing?.windows.contains(focused) == true {
      state.insertionPoint[workspaceId] = focused
    }
    let insertionPointKey = state.insertionPoint[workspaceId]

    let treeBefore = existing?.windows.map { $0.windowID } ?? []
    debugLog.log(
      "Sync",
      "enter \(bundleId) ws=\(workspace.name) eligible=\(eligibleToAdd) "
        + "(registered=\(registeredSet.contains(bundleId)) "
        + "inTree=\(inTree) unregistered=\(isUnregisteredAnywhere)) "
        + "discovered=\(current.map { $0.windowID }) treeBefore=\(treeBefore)"
    )

    var tree = existing
    let currentSet = Set(current)
    for key in (tree?.windows ?? []) where key.bundleId == bundleId && !currentSet.contains(key) {
      tree = tree?.removing(key)
    }

    // Insert new windows next to the insertion point. After each
    // insert, the new window becomes the insertion anchor — that's
    // what makes the dwindle wind instead of all-windows piling onto
    // one node.
    if eligibleToAdd {
      let viewSplit = settings.layout.splitType.bspSplitAxis()
      let placement: BSPNode<WindowKey>.Child = settings.layout.windowPlacement == .first
        ? .first
        : .second
      var anchor = insertionPointKey
      for key in current {
        guard let current = tree else {
          tree = .leaf(key)
          anchor = key
          state.insertionPoint[workspaceId] = key
          continue
        }
        if current.windows.contains(key) { continue }
        let present = Set(current.windows)
        let resolved = [anchor, focused]
          .compactMap { $0 }
          .first { present.contains($0) }
        tree = current.inserting(
          key,
          near: resolved,
          in: workArea,
          viewSplitType: viewSplit,
          globalPlacement: placement
        )
        anchor = key
        state.insertionPoint[workspaceId] = key
      }
    }

    let axis = bspAxis(for: settings.layout.autoBalance)
    let balanced = axis == .none ? tree : tree?.balanced(axis: axis)
    let oldWindows = Set(existing?.windows ?? [])
    let newWindows = Set(balanced?.windows ?? [])
    state.tilingTrees[workspaceId] = balanced

    let added = newWindows.subtracting(oldWindows).map { $0.windowID }
    let removed = oldWindows.subtracting(newWindows).map { $0.windowID }
    debugLog.log(
      "Sync",
      "result \(bundleId): added=\(added) removed=\(removed) "
        + "treeAfter=\(balanced?.windows.map { $0.windowID } ?? [])"
    )

    // Shared apps included so floating ones get window events too (they're
    // in neither the tree nor the workspace's registered set).
    let observeIds = Array(Set(
      (balanced?.windows.map(\.bundleId) ?? [])
        + Array(registeredSet)
        + state.config.sharedApps.map(\.bundleIdentifier)
    ))
    let observeEffect = Effect<Action>.run { [observer = windowObserver] _ in
      await observer.observe(observeIds)
    }
    let markerRefresh = refreshMarkers(state: state)

    guard oldWindows != newWindows, let final = balanced else {
      return .merge(observeEffect, markerRefresh)
    }

    // When a window closed and focus would otherwise be stranded on a
    // now-windowless app (the frontmost window is no longer part of this
    // workspace), pull focus to a remaining window so typing has a home.
    // Gated on `focused ∉ newWindows` so closing a *background* window while
    // a tiled window keeps focus never steals it.
    let refocusEffect: Effect<Action> = {
      guard settings.focus.refocusOnClose,
            !removed.isEmpty,
            focused == nil || !newWindows.contains(focused!)
      else { return .none }
      let target = (insertionPointKey.flatMap { newWindows.contains($0) ? $0 : nil })
        ?? final.windows.first
      guard let target else { return .none }
      return .run { _ in
        await MainActor.run { focusWindow(pid: target.pid, windowID: target.windowID) }
      }
    }()

    let zoomed = state.fullscreenZoomed[workspaceId] ?? []
    return .merge(
      .run { [tiler = windowTiler] _ in
        let frames = await MainActor.run {
          Self.computeFrames(
            tree: final,
            settings: settings,
            targetDisplay: display,
            fullscreenZoomed: zoomed
          )
        }
        if !frames.isEmpty {
          await tiler.apply(
            FrameApplication(windowFrames: frames, targetDisplay: display)
          )
        }
      }
      .cancellable(id: CancelID.apply(workspaceId), cancelInFlight: true),
      observeEffect,
      persist(final, fullscreenZoomed: zoomed, for: workspace, default: settings.layout.defaultTilingMemory),
      markerRefresh,
      refocusEffect
    )
  }

  /// Bundle ids registered to any workspace anywhere in the config.
  /// `syncAppWindows` uses this to decide whether a window belongs to
  /// the active workspace's tree (registered here / unregistered
  /// anywhere → transient) or to some other workspace (skip).
  private static func everyAssignedBundleId(in config: AppConfig) -> Set<String> {
    var out: Set<String> = []
    for profile in config.profiles {
      for ws in profile.workspaces {
        for app in ws.apps {
          out.insert(app.bundleIdentifier)
        }
      }
    }
    return out
  }

  /// Map persisted fullscreen-zoom bundle ids back onto live windows,
  /// consuming a distinct window per entry so that several zoomed windows
  /// of the *same* app each resolve to a different window (mirrors
  /// `BSPNode.hydrate`, which drains a per-bundle queue). Entries with no
  /// remaining live match are dropped — the layout degrades gracefully
  /// when an app has fewer windows than it did at save time.
  static func resolveFullscreenZoom(
    bundleIds: [String],
    among windows: [WindowKey]
  ) -> Set<WindowKey> {
    var available = windows
    var resolved: Set<WindowKey> = []
    for bundleId in bundleIds {
      guard let i = available.firstIndex(where: { $0.bundleId == bundleId })
      else { continue }
      resolved.insert(available.remove(at: i))
    }
    return resolved
  }

  /// Incremental merge. Removes vanished windows (sibling promotes),
  /// inserts new windows at the insertion point. Fresh trees (no
  /// existing) build via `BSPNode.build` (which uses the shallowest-
  /// leaf rule for each new window).
  private static func mergeTree(
    existing: BSPNode<WindowKey>?,
    target: [WindowKey],
    focused: WindowKey?,
    insertionPoint: WindowKey?,
    workArea: CGRect,
    settings: AppSettings
  ) -> BSPNode<WindowKey>? {
    guard !target.isEmpty else { return nil }
    let targetSet = Set(target)
    var tree = existing

    if var current = tree {
      let stale = current.windows.filter { !targetSet.contains($0) }
      for id in stale {
        if let next = current.removing(id) {
          current = next
        } else {
          tree = nil
          break
        }
      }
      if tree != nil { tree = current }
    }

    let newOnes = target.filter { id in
      !(tree?.windows.contains(id) ?? false)
    }
    guard !newOnes.isEmpty else { return tree }

    let viewSplit = settings.layout.splitType.bspSplitAxis()
    let placement: BSPNode<WindowKey>.Child = settings.layout.windowPlacement == .first
      ? .first
      : .second

    if tree == nil {
      // Initial tree — each insert picks the shallowest leaf, which
      // `inserting(...)` does when no anchor is supplied.
      var t: BSPNode<WindowKey>? = nil
      for key in newOnes {
        if let cur = t {
          t = cur.inserting(
            key, near: nil, in: workArea,
            viewSplitType: viewSplit, globalPlacement: placement
          )
        } else {
          t = .leaf(key)
        }
      }
      return t
    }

    for id in newOnes {
      let anchor: WindowKey? = {
        if let insertionPoint, tree?.windows.contains(insertionPoint) == true {
          return insertionPoint
        }
        if let focused, tree?.windows.contains(focused) == true {
          return focused
        }
        return nil
      }()
      tree = tree?.inserting(
        id, near: anchor, in: workArea,
        viewSplitType: viewSplit, globalPlacement: placement
      ) ?? .leaf(id)
    }
    return tree
  }

  // MARK: - Window key resolution

  private func resolveFocusedWindowKey(
    _ continuation: @escaping @Sendable (WindowKey) -> Action
  ) -> Effect<Action> {
    .run { send in
      let key = await MainActor.run { focusedWindowKey() }
      guard let key else { return }
      await send(continuation(key))
    }
  }

  private func resolveFrontmostApp(
    _ continuation: @escaping @Sendable (_ bundleId: String, _ name: String) -> Action
  ) -> Effect<Action> {
    .run { send in
      let resolved = await MainActor.run {
        NSWorkspace.shared.frontmostApplication.map {
          (bundleId: $0.bundleIdentifier ?? "", name: $0.localizedName ?? "")
        }
      }
      guard let resolved, !resolved.bundleId.isEmpty else { return }
      await send(continuation(resolved.bundleId, resolved.name))
    }
  }

  /// Snapshot the tree to disk when the workspace opted into
  /// `.persistent` memory. No-op otherwise. The tree is bundle-id
  /// keyed (`WindowKey`s die at process exit); fullscreen-zoom is
  /// recorded so it survives a restart too. Per-leaf parent-zoom is
  /// carried inside the tree itself.
  private func persist(
    _ tree: BSPNode<WindowKey>?,
    fullscreenZoomed: Set<WindowKey>,
    for workspace: Workspace,
    default defaultMemory: TilingMemory
  ) -> Effect<Action> {
    let memory = workspace.tilingMemory ?? defaultMemory
    guard memory == .persistent, let tree else { return .none }
    let id = workspace.id
    let template = tree.mapWindows { $0.bundleId }
    let zoomedBundleIds = fullscreenZoomed.map(\.bundleId).sorted()
    let snapshot = LayoutSnapshot(tree: template, fullscreenZoomedBundleIds: zoomedBundleIds)
    return .run { [store = layoutStore] _ in store.save(id, snapshot) }
  }

  // MARK: - Window marker

  private func markerTargets(state: State) -> [WindowKey: MarkerTarget] {
    var targets: [WindowKey: MarkerTarget] = [:]
    let cfg = state.config.settings.marker
    if cfg.fullscreenEnabled,
       let workspaceId = state.primaryActiveWorkspaceID
    {
      for key in state.fullscreenZoomed[workspaceId] ?? [] {
        targets[key] = MarkerTarget(colorHex: cfg.fullscreenColorHex)
      }
    }
    if cfg.floatingEnabled {
      // Mark floating windows only: shared floating apps + the active
      // workspace's per-window floating apps. Always visible (not focus-
      // gated) — the dot is what identifies a floating window / its mirror
      // at a glance.
      let activeFloating = state.primaryActiveWorkspaceID
        .flatMap { id in state.config.activeProfile?.workspaces.first { $0.id == id } }
        .map { $0.apps.filter(\.floating).map(\.bundleIdentifier) } ?? []
      let bundleIds = state.config.sharedApps.filter(\.floating).map(\.bundleIdentifier)
        + activeFloating
      let slsClient = sls
      let keys = MainActor.assumeIsolated {
        discoverWindowKeys(forBundleIds: bundleIds, sls: slsClient, requireResizable: false)
      }
      for key in keys {
        targets[key] = MarkerTarget(colorHex: cfg.floatingColorHex, alwaysVisible: true)
      }
    }
    return targets
  }

  /// Resolve the active workspace's floating apps (per-workspace + shared) to
  /// live windows and push them to the mirror overlay. Empty set tears every
  /// mirror down. Used on activation and whenever a floating app's windows
  /// change.
  private func refreshFloatingOverlay(state: State) -> Effect<Action> {
    let perWorkspace = state.primaryActiveWorkspaceID
      .flatMap { id in state.config.activeProfile?.workspaces.first { $0.id == id } }
      .map { $0.apps.filter(\.floating).map(\.bundleIdentifier) } ?? []
    let shared = state.config.sharedApps.filter(\.floating).map(\.bundleIdentifier)
    let bundleIds = Array(Set(perWorkspace + shared))
    let slsClient = sls
    let overlay = floatingOverlay
    return .run { _ in
      let keys = await MainActor.run {
        Set(discoverWindowKeys(forBundleIds: bundleIds, sls: slsClient, requireResizable: false))
      }
      overlay.setFloating(keys)
    }
  }

  private func refreshMarkers(state: State) -> Effect<Action> {
    let targets = markerTargets(state: state)
    let cfg = state.config.settings.marker
    let size = cfg.size
    let corner = cfg.corner
    let hideOnHover = cfg.hideOnHover
    return .run { [marker] _ in
      marker.setTargets(targets, size, corner, hideOnHover)
    }
  }

  // MARK: - Activation

  private func performActivate(
    workspaceId: Workspace.ID,
    setFocus: Bool,
    state: inout State
  ) -> Effect<Action> {
    guard let profile = state.config.activeProfile,
          let workspace = profile.workspaces.first(where: { $0.id == workspaceId })
    else { return .none }
    guard !state.isActivating else {
      debugLog.log("Activate", "skip workspaceId=\(workspaceId): already activating")
      return .none
    }
    state.isActivating = true
    let isPaused = state.isTilingPaused
    debugLog.log(
      "Activate",
      "start workspace=\(workspace.name) setFocus=\(setFocus) "
        + "paused=\(isPaused) registeredApps=\(workspace.apps.map(\.bundleIdentifier))"
    )

    // Resolve the pinned display to where it actually tiles: the connected
    // screen (UUID → name match), else the primary display as fallback.
    // Learn the UUID for a name-only hint so future matching is UUID-stable.
    let targetDisplay: DisplayName?
    if let hint = workspace.displayHint {
      let connected = MainActor.assumeIsolated {
        DisplayResolver.connectedScreen(for: hint)?.displayName
      }
      if let connected, hint.uuid != connected.uuid {
        state.$config.withLock { config in
          config.mutateWorkspace(workspaceId) { $0.displayHint = connected }
        }
      }
      targetDisplay = connected
        ?? MainActor.assumeIsolated { DisplayResolver.primaryScreen()?.displayName }
        ?? hint
    } else {
      targetDisplay = displays.current()
    }
    let request = ActivationRequest(
      workspace: workspace,
      sharedApps: state.config.sharedApps,
      targetDisplay: targetDisplay,
      setFocus: setFocus,
      mouseHidesOnFocus: setFocus && state.config.settings.focus.mouseHidesOnFocus
    )
    let warpMouse = setFocus && state.config.settings.focus.mouseFollowsFocus
    let showHUD = setFocus && state.config.settings.hud.enabled

    let settings = state.config.settings
    // Tile target: this workspace's tiled apps + shared tiled apps. Floating
    // apps (per-workspace or shared) are shown by the manager but kept out of
    // the tree.
    let bundleIds = workspace.apps.filter { !$0.floating }.map(\.bundleIdentifier)
      + state.config.sharedApps.filter { !$0.floating }.map(\.bundleIdentifier)
    // Floating apps (per-workspace + shared) are raised above the tiles after
    // the tile pass.
    let floatingBundleIds = workspace.apps.filter(\.floating).map(\.bundleIdentifier)
      + state.config.sharedApps.filter(\.floating).map(\.bundleIdentifier)
    let memory = workspace.tilingMemory ?? settings.layout.defaultTilingMemory
    let sessionTree = state.tilingTrees[workspace.id]
    let zoomed = state.fullscreenZoomed[workspace.id] ?? []
    let insertionPoint = state.insertionPoint[workspace.id]

    let hudName = workspace.name
    let hudIcon = workspace.symbolIconName
    let slsClient = sls

    return .run { [
      mgr = workspaceManager,
      tiler = windowTiler,
      store = layoutStore,
      hud = workspaceHUD,
      mouse = mouse,
      overlay = floatingOverlay
    ] send in
      if showHUD {
        await hud.show(hudName, hudIcon)
      }
      // Tear down the outgoing workspace's mirrors in the same beat as the
      // hide pass — leaving them to the post-tile `setFloating` made the
      // floating windows visibly outlive the windows they mirror.
      overlay.retainOnly(Set(floatingBundleIds))
      await mgr.activate(request)
      if !isPaused {
        let persistedSnapshot: LayoutSnapshot? =
          memory == .persistent && sessionTree == nil
            ? await store.load(workspaceId)
            : nil
        let (tree, frames, restoredZoom) = await MainActor.run {
          () -> (BSPNode<WindowKey>?, [WindowKey: CGRect], Set<WindowKey>) in
          let keys = discoverWindowKeys(forBundleIds: bundleIds, sls: slsClient)
          let focused = focusedWindowKey()
          let workArea = ScreenGeometry.workArea(for: targetDisplay).insetBy(
            dx: CGFloat(settings.layout.gapOuter),
            dy: CGFloat(settings.layout.gapOuter)
          )
          var base = sessionTree
          var persistedZoomBundleIds: [String] = []
          if let snapshot = persistedSnapshot {
            base = BSPNode.hydrate(template: snapshot.tree, keys: keys)
            persistedZoomBundleIds = snapshot.fullscreenZoomedBundleIds
          }
          let merged = Self.mergeTree(
            existing: base,
            target: keys,
            focused: focused,
            insertionPoint: insertionPoint,
            workArea: workArea,
            settings: settings
          )
          let axis = bspAxis(for: settings.layout.autoBalance)
          let tree = axis == .none ? merged : merged?.balanced(axis: axis)
          let resolvedZoom: Set<WindowKey> = {
            if !zoomed.isEmpty { return zoomed }
            guard let tree else { return [] }
            return Self.resolveFullscreenZoom(
              bundleIds: persistedZoomBundleIds, among: tree.windows
            )
          }()
          let frames = Self.computeFrames(
            tree: tree,
            settings: settings,
            targetDisplay: targetDisplay,
            fullscreenZoomed: resolvedZoom
          )
          return (tree, frames, resolvedZoom)
        }
        await send(.tilingTreeUpdated(workspaceId: workspaceId, tree: tree))
        if !restoredZoom.isEmpty, zoomed.isEmpty {
          await send(.persistedFullscreenZoomRestored(workspaceId: workspaceId, keys: restoredZoom))
        }
        if memory == .persistent, let tree {
          store.save(
            workspaceId,
            LayoutSnapshot(
              tree: tree.mapWindows { $0.bundleId },
              fullscreenZoomedBundleIds: restoredZoom.map(\.bundleId).sorted()
            )
          )
        }
        if !frames.isEmpty {
          await tiler.apply(
            FrameApplication(windowFrames: frames, targetDisplay: targetDisplay)
          )
        }
        // Mirror floating windows onto always-on-top panels (the Topit /
        // Floaty technique): a foreign window's level can't be raised without
        // SIP, so instead of trying we paint a live mirror above the tiles.
        // Passing the resolved set (possibly empty) also tears down mirrors
        // for apps that were just un-floated or belong to another workspace.
        let floatingKeys = await MainActor.run {
          Set(discoverWindowKeys(
            forBundleIds: floatingBundleIds, sls: slsClient, requireResizable: false
          ))
        }
        overlay.setFloating(floatingKeys)
        if warpMouse {
          let center = await MainActor.run { () -> CGPoint? in
            guard let key = focusedWindowKey(), let rect = frames[key] else { return nil }
            return CGPoint(x: rect.midX, y: rect.midY)
          }
          if let center { mouse.warp(center) }
        }
      }
      await send(.activationCompleted(workspaceId: workspaceId, display: targetDisplay))
    }
  }

  // MARK: - Manual resize / snap-back

  /// Re-apply the active workspace's current tree frames (no tree change) —
  /// snaps a dragged window back to its slot when the drag committed nothing.
  /// Drop active-workspace tree windows that have left the screen without an
  /// AX destroy event. Electron apps like Discord `hide()` their window on
  /// close instead of destroying it, so no `kAXUIElementDestroyedNotification`
  /// fires and the slot lingers; the on-screen window list is the only signal.
  /// Re-tiles the survivors and, when focus was stranded, pulls it to one.
  private func pruneOffscreenWindows(state: inout State) -> Effect<Action> {
    guard !state.isTilingPaused, !state.isActivating,
          let workspaceId = state.primaryActiveWorkspaceID,
          let workspace = state.config.activeProfile?
            .workspaces.first(where: { $0.id == workspaceId }),
          let tree = state.tilingTrees[workspaceId]
    else { return .none }

    let (onScreen, focused) = MainActor.assumeIsolated {
      () -> (Set<CGWindowID>, WindowKey?) in
      let raw = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
      ) as? [[String: Any]] ?? []
      var ids = Set<CGWindowID>()
      for entry in raw {
        if let n = entry[kCGWindowNumber as String] as? CGWindowID { ids.insert(n) }
      }
      return (ids, focusedWindowKey())
    }

    let gone = tree.windows.filter { !onScreen.contains($0.windowID) }
    guard !gone.isEmpty else { return .none }

    var pruned: BSPNode<WindowKey>? = tree
    for key in gone { pruned = pruned?.removing(key) }
    let settings = state.config.settings
    let axis = bspAxis(for: settings.layout.autoBalance)
    let balanced = axis == .none ? pruned : pruned?.balanced(axis: axis)
    state.tilingTrees[workspaceId] = balanced
    let newWindows = Set(balanced?.windows ?? [])

    debugLog.log(
      "Prune",
      "ws=\(workspace.name) removed=\(gone.map { $0.windowID }) "
        + "treeAfter=\(balanced?.windows.map { $0.windowID } ?? [])"
    )

    let display = workspace.displayHint ?? displays.current()
    let zoomed = state.fullscreenZoomed[workspaceId] ?? []

    let refocusEffect: Effect<Action> = {
      guard settings.focus.refocusOnClose, !newWindows.isEmpty,
            focused == nil || !newWindows.contains(focused!)
      else { return .none }
      let target = (state.insertionPoint[workspaceId].flatMap { newWindows.contains($0) ? $0 : nil })
        ?? balanced?.windows.first
      guard let target else { return .none }
      return .run { _ in
        await MainActor.run { focusWindow(pid: target.pid, windowID: target.windowID) }
      }
    }()

    let retile: Effect<Action> = balanced.map { final in
      .run { [tiler = windowTiler] _ in
        let frames = await MainActor.run {
          Self.computeFrames(
            tree: final, settings: settings, targetDisplay: display, fullscreenZoomed: zoomed
          )
        }
        if !frames.isEmpty {
          await tiler.apply(FrameApplication(windowFrames: frames, targetDisplay: display))
        }
      }
      .cancellable(id: CancelID.apply(workspaceId), cancelInFlight: true)
    } ?? .none

    return .merge(
      retile,
      persist(balanced, fullscreenZoomed: zoomed, for: workspace, default: settings.layout.defaultTilingMemory),
      refreshMarkers(state: state),
      refocusEffect
    )
  }

  private func retileActive(state: State) -> Effect<Action> {
    guard let workspaceId = state.primaryActiveWorkspaceID,
          let workspace = state.config.activeProfile?
            .workspaces.first(where: { $0.id == workspaceId }),
          let tree = state.tilingTrees[workspaceId]
    else { return .none }
    let settings = state.config.settings
    let display = workspace.displayHint ?? displays.current()
    let zoomed = state.fullscreenZoomed[workspaceId] ?? []
    return .run { [tiler = windowTiler] _ in
      let frames = await MainActor.run {
        Self.computeFrames(
          tree: tree, settings: settings, targetDisplay: display, fullscreenZoomed: zoomed
        )
      }
      if !frames.isEmpty {
        await tiler.apply(FrameApplication(windowFrames: frames, targetDisplay: display))
      }
    }
  }

  private func syncTreeRatio(
    for key: WindowKey,
    frame newFrame: CGRect,
    state: inout State
  ) -> Effect<Action> {
    guard let workspaceId = state.primaryActiveWorkspaceID,
          let workspace = state.config.activeProfile?
            .workspaces.first(where: { $0.id == workspaceId }),
          let tree = state.tilingTrees[workspaceId]
    else { return .none }

    let settings = state.config.settings
    let display = workspace.displayHint ?? displays.current()
    let gap = CGFloat(settings.layout.gapInner)
    let workArea = MainActor.assumeIsolated {
      ScreenGeometry.workArea(for: display).insetBy(
        dx: CGFloat(settings.layout.gapOuter),
        dy: CGFloat(settings.layout.gapOuter)
      )
    }

    // The window's currently-tiled frame; compared against the new AX frame
    // to see which edge(s) the user dragged. (1.5 px tolerance also rejects
    // the echo of our own apply.)
    guard let expected = tree.frames(in: workArea, gap: gap)[key] else { return .none }
    let tolerance: CGFloat = 1.5

    // Each dragged edge maps to the nearest ancestor split running along it
    // (its `fence`); set that split's divider to the edge's new position. This
    // resizes against the *right join* — unlike the immediate parent, which
    // controls a single axis and can't express, say, a height change when it
    // happens to be a vertical (left/right) split.
    var newTree = tree
    func adjust(_ direction: BSPDirection, edge: CGFloat) {
      guard let fencePath = newTree.fence(of: key, direction: direction, in: workArea, gap: gap),
            case .branch(let branch) = newTree.subtree(at: fencePath)
      else { return }
      let fenceRect = newTree.rect(at: fencePath, in: workArea, gap: gap)
      // `subdivide` lays children out as [first][gap][second]. For a window in
      // the *second* child (the .west / .north fence) the dragged edge is that
      // child's leading edge = divider + gap, so back the gap out to recover
      // the divider position; first-child edges (.east / .south) sit on it.
      let ratio: CGFloat
      switch branch.split {
      case .vertical:
        let total = fenceRect.width - gap
        guard total > 0 else { return }
        let divider = direction == .west ? edge - gap : edge
        ratio = (divider - fenceRect.minX) / total
      case .horizontal:
        let total = fenceRect.height - gap
        guard total > 0 else { return }
        let divider = direction == .north ? edge - gap : edge
        ratio = (divider - fenceRect.minY) / total
      }
      newTree = newTree.updatingRatio(at: fencePath, ratio: ratio)
    }

    if abs(newFrame.minX - expected.minX) > tolerance { adjust(.west, edge: newFrame.minX) }
    if abs(newFrame.maxX - expected.maxX) > tolerance { adjust(.east, edge: newFrame.maxX) }
    if abs(newFrame.minY - expected.minY) > tolerance { adjust(.north, edge: newFrame.minY) }
    if abs(newFrame.maxY - expected.maxY) > tolerance { adjust(.south, edge: newFrame.maxY) }

    guard newTree != tree else { return .none }
    state.tilingTrees[workspaceId] = newTree
    let zoomed = state.fullscreenZoomed[workspaceId] ?? []

    return .merge(
      .run { [tiler = windowTiler] _ in
        let frames = await MainActor.run {
          Self.computeFrames(
            tree: newTree,
            settings: settings,
            targetDisplay: display,
            fullscreenZoomed: zoomed
          )
        }
        if !frames.isEmpty {
          await tiler.apply(
            FrameApplication(windowFrames: frames, targetDisplay: display)
          )
        }
      },
      persist(newTree, fullscreenZoomed: zoomed, for: workspace, default: settings.layout.defaultTilingMemory)
    )
  }

  // MARK: - Drag-to-drop (drop-zone triangles)

  /// AX reported the user moved `key` to `frame`. Inspect the drop
  /// quadrant relative to the target tile:
  ///   * center → swap (or stack, future config)
  ///   * top triangle → warp to top child (SPLIT_X, CHILD_FIRST)
  ///   * right triangle → warp to right child (SPLIT_Y, CHILD_SECOND)
  ///   * bottom triangle → warp to bottom child (SPLIT_X, CHILD_SECOND)
  ///   * left triangle → warp to left child (SPLIT_Y, CHILD_FIRST)
  /// Either way the layout is reapplied, yanking the dragged window
  /// back to its real tile slot.
  /// Live, cursor-based drop decision for a window being dragged: which tile
  /// the cursor is over and which region of it (→ swap or directional
  /// insert). Returns nil when the cursor isn't over another tile. Used both
  /// to drive the overlay and — frozen into `pendingDrop` — to commit on
  /// mouse-up, so preview and result always agree.
  private func dropDecision(
    dragged: WindowKey,
    state: State
  ) -> (target: WindowKey, targetRect: CGRect, zone: DropZone)? {
    guard let workspaceId = state.primaryActiveWorkspaceID,
          let workspace = state.config.activeProfile?
            .workspaces.first(where: { $0.id == workspaceId }),
          let tree = state.tilingTrees[workspaceId],
          tree.pathTo(window: dragged) != nil
    else { return nil }

    let settings = state.config.settings
    let display = workspace.displayHint ?? displays.current()
    let (workArea, cursor) = MainActor.assumeIsolated { () -> (CGRect, CGPoint) in
      let area = ScreenGeometry.workArea(for: display).insetBy(
        dx: CGFloat(settings.layout.gapOuter),
        dy: CGFloat(settings.layout.gapOuter)
      )
      // Cursor in AX top-left coords (matches `frames` / `workArea`).
      let cocoa = NSEvent.mouseLocation
      let primaryHeight = NSScreen.screens.first?.frame.height ?? cocoa.y
      return (area, CGPoint(x: cocoa.x, y: primaryHeight - cocoa.y))
    }

    let allFrames = tree.frames(in: workArea, gap: CGFloat(settings.layout.gapInner))
    guard let target = allFrames.first(where: { other, rect in
            other != dragged && rect.contains(cursor)
          })?.key,
          let targetRect = allFrames[target]
    else { return nil }

    switch dropQuadrant(point: cursor, in: targetRect) {
    case .none: return nil
    case .center: return (target, targetRect, .swap)
    case .top: return (target, targetRect, .top)
    case .right: return (target, targetRect, .right)
    case .bottom: return (target, targetRect, .bottom)
    case .left: return (target, targetRect, .left)
    }
  }

  /// Commit a frozen drop decision: swap the two windows in place, or warp
  /// the dragged one into the chosen side of the target. Re-tiles + persists.
  private func applyDrop(
    _ drop: State.PendingDrop,
    state: inout State
  ) -> Effect<Action> {
    guard let workspaceId = state.primaryActiveWorkspaceID,
          let workspace = state.config.activeProfile?
            .workspaces.first(where: { $0.id == workspaceId }),
          let tree = state.tilingTrees[workspaceId],
          tree.pathTo(window: drop.dragged) != nil,
          tree.pathTo(window: drop.target) != nil
    else { return .none }

    let settings = state.config.settings
    let display = workspace.displayHint ?? displays.current()
    let newTree: BSPNode<WindowKey>
    switch drop.zone {
    case .swap:
      newTree = tree.swapping(drop.dragged, drop.target)
    case .top:
      newTree = warpInto(tree: tree, source: drop.dragged, target: drop.target, axis: .horizontal, child: .first)
    case .right:
      newTree = warpInto(tree: tree, source: drop.dragged, target: drop.target, axis: .vertical, child: .second)
    case .bottom:
      newTree = warpInto(tree: tree, source: drop.dragged, target: drop.target, axis: .horizontal, child: .second)
    case .left:
      newTree = warpInto(tree: tree, source: drop.dragged, target: drop.target, axis: .vertical, child: .first)
    }
    state.tilingTrees[workspaceId] = newTree
    let zoomed = state.fullscreenZoomed[workspaceId] ?? []

    return .merge(
      .run { [tiler = windowTiler] _ in
        let frames = await MainActor.run {
          Self.computeFrames(
            tree: newTree,
            settings: settings,
            targetDisplay: display,
            fullscreenZoomed: zoomed
          )
        }
        if !frames.isEmpty {
          await tiler.apply(
            FrameApplication(windowFrames: frames, targetDisplay: display)
          )
        }
      },
      persist(newTree, fullscreenZoomed: zoomed, for: workspace, default: settings.layout.defaultTilingMemory)
    )
  }

  /// Returns which quadrant of `rect` `point` falls into. The center
  /// is a square covering the middle 50% of the rect; outside it the
  /// four triangles fan out to the corners.
  private enum DropQuadrant { case none, center, top, right, bottom, left }
  private func dropQuadrant(point: CGPoint, in rect: CGRect) -> DropQuadrant {
    let wp = CGPoint(x: point.x - rect.origin.x, y: point.y - rect.origin.y)
    let centerRect = CGRect(
      x: 0.25 * rect.width, y: 0.25 * rect.height,
      width: 0.5 * rect.width, height: 0.5 * rect.height
    )
    if centerRect.contains(wp) { return .center }
    // Four triangles. Use signed cross products against the rect's
    // diagonals to classify.
    let mid = CGPoint(x: 0.5 * rect.width, y: 0.5 * rect.height)
    let onAboveDownDiag = (wp.x - 0) * (rect.height - 0) - (wp.y - 0) * (rect.width - 0) < 0
    let onAboveUpDiag = (wp.x - 0) * (0 - rect.height) - (wp.y - rect.height) * (rect.width - 0) < 0
    _ = mid
    // Coordinates are AX top-left (y grows downward), so the *top* triangle
    // is the small-y one, `(false, false)`, and the bottom is `(true, true)`.
    switch (onAboveDownDiag, onAboveUpDiag) {
    case (false, false): return .top
    case (false, true):  return .right
    case (true, true):   return .bottom
    case (true, false):  return .left
    }
  }

  /// Warp `source` next to `target` with a specific split axis +
  /// child placement: remove source from current slot, then re-insert
  /// next to target after seeding the target leaf's `preferredSplit`
  /// + `preferredChild`.
  private func warpInto(
    tree: BSPNode<WindowKey>,
    source: WindowKey,
    target: WindowKey,
    axis: BSPNode<WindowKey>.SplitAxis,
    child: BSPNode<WindowKey>.Child
  ) -> BSPNode<WindowKey> {
    guard let targetPath = tree.pathTo(window: target) else { return tree }
    let seeded = tree.replacing_(path: targetPath) { node in
      guard case .leaf(var leaf) = node else { return node }
      leaf.preferredSplit = axis
      leaf.preferredChild = child
      return .leaf(leaf)
    }
    guard let removed = seeded.removing(source) else { return tree }
    return removed.inserting(source, near: target, in: CGRect(x: 0, y: 0, width: 1, height: 1))
  }

  // MARK: - BSP ops

  private func applyBSPOp(
    windowKey: WindowKey,
    op: BSPOp,
    state: inout State
  ) -> Effect<Action> {
    guard let workspaceId = state.primaryActiveWorkspaceID,
          let workspace = state.config.activeProfile?
            .workspaces.first(where: { $0.id == workspaceId }),
          var tree = state.tilingTrees[workspaceId]
    else { return .none }

    let settings = state.config.settings
    let display = workspace.displayHint ?? displays.current()
    let gap = CGFloat(settings.layout.gapInner)
    let workArea = MainActor.assumeIsolated {
      ScreenGeometry.workArea(for: display).insetBy(
        dx: CGFloat(settings.layout.gapOuter),
        dy: CGFloat(settings.layout.gapOuter)
      )
    }

    switch op {
    case .swap(let direction):
      if let target = tree.directionalNeighbor(
        of: windowKey,
        direction: direction,
        in: workArea,
        gap: gap,
        focusOrder: tree.windows
      ) {
        tree = tree.swapping(windowKey, target)
      } else {
        let warped = tree.warping(windowKey, direction: direction)
        guard warped != tree else { return .none }
        tree = warped
      }

    case .resize(let direction, let delta):
      // Grow/shrink the focused window along the axis implied by the
      // direction. `resizing` walks to the nearest ancestor whose split
      // matches that axis and flips the sign by side, so a positive delta
      // always grows the focused window — including when it sits on the
      // east/south edge. (The previous fence-based path returned nil at the
      // edge, which made grow/shrink a no-op for edge windows.)
      let axis: BSPNode<WindowKey>.SplitAxis =
        (direction == .east || direction == .west) ? .vertical : .horizontal
      tree = tree.resizing(window: windowKey, axis: axis, delta: delta)

    case .toggleOrientation:
      tree = tree.togglingSplit(at: windowKey)

    case .toggleZoomParent:
      // Per-leaf zoom: tree unchanged, the focused leaf renders at
      // its parent branch's area on the next layout pass.
      tree = tree.togglingParentZoom(at: windowKey)

    case .toggleZoomFullscreen:
      // Tatami-specific multi-window fullscreen. Track in workspace
      // state; the tree itself is untouched. computeFrames trims
      // these windows out and overlays them on the work area.
      var set = state.fullscreenZoomed[workspaceId] ?? []
      if set.contains(windowKey) {
        set.remove(windowKey)
      } else {
        set.insert(windowKey)
      }
      state.fullscreenZoomed[workspaceId] = set.isEmpty ? nil : set

    case .setInsertDirection(let direction):
      tree = tree.settingInsertDirection(at: windowKey, direction: direction)
      // Update the per-workspace insertion point to this window so
      // the next inserted window honors the direction.
      if direction != nil {
        state.insertionPoint[workspaceId] = windowKey
      }
    }

    state.tilingTrees[workspaceId] = tree
    let zoomed = state.fullscreenZoomed[workspaceId] ?? []

    return .merge(
      .run { [tiler = windowTiler] _ in
        let frames = await MainActor.run {
          Self.computeFrames(
            tree: tree,
            settings: settings,
            targetDisplay: display,
            fullscreenZoomed: zoomed
          )
        }
        await tiler.apply(
          FrameApplication(windowFrames: frames, targetDisplay: display)
        )
      },
      persist(tree, fullscreenZoomed: zoomed, for: workspace, default: settings.layout.defaultTilingMemory),
      refreshMarkers(state: state)
    )
  }

  private func applyTreeTransform(
    state: inout State,
    _ transform: (BSPNode<WindowKey>) -> BSPNode<WindowKey>
  ) -> Effect<Action> {
    guard let workspaceId = state.primaryActiveWorkspaceID,
          let workspace = state.config.activeProfile?
            .workspaces.first(where: { $0.id == workspaceId }),
          let tree = state.tilingTrees[workspaceId]
    else { return .none }
    let newTree = transform(tree)
    state.tilingTrees[workspaceId] = newTree
    let settings = state.config.settings
    let display = workspace.displayHint ?? displays.current()
    let zoomed = state.fullscreenZoomed[workspaceId] ?? []
    return .merge(
      .run { [tiler = windowTiler] _ in
        let frames = await MainActor.run {
          Self.computeFrames(
            tree: newTree,
            settings: settings,
            targetDisplay: display,
            fullscreenZoomed: zoomed
          )
        }
        if !frames.isEmpty {
          await tiler.apply(
            FrameApplication(windowFrames: frames, targetDisplay: display)
          )
        }
      },
      persist(newTree, fullscreenZoomed: zoomed, for: workspace, default: settings.layout.defaultTilingMemory)
    )
  }

  // MARK: - Cycle

  private func cycle(by direction: Int, state: inout State) -> Effect<Action> {
    guard let id = adjacentWorkspaceId(by: direction, state: state) else { return .none }
    return .send(.activate(workspaceId: id, setFocus: true))
  }

  /// The workspace `direction` steps from the active one, honoring the
  /// `loop` / `skipEmpty` switching preferences. Shared by cycling and by
  /// "move focused app to next/previous workspace". Returns `nil` when there
  /// is no eligible target (e.g. at an end with looping off).
  private func adjacentWorkspaceId(by direction: Int, state: State) -> Workspace.ID? {
    guard let all = state.config.activeProfile?.workspaces, !all.isEmpty
    else { return nil }
    let settings = state.config.settings
    // Scope the cycle. `cycleAcrossDisplays` → every workspace. Otherwise stay
    // on the cursor's display: pinned workspaces by their display, dynamic
    // (unpinned) ones by the display they were last activated on (never-active
    // ones are included so they stay reachable).
    let workspaces: [Workspace]
    if !settings.switching.cycleAcrossDisplays, let focused = state.focusedDisplay {
      workspaces = all.filter { ws in
        if let hint = ws.displayHint {
          // A pinned workspace belongs to the display it actually tiles on —
          // the connected screen, or the primary as fallback — so one pinned
          // to a *disconnected* display stays reachable on the primary.
          let resolved = MainActor.assumeIsolated {
            DisplayResolver.screenOrPrimary(for: hint)?.displayName
          }
          return resolved?.matches(focused) ?? true
        }
        // Dynamic: the monitor it was last on (or include if never activated).
        if let last = state.lastActiveDisplay[ws.id] { return last.matches(focused) }
        return true
      }
    } else {
      workspaces = all
    }
    guard !workspaces.isEmpty else { return nil }
    // Anchor at the active workspace on the focused display.
    let currentID = state.primaryActiveWorkspaceID
    let currentIndex = workspaces.firstIndex { $0.id == currentID } ?? -1
    let count = workspaces.count

    let runningBundleIds: Set<String> = settings.switching.skipEmpty
      ? MainActor.assumeIsolated {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
      }
      : []

    var index = currentIndex
    for _ in 0 ..< count {
      let next = index + direction
      if settings.switching.loop {
        index = (next + count) % count
      } else {
        guard next >= 0, next < count else { return nil }
        index = next
      }
      let candidate = workspaces[index]
      if settings.switching.skipEmpty {
        let hasRunning = candidate.apps.contains {
          runningBundleIds.contains($0.bundleIdentifier)
        }
        if !hasRunning { continue }
      }
      return candidate.id
    }
    return nil
  }

  // MARK: - Helpers

  /// Lay the tree out, trimming fullscreen-zoomed windows so the rest
  /// of the tree shapes around as if they weren't present. Parent-zoom
  /// is handled inside `tree.frames(...)` directly.
  @MainActor
  static func computeFrames(
    tree: BSPNode<WindowKey>?,
    settings: AppSettings,
    targetDisplay: DisplayName?,
    fullscreenZoomed: Set<WindowKey> = []
  ) -> [WindowKey: CGRect] {
    guard let tree else { return [:] }
    let workArea = ScreenGeometry.workArea(for: targetDisplay).insetBy(
      dx: CGFloat(settings.layout.gapOuter),
      dy: CGFloat(settings.layout.gapOuter)
    )
    let gap = CGFloat(settings.layout.gapInner)
    let activeZoom = fullscreenZoomed.filter { tree.pathTo(window: $0) != nil }
    if !activeZoom.isEmpty {
      var trimmed: BSPNode<WindowKey>? = tree
      for key in activeZoom { trimmed = trimmed?.removing(key) }
      var frames = trimmed?.frames(in: workArea, gap: gap) ?? [:]
      for key in activeZoom { frames[key] = workArea }
      return frames
    }
    return tree.frames(in: workArea, gap: gap)
  }
}

@MainActor
func focusedWindowKey() -> WindowKey? {
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
  return WindowKey.from(
    axWindow: value as! AXUIElement,
    pid: app.processIdentifier,
    bundleId: bundleId
  )
}

/// Map an `AutoBalanceMode` to the `BSPNode.balanced(axis:)` enum.
private func bspAxis(for mode: AutoBalanceMode) -> AutoBalanceAxis {
  switch mode {
  case .none: return .none
  case .horizontal: return .horizontal
  case .vertical: return .vertical
  case .both: return .both
  }
}

extension SplitTypePreference {
  /// Translate the user-facing preference to the internal split axis
  /// used by `BSPNode.inserting(...)`. `.auto` returns nil so the
  /// aspect-ratio heuristic kicks in.
  func bspSplitAxis() -> BSPNode<WindowKey>.SplitAxis? {
    switch self {
    case .auto: return nil
    case .horizontal: return .horizontal
    case .vertical: return .vertical
    }
  }
}

// MARK: - BSPNode internal helper used by drag warp

extension BSPNode {
  /// File-internal `replacing(path:with:)` exposed under a different
  /// name so the reducer can patch leaf metadata directly. Identical
  /// implementation to the file-private version inside BSPTree.swift —
  /// we re-expose it here rather than make the original public so the
  /// public surface stays terse.
  fileprivate func replacing_(
    path: [Side],
    with transform: (BSPNode) -> BSPNode
  ) -> BSPNode {
    guard let next = path.first else {
      return transform(self)
    }
    switch self {
    case .leaf:
      return transform(self)
    case .branch(let b):
      let rest = Array(path.dropFirst())
      switch next {
      case .left:
        return .branch(BSPBranch(
          split: b.split,
          ratio: b.ratio,
          preferredChild: b.preferredChild,
          left: b.left.replacing_(path: rest, with: transform),
          right: b.right
        ))
      case .right:
        return .branch(BSPBranch(
          split: b.split,
          ratio: b.ratio,
          preferredChild: b.preferredChild,
          left: b.left,
          right: b.right.replacing_(path: rest, with: transform)
        ))
      }
    }
  }
}
