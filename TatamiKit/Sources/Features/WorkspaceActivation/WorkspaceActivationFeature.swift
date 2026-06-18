import AppKit
import ApplicationServices
import ComposableArchitecture
import Foundation
import OrderedCollections
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
    /// The workspace the in-flight activation is switching to. Cycling
    /// anchors here (falling back to the *completed* active workspace) so
    /// rapid next/previous presses advance from the switch in progress —
    /// anchoring at the completed one re-targeted the same slow workspace
    /// on every press, which read as the cycle being stuck on it.
    public var activatingWorkspaceID: Workspace.ID?
    /// Runtime-only "pause tiling" flag. Workspace switching keeps
    /// running while tiling is paused; flipped by `togglePaused`.
    public var isTilingPaused = false
    /// Per-workspace BSP tree of window keys, kept in-memory only.
    public var tilingTrees: [Workspace.ID: BSPNode<WindowKey>] = [:]
    /// Sticky per-workspace insertion point. The next window inserted
    /// lands next to this one (and the `insertDirection` carried on its
    /// leaf decides north/east/south/west/stack). Updated by focus
    /// events.
    public var insertionPoint: [Workspace.ID: WindowKey] = [:]
    /// Per-workspace most-recently-focused window, session-only. Unlike
    /// `insertionPoint` (which `tilingTreeUpdated` resets to the first
    /// leaf), this is only ever written by an actual focus event — so on
    /// re-activation it still names the exact window the user last used,
    /// which the "Most recently used" focus target restores.
    public var lastFocusedWindow: [Workspace.ID: WindowKey] = [:]
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
    /// What the in-flight manual drag will commit at mouse-up. One enum
    /// instead of three optionals: the commit outcomes are mutually
    /// exclusive, and the old triple admitted stale combinations (e.g. a
    /// pending drop with no dragged window) by construction.
    public enum DragState: Equatable, Sendable {
      case idle
      /// A resize drag — mouse-up syncs the tree ratio to the new frame.
      case resizing(PendingDrag)
      /// A move drag with a frozen drop decision (target tile + zone).
      case dropping(PendingDrop)
      /// A move drag with nothing committed yet — mouse-up re-tiles to
      /// snap the window back to its slot.
      case moving(WindowKey)
    }

    /// Warned about missing Screen Recording once already (per session) —
    /// floating windows silently lose their always-on-top mirrors without
    /// it, so the first activation that needs mirrors surfaces a system
    /// prompt + HUD instead of failing quietly.
    public var didWarnMissingScreenRecording = false

    public var drag: DragState = .idle

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
    case windowServerWindowDestroyed(CGWindowID)
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
    /// Hotkey entry point for every membership mutation of the focused
    /// window's app. The edits differ in which config collection they
    /// mutate and which HUD they show — that's data, not control flow, so
    /// one action pair carries all six instead of six near-identical pairs.
    case membershipEdit(MembershipEdit)
    case membershipEditResolved(bundleId: String, name: String, edit: MembershipEdit)
    case togglePaused
    case bspFocus(BSPDirection)
    case bspFocusResolved(windowKey: WindowKey, direction: BSPDirection)
    /// Cycle focus through every visible window in the active workspace
    /// (tiled + floating) — same-app windows cycle individually, and
    /// off-screen / other-space / minimized windows are excluded.
    case cycleWindow(CycleDirection)
    case cycleWindowResolved(windowKey: WindowKey, direction: CycleDirection)
    case bspSwap(BSPDirection)
    case bspResize(direction: BSPDirection, delta: CGFloat)
    case bspToggleOrientation
    /// Tatami's fullscreen-zoom: multi-window, takes the window out of
    /// the tree's layout and renders it at the work area.
    case bspToggleZoomFullscreen
    case bspBalance
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
    /// `performActivate` did not report completion within the watchdog
    /// window — release the `isActivating` gate so one wedged activation
    /// (an app stuck past every AX timeout) can't refuse all future
    /// activations and syncs for the rest of the session.
    case activationTimedOut
  }

  /// What to do with the focused window's app once it's resolved.
  /// Mutations live on `AppConfig` (see `AppConfig+Membership.swift`);
  /// the reducer only adds HUD + re-activation on top.
  public enum MembershipEdit: Sendable, Hashable {
    /// Add/remove in the active workspace (single-membership — adding
    /// takes the app away from any other workspace).
    case toggleInActiveWorkspace
    /// Flip floating in the active workspace (adds as floating member
    /// when not assigned there yet).
    case toggleFloating
    /// Flip shared floating (joins Shared Apps as floating when absent).
    case toggleSharedFloating
    /// Add/remove in Shared Apps (added tiled).
    case toggleShared
    /// Relocate to a single workspace and switch to it.
    case move(to: Workspace.ID)
    /// Duplicate-assign to a workspace (keeps other memberships) and
    /// switch to it.
    case assign(to: Workspace.ID)
  }

  /// Tag used to dispatch a BSP mutation once we've resolved the
  /// focused window's `WindowKey`.
  public enum BSPOp: Sendable, Hashable {
    case swap(BSPDirection)
    case resize(BSPDirection, delta: CGFloat)
    case toggleOrientation
    case toggleZoomFullscreen
  }

  /// Cancellation identifiers for debounced window-event handling.
  enum CancelID: Hashable {
    case sync(String)
    /// Coalesces frame application per workspace: a newer layout
    /// cancels an in-flight apply so a stale one can't land after it.
    case apply(Workspace.ID)
    /// Debounces the off-screen prune so rapid app switches collapse into one.
    case prune
    /// Single-consumer stream subscriptions: `cancelInFlight` makes a
    /// repeated subscribe replace the old consumer instead of trapping
    /// AsyncStream with a second one.
    case windowEvents
    case appLaunchEvents
    /// Releases the `isActivating` gate if an activation never completes
    /// (see `activationTimedOut`); cancelled by `activationCompleted`.
    case activationWatchdog
    /// Latest-wins workspace switching: a new activation cancels the
    /// in-flight one instead of being dropped, so a hotkey pressed while
    /// a slow activation runs (an app being slow to launch, AX waits
    /// under load) is never swallowed.
    case activation
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
  @Dependency(\.floatingOverlay) var floatingOverlay
  @Dependency(\.screenRecording) var screenRecording
  @Dependency(\.debugLog) var debugLog
  @Dependency(\.windowSnapshot) var windowSnapshot
  @Dependency(\.focusManager) var focusManager
  @Dependency(\.continuousClock) var clock
  @Dependency(\.sls) var sls

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      // Track the display the user is acting on so "the current workspace"
      // resolves to the focused monitor. Only user-intent entry points
      // refresh it: window events must not move it (the dragged window's
      // workspace stays stable as the cursor crosses monitors mid-drag),
      // and internal bookkeeping actions don't act on a display at all —
      // refreshing on *every* action cost an NSScreen scan + display-UUID
      // lookup per reduction during window-event storms, and made every
      // action a hidden state mutation.
      if Self.refreshesFocusedDisplay(action) {
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
          },
          .run { [sls] send in
            // WindowServer destroy events catch hide-on-close windows that
            // emit no AX notification (KakaoTalk), which the AX observer
            // can't see.
            for await wid in sls.windowDestructionEvents() {
              await send(.windowServerWindowDestroyed(wid))
            }
          }
        )
        .cancellable(id: CancelID.windowEvents, cancelInFlight: true)

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
        debugLog.log(
          "Display",
          "reconfigured connected=\(names.map(\.name)) "
            + "activeByDisplay=\(state.activeWorkspacesByDisplay.map { "\($0.key.name)→\($0.value)" }) "
            + "focused=\(state.focusedDisplay?.name ?? "nil")"
        )
        return .none

      case .windowChanged(let event):
        switch event {
        case .windowResized(let key, let frame):
          // Defer to drag-end: AX fires continuously during the drag, and
          // committing mid-drag re-tiles the siblings under the cursor.
          // Record the latest geometry; `.windowDragEnded` (mouse-up) flushes
          // it once, so the commit lands at the true end of the drag.
          state.drag = .resizing(State.PendingDrag(key: key, frame: frame))
          return .none
        case .windowMoved(let key, _):
          // A top-left resize fires Moved and Resized interleaved; once a
          // resize is pending it stays the commit — a move event must not
          // demote it to a drop/snap-back.
          if case .resizing = state.drag { return .none }
          // Cursor-based drop preview: find the tile + region under the
          // cursor and highlight it. Freeze the decision so the mouse-up
          // commit lands exactly where the overlay showed.
          let decision = dropDecision(dragged: key, state: state)
          state.drag = decision.map {
            .dropping(State.PendingDrop(dragged: key, target: $0.target, zone: $0.zone))
          } ?? .moving(key)
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
          let drag = state.drag
          state.drag = .idle
          var effects: [Effect<Action>] = [.run { _ in preview.hide() }]
          switch drag {
          case .idle:
            break
          case .resizing(let resize):
            debugLog.log(
              "Drag",
              "end resize \(resize.key.bundleId)#\(resize.key.windowID) frame=\(resize.frame)"
            )
            effects.append(syncTreeRatio(for: resize.key, frame: resize.frame, state: &state))
          case .dropping(let drop):
            debugLog.log(
              "Drag",
              "end drop \(drop.dragged.bundleId)#\(drop.dragged.windowID) "
                + "→ \(drop.target.bundleId)#\(drop.target.windowID) zone=\(drop.zone)"
            )
            effects.append(applyDrop(drop, state: &state))
          case .moving:
            // Dragged but nothing committed (dropped on empty space / back on
            // itself) → snap the window back to its tile.
            debugLog.log("Drag", "end without drop target — snap back")
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
            state.lastFocusedWindow[wsId] = key
          }
          // Forward the focus change to the marker controller so it
          // can render the dot only on the now-focused window.
          let markerClient = marker
          let focusedKey = key
          return .merge(
            debouncedSync(bundleId, delayMs: 0),
            // A hide-on-close window (KakaoTalk, Discord) fires no AX
            // destroy event; only the off-screen prune reclaims its
            // lingering tile. `appActivated` schedules one, but a same-app
            // close keeps that app frontmost — the next focus change is
            // then the only trigger left.
            debouncedPrune(),
            .run { _ in markerClient.setFocused(focusedKey) }
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
        .cancellable(id: CancelID.appLaunchEvents, cancelInFlight: true)

      case .reconcileAllTrackedApps:
        // Union of tree members + registered apps in the active
        // workspace: refresh every app we currently care about.
        var bundleIds: Set<String> = []
        for tree in state.tilingTrees.values {
          for window in tree.windows { bundleIds.insert(window.bundleId) }
        }
        if let workspaceId = state.primaryActiveWorkspaceID,
           let workspace = state.config.activeProfile?
             .workspaces[id: workspaceId]
        {
          for app in workspace.apps { bundleIds.insert(app.bundleIdentifier) }
        }
        guard !bundleIds.isEmpty else { return .none }
        return .merge(bundleIds.map { debouncedSync($0, delayMs: 10) })

      case .appLaunched(let bundleId, _):
        return debouncedSync(bundleId, delayMs: 10)

      case .appActivated(let bundleId):
        if MacApp.isTatami(bundleId) {
          return .none
        }
        // Refresh marker focus on every app activation. AX
        // `kAXFocusedWindowChanged` is only fired for the apps we
        // already observe, so a switch *into* a previously-unobserved
        // app wouldn't otherwise wake the marker.
        let markerClient = marker
        let markerEffect = Effect<Action>.run { [snapshot = windowSnapshot] _ in
          let key = await MainActor.run { snapshot.focusedWindowKey() }
          markerClient.setFocused(key)
        }
        if !state.isActivating,
           state.config.settings.switching.followAppFocus,
           !state.config.sharedApps.contains(where: { $0.bundleIdentifier == bundleId }),
           let owner = state.config.activeProfile?.workspaces.first(where: {
             $0.apps.contains { $0.bundleIdentifier == bundleId }
           }),
           state.primaryActiveWorkspaceID != owner.id {
          // The one path that switches workspaces without a hotkey — when a
          // bounce-back is suspected, this line (or its absence) is the tell.
          debugLog.log(
            "Activate",
            "followAppFocus jump: didActivate \(bundleId) → ws=\(owner.name)"
          )
          return .merge(
            markerEffect,
            .send(.activate(workspaceId: owner.id, setFocus: false)),
            debouncedPrune()
          )
        }
        // One focused-window resolution serves marker focus, insertion-
        // point tracking, and the sync — the `windowFocused` handler does
        // all three. Resolving here *and* eagerly inside the sync cost two
        // AX round trips to the just-activated app (the slowest possible
        // target — Electron apps answer AX late right after activation).
        return .merge(
          .run { [snapshot = windowSnapshot] send in
            let key = await MainActor.run { snapshot.focusedWindowKey() }
            await send(.windowChanged(.windowFocused(bundleId: bundleId, key: key)))
          },
          debouncedPrune()
        )

      case .windowServerWindowDestroyed(let wid):
        // A window vanished at the WindowServer level (incl. hide-on-close
        // with no AX event). This is authoritative, so prune now — the
        // debounce only exists to let a focus-driven off-screen guess
        // settle, which doesn't apply here.
        debugLog.log("SLS", "window destroyed wid=\(wid)")
        return pruneOffscreenWindows(state: &state)

      case .pruneOffscreenWindows:
        return pruneOffscreenWindows(state: &state)

      case .appTerminated(let bundleId):
        return debouncedSync(bundleId, delayMs: 0)

      case .activateInitial:
        guard let profile = state.config.activeProfile,
              !profile.workspaces.isEmpty
        else { return .none }
        let frontBundle = windowSnapshot.frontmostApp()?.bundleId
        let target = profile.workspaces.first { ws in
          guard let fb = frontBundle else { return false }
          return ws.apps.contains { $0.bundleIdentifier == fb }
        } ?? profile.workspaces[0]
        debugLog.log(
          "Activate",
          "initial → ws=\(target.name) (frontmost=\(frontBundle ?? "nil"))"
        )
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
        guard let recent else {
          debugLog.log("Activate", "recent: no previous workspace recorded")
          return .none
        }
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
        else {
          debugLog.log(
            "Display",
            "focusAdjacent → \(nextDisplay.name): no active workspace recorded"
          )
          return .none
        }
        debugLog.log("Display", "focusAdjacent → \(nextDisplay.name)")
        return .send(.activate(workspaceId: wsId, setFocus: true))

      case .moveFocusedAppToAdjacent(let direction):
        guard let id = adjacentWorkspaceId(by: direction, state: state) else { return .none }
        return .send(.membershipEdit(.move(to: id)))

      case .membershipEdit(let edit):
        if case .toggleInActiveWorkspace = edit, state.primaryActiveWorkspaceID == nil {
          return .none
        }
        return resolveFrontmostApp { bundleId, name in
          .membershipEditResolved(bundleId: bundleId, name: name, edit: edit)
        }

      case .membershipEditResolved(let bundleId, let name, let edit):
        // Tatami must never enter its own membership sets.
        if MacApp.isTatami(bundleId) { return .none }
        debugLog.log("App", "membership \(String(describing: edit)) bundle=\(bundleId)")
        let displayName = name.isEmpty ? bundleId : name
        switch edit {
        case .toggleInActiveWorkspace:
          guard let workspaceId = state.primaryActiveWorkspaceID else { return .none }
          var didAdd = false
          state.$config.withLock {
            didAdd = $0.toggleMembership(bundleId: bundleId, name: name, in: workspaceId)
          }
          // Re-activate so the hide/show pass + tree rebuild reflect the
          // new membership. setFocus stays false — the user just used a
          // hotkey, no need to steal focus from whatever they had.
          if didAdd {
            state.tilingTrees[workspaceId] = nil
          }
          let workspaceName = state.config.activeProfile?
            .workspaces[id: workspaceId]?.name ?? ""
          let hudTitle = didAdd
            ? "Added \(displayName) → \(workspaceName)"
            : "Removed \(displayName) ← \(workspaceName)"
          let hudIcon = didAdd ? "plus.circle.fill" : "minus.circle.fill"
          return .merge(
            hudEffect(state, \.appMembership, hudTitle, hudIcon),
            .send(.activate(workspaceId: workspaceId, setFocus: false))
          )

        case .toggleFloating:
          guard let workspaceId = state.primaryActiveWorkspaceID else { return .none }
          var nowFloating = false
          state.$config.withLock {
            nowFloating = $0.toggleFloating(bundleId: bundleId, name: name, in: workspaceId)
          }
          // Rebuild the tree so the window drops out of / back into the layout.
          state.tilingTrees[workspaceId] = nil
          let hudTitle = nowFloating
            ? "Floating: \(displayName)"
            : "Tiled: \(displayName)"
          // Different glyphs for the two states so the HUD reads at a
          // glance — open frame for floating, filled stack for tiled.
          let hudIcon = nowFloating ? "rectangle.dashed" : "square.stack.3d.up.fill"
          // Un-floating keeps the workspace assignment — hint at the
          // membership shortcut for users who meant "take it out entirely".
          let hudHint: String? = nowFloating
            ? nil
            : state.config.settings.shortcuts.toggleFocusedAppInActiveWorkspace.map { key in
              "Still in this workspace — \(key.symbols) removes it"
            }
          return .merge(
            .send(.activate(workspaceId: workspaceId, setFocus: false)),
            hudEffect(state, \.floating, hudTitle, hudIcon, subtitle: hudHint)
          )

        case .toggleSharedFloating:
          var nowFloating = false
          state.$config.withLock {
            nowFloating = $0.toggleSharedFloating(bundleId: bundleId, name: name)
          }
          let hudTitle = nowFloating
            ? "Shared Floating: \(displayName)"
            : "Shared Tiled: \(displayName)"
          let hudIcon = nowFloating ? "rectangle.dashed" : "square.stack.3d.up.fill"
          // Un-floating keeps the app shared (tiled everywhere) — hint at
          // the membership shortcut for users who meant "take it out of Shared".
          let hudHint: String? = nowFloating
            ? nil
            : state.config.settings.shortcuts.toggleAppInSharedApps.map { key in
              "Still in Shared Apps — \(key.symbols) removes it"
            }
          let hud = hudEffect(state, \.floating, hudTitle, hudIcon, subtitle: hudHint)
          guard let workspaceId = state.primaryActiveWorkspaceID else { return hud }
          state.tilingTrees[workspaceId] = nil
          return .merge(
            .send(.activate(workspaceId: workspaceId, setFocus: false)),
            hud
          )

        case .toggleShared:
          var didAdd = false
          state.$config.withLock {
            didAdd = $0.toggleSharedMembership(bundleId: bundleId, name: name)
          }
          let hudTitle = didAdd
            ? "Added \(displayName) → Shared Apps"
            : "Removed \(displayName) ← Shared Apps"
          let hudIcon = didAdd ? "plus.circle.fill" : "minus.circle.fill"
          let hud = hudEffect(state, \.appMembership, hudTitle, hudIcon)
          guard let workspaceId = state.primaryActiveWorkspaceID else { return hud }
          state.tilingTrees[workspaceId] = nil
          return .merge(
            .send(.activate(workspaceId: workspaceId, setFocus: false)),
            hud
          )

        case .move(let workspaceId):
          state.$config.withLock {
            $0.moveApp(bundleId: bundleId, name: name, to: workspaceId)
          }
          state.tilingTrees[workspaceId] = nil
          return .send(.activate(workspaceId: workspaceId, setFocus: true))

        case .assign(let workspaceId):
          state.$config.withLock {
            $0.assignApp(bundleId: bundleId, name: name, to: workspaceId)
          }
          state.tilingTrees[workspaceId] = nil
          // Switch to the target so the just-assigned app is visible there.
          return .send(.activate(workspaceId: workspaceId, setFocus: true))
        }

      case .togglePaused:
        let wasPaused = state.isTilingPaused
        state.isTilingPaused.toggle()
        let hud = hudEffect(
          state,
          \.tilingPaused,
          state.isTilingPaused ? "Tiling Paused" : "Tiling Resumed",
          state.isTilingPaused ? "pause.circle.fill" : "play.circle.fill"
        )
        if wasPaused {
          return .merge(reflowActiveWorkspace(state: &state), hud)
        }
        return hud

      case .cycleWindow(let direction):
        return resolveFocusedWindowKey { key in
          .cycleWindowResolved(windowKey: key, direction: direction)
        }

      case .cycleWindowResolved(let key, let direction):
        guard let workspaceId = state.primaryActiveWorkspaceID,
              let workspace = state.config.activeProfile?
                .workspaces[id: workspaceId],
              let tree = state.tilingTrees[workspaceId]
        else { return .none }
        // The visible windows of the active workspace: tiled (the BSP tree)
        // plus floating. Both are managed and on-screen, so off-screen /
        // other-space / minimized windows never enter the cycle. Each window
        // is its own key, so multiple windows of the same app cycle
        // individually.
        var ordered = tree.windows
        let floatingBundles = Self.floatingBundleIds(state: state)
        if !floatingBundles.isEmpty {
          ordered += windowSnapshot.cachedKeys(floatingBundles, false)
        }
        guard ordered.count > 1 else { return .none }
        let n = ordered.count
        let step = direction == .next ? 1 : -1
        let idx = ordered.firstIndex(of: key) ?? -1
        let target = ordered[((idx + step) % n + n) % n]
        guard target != key else { return .none }
        debugLog.log(
          "BSP",
          "cycle \(direction) \(key.bundleId)#\(key.windowID) "
            + "→ \(target.bundleId)#\(target.windowID)"
        )
        let cycleSettings = state.config.settings
        let cycleDisplay = workspace.displayHint ?? displays.current()
        let cycleWarp = cycleSettings.focus.mouseFollowsFocus
        let cycleZoomed = state.fullscreenZoomed[workspaceId] ?? []
        return .run { [mouse = mouse, focus = focusManager] _ in
          await focus.focusWindow(target)
          if cycleWarp {
            let frames = await MainActor.run {
              Self.computeFrames(
                tree: tree, settings: cycleSettings,
                targetDisplay: cycleDisplay, fullscreenZoomed: cycleZoomed
              )
            }
            if let rect = frames[target] {
              mouse.warp(CGPoint(x: rect.midX, y: rect.midY))
            }
          }
        }

      case .bspFocus(let direction):
        return resolveFocusedWindowKey { key in
          .bspFocusResolved(windowKey: key, direction: direction)
        }

      case .bspFocusResolved(let key, let direction):
        guard let workspaceId = state.primaryActiveWorkspaceID,
              let workspace = state.config.activeProfile?
                .workspaces[id: workspaceId],
              let tree = state.tilingTrees[workspaceId]
        else {
          debugLog.log("BSP", "focus \(direction): no active workspace/tree")
          return .none
        }
        let settings = state.config.settings
        let display = workspace.displayHint ?? displays.current()
        let gap = CGFloat(settings.layout.gapInner)
        let workArea = tilingWorkArea(for: display, settings: settings)
        // Directional focus stays within the tiled set.
        guard let target = tree.directionalNeighbor(
          of: key,
          direction: direction,
          in: workArea,
          gap: gap,
          focusOrder: tree.windows
        ) else {
          debugLog.log(
            "BSP",
            "focus \(direction) from \(key.bundleId)#\(key.windowID): no neighbor"
          )
          return .none
        }
        debugLog.log(
          "BSP",
          "focus \(direction) \(key.bundleId)#\(key.windowID) "
            + "→ \(target.bundleId)#\(target.windowID)"
        )
        let warpMouse = settings.focus.mouseFollowsFocus
        let zoomed = state.fullscreenZoomed[workspaceId] ?? []
        return .run { [mouse = mouse, focus = focusManager] _ in
          await focus.focusWindow(target)
          if warpMouse {
            let frames = await MainActor.run {
              Self.computeFrames(
                tree: tree, settings: settings, targetDisplay: display, fullscreenZoomed: zoomed
              )
            }
            if let rect = frames[target] {
              mouse.warp(CGPoint(x: rect.midX, y: rect.midY))
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

      case .bspToggleZoomFullscreen:
        return resolveFocusedWindowKey { key in
          .bspOpResolved(windowKey: key, op: .toggleZoomFullscreen)
        }

      case .bspBalance:
        // The manual balance command always equalizes both axes. The
        // `autoBalance` setting governs only the automatic balancing applied
        // on activation (see `performActivate`); gating the hotkey on it made
        // balance a no-op whenever auto-balance was off — which is the default.
        return .merge(
          applyTreeTransform(state: &state) { $0.balanced(axis: .both) },
          hudEffect(state, \.layout, "Layout Balanced", "equal.circle")
        )

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
        state.activatingWorkspaceID = nil
        if let display, let previous = state.activeWorkspacesByDisplay[display], previous != id {
          state.previousWorkspacesByDisplay[display] = previous
        }
        if let display {
          state.activeWorkspacesByDisplay[display] = id
          state.lastActiveDisplay[id] = display
        }
        let treeIds = state.tilingTrees[id]?.windows.map(\.bundleId)
        let registeredIds = state.config.activeProfile?
          .workspaces[id: id]?
          .apps.map(\.bundleIdentifier) ?? []
        // Floating apps never enter the tree, and shared ones aren't in the
        // workspace's registered set either — without observing them their
        // windowCreated/Destroyed events never fire, so a newly opened
        // floating window got no mirror until its app was focused once.
        let floatingIds = state.config.sharedApps.map(\.bundleIdentifier)
          + (state.config.activeProfile?.workspaces[id: id]?
            .apps.filter(\.floating).map(\.bundleIdentifier) ?? [])
        let observeIds = Array(OrderedSet((treeIds ?? registeredIds) + floatingIds))
        debugLog.log(
          "Activate",
          "completed workspaceId=\(id) "
            + "treeWindows=\(state.tilingTrees[id]?.windows.map { $0.windowID } ?? []) "
            + "observe=\(observeIds)"
        )
        return .merge(
          .cancel(id: CancelID.activationWatchdog),
          .run { [observer = windowObserver] _ in await observer.observe(observeIds) },
          // The unpaused path already pushed markers from the activation
          // effect's own floating discovery; only the paused path (which
          // skips that block) still needs a refresh here.
          state.isTilingPaused ? refreshMarkers(state: state) : .none,
          // Stale-while-revalidate: activation served its window keys from
          // `WindowKeyCache`, and window events that arrived *during* the
          // activation were dropped by the `isActivating` gate. Rescan every
          // bundle this workspace relies on now that the gate is open — the
          // per-app sync is a no-op when nothing drifted, and repairs the
          // tree (and the cache) when something did. The delay keeps the
          // rescan (a main-thread AX pass) out of rapid cycling: a switch
          // arriving sooner re-enters the gate and the sync drops; only a
          // workspace the user actually settles on pays for revalidation.
          state.isTilingPaused
            ? .none
            : .merge(observeIds.map { debouncedSync($0, delayMs: 150) })
        )

      case .activationTimedOut:
        guard state.isActivating else { return .none }
        state.isActivating = false
        state.activatingWorkspaceID = nil
        debugLog.log(
          "Activate",
          "watchdog: activation did not complete in 10 s — releasing the gate"
        )
        return .none
      }
    }
  }

  // MARK: - Window key resolution

  private func resolveFocusedWindowKey(
    _ continuation: @escaping @Sendable (WindowKey) -> Action
  ) -> Effect<Action> {
    .run { [snapshot = windowSnapshot, debugLog] send in
      let key = await MainActor.run { snapshot.focusedWindowKey() }
      guard let key else {
        // Silent-drop tell for "the BSP hotkey did nothing".
        debugLog.log("BSP", "no focused window — op dropped")
        return
      }
      await send(continuation(key))
    }
  }

  private func resolveFrontmostApp(
    _ continuation: @escaping @Sendable (_ bundleId: String, _ name: String) -> Action
  ) -> Effect<Action> {
    .run { [snapshot = windowSnapshot, debugLog] send in
      let resolved = await MainActor.run { snapshot.frontmostApp() }
      guard let resolved else {
        debugLog.log("App", "no frontmost app — membership edit dropped")
        return
      }
      await send(continuation(resolved.bundleId, resolved.name))
    }
  }

  /// The named display's work area inset by the outer gap — the rect
  /// every tiling computation runs in.
  func tilingWorkArea(for display: DisplayName?, settings: AppSettings) -> CGRect {
    displays.workArea(display).insetBy(
      dx: CGFloat(settings.layout.gapOuter),
      dy: CGFloat(settings.layout.gapOuter)
    )
  }

  /// Flush `tree`'s layout to the tiler: compute frames on the main actor,
  /// then apply. Every layout flush funnels through here so the coalescing
  /// policy can't drift per call site — `CancelID.apply(workspaceId)` with
  /// `cancelInFlight` guarantees a stale apply is cancelled the moment a
  /// newer layout for the same workspace starts flushing.
  func applyLayout(
    tree: BSPNode<WindowKey>,
    workspaceId: Workspace.ID,
    settings: AppSettings,
    display: DisplayName?,
    fullscreenZoomed: Set<WindowKey>
  ) -> Effect<Action> {
    .run { [tiler = windowTiler] _ in
      let frames = await MainActor.run {
        Self.computeFrames(
          tree: tree,
          settings: settings,
          targetDisplay: display,
          fullscreenZoomed: fullscreenZoomed
        )
      }
      guard !frames.isEmpty else { return }
      await tiler.apply(FrameApplication(windowFrames: frames, targetDisplay: display))
    }
    .cancellable(id: CancelID.apply(workspaceId), cancelInFlight: true)
  }

  /// Snapshot the tree to disk when the workspace opted into
  /// `.persistent` memory. No-op otherwise. The tree is bundle-id
  /// keyed (`WindowKey`s die at process exit); fullscreen-zoom is
  /// recorded so it survives a restart too. Per-leaf parent-zoom is
  /// carried inside the tree itself.
  func persist(
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

  // MARK: - BSP ops

  private func applyBSPOp(
    windowKey: WindowKey,
    op: BSPOp,
    state: inout State
  ) -> Effect<Action> {
    guard let workspaceId = state.primaryActiveWorkspaceID,
          let workspace = state.config.activeProfile?
            .workspaces[id: workspaceId],
          var tree = state.tilingTrees[workspaceId]
    else {
      debugLog.log(
        "BSP",
        "\(String(describing: op)) \(windowKey.bundleId)#\(windowKey.windowID): "
          + "no active workspace/tree"
      )
      return .none
    }
    debugLog.log(
      "BSP",
      "\(String(describing: op)) \(windowKey.bundleId)#\(windowKey.windowID)"
    )

    let settings = state.config.settings
    let display = workspace.displayHint ?? displays.current()
    let gap = CGFloat(settings.layout.gapInner)
    let workArea = tilingWorkArea(for: display, settings: settings)
    // Ops with no obvious visual cue of their own attach a HUD here.
    var hud: Effect<Action> = .none

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

    case .toggleZoomFullscreen:
      // Tatami-specific multi-window fullscreen. Track in workspace
      // state; the tree itself is untouched. computeFrames trims
      // these windows out and overlays them on the work area.
      var set = state.fullscreenZoomed[workspaceId] ?? []
      let zoomingIn = !set.contains(windowKey)
      if zoomingIn {
        set.insert(windowKey)
      } else {
        set.remove(windowKey)
      }
      state.fullscreenZoomed[workspaceId] = set.isEmpty ? nil : set
      hud = hudEffect(
        state,
        \.fullscreen,
        zoomingIn ? "Fullscreen" : "Exit Fullscreen",
        zoomingIn
          ? "arrow.up.left.and.arrow.down.right"
          : "arrow.down.right.and.arrow.up.left"
      )
    }

    state.tilingTrees[workspaceId] = tree
    let zoomed = state.fullscreenZoomed[workspaceId] ?? []

    return .merge(
      applyLayout(
        tree: tree, workspaceId: workspaceId, settings: settings,
        display: display, fullscreenZoomed: zoomed
      ),
      persist(tree, fullscreenZoomed: zoomed, for: workspace, default: settings.layout.defaultTilingMemory),
      refreshMarkers(state: state),
      hud
    )
  }

  private func applyTreeTransform(
    state: inout State,
    _ transform: (BSPNode<WindowKey>) -> BSPNode<WindowKey>
  ) -> Effect<Action> {
    guard let workspaceId = state.primaryActiveWorkspaceID,
          let workspace = state.config.activeProfile?
            .workspaces[id: workspaceId],
          let tree = state.tilingTrees[workspaceId]
    else { return .none }
    let newTree = transform(tree)
    state.tilingTrees[workspaceId] = newTree
    let settings = state.config.settings
    let display = workspace.displayHint ?? displays.current()
    let zoomed = state.fullscreenZoomed[workspaceId] ?? []
    return .merge(
      applyLayout(
        tree: newTree, workspaceId: workspaceId, settings: settings,
        display: display, fullscreenZoomed: zoomed
      ),
      persist(newTree, fullscreenZoomed: zoomed, for: workspace, default: settings.layout.defaultTilingMemory)
    )
  }

  // MARK: - Helpers

  /// Actions that represent the user acting on a display (hotkeys,
  /// gestures, membership edits) — exactly the ones that refresh
  /// `focusedDisplay`. The `*Resolved` continuations are deliberately
  /// absent: the display was resolved at their entry action, and
  /// re-resolving mid-flow could move the target if the cursor crossed
  /// monitors between the two beats.
  private static func refreshesFocusedDisplay(_ action: Action) -> Bool {
    switch action {
    case .activateInitial, .activate, .activateNext, .activatePrevious,
         .activateRecent, .focusAdjacentDisplay, .moveFocusedAppToAdjacent,
         .membershipEdit, .togglePaused, .bspFocus, .bspSwap, .bspResize,
         .bspToggleOrientation, .bspToggleZoomFullscreen, .bspBalance,
         .appActivated:
      return true
    default:
      return false
    }
  }
}
