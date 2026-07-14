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
    /// Per-display MRU list of workspaces shown on it (newest first). Unlike
    /// `activeWorkspacesByDisplay`, this survives a disconnect (session only, not
    /// pruned when a display goes away), so reconnecting a monitor can restore
    /// its last workspace and walk older ones when the newest is in use.
    public var displayWorkspaceHistory: [DisplayName: [Workspace.ID]] = [:]
    /// Global MRU of workspaces (newest first), for the reconnect fallback of
    /// "the last-used dynamic workspace not in use on another display."
    public var workspaceMRU: [Workspace.ID] = []
    /// Displays connected as of the last reconfigure, to detect which ones are
    /// newly plugged in on the next change.
    public var connectedDisplays: Set<DisplayName> = []
    /// Reconnect restores to run one-at-a-time through the single (latest-wins)
    /// activation slot — dequeued as each activation completes.
    public var pendingDisplayRestores: [DisplayAssignment] = []
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
    /// True while the active Space is a native macOS fullscreen Space. Every
    /// layout side effect (reconcile, sync, prune, followAppFocus jump) is
    /// gated on this — re-tiling or raising a Desktop window from a fullscreen
    /// Space bounces the user straight back to the Desktop. Set from the
    /// space-change observer.
    public var isInFullscreenSpace = false
    /// Per-workspace BSP tree of window keys, kept in-memory only.
    public var tilingTrees: [Workspace.ID: BSPNode<WindowKey>] = [:]
    /// Sticky per-workspace insertion point. The next window inserted
    /// lands next to this one (and the `insertDirection` carried on its
    /// leaf decides north/east/south/west/stack). Updated by focus
    /// events.
    public var insertionPoint: [Workspace.ID: WindowKey] = [:]
    /// Per-workspace most-recently-used window order — front is most recent,
    /// session-only, pruned to the live tree. Written by focus events and
    /// never reset by tree updates (unlike `insertionPoint`), so it drives
    /// both "restore last window" on activation and the refocus target when
    /// the focused window closes — fall back through the list to the next
    /// most-recent window that's still on screen.
    public var mruWindows: [Workspace.ID: [WindowKey]] = [:]
    /// Per-workspace set of fullscreen-zoomed windows. Tatami-specific
    /// multi-window fullscreen: each member is trimmed from the tree
    /// before layout and rendered at the workspace's work area. Several
    /// can be active at once; focus determines which sits on top
    /// visually. Persisted via `LayoutSnapshot.fullscreenZoomedBundleIds`.
    /// Parent-zoom is *not* tracked here — that one lives inside the
    /// tree leaves directly.
    public var fullscreenZoomed: [Workspace.ID: Set<WindowKey>] = [:]

    /// Active composition per display — a host workspace plus borrowed
    /// blocks. Absent → that display shows its host alone (default behavior).
    public var compositionsByDisplay: [DisplayName: Composition] = [:]
    /// Workspace awaiting a direction key to be borrowed into the current
    /// screen; nil when not capturing. Set by the borrow combo; a direction
    /// keystroke commits the borrow at that edge.
    public var borrowCaptureTarget: Workspace.ID?

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

    /// The Tatami-managed universe: every bundle id registered to a workspace
    /// in the active profile, plus shared apps. Borrow activations pass this to
    /// the hide pass so an unregistered floating app isn't swept away with the
    /// managed ones; a plain switch passes an empty set and keeps the original
    /// "hide everything unassigned" behavior.
    var managedBundleIds: Set<String> {
      var ids = Set(config.sharedApps.map(\.bundleIdentifier))
      for workspace in config.activeProfile?.workspaces ?? [] {
        for app in workspace.apps { ids.insert(app.bundleIdentifier) }
      }
      return ids
    }

    /// The composed workspace (borrowed block or host) that should own a
    /// window of `bundleId` — by tree membership when `key` is known, else by
    /// app registration in a borrowed workspace (so a brand-new borrowed
    /// window routes to its block before it syncs in). Falls back to the
    /// active workspace, so every non-composed path is byte-identical to
    /// before.
    func composedOwner(bundleId: String, key: WindowKey?) -> Workspace.ID? {
      guard let display = focusedDisplay,
            let comp = compositionsByDisplay[display]
      else { return primaryActiveWorkspaceID }
      if let key {
        for slot in comp.borrowed
        where tilingTrees[slot.workspace]?.windows.contains(key) == true {
          return slot.workspace
        }
        if tilingTrees[comp.host]?.windows.contains(key) == true { return comp.host }
      }
      for slot in comp.borrowed
      where config.activeProfile?.workspaces[id: slot.workspace]?
        .apps.contains(where: { $0.bundleIdentifier == bundleId }) == true {
        return slot.workspace
      }
      return comp.host
    }

    /// The workspace owning `key` within the focused display's composition:
    /// a borrowed workspace if the key is in its tree, else the host. With no
    /// composition active this returns the single active workspace, so every
    /// non-composed path behaves byte-identically to before.
    func workspaceOwning(_ key: WindowKey) -> Workspace.ID? {
      composedOwner(bundleId: key.bundleId, key: key)
    }

    /// The workspace the user is acting in: owner of the focused window,
    /// falling back to the single active workspace. Replaces
    /// `primaryActiveWorkspaceID` for focus-relative ops once composed.
    func focusedWorkspaceID(focusedKey: WindowKey?) -> Workspace.ID? {
      if let key = focusedKey { return workspaceOwning(key) }
      return primaryActiveWorkspaceID
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
    /// Set the active profile from the persisted session (ProfileSessionStore)
    /// at startup, before `activateInitial` — no re-activation of its own.
    case restoreActiveProfile(Profile.ID)
    /// Re-activate the whole active profile across *every* connected display —
    /// a manual profile switch fires no `displaysReconfigured`, so this re-runs
    /// the same per-display restore plan to retile all monitors for the new
    /// profile (apps show/hide/tile per its workspaces).
    case reactivateActiveProfile
    /// Startup permission gate: prompt for any missing permission, surfacing
    /// Accessibility + Screen Recording together when both are absent.
    case surfaceMissingPermissions
    case activate(workspaceId: Workspace.ID, setFocus: Bool)
    case activateNext
    case activatePrevious
    case activateRecent
    /// Restore a workspace onto a specific display (silent, no focus steal) —
    /// used when a monitor is reconnected. Dynamic workspaces are pinned to the
    /// display for this activation via `displayOverride`.
    case restoreDisplay(workspaceId: Workspace.ID, display: DisplayName)
    /// Drain the reconnect-restore queue one activation at a time through the
    /// single (latest-wins) activation slot.
    case processDisplayRestores
    /// Borrow another workspace into the focused display's host. Re-borrowing
    /// the same target re-docks it to the new edge.
    case borrow(workspaceId: Workspace.ID, edge: BorrowEdge)
    /// Drop the active borrow on a display (internal: composition collapse).
    case dismissBorrow(display: DisplayName?)
    /// Start borrowing `workspaceId`: with a default edge, borrow immediately;
    /// otherwise arm a one-key direction pick (h/j/k/l or arrows). Re-firing
    /// for the same pending target cancels.
    case beginBorrowDirection(workspaceId: Workspace.ID)
    /// Assign the focused app to the recent / adjacent workspace + switch
    /// there — the recent/next/previous key with the assign modifier.
    case assignFocusedAppToRecentWorkspace
    case assignFocusedAppToAdjacentWorkspace(direction: Int)
    /// Borrow the recent / adjacent workspace — the recent/next/previous key
    /// with the borrow modifier.
    case borrowRecentWorkspace
    case borrowAdjacentWorkspace(direction: Int)
    /// Internal: a decoded direction keystroke from the borrow direction pick.
    case borrowChordKey(BorrowChordKey)
    /// Internal: re-flush a display's composition after its trees change.
    case flushComposition(display: DisplayName?)
    /// Internal: land focus + cursor on a freshly-borrowed block once its tree
    /// is in state — the deliberate-summon focus an unhide-only borrow can't
    /// provide on its own.
    case focusBorrowedBlock(workspaceId: Workspace.ID)
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
    /// GUI layout-preview edit for the *active* workspace: apply a structural
    /// op to its live tree, re-tile on screen, and persist per memory setting.
    case layoutEdited(workspaceId: Workspace.ID, op: LayoutEditOp)
    /// A GUI edit changed an *inactive* workspace's saved layout — drop its
    /// resident in-memory tree/zoom so the next activation rebuilds from the
    /// edited snapshot rather than the stale session state.
    case invalidateResidentLayout(workspaceId: Workspace.ID)
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
    /// A native-Space change (or wake): re-read whether the active Space is a
    /// native fullscreen Space, set `isInFullscreenSpace`, and reconcile only
    /// when it isn't (re-tiling into a fullscreen Space bounces to the Desktop).
    case activeSpaceChanged
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
    /// Bubbled to AppFeature, which owns the profile-switch side effects
    /// (hotkey rebind, session-store save, HUD) the activation feature can't do.
    case delegate(Delegate)

    public enum Delegate: Equatable {
      /// A display rule matched and this feature already retiled for it —
      /// AppFeature runs the remaining switch side effects.
      case profileAutoActivated(Profile.ID)
    }
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
    /// Equalize both split axes. Resolved against the focused window so it
    /// balances the owning block when a composition is active.
    case balance
  }

  /// Cancellation identifiers for debounced window-event handling.
  enum CancelID: Hashable {
    case sync(String)
    /// Coalesces frame application per workspace: a newer layout
    /// cancels an in-flight apply so a stale one can't land after it.
    case apply(Workspace.ID)
    case applyComposition(DisplayName)
    /// Debounces the off-screen prune so rapid app switches collapse into one.
    case prune
    /// Single-consumer stream subscriptions: `cancelInFlight` makes a
    /// repeated subscribe replace the old consumer instead of trapping
    /// AsyncStream with a second one.
    case windowEvents
    case appLaunchEvents
    /// Auto-cancels borrow-mode key capture if the user never finishes the
    /// chord, so the tap can't keep swallowing keystrokes.
    case borrowChordTimeout
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
  @Dependency(\.borrowChord) var borrowChord
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
          },
          .run { [borrowChord] send in
            // Borrow-mode key capture; the tap only emits while armed.
            for await key in borrowChord.events() {
              await send(.borrowChordKey(key))
            }
          }
        )
        .cancellable(id: CancelID.windowEvents, cancelInFlight: true)

      case .displaysReconfigured(let names):
        let connected = Set(names)
        // Displays present now but not at the last reconfigure = freshly plugged
        // in. (Empty `connectedDisplays` is the pre-startup state; seed it in
        // `activateInitial` so a first *unplug* isn't mistaken for a plug-in.)
        let newlyConnected = Set(names.filter { !state.connectedDisplays.contains($0) })
        // Only a real connect/disconnect (the display *set* changed) triggers a
        // re-tile; a bare resolution/arrangement tweak doesn't reshuffle
        // workspaces.
        let setChanged = connected != state.connectedDisplays
        state.connectedDisplays = connected
        state.activeWorkspacesByDisplay = state.activeWorkspacesByDisplay
          .filter { connected.contains($0.key) }
        state.previousWorkspacesByDisplay = state.previousWorkspacesByDisplay
          .filter { connected.contains($0.key) }
        // Drop last-display records for displays that are gone so dynamic
        // workspaces aren't stranded off-screen in the cycle.
        state.lastActiveDisplay = state.lastActiveDisplay
          .filter { connected.contains($0.value) }
        // `displayWorkspaceHistory` is deliberately NOT filtered — it must
        // survive a disconnect so a reconnect can restore the monitor's last
        // workspace.
        if let focused = state.focusedDisplay, !connected.contains(focused) {
          state.focusedDisplay = nil
        }
        debugLog.log(
          "Display",
          "reconfigured connected=\(names.map(\.name)) "
            + "new=\(newlyConnected.map(\.name)) "
            + "activeByDisplay=\(state.activeWorkspacesByDisplay.map { "\($0.key.name)→\($0.value)" }) "
            + "focused=\(state.focusedDisplay?.name ?? "nil")"
        )
        guard setChanged else { return .none }
        // Auto-activation: if a profile's display rule now matches the connected
        // set (and isn't already active), switch to it and retile every display
        // for the new profile. Its workspace ids differ from the current
        // profile's, so start fresh — clear the per-display map and fill all.
        var autoSwitch: Effect<Action> = .none
        var restoreNewlyConnected = newlyConnected
        var restoreActive = state.activeWorkspacesByDisplay
        let currentActiveProfile = state.config.activeProfileId ?? state.config.profiles.first?.id
        if let matched = state.config.autoActiveProfile(connected: connected),
           matched != currentActiveProfile {
          state.$config.withLock { $0.activeProfileId = matched }
          state.activeWorkspacesByDisplay = [:]
          restoreActive = [:]
          restoreNewlyConnected = connected
          autoSwitch = .send(.delegate(.profileAutoActivated(matched)))
          debugLog.log(
            "Profile",
            "auto-activate \(state.config.activeProfile?.name ?? "?") for \(names.map(\.name))"
          )
        }
        guard let profile = state.config.activeProfile else { return autoSwitch }
        let plan = Self.planDisplayRestore(
          connected: names,
          newlyConnected: restoreNewlyConnected,
          workspaces: profile.workspaces.elements,
          active: restoreActive,
          history: state.displayWorkspaceHistory,
          workspaceMRU: state.workspaceMRU
        )
        guard !plan.isEmpty else { return autoSwitch }
        debugLog.log(
          "Display",
          "restore plan=\(plan.map { "\($0.display.name)→\($0.workspace)" })"
        )
        state.pendingDisplayRestores = plan
        return .merge(autoSwitch, .send(.processDisplayRestores))

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
          if let key, let wsId = state.composedOwner(bundleId: bundleId, key: key) {
            let treeWindows = state.tilingTrees[wsId]?.windows ?? []
            let inTree = treeWindows.contains(key)
            // insertionPoint is the *tile* anchor, so only tree windows.
            if inTree { state.insertionPoint[wsId] = key }
            // MRU also records a just-created window not yet synced into the
            // tree (focus a brand-new window, open KakaoTalk, close it →
            // focus should return to the new window, not the first leaf), as
            // long as it belongs to this workspace.
            let wsApps = state.config.activeProfile?.workspaces[id: wsId]?.apps ?? []
            let isMember = inTree
              || wsApps.contains { $0.bundleIdentifier == bundleId }
              || state.config.sharedApps.contains { $0.bundleIdentifier == bundleId }
            if isMember {
              var mru = state.mruWindows[wsId] ?? []
              mru.removeAll { $0 == key }
              mru.insert(key, at: 0)
              // Prune closed windows, but keep the just-focused key even if
              // it hasn't synced into the tree yet.
              mru.removeAll { $0 != key && !treeWindows.contains($0) }
              state.mruWindows[wsId] = mru
            }
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
        case .windowTitleChanged:
          // Cosmetic — only the layout preview cares. No re-tile.
          return .none
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
              await send(.activeSpaceChanged)
            }
          }
        }
        .cancellable(id: CancelID.appLaunchEvents, cancelInFlight: true)

      case .activeSpaceChanged:
        // Re-read whether we're in a native fullscreen Space. Every layout side
        // effect (sync, prune, reconcile, followAppFocus jump) is gated on this
        // flag — re-tiling into a fullscreen Space fights the OS and bounces the
        // user to the Desktop; returning from one catches the tree up below.
        let nowFullscreen = sls.isActiveSpaceFullscreen()
        state.isInFullscreenSpace = nowFullscreen
        debugLog.log("Space", "active space changed: fullscreen=\(nowFullscreen)")
        return nowFullscreen ? .none : .send(.reconcileAllTrackedApps)

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
        // Observe the new app immediately — even before it's in any tree.
        // A transient (unregistered) app's first window can appear seconds after
        // launch with AX not yet ready; the initial sync then discovers nothing,
        // and because the app isn't in any tree it's also not in the observe set
        // — so nothing re-triggers discovery and the late window never tiles
        // (until the next workspace switch). Arming the observer now breaks that
        // chicken-and-egg: its AX-retry installs kAXWindowCreated as soon as the
        // app is reachable, which re-runs the sync when the window shows up.
        return .merge(
          debouncedSync(bundleId, delayMs: 10),
          .run { [observer = windowObserver] _ in await observer.observe([bundleId]) }
        )

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
        // Workspaces (on any display) already on screen — a focus within one of
        // them shouldn't switch away.
        let activeWorkspaceIds = Set(state.activeWorkspacesByDisplay.values)
        let hostsApp: (Workspace) -> Bool = { $0.apps.contains { $0.bundleIdentifier == bundleId } }
        if !state.isActivating,
           // A borrow direction-pick is armed — a repeat app-activation must
           // not re-fire the jump (re-entering beginBorrowDirection cancels the
           // pending pick). Opening a scratchpad app fires appActivated more
           // than once, and a borrow never makes it the active workspace, so
           // without this the second event kills the direction prompt.
           state.borrowCaptureTarget == nil,
           state.config.settings.switching.followAppFocus,
           !state.config.sharedApps.contains(where: { $0.bundleIdentifier == bundleId }),
           // An app can belong to several workspaces. Prefer the one already on
           // screen so focusing it there stays put; only fall back to another
           // (and jump) when no active workspace hosts it. Without the first
           // clause, a multi-membership app always jumped to its first-listed
           // workspace (e.g. focus Ghostty in Notion bounced to Terminal).
           let owner = state.config.activeProfile?.workspaces
             .first(where: { activeWorkspaceIds.contains($0.id) && hostsApp($0) })
             ?? state.config.activeProfile?.workspaces.first(where: hostsApp),
           // Suppress only when the owner is already on screen as part of a
           // composition (its host or a borrowed block) — focusing within a
           // borrow shouldn't switch away. An app from any *other* workspace
           // still jumps: it drops the live composition (or summons a
           // scratchpad as a borrow, replacing the current one), so a borrow
           // never traps focus on a third app.
           !state.compositionsByDisplay.values.contains(where: {
             $0.host == owner.id || $0.borrowed.contains { $0.workspace == owner.id }
           }),
           // An app activating as its window enters native fullscreen would
           // otherwise jump to its workspace and raise Desktop windows, bouncing
           // the user back out of the fullscreen Space (symptom: enter fullscreen
           // of a workspace-B app from A → lands on Desktop + switches to B).
           !state.isInFullscreenSpace,
           // Jump only when the owner isn't already on screen anywhere.
           !activeWorkspaceIds.contains(owner.id) {
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
        // Genuine destroy (a real close — not a monitor-unplug off-screen, which
        // fires no destroy): drop this window from any fullscreen-zoom set so a
        // reopened window doesn't inherit the closed one's zoom. The sync prune
        // deliberately keeps keys for transiently-absent windows; only a real
        // destroy clears them.
        for (wsId, zoom) in state.fullscreenZoomed where zoom.contains(where: { $0.windowID == wid }) {
          let remaining = zoom.filter { $0.windowID != wid }
          state.fullscreenZoomed[wsId] = remaining.isEmpty ? nil : remaining
        }
        return pruneOffscreenWindows(state: &state)

      case .pruneOffscreenWindows:
        return pruneOffscreenWindows(state: &state)

      case .appTerminated(let bundleId):
        return debouncedSync(bundleId, delayMs: 0)

      case .restoreActiveProfile(let id):
        // Startup-only: adopt the persisted selection if it still exists.
        // Bindings + `activateInitial` are sent after this, so they target it.
        guard state.config.profiles.contains(where: { $0.id == id }) else { return .none }
        state.$config.withLock { $0.activeProfileId = id }
        return .none

      case .reactivateActiveProfile:
        guard let profile = state.config.activeProfile else { return .none }
        let connected = displays.all()
        guard !connected.isEmpty else { return .send(.activateInitial) }
        // The prior per-display assignments point at the *old* profile's
        // workspace ids (independent per profile), so start fresh and re-fill
        // every display from the new profile — its pinned workspaces land on
        // their monitors, dynamics fill the rest (reuses the reconnect planner).
        state.activeWorkspacesByDisplay = [:]
        state.pendingDisplayRestores = []
        let plan = Self.planDisplayRestore(
          connected: connected,
          newlyConnected: Set(connected),
          workspaces: profile.workspaces.elements,
          active: [:],
          history: state.displayWorkspaceHistory,
          workspaceMRU: state.workspaceMRU
        )
        debugLog.log(
          "Profile",
          "reactivate \(profile.name) plan=\(plan.map { "\($0.display.name)→\($0.workspace)" })"
        )
        // Empty profile (nothing pinnable) → nothing to tile; leave screens as-is.
        guard !plan.isEmpty else { return .none }
        state.pendingDisplayRestores = plan
        return .send(.processDisplayRestores)

      case .delegate:
        return .none

      case .activateInitial:
        // Startup: a matching display rule wins over the persisted / first
        // selection, so launching docked lands in the docked profile.
        state.connectedDisplays = Set(displays.all())
        let startupActive = state.config.activeProfileId ?? state.config.profiles.first?.id
        if let matched = state.config.autoActiveProfile(connected: state.connectedDisplays),
           matched != startupActive {
          state.$config.withLock { $0.activeProfileId = matched }
          debugLog.log("Profile", "startup auto-activate for displays=\(displays.all().map(\.name))")
          return .merge(
            .send(.delegate(.profileAutoActivated(matched))),
            .send(.reactivateActiveProfile)
          )
        }
        // (connectedDisplays already seeded above so the first real reconfigure
        // diffs against reality — an unplug must not read as everything
        // plugging in.)
        guard let profile = state.config.activeProfile else { return .none }
        // Scratchpads are borrow-only — never auto-activate one on launch.
        let candidates = profile.workspaces.filter { $0.kind != .scratchpad }
        guard !candidates.isEmpty else { return .none }
        let frontBundle = windowSnapshot.frontmostApp()?.bundleId
        let target = candidates.first { ws in
          guard let fb = frontBundle else { return false }
          return ws.apps.contains { $0.bundleIdentifier == fb }
        } ?? candidates[0]
        debugLog.log(
          "Activate",
          "initial → ws=\(target.name) (frontmost=\(frontBundle ?? "nil"))"
        )
        return .send(.activate(workspaceId: target.id, setFocus: false))

      case .surfaceMissingPermissions:
        // Startup permission gate, kept beside the floating Screen-Recording
        // warning (performActivate) so all permission prompting funnels through
        // one feature. AX is the master gate — tiling does nothing without it —
        // so prompt it first; when Screen Recording is *also* missing, surface
        // both in the same beat (each system prompt + one HUD naming both)
        // instead of meeting the Screen-Recording prompt later, on the first
        // floating window. (When AX is missing the app can't tile, so the lazy
        // floating warning never fires before relaunch — no double prompt.)
        let permsHudMs = max(state.config.settings.hud.durationMs * 2, 4000)
        return .run { [screenRecording, workspaceHUD] _ in
          let axTrusted = await MainActor.run { isAccessibilityTrusted() }
          guard !axTrusted else { return }
          // AX is missing — always surface a HUD (AX is the master gate). Prompt
          // AX, and when Screen Recording is *also* missing prompt it in the same
          // beat and name both; otherwise name AX alone.
          _ = await MainActor.run { ensureAccessibilityTrust() }
          let subtitle: String
          if screenRecording.isGranted() {
            subtitle = "Grant Accessibility in System Settings → "
              + "Privacy & Security, then relaunch Tatami"
          } else {
            await screenRecording.requestAccess()
            subtitle = "Grant Accessibility and Screen Recording in System Settings → "
              + "Privacy & Security, then relaunch Tatami"
          }
          await workspaceHUD.show(
            "Permissions Needed", "exclamationmark.triangle.fill", subtitle, permsHudMs
          )
        }

      case .activate(let workspaceId, let setFocus):
        // A deliberate switch supersedes any in-flight reconnect restore cascade
        // — the user's action wins over the display-restore queue.
        state.pendingDisplayRestores = []
        return performActivate(
          workspaceId: workspaceId,
          setFocus: setFocus,
          state: &state
        )

      case .restoreDisplay(let workspaceId, let display):
        return performActivate(
          workspaceId: workspaceId,
          setFocus: false,
          displayOverride: display,
          state: &state
        )

      case .processDisplayRestores:
        guard !state.pendingDisplayRestores.isEmpty else { return .none }
        let next = state.pendingDisplayRestores.removeFirst()
        return .send(.restoreDisplay(workspaceId: next.workspace, display: next.display))

      case .borrow(let workspaceId, let edge):
        return performBorrow(targetId: workspaceId, edge: edge, state: &state)

      case .dismissBorrow(let display):
        return dismissBorrow(display: display, state: &state)

      case .beginBorrowDirection(let workspaceId):
        // Re-firing for the same pending target cancels.
        if state.borrowCaptureTarget == workspaceId {
          return endBorrowCapture(state: &state)
        }
        guard let ws = state.config.activeProfile?.workspaces[id: workspaceId]
        else { return .none }
        // Can't borrow the workspace that's already active on this display.
        if state.primaryActiveWorkspaceID == workspaceId {
          debugLog.log("Borrow", "skip borrow of current workspace \(ws.name)")
          return hudEffect(
            state, \.borrow, "Already here", "rectangle",
            subtitle: "Can't borrow the current workspace"
          )
        }
        // A configured default edge (per-workspace override, else global)
        // borrows immediately; otherwise arm the direction pick.
        if let edge = ws.borrowEdge ?? state.config.settings.switching.borrowDefaultEdge {
          return performBorrow(targetId: workspaceId, edge: edge, state: &state)
        }
        state.borrowCaptureTarget = workspaceId
        debugLog.log("BorrowChord", "begin borrow direction for \(ws.name)")
        return .merge(
          .run { [borrowChord] _ in await borrowChord.setArmed(true) },
          borrowChordTimeout(),
          borrowChordHint(state: state)
        )

      case .borrowChordKey(let key):
        guard let target = state.borrowCaptureTarget else { return .none }
        switch key {
        case .edge(let edge):
          let end = endBorrowCapture(state: &state)
          return .merge(end, performBorrow(targetId: target, edge: edge, state: &state))
        case .cancel:
          // Esc / timeout: end capture and clear the borrow-mode hint HUD.
          return .merge(
            endBorrowCapture(state: &state),
            .run { [workspaceHUD] _ in await workspaceHUD.dismiss() }
          )
        }

      case .assignFocusedAppToRecentWorkspace:
        guard let id = recentWorkspaceId(state: state) else { return .none }
        return .send(.membershipEdit(.assign(to: id)))

      case .assignFocusedAppToAdjacentWorkspace(let direction):
        guard let id = adjacentWorkspaceId(by: direction, state: state) else { return .none }
        return .send(.membershipEdit(.assign(to: id)))

      case .borrowRecentWorkspace:
        guard let id = recentWorkspaceId(state: state) else { return .none }
        return .send(.beginBorrowDirection(workspaceId: id))

      case .borrowAdjacentWorkspace(let direction):
        guard let id = adjacentWorkspaceId(by: direction, state: state) else { return .none }
        return .send(.beginBorrowDirection(workspaceId: id))

      case .flushComposition(let display):
        // Re-tile the composition and (re)push markers — the borrowed block's
        // windows now exist, so they can be badged with the source's icon.
        return .merge(
          applyComposition(display: display, state: state),
          refreshMarkers(state: state)
        )

      case .focusBorrowedBlock(let workspaceId):
        return focusBorrowedBlock(workspaceId: workspaceId, state: state)

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
        guard let workspaceId = state.workspaceOwning(key) ?? state.primaryActiveWorkspaceID,
              let tree = state.tilingTrees[workspaceId]
        else { return .none }
        // Cycle within the focused block. Floating/unmanaged join only when
        // uncomposed (their bundle sets resolve per active workspace, not per
        // block); each window is its own key so same-app windows cycle.
        var allWindows = tree.windows
        if state.compositionsByDisplay.isEmpty {
          let floatingBundles = Self.floatingBundleIds(state: state)
          if !floatingBundles.isEmpty {
            allWindows += windowSnapshot.cachedKeys(floatingBundles, false)
          }
          let unmanagedBundles = Self.unmanagedBundleIds(state: state)
          if !unmanagedBundles.isEmpty {
            allWindows += windowSnapshot.cachedKeys(unmanagedBundles, false)
          }
        }
        // App-level cycling (the default) keeps one representative window per
        // app, so a press lands on the next *app*; window-level cycling walks
        // every window, including same-app ones.
        let byWindow = state.config.settings.switching.cycleSameAppWindows
        var ordered = allWindows
        if !byWindow {
          var seenApps = Set<String>()
          ordered = allWindows.filter { seenApps.insert($0.bundleId).inserted }
        }
        guard ordered.count > 1 else { return .none }
        let n = ordered.count
        let step = direction == .next ? 1 : -1
        let idx = byWindow
          ? (ordered.firstIndex(of: key) ?? -1)
          : (ordered.firstIndex { $0.bundleId == key.bundleId } ?? -1)
        var target = ordered[((idx + step) % n + n) % n]
        // App-level cycle lands on the target app's most-recently-focused
        // window, not its first-in-tree representative — so returning to an app
        // restores the window you last used there (e.g. Dia's personal window,
        // not work). Falls back to the representative if the app has no MRU yet.
        if !byWindow {
          let mru = state.mruWindows[workspaceId] ?? []
          let live = Set(allWindows)
          if let recent = mru.first(where: { $0.bundleId == target.bundleId && live.contains($0) }) {
            target = recent
          }
        }
        guard target != key else { return .none }
        debugLog.log(
          "BSP",
          "cycle \(direction) \(key.bundleId)#\(key.windowID) "
            + "→ \(target.bundleId)#\(target.windowID)"
        )
        let cycleSettings = state.config.settings
        let (cycleDisplay, cycleRect) = tilingContext(for: workspaceId, state: state)
        let cycleWarp = cycleSettings.focus.mouseFollowsFocus
        let cycleZoomed = state.fullscreenZoomed[workspaceId] ?? []
        return .run { [mouse = mouse, focus = focusManager, target] _ in
          await focus.focusWindow(target)
          if cycleWarp {
            let frames = await MainActor.run {
              Self.computeFrames(
                tree: tree, settings: cycleSettings,
                targetDisplay: cycleDisplay, fullscreenZoomed: cycleZoomed,
                targetRect: cycleRect
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
        guard let workspaceId = state.workspaceOwning(key) ?? state.primaryActiveWorkspaceID,
              let tree = state.tilingTrees[workspaceId]
        else {
          debugLog.log("BSP", "focus \(direction): no active workspace/tree")
          return .none
        }
        let settings = state.config.settings
        let (display, workArea) = tilingContext(for: workspaceId, state: state)
        let gap = CGFloat(settings.layout.gapInner)
        // Directional focus moves within the block; at the block edge it can
        // cross into the sibling composition block (host ↔ borrowed).
        guard let target = tree.directionalNeighbor(
          of: key,
          direction: direction,
          in: workArea,
          gap: gap,
          focusOrder: tree.windows
        ) else {
          if let cross = crossBlockFocus(
            from: key, currentId: workspaceId, currentTree: tree,
            currentRect: workArea, direction: direction, state: state
          ) {
            debugLog.log("BSP", "focus \(direction) → cross into \(cross.target.bundleId)")
            let warp = settings.focus.mouseFollowsFocus
            return .run { [mouse = mouse, focus = focusManager] _ in
              await focus.focusWindow(cross.target)
              if warp {
                let frames = await MainActor.run {
                  Self.computeFrames(
                    tree: cross.tree, settings: settings, targetDisplay: cross.display,
                    fullscreenZoomed: cross.zoomed, targetRect: cross.rect
                  )
                }
                if let rect = frames[cross.target] {
                  mouse.warp(CGPoint(x: rect.midX, y: rect.midY))
                }
              }
            }
          }
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
                tree: tree, settings: settings, targetDisplay: display,
                fullscreenZoomed: zoomed, targetRect: workArea
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
        // Resolve the focused window first so balance targets the owning block
        // when a composition is active (and the HUD/flush stay in one place).
        return resolveFocusedWindowKey { key in
          .bspOpResolved(windowKey: key, op: .balance)
        }

      case .bspOpResolved(let key, let op):
        return applyBSPOp(windowKey: key, op: op, state: &state)

      case .layoutEdited(let workspaceId, let op):
        // Only the active workspace has a live tree here; the inactive path
        // edits the on-disk snapshot in WorkspaceDetailFeature instead.
        guard let workspace = state.config.activeProfile?.workspaces[id: workspaceId],
              let tree = state.tilingTrees[workspaceId]
        else { return .none }
        let newTree = tree.applying(op)
        guard newTree != tree else { return .none }
        state.tilingTrees[workspaceId] = newTree
        let zoomed = state.fullscreenZoomed[workspaceId] ?? []
        return .merge(
          flushLayout(workspaceId: workspaceId, state: state),
          persist(newTree, fullscreenZoomed: zoomed, for: workspace)
        )

      case .invalidateResidentLayout(let workspaceId):
        // The inactive workspace's saved snapshot was edited in the GUI. Its
        // resident session tree/zoom would otherwise win at the next activation
        // (activation only loads the snapshot when there's no session tree), so
        // drop them — activation then rebuilds from the edited snapshot.
        guard !state.activeWorkspacesByDisplay.values.contains(workspaceId) else { return .none }
        state.tilingTrees[workspaceId] = nil
        state.fullscreenZoomed[workspaceId] = nil
        state.insertionPoint[workspaceId] = nil
        return .none

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
        var emptiedByMove: [DisplayName] = []
        if let display {
          // Invariant: a workspace is on exactly one display. Clear stale copies
          // so a dynamic workspace that just moved here doesn't stay recorded on
          // the display it left (which would strand that monitor "occupied").
          for (other, ws) in state.activeWorkspacesByDisplay where other != display && ws == id {
            state.activeWorkspacesByDisplay[other] = nil
            emptiedByMove.append(other)
          }
          state.activeWorkspacesByDisplay[display] = id
          state.lastActiveDisplay[id] = display
          // Per-display MRU (survives disconnect): most recent first, deduped.
          var mru = state.displayWorkspaceHistory[display] ?? []
          mru.removeAll { $0 == id }
          mru.insert(id, at: 0)
          state.displayWorkspaceHistory[display] = mru
          // Global MRU too (reconnect dynamic fallback).
          state.workspaceMRU.removeAll { $0 == id }
          state.workspaceMRU.insert(id, at: 0)
        }
        // A display a dynamic workspace just vacated gets refilled with what the
        // user last had on it — same rules as a reconnect. Skipped mid-cascade
        // (a reconnect plan already schedules its own refills).
        if state.pendingDisplayRestores.isEmpty, !emptiedByMove.isEmpty,
           let profile = state.config.activeProfile {
          var byId: [Workspace.ID: Workspace] = [:]
          for w in profile.workspaces.elements where w.kind != .scratchpad { byId[w.id] = w }
          let fills = emptiedByMove
            .filter { state.connectedDisplays.contains($0) }
            .compactMap { vacated -> DisplayAssignment? in
              Self.chooseWorkspaceForDisplay(
                vacated, reconnect: false, byId: byId,
                workspaces: profile.workspaces.elements,
                assigned: state.activeWorkspacesByDisplay,
                history: state.displayWorkspaceHistory
              ).map { DisplayAssignment(display: vacated, workspace: $0) }
            }
          state.pendingDisplayRestores = fills
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
            .apps.filter { $0.layout == .floating }.map(\.bundleIdentifier) ?? [])
        // Unmanaged apps are members too — observe them so their window
        // events keep the cache fresh (FFM + cycling read it).
        let unmanagedIds = state.config.activeProfile?.workspaces[id: id]?
          .apps.filter { $0.layout == .unmanaged }.map(\.bundleIdentifier) ?? []
        let observeIds = Array(OrderedSet((treeIds ?? registeredIds) + floatingIds + unmanagedIds))
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
            : .merge(observeIds.map { debouncedSync($0, delayMs: 150) }),
          // Drain the reconnect-restore queue: this activation just freed the
          // single activation slot, so kick the next display's restore (if any).
          state.pendingDisplayRestores.isEmpty ? .none : .send(.processDisplayRestores)
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

  /// Composition-aware flush for a workspace whose tree was just mutated.
  /// When the workspace is a block in an active composition, the whole
  /// composition is re-laid (both blocks into their sub-rects) so a
  /// single-tree apply can't clobber the sibling block; otherwise it tiles
  /// into its own work area. The mutated tree must already be written to
  /// `state.tilingTrees[workspaceId]`.
  func flushLayout(workspaceId: Workspace.ID, state: State) -> Effect<Action> {
    for (display, comp) in state.compositionsByDisplay
    where comp.host == workspaceId
      || comp.borrowed.contains(where: { $0.workspace == workspaceId }) {
      return applyComposition(display: display, state: state)
    }
    guard let workspace = state.config.activeProfile?.workspaces[id: workspaceId],
          let tree = state.tilingTrees[workspaceId]
    else { return .none }
    let settings = state.config.settings
    let display = workspace.displayHint ?? displays.current()
    let zoomed = state.fullscreenZoomed[workspaceId] ?? []
    return applyLayout(
      tree: tree, workspaceId: workspaceId, settings: settings,
      display: display, fullscreenZoomed: zoomed
    )
  }

  /// Snapshot the tree to disk so the workspace's BSP layout survives a
  /// restart. The tree is bundle-id keyed (`WindowKey`s die at process exit);
  /// fullscreen-zoom is recorded so it survives too. Per-leaf parent-zoom is
  /// carried inside the tree itself. No-op only when the tree is empty.
  func persist(
    _ tree: BSPNode<WindowKey>?,
    fullscreenZoomed: Set<WindowKey>,
    for workspace: Workspace
  ) -> Effect<Action> {
    guard let tree else { return .none }
    let id = workspace.id
    // Occurrence-aware slots (windowID rank per bundle) so two windows of one
    // app persist their distinct positions; the same map keys the zoom set.
    let slots = slotAssignment(tree.windows)
    let template = tree.mapWindows { slots[$0]! }
    let zoomedSlots = fullscreenZoomed
      .compactMap { slots[$0] }
      .sorted { ($0.bundleId, $0.occurrence) < ($1.bundleId, $1.occurrence) }
    let snapshot = LayoutSnapshot(tree: template, fullscreenZoomedSlots: zoomedSlots)
    return .run { [store = layoutStore] _ in store.save(id, snapshot) }
  }

  // MARK: - BSP ops

  private func applyBSPOp(
    windowKey: WindowKey,
    op: BSPOp,
    state: inout State
  ) -> Effect<Action> {
    // Resolve to the block that owns the focused window — the borrowed
    // workspace when composed, else the single active one. Every mutation
    // runs on this one tree, so directional ops can't cross the boundary.
    guard let workspaceId = state.workspaceOwning(windowKey) ?? state.primaryActiveWorkspaceID,
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
    // The block's geometry: a composition sub-rect when composed, else the
    // workspace's full work area. (Display is re-derived in `flushLayout`.)
    let (_, workArea) = tilingContext(for: workspaceId, state: state)
    let gap = CGFloat(settings.layout.gapInner)
    // Ops with no obvious visual cue of their own attach a HUD here.
    var hud: Effect<Action> = .none
    // Ops that relocate the focused window itself (swap/warp) should carry the
    // cursor with it under mouse-follows-focus — the directional *focus* paths
    // already warp, but the swap path moved the window and left the cursor
    // behind on the now-other tile.
    var warpFocused = false

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
      warpFocused = true

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

    case .balance:
      tree = tree.balanced(axis: .both)
      hud = hudEffect(state, \.layout, "Layout Balanced", "equal.circle")
    }

    state.tilingTrees[workspaceId] = tree
    let zoomed = state.fullscreenZoomed[workspaceId] ?? []

    return .merge(
      flushLayout(workspaceId: workspaceId, state: state),
      persist(tree, fullscreenZoomed: zoomed, for: workspace),
      refreshMarkers(state: state),
      warpFocused
        ? warpToWindow(windowKey, in: tree, workspaceId: workspaceId, state: state)
        : .none,
      hud
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
