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

  // MARK: Lifecycle

  public init() { }

  // MARK: Public

  @ObservableState
  public struct State: Equatable {

    // MARK: Lifecycle

    public init() { }

    // MARK: Public

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

    /// A direction-pick in progress. Capturing the pointer display together
    /// with the target keeps the eventual edge keystroke on the monitor where
    /// the user started the borrow, even if focus changes while the chord is
    /// armed.
    public struct BorrowCapture: Equatable, Sendable {
      public var display: DisplayName
      public var workspaceId: Workspace.ID
    }

    /// The deliberate focus/MFF completion still owed by a Borrow transaction.
    /// A cold app may publish its first WindowServer surface only after the
    /// initial reveal/discovery has completed, so composition membership alone
    /// is not enough to distinguish that first late window from an ordinary
    /// replacement window in a long-lived Borrow.
    public struct PendingBorrowCompletion: Equatable, Sendable {
      public var workspaceId: Workspace.ID
      public var generation: UInt64
    }

    /// A native-style keyboard window-cycle session. The focused window does
    /// not move while the shortcut modifier is held; repeated presses only
    /// advance `selected`, and releasing the modifier commits exactly once.
    public struct WindowCycleSession: Equatable, Sendable {
      public var workspaceId: Workspace.ID
      public var windows: [WindowKey]
      public var selected: WindowKey
      public var focusedWindow: WindowKey
      public var byWindow: Bool
      public var display: DisplayName?
      public var holdModifiers: HotKeyModifiers
      public var isHUDVisible: Bool
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

    /// Independent lifecycle reasons that freeze destructive window-membership
    /// updates. They may overlap: a sleeping Mac commonly wakes to a still-
    /// locked screen, and reconciliation must wait for both edges to clear.
    public enum LayoutSuspensionReason: Equatable, Hashable, Sendable {
      case screenLock
      case sessionInactive
      case systemSleep
    }

    @Shared(.tatamiConfig) public var config = AppConfig()
    public var activeWorkspacesByDisplay = [DisplayName: Workspace.ID]()
    /// Per-display "most recent" workspace, for switch-to-recent on the
    /// display the user is currently on (multi-monitor aware).
    public var previousWorkspacesByDisplay = [DisplayName: Workspace.ID]()
    /// Last display each workspace was activated on (including dynamic /
    /// unpinned ones), so cycling can scope dynamic workspaces to the monitor
    /// they were last on.
    public var lastActiveDisplay = [Workspace.ID: DisplayName]()
    /// Per-display MRU list of workspaces shown on it (newest first). Unlike
    /// `activeWorkspacesByDisplay`, this survives disconnects and app restarts,
    /// so each monitor can restore its last workspace and walk older valid ones
    /// when the newest was removed from config or is already in use.
    public var displayWorkspaceHistory = [DisplayName: [Workspace.ID]]()
    /// Global persisted MRU of workspaces (newest first), for restart/reconnect
    /// fallback to the last-used dynamic workspace not in use elsewhere.
    public var workspaceMRU = [Workspace.ID]()
    /// Displays connected as of the last reconfigure, to detect which ones are
    /// newly plugged in on the next change.
    public var connectedDisplays = Set<DisplayName>()
    /// Reconnect restores to run one-at-a-time through the single (latest-wins)
    /// activation slot — dequeued as each activation completes.
    public var pendingDisplayRestores = [DisplayAssignment]()
    /// The workspace to focus once its restore lands — set by a focused
    /// `reactivateActiveProfile` so the last plan entry activates with focus.
    /// Cleared as soon as that restore is processed.
    public var focusWorkspaceOnRestore: Workspace.ID?
    /// The display that owns keyboard focus (or the latest explicit display
    /// focus transfer). The cursor is used only while this is unknown: once an
    /// exact managed window focuses, its workspace/display ownership is the
    /// authoritative interaction context.
    public var focusedDisplay: DisplayName?
    public var isActivating = false
    /// A work-area change that arrived during activation. The activation owns
    /// its target display's writer, so the global reflow is committed once that
    /// transaction completes instead of polling or racing it.
    public var pendingDisplayGeometryReflow = false
    /// Window notifications received while activation owns the authoritative
    /// show/hide + layout transaction. Record only the affected bundles and
    /// reconcile them once the gate opens instead of rescanning every workspace
    /// app after a fixed delay.
    public var pendingWindowSyncBundleIds = Set<String>()
    /// WindowServer termination/invisibility edges received while activation
    /// owns the tree writer. One post-activation snapshot catches the finished
    /// tree up without replaying a stale visibility edge after a window reappears.
    public var pendingWindowServerPrune = false
    /// Live WindowServer surfaces observed leaving the screen through an 816
    /// invisibility edge. The edge can arrive after activation has already
    /// moved the display mapping away from the outgoing tree, so keep the exact
    /// key until reinsertion. If the same surface returns, its app can restore
    /// the old frame after Tatami's first layout write; presentation
    /// convergence must remain armed across that delayed restore.
    public var windowServerHiddenWindows = Set<WindowKey>()
    /// Exact 815 returns waiting for their owning bundle reconciliation to
    /// publish membership. `armPresentationMonitoring` intentionally accepts
    /// only tree members, so an unhidden surface that is not inserted yet must
    /// carry this intent into the completed sync transaction.
    public var pendingWindowServerPresentationWindows = Set<WindowKey>()
    /// AX discovery is synchronous IPC on a worker. Keep one request per bundle
    /// in flight and mark any notification that arrives during it dirty; its
    /// completion immediately launches one trailing refresh. This is real
    /// latest-state coalescing without a scheduler-dependent time debounce.
    public var windowSyncBundleIdsInFlight = Set<String>()
    public var dirtyWindowSyncBundleIds = Set<String>()
    /// Windows whose app-owned post-reveal frame restoration should converge
    /// back to the current BSP tile. They stay armed while visible so apps
    /// that restore geometry in several stages cannot escape after one repair.
    public var presentationConvergenceWindows = Set<WindowKey>()
    /// Full WindowServer verification is single-flight. Requests that arrive
    /// during a snapshot collapse into one immediate trailing read, preserving
    /// a post-snapshot geometry edge without enumerating every surface once per
    /// AX callback.
    public var isPresentationSnapshotInFlight = false
    public var dirtyPresentationSnapshotWindows = Set<WindowKey>()
    /// Every frame writer receives a monotonic generation before its effect
    /// starts. Presentation snapshots wait until all writers finish and reject
    /// results captured before a newer writer, preventing a stale repair from
    /// canceling the layout it was supposed to verify.
    public var layoutWriteGeneration: UInt64 = 0
    public var activeLayoutWriteGenerations = Set<UInt64>()
    /// Consecutive failed convergence writes. A hard app size constraint must
    /// not create an unbounded AX feedback loop; a fresh authoritative layout
    /// resets the budget.
    public var presentationRepairAttempts = [WindowKey: Int]()
    /// A pointer-driven focus must repair geometry without subsequently
    /// centering the pointer. Kept separately from the convergence membership
    /// so the event path stays immediate without losing click semantics.
    public var presentationPreservesPointerWindows = Set<WindowKey>()
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
    /// Active lifecycle gates that make AX/WindowServer membership snapshots
    /// temporarily non-authoritative.
    public var layoutSuspensionReasons = Set<LayoutSuspensionReason>()
    /// The pre-suspend tree identities and the bundle reconciliations still
    /// outstanding after wake. Keeping this gate through the reconciliation
    /// also catches teardown events queued by WindowServer until after
    /// `didWake`.
    public var isRecoveringSystemLayout = false
    public var suspendedLayoutWindows = [Workspace.ID: Set<WindowKey>]()
    public var pendingSystemLayoutBundleIds = Set<String>()
    /// Per-workspace BSP tree of window keys, kept in-memory only.
    public var tilingTrees = [Workspace.ID: BSPNode<WindowKey>]()
    /// Sticky per-workspace insertion point. The next window inserted
    /// lands next to this one (and the `insertDirection` carried on its
    /// leaf decides north/east/south/west/stack). Updated by focus
    /// events.
    public var insertionPoint = [Workspace.ID: WindowKey]()
    /// Per-workspace most-recently-used window order — front is most recent,
    /// session-only, pruned to the live tree. Written by focus events and
    /// never reset by tree updates (unlike `insertionPoint`), so it drives
    /// both "restore last window" on activation and the refocus target when
    /// the focused window closes — fall back through the list to the next
    /// most-recent window that's still on screen.
    public var mruWindows = [Workspace.ID: [WindowKey]]()
    /// Last exact focus reported by the merged app/AX event stream. App
    /// activation and AX observers can report the same focus several times,
    /// sometimes after the cursor has already moved away. Only a transition
    /// away from this key may trigger observed mouse-follows-focus behavior.
    public var lastObservedFocusedWindow: WindowKey?
    /// A programmatic focus caused by a tree edit still owes one unconditional
    /// center warp. AX focus echoes must leave that ordered effect in place
    /// instead of replacing it with the ordinary click-preserving
    /// `skipIfCursorInside` behavior.
    public var pendingCenterWarps = [Workspace.ID: WindowKey]()
    /// Per-workspace set of fullscreen-zoomed windows. Tatami-specific
    /// multi-window fullscreen: each member is trimmed from the tree
    /// before layout and rendered at the workspace's work area. Several
    /// can be active at once; focus determines which sits on top
    /// visually. Persisted via `LayoutSnapshot.fullscreenZoomedBundleIds`.
    /// Parent-zoom is *not* tracked here — that one lives inside the
    /// tree leaves directly.
    public var fullscreenZoomed = [Workspace.ID: Set<WindowKey>]()
    /// Persisted zoom slots that could not resolve during a transiently empty
    /// startup discovery. The first later sync that sees the matching live
    /// occurrences promotes them into `fullscreenZoomed`.
    public var unresolvedFullscreenZoomSlots = [Workspace.ID: Set<SlotID>]()

    /// Active composition per display — a host workspace plus borrowed
    /// blocks. Absent → that display shows its host alone (default behavior).
    public var compositionsByDisplay = [DisplayName: Composition]()
    /// Monotonic identity of the Borrow transaction currently owning each
    /// display. Async reveal/discovery results must match this generation
    /// before they can publish a tree or focus a block.
    public var borrowGenerationByDisplay = [DisplayName: UInt64]()
    /// A fresh Borrow keeps its completion intent until focus/MFF actually
    /// finishes. Empty initial hydration must not consume it: the first live
    /// window sync resumes the same generation-validated transaction.
    public var pendingBorrowCompletionByDisplay = [
      DisplayName: PendingBorrowCompletion
    ]()
    /// Workspace and pointer display awaiting a direction key; nil when not
    /// capturing. Set by the borrow combo; a direction keystroke commits the
    /// borrow at that edge without re-resolving its monitor mid-chord.
    public var borrowCapture: BorrowCapture?
    public var windowCycleSession: WindowCycleSession?

    /// Warned about missing Screen Recording once already (per session) —
    /// floating windows silently lose their always-on-top mirrors without
    /// it, so the first activation that needs mirrors surfaces a system
    /// prompt + HUD instead of failing quietly.
    public var didWarnMissingScreenRecording = false

    public var drag = DragState.idle

    public var isLayoutSuspended: Bool {
      !layoutSuspensionReasons.isEmpty
    }

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

    // MARK: Internal

    /// Every workspace with windows intentionally visible right now, including
    /// borrowed blocks (which are not values of `activeWorkspacesByDisplay`).
    var visibleWorkspaceIDs: Set<Workspace.ID> {
      var ids = Set(activeWorkspacesByDisplay.values)
      for composition in compositionsByDisplay.values {
        ids.insert(composition.host)
        ids.formUnion(composition.borrowed.map(\.workspace))
      }
      return ids
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

    /// The display that owns a live workspace. Placement is derived from the
    /// display/workspace graph, never from the cursor.
    func displayShowing(_ workspaceId: Workspace.ID) -> DisplayName? {
      if let display = activeWorkspacesByDisplay.first(where: { $0.value == workspaceId })?.key {
        return display
      }
      return compositionsByDisplay.first(where: { _, composition in
        composition.host == workspaceId
          || composition.borrowed.contains(where: { $0.workspace == workspaceId })
      })?.key
    }

    /// The composed workspace (borrowed block or host) that should own a
    /// window of `bundleId` — by tree membership when `key` is known, else by
    /// app registration in a borrowed workspace (so a brand-new borrowed
    /// window routes to its block before it syncs in). Falls back to the
    /// active workspace, so every non-composed path is byte-identical to
    /// before.
    func composedOwner(bundleId: String, key: WindowKey?) -> Workspace.ID? {
      if let key {
        for comp in compositionsByDisplay.values {
          for slot in comp.borrowed
            where tilingTrees[slot.workspace]?.windows.contains(key) == true
          {
            return slot.workspace
          }
          if tilingTrees[comp.host]?.windows.contains(key) == true { return comp.host }
        }
      }
      guard
        let display = focusedDisplay,
        let comp = compositionsByDisplay[display]
      else { return primaryActiveWorkspaceID }
      for slot in comp.borrowed
        where config.activeProfile?.workspaces[id: slot.workspace]?
        .apps.contains(where: { $0.bundleIdentifier == bundleId }) == true
      {
        return slot.workspace
      }
      return comp.host
    }

    /// Route bundle-only AX events without assuming they came from the cursor's
    /// monitor. Every visible tree owner is reconciled: a shared/multi-member
    /// app can have windows on several displays, and its create/destroy event
    /// carries no window identity with which to choose only one. Before the
    /// first window enters a tree, every visible registration owner is used.
    /// The focused composition fallback is only for an app with no visible
    /// ownership evidence yet.
    func workspacesForSync(bundleId: String) -> [Workspace.ID] {
      let orderedVisible = (config.activeProfile?.workspaces.map(\.id) ?? [])
        .filter(visibleWorkspaceIDs.contains)
      let treeOwners = orderedVisible.filter {
        tilingTrees[$0]?.windows.contains(where: { $0.bundleId == bundleId }) == true
      }
      if !treeOwners.isEmpty { return treeOwners }

      let registeredOwners = orderedVisible.filter { workspaceId in
        config.activeProfile?.workspaces[id: workspaceId]?
          .apps.contains(where: { $0.bundleIdentifier == bundleId }) == true
      }
      if !registeredOwners.isEmpty { return registeredOwners }
      return composedOwner(bundleId: bundleId, key: nil).map { [$0] } ?? []
    }

    func workspaceForSync(bundleId: String) -> Workspace.ID? {
      workspacesForSync(bundleId: bundleId).first
    }

    /// Exact current BSP membership, with no registration fallback. Use this
    /// when deciding whether an observed WindowKey has already entered Tatami;
    /// a bundle can be registered to a visible workspace while this particular
    /// newly-unhidden surface is still absent from its tree.
    func workspaceContaining(_ key: WindowKey) -> Workspace.ID? {
      visibleWorkspaceIDs.first {
        tilingTrees[$0]?.windows.contains(key) == true
      }
    }

    /// Whether a focus edge can repair missing tiled membership. Floating and
    /// unmanaged registrations intentionally never enter a BSP tree, while a
    /// second window from an already-tiled or transient app still must trigger
    /// discovery when its exact key is new.
    func shouldSyncFocusedWindow(
      bundleId: String,
      key: WindowKey?,
    ) -> Bool {
      guard let key else { return true }
      if workspaceContaining(key) != nil { return false }

      if
        visibleWorkspaceIDs.contains(where: { workspaceId in
          tilingTrees[workspaceId]?.windows.contains(where: {
            $0.bundleId == bundleId
          }) == true
        })
      {
        return true
      }

      let visibleAssignments = visibleWorkspaceIDs.flatMap { workspaceId in
        config.activeProfile?.workspaces[id: workspaceId]?.apps.filter {
          $0.bundleIdentifier == bundleId
        } ?? []
      }
      if visibleAssignments.contains(where: { $0.layout == .tiled }) {
        return true
      }

      let sharedAssignments = config.sharedApps.filter {
        $0.bundleIdentifier == bundleId
      }
      if sharedAssignments.contains(where: { $0.layout == .tiled }) {
        return true
      }

      if !visibleAssignments.isEmpty || !sharedAssignments.isEmpty {
        return false
      }
      return !managedBundleIds.contains(bundleId)
    }

    /// The workspace that owns `key` — the one whose live tree contains it.
    /// Searched across EVERY active display, so a focused window on a secondary
    /// display resolves to *its* workspace instead of falling back to the
    /// primary display's active one (which made window cycling / directional
    /// focus operate on the wrong monitor's workspace). A borrowed block's tree
    /// isn't in `activeWorkspacesByDisplay`, so the composed fallback still
    /// resolves it; single-display behavior is unchanged.
    func workspaceOwning(_ key: WindowKey) -> Workspace.ID? {
      for wsId in visibleWorkspaceIDs
        where tilingTrees[wsId]?.windows.contains(key) == true
      {
        return wsId
      }
      return workspaceForSync(bundleId: key.bundleId)
    }

    /// Remove windows that are no longer valid from the session MRU without
    /// disturbing the relative order of survivors.
    mutating func removeFromWindowMRU(
      _ keys: Set<WindowKey>,
      workspaceId: Workspace.ID,
    ) {
      guard !keys.isEmpty, var mru = mruWindows[workspaceId] else { return }
      mru.removeAll(where: keys.contains)
      mruWindows[workspaceId] = mru.isEmpty ? nil : mru
    }

    /// Carry same-physical-window recency across a WindowServer identity swap.
    /// Native tabs replace CGWindowIDs while the user's logical tile stays put.
    mutating func replaceInWindowMRU(
      _ replacements: [WindowKey: WindowKey],
      workspaceId: Workspace.ID,
    ) {
      guard !replacements.isEmpty, var mru = mruWindows[workspaceId] else { return }
      mru = mru.map { replacements[$0] ?? $0 }
      var seen = Set<WindowKey>()
      mru.removeAll { !seen.insert($0).inserted }
      mruWindows[workspaceId] = mru.isEmpty ? nil : mru
    }

    /// A terminated process invalidates every one of its window ids, including
    /// floating/unmanaged entries that never appeared in a BSP tree.
    mutating func removeBundleFromWindowMRU(_ bundleId: String) {
      for workspaceId in Array(mruWindows.keys) {
        guard var mru = mruWindows[workspaceId] else { continue }
        mru.removeAll { $0.bundleId == bundleId }
        mruWindows[workspaceId] = mru.isEmpty ? nil : mru
      }
    }

    /// Consume exact evidence that an 816-hidden WindowServer surface is live
    /// again. SLS 815 is not guaranteed for hide-on-close Electron windows;
    /// their AX observer can instead report the same focused window id when the
    /// app recreates its presentation. Carry the repair intent until bundle
    /// reconciliation has restored BSP membership.
    mutating func markWindowServerSurfaceVisible(_ key: WindowKey) {
      guard windowServerHiddenWindows.remove(key) != nil else { return }
      pendingWindowServerPresentationWindows.insert(key)
    }

    mutating func removeFromPresentationMonitoring(_ keys: Set<WindowKey>) {
      guard !keys.isEmpty else { return }
      presentationConvergenceWindows.subtract(keys)
      dirtyPresentationSnapshotWindows.subtract(keys)
      presentationPreservesPointerWindows.subtract(keys)
      for key in keys { presentationRepairAttempts[key] = nil }
      WindowFrameWriteTracker.shared.setMonitoredKeys(
        presentationConvergenceWindows
      )
    }

    /// Arm exact visible windows before an authoritative layout writer can
    /// provoke an app-owned geometry restore. Post-focus actions may re-arm the
    /// same root to verify a second restore caused by activation itself.
    @discardableResult
    mutating func armPresentationMonitoring(
      _ keys: Set<WindowKey>,
      preservesPointer: Bool,
    ) -> Set<WindowKey> {
      let visibleWindows = visibleWorkspaceIDs.reduce(into: Set<WindowKey>()) {
        $0.formUnion(tilingTrees[$1]?.windows ?? [])
      }
      let monitored = keys.intersection(visibleWindows)
      presentationConvergenceWindows.formIntersection(visibleWindows)
      presentationConvergenceWindows.formUnion(monitored)
      for key in monitored { presentationRepairAttempts[key] = nil }
      if preservesPointer {
        presentationPreservesPointerWindows.formUnion(monitored)
      } else {
        presentationPreservesPointerWindows.subtract(monitored)
      }
      WindowFrameWriteTracker.shared.setMonitoredKeys(
        presentationConvergenceWindows
      )
      return monitored
    }

    /// Record exact focus in the owning workspace. Events permit registered
    /// unsynced windows; activation reconciliation requires a visible tree leaf.
    @discardableResult
    mutating func recordFocusedWindow(
      _ key: WindowKey,
      requireVisibleTreeMembership: Bool = false,
      updateFocusedDisplay: Bool = true,
    ) -> Workspace.ID? {
      let workspaceId: Workspace.ID?
      if requireVisibleTreeMembership {
        let visible = visibleWorkspaceIDs
        workspaceId = config.activeProfile?.workspaces.lazy
          .map(\.id)
          .first {
            visible.contains($0)
              && tilingTrees[$0]?.windows.contains(key) == true
          }
      } else {
        workspaceId = workspaceOwning(key)
      }
      guard let workspaceId else { return nil }

      if updateFocusedDisplay, let display = displayShowing(workspaceId) {
        focusedDisplay = display
      }
      let treeWindows = tilingTrees[workspaceId]?.windows ?? []
      let inTree = treeWindows.contains(key)
      if inTree { insertionPoint[workspaceId] = key }

      let workspaceApps = config.activeProfile?.workspaces[id: workspaceId]?.apps ?? []
      guard
        inTree
        || (!requireVisibleTreeMembership
          && workspaceApps.contains { $0.bundleIdentifier == key.bundleId })
      else { return workspaceId }

      var mru = mruWindows[workspaceId] ?? []
      mru.removeAll { $0 == key }
      mru.insert(key, at: 0)
      // Preserve a newly-focused registered window until its first sync, while
      // pruning every older entry that is no longer present in the live tree.
      mru.removeAll { $0 != key && !treeWindows.contains($0) }
      mruWindows[workspaceId] = mru
      return workspaceId
    }

  }

  public enum Action {
    case startObservingWindowEvents
    case windowServerWindowEvent(SLSWindowEvent)
    /// Connected displays changed — drop active/recent state for displays
    /// that are gone so multi-monitor tracking doesn't hold stale entries.
    case displaysReconfigured([DisplayName])
    /// The display set is unchanged, but its work areas moved or resized.
    case displayGeometryChanged
    /// Activate a sensible workspace on launch so tiling starts
    /// immediately instead of waiting for the first manual switch. The startup
    /// session must be restored first so this plans within the resolved profile.
    case activateInitial
    /// Resolve the last-used profile against the connected displays first, then
    /// adopt only valid workspace recency before `activateInitial`. Scratchpad
    /// ids are discarded and saved display identities are reconciled onto the
    /// currently connected UUID/name identities.
    case restoreStartupSession(
      lastUsedProfileId: Profile.ID?,
      displayWorkspaceHistory: [DisplayName: [Workspace.ID]],
      workspaceMRU: [Workspace.ID],
    )
    /// Re-activate the whole active profile across *every* connected display —
    /// a manual profile switch fires no `displaysReconfigured`, so this re-runs
    /// the same per-display restore plan to retile all monitors for the new
    /// profile (apps show/hide/tile per its workspaces).
    /// `focus`, when set, is a workspace forced to the end of the restore plan
    /// (on its display) and activated with focus — so a profile switch that
    /// targets a specific workspace lands on it after the per-display retile,
    /// with no race against the restore cascade.
    case reactivateActiveProfile(focus: Workspace.ID?)
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
    /// Borrow another workspace into the pointer display's host. Re-borrowing
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
    /// A fresh Borrow must finish its AX frame writes before focus/MFF moves
    /// into that block. Running both concurrently makes app activation,
    /// tiling, and floating-mirror hover fight over the same main-thread beat.
    case flushCompositionAndFocus(
      display: DisplayName,
      workspaceId: Workspace.ID,
      generation: UInt64,
    )
    /// The exact Borrow composition's frame writer completed without
    /// cancellation. Revalidate its transaction before starting focus: a
    /// dismiss, replacement Borrow, or re-dock can all supersede this phase.
    case borrowCompositionLayoutCompleted(
      display: DisplayName,
      workspaceId: Workspace.ID,
      generation: UInt64,
      composition: Composition,
    )
    /// The exact Borrow composition's focus/MFF phase completed. Revalidate
    /// once more before arming post-presentation geometry convergence.
    case borrowFocusCompleted(
      display: DisplayName,
      workspaceId: Workspace.ID,
      generation: UInt64,
      composition: Composition,
    )
    /// Internal: land focus + cursor on a freshly-borrowed block once its tree
    /// is in state — the deliberate-summon focus an unhide-only borrow can't
    /// provide on its own.
    case focusBorrowedBlock(workspaceId: Workspace.ID)
    /// Complete a layout-dependent focus/pointer transition only after the
    /// latest display-scoped frame writer has finished.
    case settleFocusAfterLayout(
      windowKey: WindowKey,
      workspaceId: Workspace.ID,
      shouldFocus: Bool,
    )
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
    /// Cycle focus through every visible window in the active composition
    /// (host + borrowed block; otherwise the active workspace). Same-app
    /// windows cycle individually, and off-screen / other-space / minimized
    /// windows are excluded.
    case cycleWindow(CycleDirection)
    case cycleWindowResolved(windowKey: WindowKey, direction: CycleDirection)
    /// Keyboard-only entry path with Cmd-Tab semantics. Gesture/menu actions
    /// continue through `cycleWindow` and commit immediately.
    case cycleWindowShortcut(CycleDirection, holdModifiers: HotKeyModifiers)
    case cycleWindowShortcutResolved(
      windowKey: WindowKey,
      direction: CycleDirection,
      holdModifiers: HotKeyModifiers,
    )
    case windowCycleHUDDelayElapsed
    case windowCycleModifierReleased
    case windowCycleHUDInteraction(WindowSwitcherInteraction)
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
    /// The timeout-prone AX discovery for `syncAppWindows` completed off the
    /// main actor. `resizableKeys` is nil when every visible membership was
    /// floating/unmanaged and no tiled result was needed.
    case syncAppWindowsResolved(
      bundleId: String,
      resizableKeys: [WindowKey]?,
      onScreenFrames: [CGWindowID: CGRect],
    )
    /// A worker-side live presence check completed for a tree that became
    /// empty. The reducer rechecks that it is still empty before switching or
    /// collapsing a Borrow composition.
    case emptyWorkspacePresenceResolved(
      workspaceId: Workspace.ID,
      hasOnScreenMembers: Bool,
      hasFloatingWindows: Bool,
      borrowDisplay: DisplayName?,
      borrowGeneration: UInt64?,
      borrowComposition: Composition?,
    )
    /// Drop active-workspace tree windows that are no longer on screen.
    /// Catches apps that *hide* their window on close (Electron apps like
    /// Discord) instead of destroying it — WindowServer destruction and
    /// lifecycle reconciliation provide the authoritative triggers.
    case pruneOffscreenWindows
    /// Native-Space-change / "something on the system shifted":
    /// re-reconcile every tree-resident + registered app.
    case reconcileAllTrackedApps
    /// A native-Space change: re-read whether the active Space is a native
    /// fullscreen Space, set `isInFullscreenSpace`, and reconcile only when it
    /// isn't (re-tiling into a fullscreen Space bounces to the Desktop).
    case activeSpaceChanged
    /// Freeze destructive membership updates before WindowServer tears down
    /// surfaces for sleep or shutdown, then reconcile fresh identities on wake.
    case systemWillSuspend
    case systemDidWake
    /// Screen lock and user-session switches can make AX return zero window ids
    /// even though every physical window remains alive.
    case screenWillLock
    case screenDidUnlock
    case sessionWillResign
    case sessionDidBecomeActive
    case systemLayoutBundleReconciled(bundleId: String)
    case startObservingAppLaunches
    case appLaunched(bundleId: String, name: String)
    case appActivated(bundleId: String)
    case appUnhidden(bundleId: String)
    case appTerminated(bundleId: String)
    /// A floating-window scan completed. The reducer commits the overlay from
    /// this exact result, then derives marker targets from current state so a
    /// marker-only refresh can never cancel the authoritative mirror update.
    case floatingPresentationResolved([WindowKey])
    /// Activation already resolved its floating windows. Rebuild only the
    /// marker targets from current reducer state, so a composition cleared
    /// during the switch cannot leave its old Borrow badge behind.
    case activationMarkerKeysResolved([WindowKey])
    /// The latest warp for this target completed (or found no frame), so an AX
    /// focus echo no longer needs to preserve the unconditional-center policy.
    case cursorWarpFinished(workspaceId: Workspace.ID, target: WindowKey)
    /// The pre-switch frontmost identity was captured synchronously, then its
    /// timeout-prone focused-window lookup completed on the AX worker.
    case activationFocusSnapshotResolved(WindowKey)
    case tilingTreeUpdated(workspaceId: Workspace.ID, tree: BSPNode<WindowKey>?)
    /// Borrow hydration began from `previousTree`. Commit only if no observer-
    /// driven sync has published a newer tree while reveal/discovery was in
    /// flight; either way, the following composition flush uses current state.
    case borrowedTilingTreeHydrated(
      display: DisplayName,
      workspaceId: Workspace.ID,
      generation: UInt64,
      previousTree: BSPNode<WindowKey>?,
      tree: BSPNode<WindowKey>?,
    )
    /// A frame application completed. Arm its exact windows for app-owned
    /// post-reveal geometry changes and immediately verify current
    /// WindowServer frames—no scheduler delay or polling window.
    case presentationLayoutApplied(keys: Set<WindowKey>, preservesPointer: Bool)
    /// A frame writer ended normally or through latest-wins cancellation.
    /// Its verification keys survive child cancellation; only the last active
    /// generation releasing the barrier may drain them.
    case layoutWriteFinished(
      generation: UInt64,
      verificationKeys: Set<WindowKey>,
    )
    /// Observer installation is now complete for these apps. This second
    /// event-driven verification closes the narrow interval between the first
    /// frame snapshot and AX moved/resized subscription readiness.
    case presentationObservationReady(bundleIds: Set<String>)
    /// A worker-side WindowServer snapshot completed. Keeping dictionary
    /// creation outside the reducer prevents a geometry callback from blocking
    /// hotkeys while the system is already CPU-saturated.
    case presentationFramesResolved(
      keys: Set<WindowKey>,
      currentFrames: [CGWindowID: CGRect],
      layoutGeneration: UInt64,
    )
    /// Activation loaded fullscreen zoom slots from disk. Live occurrences
    /// resolve immediately; transiently absent slots stay pending for the
    /// first valid observer-driven sync.
    case persistedFullscreenZoomRestored(
      workspaceId: Workspace.ID,
      keys: Set<WindowKey>,
      unresolvedSlots: Set<SlotID>,
    )
    case activationCompleted(workspaceId: Workspace.ID, display: DisplayName?)
    /// The whole activation effect ran out, post-layout tail included.
    /// `activationCompleted` fires early — as soon as the *visible* switch is
    /// published — so anything that starts another activation must wait for
    /// this instead, or it cancels the tail (floating mirrors, markers, the
    /// pointer warp) of the activation that just completed.
    case activationTailFinished
    /// `performActivate` did not report completion within the watchdog
    /// window — release the `isActivating` gate so one wedged activation
    /// (an app stuck past every AX timeout) can't refuse all future
    /// activations and syncs for the rest of the session.
    case activationTimedOut
    /// Bubbled to AppFeature, which owns the profile-switch side effects
    /// (hotkey rebind, session-store save, HUD) the activation feature can't do.
    case delegate(Delegate)

    // MARK: Public

    public enum Delegate: Equatable {
      /// A gesture assigned an app into a workspace owned by another
      /// profile. AppFeature owns the actual profile switch transaction.
      case profileSwitchRequested(Profile.ID, focus: Workspace.ID?)
      /// A display rule matched and this feature already retiled for it —
      /// AppFeature runs the remaining switch side effects.
      case profileAutoActivated(Profile.ID)
      /// Startup rejected a missing or condition-mismatched last profile and
      /// resolved another one. AppFeature persists the corrected session id.
      case startupProfileResolved(Profile.ID)
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
    /// Follow the configured auto-balance axes, or rebuild the canonical
    /// recursive BSP topology when automatic balancing is disabled.
    /// Resolved against the focused window so it targets the owning block.
    case balance
  }

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      // The focused window's physical workspace is the interaction owner.
      // Consult the cursor only until that owner is known (startup / empty
      // desktop). Re-reading it on every hotkey overwrote a secondary-display
      // focus immediately before MRU/cycle/activation resolution and sent the
      // operation back to the cursor monitor.
      if Self.refreshesFocusedDisplay(action), state.focusedDisplay == nil {
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
            // WindowServer visibility edges catch hide-on-close windows that
            // emit no AX notification; termination remains the authoritative
            // cache tombstone.
            for await event in sls.windowEvents() {
              await send(.windowServerWindowEvent(event))
            }
          },
          .run { [borrowChord] send in
            // Borrow-mode key capture; the tap only emits while armed.
            for await key in borrowChord.events() {
              await send(.borrowChordKey(key))
            }
          },
        )
        .cancellable(id: CancelID.windowEvents, cancelInFlight: true)

      case .displaysReconfigured(let names):
        let connected = Set(names)
        // DisplayClient emits only when either identity or geometry changed.
        // With an unchanged set this is a resolution/arrangement/work-area
        // update: preserve assignment state and reflow every visible display.
        guard connected != state.connectedDisplays else {
          return .send(.displayGeometryChanged)
        }
        // Displays present now but not at the last reconfigure = freshly plugged
        // in. (Empty `connectedDisplays` is the pre-startup state; seed it in
        // `activateInitial` so a first *unplug* isn't mistaken for a plug-in.)
        let newlyConnected = Set(names.filter { !state.connectedDisplays.contains($0) })
        state.connectedDisplays = connected
        state.activeWorkspacesByDisplay = state.activeWorkspacesByDisplay
          .filter { connected.contains($0.key) }
        state.previousWorkspacesByDisplay = state.previousWorkspacesByDisplay
          .filter { connected.contains($0.key) }
        // Drop last-display records for displays that are gone so dynamic
        // workspaces aren't stranded off-screen in the cycle.
        state.lastActiveDisplay = state.lastActiveDisplay
          .filter { connected.contains($0.value) }
        let disconnectedBorrowedWorkspaceIDs = state.compositionsByDisplay
          .filter { !connected.contains($0.key) }
          .values
          .flatMap { $0.borrowed.map(\.workspace) }
        for workspaceId in disconnectedBorrowedWorkspaceIDs {
          state.pendingCenterWarps[workspaceId] = nil
        }
        state.compositionsByDisplay = state.compositionsByDisplay
          .filter { connected.contains($0.key) }
        state.pendingBorrowCompletionByDisplay =
          state.pendingBorrowCompletionByDisplay
            .filter { connected.contains($0.key) }
        // `displayWorkspaceHistory` is deliberately NOT filtered — it must
        // survive a disconnect so a reconnect can restore the monitor's last
        // workspace.
        if let focused = state.focusedDisplay, !connected.contains(focused) {
          state.focusedDisplay = nil
        }
        if debugLog.isEnabled() {
          debugLog.log(
            "Display",
            "reconfigured connected=\(names.map(\.name)) "
              + "new=\(newlyConnected.map(\.name)) "
              + "activeByDisplay=\(state.activeWorkspacesByDisplay.map { "\($0.key.name)→\($0.value)" }) "
              + "focused=\(state.focusedDisplay?.name ?? "nil")",
          )
        }
        // Auto-activation: if a profile's display rule now matches the connected
        // set (and isn't already active), switch to it and retile every display
        // for the new profile. Its workspace ids differ from the current
        // profile's, so start fresh — clear the per-display map and fill all.
        var autoSwitch = Effect<Action>.none
        var restoreNewlyConnected = newlyConnected
        var restoreActive = state.activeWorkspacesByDisplay
        var didAutoSwitch = false
        let currentActiveProfile = state.config.activeProfileId ?? state.config.profiles.first?.id
        if
          let matched = state.config.autoActiveProfile(connected: connected),
          matched != currentActiveProfile
        {
          state.$config.withLock { $0.activeProfileId = matched }
          state.activeWorkspacesByDisplay = [:]
          restoreActive = [:]
          restoreNewlyConnected = connected
          didAutoSwitch = true
          autoSwitch = .send(.delegate(.profileAutoActivated(matched)))
          debugLog.log(
            "Profile",
            "auto-activate \(state.config.activeProfile?.name ?? "?") for \(names.map(\.name))",
          )
        }
        let disconnectedPresentationCleanup = Effect<Action>.merge(
          refreshFloatingPresentation(state: state),
          refreshMarkers(state: state),
        )
        guard let profile = state.config.activeProfile else {
          return .merge(autoSwitch, disconnectedPresentationCleanup)
        }
        let plan = Self.planDisplayRestore(
          connected: names,
          newlyConnected: restoreNewlyConnected,
          workspaces: profile.workspaces.elements,
          active: restoreActive,
          history: state.displayWorkspaceHistory,
          workspaceMRU: state.workspaceMRU,
        )
        guard !plan.isEmpty else {
          return .merge(autoSwitch, disconnectedPresentationCleanup)
        }
        debugLog.log(
          "Display",
          "restore plan=\(plan.map { "\($0.display.name)→\($0.workspace)" })",
        )
        state.pendingDisplayRestores = plan
        // An auto-switch is a profile change — announce it per display too.
        let autoHUD = didAutoSwitch
          ? profileSwitchHUDs(
            profile: profile,
            plan: plan,
            show: state.config.settings.hud.shows(\.profileSwitch),
            durationMs: state.config.settings.hud.durationMs,
          )
          : .none
        return .merge(autoSwitch, autoHUD, .send(.processDisplayRestores))

      case .displayGeometryChanged:
        // Don't race an activation's authoritative show/hide + frame pass.
        // Remember one pending transaction; activation completion drains it.
        if state.isActivating {
          state.pendingDisplayGeometryReflow = true
          return .none
        }
        state.pendingDisplayGeometryReflow = false
        guard !state.isTilingPaused, !state.isInFullscreenSpace else { return .none }
        let workspaceIds = Array(Set(state.activeWorkspacesByDisplay.values))
        debugLog.log(
          "Display",
          "geometry changed → reflow workspaces=\(workspaceIds)",
        )
        var reflows = [Effect<Action>]()
        for workspaceId in workspaceIds {
          reflows.append(
            flushLayout(workspaceId: workspaceId, state: &state)
          )
        }
        return .merge(reflows)

      case .windowChanged(let event):
        switch event {
        case .windowFrameChanged(let key, let frame):
          guard state.presentationConvergenceWindows.contains(key) else { return .none }
          guard
            !state.isActivating,
            !state.isTilingPaused,
            !state.isInFullscreenSpace,
            case .idle = state.drag
          else { return .none }
          debugLog.log(
            "Tiler",
            "geometry event \(key.bundleId)#\(key.windowID) frame=\(frame)",
          )
          return repairPresentationDrift(
            [key],
            currentFrames: [key.windowID: frame],
            state: &state,
          )

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
          let nextDrag: State.DragState = decision.map {
            .dropping(State.PendingDrop(dragged: key, target: $0.target, zone: $0.zone))
          } ?? .moving(key)
          // AX can emit dozens of identical move events while the cursor stays
          // within one drop zone. The frozen commit decision and the preview are
          // already correct, so don't enqueue another main-actor panel update.
          guard nextDrag != state.drag else { return .none }
          state.drag = nextDrag
          let preview = dragPreview
          return .run { _ in
            guard !Task.isCancelled else { return }
            if let decision {
              await preview.show(decision.targetRect, decision.zone)
            } else {
              await preview.hide()
            }
          }
          .cancellable(id: CancelID.dragPreview, cancelInFlight: true)

        case .windowDragEnded(
          let trackedWindowID,
          let completedKey,
          let completedFrame,
          let pointerMoved,
        ):
          // AX geometry callbacks can be delayed past a short drag while the
          // target app is CPU-starved. Recover from the authoritative
          // mouse-up frame by comparing it with the BSP's rendered frame.
          // Existing AX evidence still wins because it distinguishes a
          // top-left resize from a move without inference.
          let currentKey: WindowKey? =
            switch state.drag {
            case .idle:
              nil
            case .resizing(let resize):
              resize.key
            case .dropping(let drop):
              drop.dragged
            case .moving(let key):
              key
            }
          let authoritativeWindowID =
            completedKey?.windowID ?? trackedWindowID
          if
            !pointerMoved
            || authoritativeWindowID == nil
            || currentKey.map(\.windowID) != authoritativeWindowID
          {
            // A click/net-zero drag must discard intermediate geometry. A
            // newer pointer generation also supersedes any delayed event left
            // by the previous window before this mouse-up arrived.
            state.drag = .idle
          }

          if
            pointerMoved,
            let completedKey,
            let completedFrame
          {
            if currentKey == completedKey, state.drag != .idle {
              switch state.drag {
              case .resizing:
                state.drag = .resizing(
                  State.PendingDrag(
                    key: completedKey,
                    frame: completedFrame,
                  )
                )

              case .dropping,
                   .moving:
                state.drag = dropDecision(
                  dragged: completedKey,
                  state: state,
                ).map {
                  .dropping(
                    State.PendingDrop(
                      dragged: completedKey,
                      target: $0.target,
                      zone: $0.zone,
                    )
                  )
                } ?? .moving(completedKey)

              case .idle:
                break
              }
            } else {
              // A newer pointer generation supersedes any delayed geometry
              // from the previous drag. Start from the mouse-up window only.
              state.drag = .idle
              if
                let expected = expectedPresentationFrames(
                  for: [completedKey],
                  state: state,
                )[completedKey]
              {
                let tolerance: CGFloat = 1.5
                let sizeChanged =
                  abs(expected.width - completedFrame.width) > tolerance
                    || abs(expected.height - completedFrame.height) > tolerance
                let originChanged =
                  abs(expected.minX - completedFrame.minX) > tolerance
                    || abs(expected.minY - completedFrame.minY) > tolerance
                if sizeChanged {
                  state.drag = .resizing(
                    State.PendingDrag(
                      key: completedKey,
                      frame: completedFrame,
                    )
                  )
                } else if originChanged {
                  state.drag = dropDecision(
                    dragged: completedKey,
                    state: state,
                  ).map {
                    .dropping(
                      State.PendingDrop(
                        dragged: completedKey,
                        target: $0.target,
                        zone: $0.zone,
                      )
                    )
                  } ?? .moving(completedKey)
                }
              }
            }
          }
          let preview = dragPreview
          let drag = state.drag
          state.drag = .idle
          var effects: [Effect<Action>] = [
            .run { _ in await preview.hide() }
              .cancellable(id: CancelID.dragPreview, cancelInFlight: true)
          ]
          switch drag {
          case .idle:
            break

          case .resizing(let resize):
            debugLog.log(
              "Drag",
              "end resize \(resize.key.bundleId)#\(resize.key.windowID) frame=\(resize.frame)",
            )
            effects.append(syncTreeRatio(for: resize.key, frame: resize.frame, state: &state))

          case .dropping(let drop):
            debugLog.log(
              "Drag",
              "end drop \(drop.dragged.bundleId)#\(drop.dragged.windowID) "
                + "→ \(drop.target.bundleId)#\(drop.target.windowID) zone=\(drop.zone)",
            )
            effects.append(applyDrop(drop, state: &state))

          case .moving(let key):
            // Dragged but nothing committed (dropped on empty space / back on
            // itself) → snap the window back to its tile.
            debugLog.log("Drag", "end without drop target — snap back")
            effects.append(retile(windowKey: key, state: &state))
          }
          return .merge(effects)

        case .observationReady(let bundleId):
          let snapshot = windowSnapshot
          let log = debugLog
          return .merge(
            requestWindowSync(bundleId),
            .run { send in
              guard
                let key = await snapshot.focusedWindowKeyOffMain(),
                key.bundleId == bundleId
              else { return }
              log.log(
                "FocusDiag",
                "observer ready recovered focus \(key.bundleId)#\(key.windowID)",
              )
              await send(
                .windowChanged(
                  .windowFocused(bundleId: bundleId, key: key)
                )
              )
            },
          )

        case .windowCreated(let bundleId):
          return requestWindowSync(bundleId)

        case .windowDestroyed(let bundleId):
          return requestWindowSync(bundleId)

        case .windowFocused(let bundleId, let key):
          let isPointerDriven = focusEventOrigin.consumePointerDrivenFocus(key?.windowID)
          if isPointerDriven, let key {
            debugLog.log(
              "FocusDiag",
              "windowFocused origin=FFM \(key.bundleId)#\(key.windowID) — preserve pointer",
            )
          }
          let isFocusTransition = state.lastObservedFocusedWindow != key
          if let key { state.markWindowServerSurfaceVisible(key) }
          state.lastObservedFocusedWindow = key
          // Keep the per-workspace insertion point current — even for
          // same-app window switches (which don't fire
          // didActivateApplication).
          if let key { state.recordFocusedWindow(key) }
          // Mouse-follows-focus on a focus change we only *observed* (cmd+`,
          // the app menu's window list, a click): warp to the newly focused
          // tile. `skipIfCursorInside` leaves clicks alone (cursor already
          // there) while still following a keyboard switch. Tatami's own focus
          // ops warp themselves, and their post-warp cursor lands on the tile,
          // so this observed pass then no-ops.
          var followWarp = Effect<Action>.none
          if
            !isPointerDriven,
            isFocusTransition,
            let key,
            let owner = state.workspaceOwning(key)
          {
            if let tree = state.tilingTrees[owner], tree.windows.contains(key) {
              // A different AX notification can be the delayed echo of the
              // focus we just left. It must not cancel the newer requested
              // target's warp or erase its obligation. The requested target
              // effect is the only operation that may settle it. Even the
              // matching AX echo must not replace that ordered effect before
              // it reads the post-layout live frame.
              if state.pendingCenterWarps[owner] == nil {
                followWarp = warpToWindow(
                  key,
                  in: tree,
                  workspaceId: owner,
                  state: state,
                  skipIfCursorInside: true,
                )
              }
            }
          }
          // Forward the focus change to the marker controller so it
          // can render the dot only on the now-focused window.
          let markerClient = marker
          let focusedKey = key
          // A known key already has authoritative membership. Re-scanning its
          // whole app on every cmd-`/click focus was a synchronous AX pass that
          // could block for the full messaging timeout without changing the
          // tree. Unknown/nil focus still reconciles to discover a new or
          // temporarily AX-hidden window.
          let focusSync = state.shouldSyncFocusedWindow(
            bundleId: bundleId,
            key: key,
          )
            ? requestWindowSync(bundleId)
            : .none
          return .merge(
            followWarp,
            focusSync,
            isFocusTransition
              ? monitorBorrowedPresentationAfterFocus(
                bundleId: bundleId,
                preservesPointer: isPointerDriven,
                state: state,
              )
              : .none,
            .run { _ in await markerClient.setFocused(focusedKey) },
          )

        case .windowTitleChanged:
          // Cosmetic — only the layout preview cares. No re-tile.
          return .none
        }

      case .syncAppWindows(let bundleId):
        if
          state.isRecoveringSystemLayout,
          state.isTilingPaused,
          state.pendingSystemLayoutBundleIds.contains(bundleId)
        {
          return .send(.systemLayoutBundleReconciled(bundleId: bundleId))
        }
        if state.isActivating {
          state.pendingWindowSyncBundleIds.insert(bundleId)
          debugLog.log("Sync", "defer \(bundleId): activation in flight")
          return .none
        }
        return syncAppWindows(bundleId: bundleId, state: &state)

      case .syncAppWindowsResolved(let bundleId, let resizableKeys, let onScreenFrames):
        state.windowSyncBundleIdsInFlight.remove(bundleId)
        let needsTrailingRefresh = state.dirtyWindowSyncBundleIds.remove(bundleId) != nil
        if state.isLayoutSuspended {
          return .none
        }
        if state.isActivating {
          state.pendingWindowSyncBundleIds.insert(bundleId)
          return .none
        }
        // An event arrived after this snapshot began. Publishing it would
        // briefly restore stale membership/layout before the trailing scan;
        // skip straight to the one dirty-bit refresh instead.
        if needsTrailingRefresh {
          return requestWindowSync(bundleId)
        }
        let sync = applySyncedAppWindows(
          bundleId: bundleId,
          resizableKeys: resizableKeys,
          onScreenFrames: onScreenFrames,
          state: &state,
        )
        guard
          state.isRecoveringSystemLayout,
          state.pendingSystemLayoutBundleIds.contains(bundleId)
        else { return sync }
        // Recovery suppresses every incremental snapshot save. The resolved
        // tree is already in reducer state, so complete this bundle without
        // waiting for presentation verification; the last completion performs
        // the one authoritative save.
        return .merge(
          sync,
          .send(.systemLayoutBundleReconciled(bundleId: bundleId)),
        )

      case .systemLayoutBundleReconciled(let bundleId):
        return completeSystemLayoutRecovery(
          bundleId: bundleId,
          state: &state,
        )

      case .emptyWorkspacePresenceResolved(
        let workspaceId,
        let hasOnScreenMembers,
        let hasFloatingWindows,
        let borrowDisplay,
        let borrowGeneration,
        let borrowComposition,
      ):
        return handleEmptyWorkspacePresenceResolution(
          workspaceId: workspaceId,
          hasOnScreenMembers: hasOnScreenMembers,
          hasFloatingWindows: hasFloatingWindows,
          borrowDisplay: borrowDisplay,
          borrowGeneration: borrowGeneration,
          borrowComposition: borrowComposition,
          state: state,
        )

      case .floatingPresentationResolved(let keys):
        let overlay = floatingOverlay
        return .merge(
          .run { _ in await overlay.setFloating(Set(keys)) }
            .cancellable(id: CancelID.floatingPresentation, cancelInFlight: true),
          refreshMarkers(state: state, resolvedFloatingKeys: keys),
        )

      case .activationMarkerKeysResolved(let keys):
        return refreshMarkers(state: state, resolvedFloatingKeys: keys)

      case .cursorWarpFinished(let workspaceId, let target):
        if state.pendingCenterWarps[workspaceId] == target {
          state.pendingCenterWarps[workspaceId] = nil
        }
        return .none

      case .startObservingAppLaunches:
        return .run { [client = appLaunch] send in
          for await event in client.events() {
            switch event {
            case .launched(let bundleId, let name):
              await send(.appLaunched(bundleId: bundleId, name: name))
            case .activated(let bundleId):
              await send(.appActivated(bundleId: bundleId))
            case .unhidden(let bundleId):
              await send(.appUnhidden(bundleId: bundleId))
            case .terminated(let bundleId):
              await send(.appTerminated(bundleId: bundleId))
            case .activeSpaceChanged:
              await send(.activeSpaceChanged)
            case .willSleep,
                 .willPowerOff:
              await send(.systemWillSuspend)
            case .didWake:
              await send(.systemDidWake)
            case .sessionWillResign:
              await send(.sessionWillResign)
            case .sessionDidBecomeActive:
              await send(.sessionDidBecomeActive)
            case .screenWillLock:
              await send(.screenWillLock)
            case .screenDidUnlock:
              await send(.screenDidUnlock)
            }
          }
        }
        .cancellable(id: CancelID.appLaunchEvents, cancelInFlight: true)

      case .systemWillSuspend:
        return beginLayoutSuspension(.systemSleep, state: &state)

      case .systemDidWake:
        return endLayoutSuspension(.systemSleep, state: &state)

      case .screenWillLock:
        return beginLayoutSuspension(.screenLock, state: &state)

      case .screenDidUnlock:
        return endLayoutSuspension(.screenLock, state: &state)

      case .sessionWillResign:
        return beginLayoutSuspension(.sessionInactive, state: &state)

      case .sessionDidBecomeActive:
        return endLayoutSuspension(.sessionInactive, state: &state)

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
        // Union of tree members + registered apps in every visible workspace:
        // wake/Space changes are global, not scoped to the cursor monitor.
        var bundleIds = Set<String>()
        for workspaceId in state.visibleWorkspaceIDs {
          for window in state.tilingTrees[workspaceId]?.windows ?? [] {
            bundleIds.insert(window.bundleId)
          }
          if let workspace = state.config.activeProfile?.workspaces[id: workspaceId] {
            for app in workspace.apps { bundleIds.insert(app.bundleIdentifier) }
          }
        }
        bundleIds.formUnion(state.config.sharedApps.map(\.bundleIdentifier))
        guard !bundleIds.isEmpty else {
          state.isRecoveringSystemLayout = false
          state.suspendedLayoutWindows = [:]
          state.pendingSystemLayoutBundleIds = []
          return .none
        }
        if state.isRecoveringSystemLayout {
          // A duplicate Space/wake notification while the batch is live must
          // not re-add bundles that already completed.
          guard state.pendingSystemLayoutBundleIds.isEmpty else { return .none }
          state.pendingSystemLayoutBundleIds = bundleIds
        }
        return .merge(bundleIds.map { requestWindowSync($0) })

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
          requestWindowSync(bundleId),
          .run { [observer = windowObserver] _ in await observer.observe([bundleId]) },
        )

      case .appUnhidden(let bundleId):
        guard !MacApp.isTatami(bundleId) else { return .none }
        // Borrow deliberately keeps the host frontmost, so this visibility
        // edge must never pass through `appActivated`'s stale-frontmost gate.
        // Advance the discovery generation but preserve last-known identities:
        // if an older scan is running, the reducer's dirty bit schedules one
        // fresh trailing scan; if AX times out, the cache remains usable.
        windowSnapshot.markBundleDirty(bundleId)
        debugLog.log("Sync", "unhidden \(bundleId) → reconcile membership")
        return .merge(
          requestWindowSync(bundleId),
          .run { [observer = windowObserver] _ in
            await observer.observe([bundleId])
          },
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
          let key = await snapshot.focusedWindowKeyOffMain()
          await markerClient.setFocused(key)
        }
        // NSWorkspace activation notifications can be delivered after a
        // subsequent host activation has already won (observed with KakaoTalk
        // auto-open during a fast Borrow → dismiss). Never switch workspaces
        // from that stale historical event; AppKit frontmost identity is a
        // cheap synchronous proof and requires no AX round trip or timer.
        let currentFrontmost = windowSnapshot.frontmostApp()
        if currentFrontmost?.bundleId != bundleId {
          debugLog.log(
            "Activate",
            "ignore unverified didActivate \(bundleId); "
              + "frontmost=\(currentFrontmost?.bundleId ?? "nil")",
          )
          return markerEffect
        }
        // Workspaces (on any display) already on screen — a focus within one of
        // them shouldn't switch away.
        let activeWorkspaceIds = Set(state.activeWorkspacesByDisplay.values)
        let hostsApp: (Workspace) -> Bool = { $0.apps.contains { $0.bundleIdentifier == bundleId } }
        if
          !state.isActivating,
          // A borrow direction-pick is armed — a repeat app-activation must
          // not re-fire the jump (re-entering beginBorrowDirection cancels the
          // pending pick). Opening a scratchpad app fires appActivated more
          // than once, and a borrow never makes it the active workspace, so
          // without this the second event kills the direction prompt.
          state.borrowCapture == nil,
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
          !activeWorkspaceIds.contains(owner.id)
        {
          // The one path that switches workspaces without a hotkey — when a
          // bounce-back is suspected, this line (or its absence) is the tell.
          debugLog.log(
            "Activate",
            "followAppFocus jump: didActivate \(bundleId) → ws=\(owner.name)",
          )
          return .merge(
            markerEffect,
            .send(.activate(workspaceId: owner.id, setFocus: false)),
          )
        }
        // One focused-window resolution serves marker focus, insertion-
        // point tracking, and the sync — the `windowFocused` handler does
        // all three. Resolving here *and* eagerly inside the sync cost two
        // AX round trips to the just-activated app (the slowest possible
        // target — Electron apps answer AX late right after activation).
        return .merge(
          .run { [snapshot = windowSnapshot] send in
            let key = await snapshot.focusedWindowKeyOffMain()
            await send(.windowChanged(.windowFocused(bundleId: bundleId, key: key)))
          }
        )

      case .windowServerWindowEvent(.terminated(let wid)):
        // A WindowServer destruction is the authoritative membership edge.
        // Remove that exact id immediately instead of sleeping for a guessed
        // frame boundary and asking CGWindowList whether it has caught up.
        // Presentation convergence handles any later app-owned survivor reset.
        debugLog.log("SLS", "window terminated wid=\(wid)")
        // NOTE: we deliberately do NOT strip `wid` from `fullscreenZoomed` here.
        // 804 also fires when the WindowServer merely recycles a surface (deep
        // sleep / clamshell / display wake) for a window that isn't really
        // closed — clearing zoom then, and letting the prune below persist the
        // emptied set, was the deep-sleep zoom-loss. The sync path owns zoom
        // lifecycle: it migrates a zoom key onto the app's replacement window by
        // slot (718ec31), and a stale key never in the tree is harmless
        // (`computeFrames` ignores it). Prune reclaims the lingering tile.
        if
          let hidden = state.windowServerHiddenWindows.first(where: {
            $0.windowID == wid
          })
        {
          state.windowServerHiddenWindows.remove(hidden)
        }
        if
          let pending = state.pendingWindowServerPresentationWindows.first(where: {
            $0.windowID == wid
          })
        {
          state.pendingWindowServerPresentationWindows.remove(pending)
        }
        windowSnapshot.invalidateWindowIDs([wid])
        if state.isLayoutSuspended || state.isRecoveringSystemLayout {
          debugLog.log("Suspend", "preserve terminated surface wid=\(wid)")
          return .none
        }
        if state.isActivating {
          state.pendingWindowServerPrune = true
          return .none
        }
        return pruneOffscreenWindows(
          knownDestroyedWindowIDs: [wid],
          state: &state,
        )

      case .windowServerWindowEvent(.becameInvisible(let wid)):
        debugLog.log("SLS", "window invisible wid=\(wid)")
        if state.isLayoutSuspended || state.isRecoveringSystemLayout {
          debugLog.log("Suspend", "preserve invisible surface wid=\(wid)")
          return .none
        }
        let residentKey = state.tilingTrees.values.lazy.compactMap { tree in
          tree.windows.first(where: { $0.windowID == wid })
        }.first
        let eventKey = residentKey
          ?? windowSnapshot.cachedWindowKey(wid)
          ?? state.lastObservedFocusedWindow.flatMap {
            $0.windowID == wid ? $0 : nil
          }
        if let eventKey {
          state.pendingWindowServerPresentationWindows.remove(eventKey)
        }
        if
          !state.isTilingPaused,
          !state.isInFullscreenSpace,
          let residentKey
        {
          state.windowServerHiddenWindows.insert(residentKey)
        }
        if state.isActivating {
          // Activation deliberately hides the outgoing workspace before its
          // display mapping changes. Preserve that surface identity now; the
          // deferred prune runs after `activationCompleted`, when the outgoing
          // tree is no longer visible and can no longer establish ownership.
          state.pendingWindowServerPrune = true
          return .none
        }
        guard !state.isTilingPaused, !state.isInFullscreenSpace else {
          return .none
        }
        // A native macOS tab switch orders a new layer-0 surface in for the
        // same process as it orders the old tab out. Commit that identity swap
        // as one BSP transaction. Without this edge pairing, the old 816 path
        // first expanded every sibling and a later AX sync split them again.
        if
          let replacement = replaceInvisibleWindowServerSurface(
            windowID: wid,
            state: &state,
          )
        {
          return replacement
        }
        guard let eventKey else {
          debugLog.log("SLS", "window invisible wid=\(wid) — no cached owner")
          return .none
        }
        // During a rapid native-tab sequence the WindowServer identity can
        // advance through several intermediate ids before the BSP tree's
        // previous reconciliation completes. An 816 for such an intermediate
        // id must not prune every tree surface missing from the same global
        // snapshot: that briefly expands an unrelated sibling (for example,
        // Alacritty) to the full work area. Keep the logical slot until this
        // bundle's authoritative AX set arrives. The reducer's single-flight
        // dirty bit guarantees a trailing latest-state scan without a timer.
        windowSnapshot.markBundleDirty(eventKey.bundleId)
        debugLog.log(
          "SLS",
          "window invisible wid=\(wid) bundle=\(eventKey.bundleId) → reconcile",
        )
        return requestWindowSync(eventKey.bundleId)

      case .windowServerWindowEvent(.becameVisible(let wid)):
        guard let key = windowSnapshot.cachedWindowKey(wid) else {
          debugLog.log("SLS", "window visible wid=\(wid) — no cached owner")
          return .none
        }
        state.markWindowServerSurfaceVisible(key)
        windowSnapshot.markBundleDirty(key.bundleId)
        debugLog.log(
          "SLS",
          "window visible wid=\(wid) bundle=\(key.bundleId) → reconcile",
        )
        return requestWindowSync(key.bundleId)

      case .pruneOffscreenWindows:
        return pruneOffscreenWindows(state: &state)

      case .appTerminated(let bundleId):
        state.removeBundleFromWindowMRU(bundleId)
        for key in Array(state.windowServerHiddenWindows)
          where key.bundleId == bundleId
        {
          state.windowServerHiddenWindows.remove(key)
        }
        for key in Array(state.pendingWindowServerPresentationWindows)
          where key.bundleId == bundleId
        {
          state.pendingWindowServerPresentationWindows.remove(key)
        }
        windowSnapshot.invalidateBundle(bundleId)
        if state.isLayoutSuspended || state.isRecoveringSystemLayout {
          return .none
        }
        let prune = pruneOffscreenWindows(state: &state)
        return .merge(prune, requestWindowSync(bundleId))

      case .restoreStartupSession(
        let lastUsedProfileId,
        let displayWorkspaceHistory,
        let workspaceMRU,
      ):
        // Profile selection is the first half of this transaction: workspace
        // history below derives `previousWorkspacesByDisplay` from the active
        // profile, so resolving it in a later action can retain the wrong ids.
        let liveDisplays = displays.all()
        let connectedDisplays = Set(liveDisplays)
        let startupProfileId = state.config.startupActiveProfile(
          lastUsedProfileId: lastUsedProfileId,
          connected: connectedDisplays,
        )
        if let startupProfileId {
          state.$config.withLock { $0.activeProfileId = startupProfileId }
        }

        let validWorkspaceIds = Set(
          state.config.profiles.flatMap {
            $0.workspaces
              .filter { $0.kind != .scratchpad }
              .map(\.id)
          }
        )
        var restoredHistory = [DisplayName: [Workspace.ID]]()
        for (savedDisplay, workspaceIds) in displayWorkspaceHistory {
          let display = liveDisplays.first { savedDisplay.matches($0) }
            ?? savedDisplay
          for workspaceId in workspaceIds
            where validWorkspaceIds.contains(workspaceId)
            && !restoredHistory[display, default: []].contains(workspaceId)
          {
            restoredHistory[display, default: []].append(workspaceId)
          }
        }
        state.displayWorkspaceHistory = restoredHistory
        state.workspaceMRU = workspaceMRU.reduce(into: []) { restored, workspaceId in
          if
            validWorkspaceIds.contains(workspaceId),
            !restored.contains(workspaceId)
          {
            restored.append(workspaceId)
          }
        }
        let activeWorkspaceIds = Set(
          state.config.activeProfile?.workspaces
            .filter { $0.kind != .scratchpad }
            .map(\.id) ?? []
        )
        state.previousWorkspacesByDisplay = restoredHistory.reduce(into: [:]) {
          previous, entry in
          let activeHistory = entry.value.filter(activeWorkspaceIds.contains)
          if let workspaceId = activeHistory.dropFirst().first {
            previous[entry.key] = workspaceId
          }
        }
        if startupProfileId != nil {
          debugLog.log(
            "Profile",
            "startup resolved profile=\(state.config.activeProfile?.name ?? "?") "
              + "last=\(lastUsedProfileId?.uuidString ?? "nil") "
              + "displays=\(connectedDisplays.map(\.name))",
          )
        }
        guard
          let startupProfileId,
          startupProfileId != lastUsedProfileId
        else { return .none }
        return .send(.delegate(.startupProfileResolved(startupProfileId)))

      case .reactivateActiveProfile(let focus):
        guard let profile = state.config.activeProfile else { return .none }
        let connected = displays.all()
        guard !connected.isEmpty else { return .send(.activateInitial) }
        // The prior per-display assignments point at the *old* profile's
        // workspace ids (independent per profile), so start fresh and re-fill
        // every display from the new profile — its pinned workspaces land on
        // their monitors, dynamics fill the rest (reuses the reconnect planner).
        state.activeWorkspacesByDisplay = [:]
        state.pendingDisplayRestores = []
        state.focusWorkspaceOnRestore = nil
        var plan = Self.planDisplayRestore(
          connected: connected,
          newlyConnected: Set(connected),
          workspaces: profile.workspaces.elements,
          active: [:],
          history: state.displayWorkspaceHistory,
          workspaceMRU: state.workspaceMRU,
        )
        // A focused switch (detail Activate on a non-active profile) forces its
        // workspace to the *end* of the plan — the cascade processes in order,
        // so it lands last, and its restore sets focus. This makes the clicked
        // workspace the final active one deterministically, without racing the
        // per-display retile.
        if let focus, profile.workspaces[id: focus] != nil {
          if let idx = plan.firstIndex(where: { $0.workspace == focus }) {
            plan.append(plan.remove(at: idx))
          } else {
            let hint = profile.workspaces[id: focus]?.displayHint
            let targetDisplay = connected.first { hint?.matches($0) ?? false }
              ?? plan.last?.display ?? connected[0]
            plan.removeAll { $0.display == targetDisplay }
            plan.append(DisplayAssignment(display: targetDisplay, workspace: focus))
          }
          state.focusWorkspaceOnRestore = focus
        }
        debugLog.log(
          "Profile",
          "reactivate \(profile.name) plan=\(plan.map { "\($0.display.name)→\($0.workspace)" })",
        )
        // Empty profile (nothing pinnable) → nothing to tile. Still honor an
        // explicit focus target so the Activate button isn't a no-op.
        guard !plan.isEmpty else {
          if let focus { return .send(.activate(workspaceId: focus, setFocus: true)) }
          return .none
        }
        state.pendingDisplayRestores = plan
        let hudEffect = profileSwitchHUDs(
          profile: profile,
          plan: plan,
          show: state.config.settings.hud.shows(\.profileSwitch),
          durationMs: state.config.settings.hud.durationMs,
        )
        return .merge(hudEffect, .send(.processDisplayRestores))

      case .delegate:
        return .none

      case .activateInitial:
        // `restoreStartupSession` has already resolved the profile against the
        // connected displays and filtered recency for that profile. This action
        // only plans its workspace restore, so it cannot switch profiles after
        // workspace state has been derived.
        let connectedDisplays = displays.all()
        state.connectedDisplays = Set(connectedDisplays)
        // (connectedDisplays already seeded above so the first real reconfigure
        // diffs against reality — an unplug must not read as everything
        // plugging in.)
        guard let profile = state.config.activeProfile else { return .none }
        // Scratchpads are borrow-only — never auto-activate one on launch.
        let candidates = profile.workspaces.filter { $0.kind != .scratchpad }
        guard !candidates.isEmpty else { return .none }
        let frontBundle = windowSnapshot.frontmostApp()?.bundleId
        let frontmostCandidate = candidates.first { ws in
          guard let frontBundle else { return false }
          return ws.apps.contains { $0.bundleIdentifier == frontBundle }
        }
        if !connectedDisplays.isEmpty {
          var restoreDisplays = connectedDisplays
          if
            let currentDisplay = displays.current(),
            let index = restoreDisplays.firstIndex(where: { $0.matches(currentDisplay) })
          {
            restoreDisplays.insert(restoreDisplays.remove(at: index), at: 0)
          }
          // An existing active-profile-only session has no workspace history.
          // Preserve the established frontmost-app startup behavior as the
          // one-time seed; once any activation completes, persisted display
          // history becomes authoritative on following launches.
          let startupWorkspaceMRU = state.workspaceMRU.isEmpty
            ? frontmostCandidate.map { [$0.id] } ?? []
            : state.workspaceMRU
          let plan = Self.planDisplayRestore(
            connected: restoreDisplays,
            newlyConnected: Set(restoreDisplays),
            workspaces: candidates.elements,
            active: [:],
            history: state.displayWorkspaceHistory,
            workspaceMRU: startupWorkspaceMRU,
          )
          if !plan.isEmpty {
            state.activeWorkspacesByDisplay = [:]
            state.pendingDisplayRestores = plan
            state.focusWorkspaceOnRestore = nil
            debugLog.log(
              "Activate",
              "initial restore plan="
                + "\(plan.map { "\($0.display.name)→\($0.workspace)" })",
            )
            return .send(.processDisplayRestores)
          }
        }
        // No usable display assignment (headless startup or a config whose
        // every normal workspace is temporarily unavailable): preserve the
        // established frontmost-app/first-workspace fallback.
        let target = frontmostCandidate ?? candidates[0]
        debugLog.log(
          "Activate",
          "initial → ws=\(target.name) (frontmost=\(frontBundle ?? "nil"))",
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
            subtitle = String(
              localized:
              "Grant Accessibility in System Settings → Privacy & Security, then relaunch Tatami"
            )
          } else {
            await screenRecording.requestAccess()
            subtitle = String(
              localized:
              "Grant Accessibility and Screen Recording in System Settings → Privacy & Security, then relaunch Tatami"
            )
          }
          await workspaceHUD.show(
            String(localized: "Permissions Needed"),
            "exclamationmark.triangle.fill",
            subtitle,
            permsHudMs,
          )
        }

      case .activate(let workspaceId, let setFocus):
        // A deliberate switch supersedes any in-flight reconnect restore cascade
        // — the user's action wins over the display-restore queue.
        state.pendingDisplayRestores = []
        // An already-active host that activation would leave exactly where it
        // is does not need activation: it is a display focus transfer.
        // Re-activating it would deliberately tear down that display's Borrow
        // composition, returning a borrowed workspace merely because the user
        // visited another monitor and came back. Borrow dismissal remains
        // explicit through `.dismissBorrow`.
        //
        // The comparison against `deliberateActivationDisplay` is what keeps a
        // dynamic workspace dynamic: it is already visible on *some* monitor
        // almost always, so shortcutting on visibility alone pinned it to
        // whichever monitor it last landed on and "follows mouse" stopped
        // moving anything.
        if
          setFocus,
          let display = state.activeWorkspacesByDisplay.first(where: {
            $0.value == workspaceId
          })?.key,
          let workspace = state.config.activeProfile?.workspaces[id: workspaceId],
          deliberateActivationDisplay(for: workspace, state: state)?.matches(display) ?? true,
          // Nothing to focus means the transfer would swallow the switch
          // whole: no app activation, no hide pass, no HUD. Fall through to a
          // real activation, which is what raises the workspace back up.
          visibleFocusTarget(workspaceId, state: state) != nil
        {
          return focusVisibleWorkspace(
            workspaceId: workspaceId,
            display: display,
            state: &state,
          )
        }
        return performActivate(
          workspaceId: workspaceId,
          setFocus: setFocus,
          state: &state,
        )

      case .restoreDisplay(let workspaceId, let display):
        // The focused-switch target (forced last in the plan) activates with
        // focus so the profile switch lands on the clicked workspace.
        let takesFocus = state.focusWorkspaceOnRestore == workspaceId
        if takesFocus { state.focusWorkspaceOnRestore = nil }
        return performActivate(
          workspaceId: workspaceId,
          setFocus: takesFocus,
          displayOverride: display,
          // The profile-switch HUD already announces this workspace as its
          // subtitle; don't let the focused restore raise a second HUD over it.
          suppressSwitchHUD: takesFocus,
          state: &state,
        )

      case .processDisplayRestores:
        guard !state.pendingDisplayRestores.isEmpty else { return .none }
        let next = state.pendingDisplayRestores.removeFirst()
        return .send(.restoreDisplay(workspaceId: next.workspace, display: next.display))

      case .borrow(let workspaceId, let edge):
        return performBorrow(
          targetId: workspaceId,
          edge: edge,
          displayOverride: displays.current(),
          state: &state,
        )

      case .dismissBorrow(let display):
        return dismissBorrow(display: display, state: &state)

      case .beginBorrowDirection(let workspaceId):
        // Re-firing for the same pending target cancels.
        if state.borrowCapture?.workspaceId == workspaceId {
          return endBorrowCapture(state: &state)
        }
        guard let ws = state.config.activeProfile?.workspaces[id: workspaceId]
        else { return .none }
        guard
          let display = displays.current() ?? state.focusedDisplay
          ?? state.activeWorkspacesByDisplay.keys.first
        else { return .none }
        // A repeated summon is a toggle by default. Resolve it before the
        // direction picker so an "Ask" configuration can dismiss immediately
        // instead of requiring a meaningless re-dock direction first.
        if
          state.config.settings.switching.toggleBorrowOnRepeat,
          state.compositionsByDisplay[display]?.borrowed.contains(where: {
            $0.workspace == workspaceId
          }) == true
        {
          return dismissBorrow(display: display, state: &state)
        }
        // Can't borrow the workspace that's already active on this display.
        if state.activeWorkspacesByDisplay[display] == workspaceId {
          debugLog.log("Borrow", "skip borrow of current workspace \(ws.name)")
          return hudEffect(
            state,
            \.borrow,
            "Already here",
            "rectangle",
            subtitle: "Can't borrow the current workspace",
          )
        }
        // A configured default edge (per-workspace override, else global)
        // borrows immediately; otherwise arm the direction pick.
        if let edge = ws.borrowEdge ?? state.config.settings.switching.borrowDefaultEdge {
          return performBorrow(
            targetId: workspaceId,
            edge: edge,
            displayOverride: display,
            state: &state,
          )
        }
        state.borrowCapture = State.BorrowCapture(display: display, workspaceId: workspaceId)
        debugLog.log("BorrowChord", "begin borrow direction for \(ws.name) on \(display.name)")
        return .merge(
          .run { [borrowChord] _ in await borrowChord.setArmed(true) },
          borrowChordTimeout(),
          borrowChordHint(state: state),
        )

      case .borrowChordKey(let key):
        guard let capture = state.borrowCapture else { return .none }
        switch key {
        case .edge(let edge):
          let end = endBorrowCapture(state: &state)
          return .merge(
            end,
            performBorrow(
              targetId: capture.workspaceId,
              edge: edge,
              displayOverride: capture.display,
              state: &state,
            ),
          )

        case .cancel:
          // Esc / timeout: end capture and clear the borrow-mode hint HUD.
          return .merge(
            endBorrowCapture(state: &state),
            .run { [workspaceHUD] _ in await workspaceHUD.dismiss() },
          )
        }

      case .assignFocusedAppToRecentWorkspace:
        guard let id = recentWorkspaceId(state: state) else { return .none }
        return .send(.membershipEdit(.assign(to: id)))

      case .assignFocusedAppToAdjacentWorkspace(let direction):
        guard let id = adjacentWorkspaceId(by: direction, state: state) else { return .none }
        return .send(.membershipEdit(.assign(to: id)))

      case .borrowRecentWorkspace:
        let display = displays.current() ?? state.focusedDisplay
        guard let id = recentWorkspaceId(state: state, display: display) else { return .none }
        return .send(.beginBorrowDirection(workspaceId: id))

      case .borrowAdjacentWorkspace(let direction):
        let display = displays.current() ?? state.focusedDisplay
        guard
          let id = adjacentWorkspaceId(by: direction, state: state, display: display)
        else { return .none }
        return .send(.beginBorrowDirection(workspaceId: id))

      case .flushComposition(let display):
        // Re-tile the composition and (re)push markers — the borrowed block's
        // windows now exist, so they can be badged with the source's icon.
        return .merge(
          applyComposition(
            display: display,
            monitorsPresentationChanges: true,
            state: &state,
          ),
          refreshMarkers(state: state),
        )

      case .flushCompositionAndFocus(let display, let workspaceId, let generation):
        guard
          state.borrowGenerationByDisplay[display] == generation,
          state.pendingBorrowCompletionByDisplay[display]
          == State.PendingBorrowCompletion(
            workspaceId: workspaceId,
            generation: generation,
          ),
          let composition = state.compositionsByDisplay[display],
          composition.borrowed.contains(where: {
            $0.workspace == workspaceId
          })
        else {
          debugLog.log("Borrow", "skip stale layout/focus \(workspaceId) on \(display.name)")
          return .none
        }
        let layout = applyComposition(
          display: display,
          monitorsPresentationChanges: true,
          borrowPhaseCompletion: BorrowPhase(
            display: display,
            workspaceId: workspaceId,
            generation: generation,
            composition: composition,
          ),
          state: &state,
        )
        return .merge(
          .concatenate(
            .cancel(id: CancelID.borrowFocus(display)),
            layout,
          ),
          refreshMarkers(state: state),
        )

      case .borrowCompositionLayoutCompleted(
        let display,
        let workspaceId,
        let generation,
        let expectedComposition,
      ):
        guard
          state.borrowGenerationByDisplay[display] == generation,
          state.pendingBorrowCompletionByDisplay[display]
          == State.PendingBorrowCompletion(
            workspaceId: workspaceId,
            generation: generation,
          ),
          state.compositionsByDisplay[display] == expectedComposition,
          expectedComposition.borrowed.contains(where: {
            $0.workspace == workspaceId
          })
        else {
          debugLog.log(
            "Borrow",
            "skip stale post-layout focus \(workspaceId) on \(display.name)",
          )
          return .none
        }
        return focusBorrowedBlock(
          workspaceId: workspaceId,
          completion: BorrowPhase(
            display: display,
            workspaceId: workspaceId,
            generation: generation,
            composition: expectedComposition,
          ),
          state: &state,
        )
        .cancellable(
          id: CancelID.borrowFocus(display),
          cancelInFlight: true,
        )

      case .borrowFocusCompleted(
        let display,
        let workspaceId,
        let generation,
        let expectedComposition,
      ):
        guard
          state.borrowGenerationByDisplay[display] == generation,
          state.pendingBorrowCompletionByDisplay[display]
          == State.PendingBorrowCompletion(
            workspaceId: workspaceId,
            generation: generation,
          ),
          state.compositionsByDisplay[display] == expectedComposition,
          expectedComposition.borrowed.contains(where: {
            $0.workspace == workspaceId
          })
        else {
          debugLog.log(
            "Borrow",
            "skip stale post-focus arm \(workspaceId) on \(display.name)",
          )
          return .none
        }
        state.pendingBorrowCompletionByDisplay[display] = nil
        let presentationKeys = Set(
          (state.tilingTrees[expectedComposition.host]?.windows ?? [])
            + expectedComposition.borrowed.flatMap {
              state.tilingTrees[$0.workspace]?.windows ?? []
            }
        )
        return .send(
          .presentationLayoutApplied(
            keys: presentationKeys,
            preservesPointer: false,
          )
        )

      case .focusBorrowedBlock(let workspaceId):
        return focusBorrowedBlock(workspaceId: workspaceId, state: &state)

      case .settleFocusAfterLayout(let key, let workspaceId, let shouldFocus):
        return settleFocusAfterLayout(
          key,
          workspaceId: workspaceId,
          shouldFocus: shouldFocus,
          state: &state,
        )

      case .activateNext:
        return cycle(by: 1, state: &state)

      case .activatePrevious:
        return cycle(by: -1, state: &state)

      case .activateRecent:
        let switching = state.config.settings.switching
        let recent = recentWorkspaceId(state: state, display: state.focusedDisplay)
        guard let recent else {
          debugLog.log("Activate", "recent: no previous workspace recorded")
          return .none
        }
        guard switching.recentAcrossDisplays else {
          return .send(.activate(workspaceId: recent, setFocus: true))
        }
        // If the global recent workspace is already on another display, this
        // is a focus transfer — keep it there and preserve any Borrow
        // composition on that display. A plain activation would both pull a
        // dynamic workspace through the cursor and return its borrowed block.
        state.pendingDisplayRestores = []
        if let display = state.displayShowing(recent) {
          return focusVisibleWorkspace(
            workspaceId: recent,
            display: display,
            state: &state,
          )
        }
        return performActivate(
          workspaceId: recent,
          setFocus: true,
          state: &state,
        )

      case .focusAdjacentDisplay(let direction):
        let ordered = displays.all()
        guard ordered.count > 1 else { return .none }
        let startIndex = state.focusedDisplay
          .flatMap { f in ordered.firstIndex { $0.matches(f) } } ?? 0
        let nextDisplay = ordered[(startIndex + direction + ordered.count) % ordered.count]
        // The workspace currently active on that display, if any.
        guard
          let wsId = state.activeWorkspacesByDisplay
            .first(where: { $0.key.matches(nextDisplay) })?.value
        else {
          debugLog.log(
            "Display",
            "focusAdjacent → \(nextDisplay.name): no active workspace recorded",
          )
          return .none
        }
        debugLog.log("Display", "focusAdjacent → \(nextDisplay.name)")
        // This is a focus transfer, not a workspace activation. Re-running
        // activation here returned any workspace borrowed into the target
        // monitor because host activation deliberately clears its composition.
        state.pendingDisplayRestores = []
        return focusVisibleWorkspace(
          workspaceId: wsId,
          display: nextDisplay,
          state: &state,
        )

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
          let hudTitle: LocalizedStringResource = didAdd
            ? "Added \(displayName) → \(workspaceName)"
            : "Removed \(displayName) ← \(workspaceName)"
          let hudIcon = didAdd ? "plus.circle.fill" : "minus.circle.fill"
          return .merge(
            hudEffect(state, \.appMembership, hudTitle, hudIcon),
            .send(.activate(workspaceId: workspaceId, setFocus: false)),
          )

        case .toggleFloating:
          guard let workspaceId = state.primaryActiveWorkspaceID else { return .none }
          var nowFloating = false
          state.$config.withLock {
            nowFloating = $0.toggleFloating(bundleId: bundleId, name: name, in: workspaceId)
          }
          // Rebuild the tree so the window drops out of / back into the layout.
          state.tilingTrees[workspaceId] = nil
          let hudTitle: LocalizedStringResource = nowFloating
            ? "Floating: \(displayName)"
            : "Tiled: \(displayName)"
          // Different glyphs for the two states so the HUD reads at a
          // glance — open frame for floating, filled stack for tiled.
          let hudIcon = nowFloating ? "rectangle.dashed" : "square.stack.3d.up.fill"
          // Un-floating keeps the workspace assignment — hint at the
          // membership shortcut for users who meant "take it out entirely".
          let hudHint: LocalizedStringResource? = nowFloating
            ? nil
            : state.config.settings.shortcuts.toggleFocusedAppInActiveWorkspace.map { key in
              "Still in this workspace — \(key.symbols) removes it"
            }
          return .merge(
            .send(.activate(workspaceId: workspaceId, setFocus: false)),
            hudEffect(state, \.floating, hudTitle, hudIcon, subtitle: hudHint),
          )

        case .toggleSharedFloating:
          var nowFloating = false
          state.$config.withLock {
            nowFloating = $0.toggleSharedFloating(bundleId: bundleId, name: name)
          }
          let hudTitle: LocalizedStringResource = nowFloating
            ? "Shared Floating: \(displayName)"
            : "Shared Tiled: \(displayName)"
          let hudIcon = nowFloating ? "rectangle.dashed" : "square.stack.3d.up.fill"
          // Un-floating keeps the app shared (tiled everywhere) — hint at
          // the membership shortcut for users who meant "take it out of Shared".
          let hudHint: LocalizedStringResource? = nowFloating
            ? nil
            : state.config.settings.shortcuts.toggleAppInSharedApps.map { key in
              "Still in Shared Apps — \(key.symbols) removes it"
            }
          let hud = hudEffect(state, \.floating, hudTitle, hudIcon, subtitle: hudHint)
          guard let workspaceId = state.primaryActiveWorkspaceID else { return hud }
          state.tilingTrees[workspaceId] = nil
          return .merge(
            .send(.activate(workspaceId: workspaceId, setFocus: false)),
            hud,
          )

        case .toggleShared:
          var didAdd = false
          state.$config.withLock {
            didAdd = $0.toggleSharedMembership(bundleId: bundleId, name: name)
          }
          let hudTitle: LocalizedStringResource = didAdd
            ? "Added \(displayName) → Shared Apps"
            : "Removed \(displayName) ← Shared Apps"
          let hudIcon = didAdd ? "plus.circle.fill" : "minus.circle.fill"
          let hud = hudEffect(state, \.appMembership, hudTitle, hudIcon)
          guard let workspaceId = state.primaryActiveWorkspaceID else { return hud }
          state.tilingTrees[workspaceId] = nil
          return .merge(
            .send(.activate(workspaceId: workspaceId, setFocus: false)),
            hud,
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
          if
            let owner = state.config.profileId(owning: workspaceId),
            owner != state.config.activeProfile?.id
          {
            return .send(.delegate(.profileSwitchRequested(owner, focus: workspaceId)))
          }
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
          state.isTilingPaused ? "pause.circle.fill" : "play.circle.fill",
        )
        if wasPaused {
          return .merge(
            .send(.displayGeometryChanged),
            .send(.reconcileAllTrackedApps),
            hud,
          )
        }
        return hud

      case .cycleWindow(let direction):
        return resolveFocusedWindowKey { key in
          .cycleWindowResolved(windowKey: key, direction: direction)
        }

      case .cycleWindowResolved(let key, let direction):
        guard
          let cycle = windowCycle(
            from: key,
            direction: direction,
            holdModifiers: [],
            state: state,
          )
        else { return .none }
        return .merge(
          commitWindowCycle(cycle, state: state),
          state.config.settings.hud.shows(\.windowCycle)
            ? showWindowCycleHUD(
              cycle,
              autoDismissAfterMs: state.config.settings.hud.durationMs,
              state: state,
            )
            : .none,
        )

      case .cycleWindowShortcut(let direction, let holdModifiers):
        guard !holdModifiers.isEmpty else { return .send(.cycleWindow(direction)) }
        if let current = state.windowCycleSession {
          guard
            var next = windowCycle(
              from: current.selected,
              direction: direction,
              holdModifiers: current.holdModifiers,
              focusedWindow: current.focusedWindow,
              state: state,
            )
          else { return .none }
          next.isHUDVisible = current.isHUDVisible
          state.windowCycleSession = next
          return next.isHUDVisible
            ? showWindowCycleHUD(next, autoDismissAfterMs: nil, state: state)
            : .none
        }
        return resolveFocusedWindowKey { key in
          .cycleWindowShortcutResolved(
            windowKey: key,
            direction: direction,
            holdModifiers: holdModifiers,
          )
        }

      case .cycleWindowShortcutResolved(let key, let direction, let holdModifiers):
        // Two key presses can resolve their focused window concurrently. Once
        // the first created the session, replay the later press against its
        // logical selection instead of the still-physically-focused window.
        if state.windowCycleSession != nil {
          return .send(.cycleWindowShortcut(direction, holdModifiers: holdModifiers))
        }
        guard
          let cycle = windowCycle(
            from: key,
            direction: direction,
            holdModifiers: holdModifiers,
            state: state,
          )
        else { return .none }
        state.windowCycleSession = cycle

        var effects: [Effect<Action>] = [
          .run { [clock, modifierKeys, holdModifiers] send in
            while modifierKeys.current().intersection(holdModifiers) == holdModifiers {
              try await clock.sleep(for: .milliseconds(10))
            }
            await send(.windowCycleModifierReleased)
          }
          .cancellable(id: CancelID.windowCycleModifier, cancelInFlight: true)
        ]
        if state.config.settings.hud.shows(\.windowCycle) {
          effects.append(
            .run { [clock] send in
              try await clock.sleep(for: .milliseconds(150))
              await send(.windowCycleHUDDelayElapsed)
            }
            .cancellable(id: CancelID.windowCycleHUDDelay, cancelInFlight: true)
          )
        }
        return .merge(effects)

      case .windowCycleHUDDelayElapsed:
        guard
          var cycle = state.windowCycleSession,
          state.config.settings.hud.shows(\.windowCycle)
        else { return .none }
        cycle.isHUDVisible = true
        state.windowCycleSession = cycle
        return showWindowCycleHUD(cycle, autoDismissAfterMs: nil, state: state)

      case .windowCycleModifierReleased:
        guard let cycle = state.windowCycleSession else { return .none }
        debugLog.log(
          "BSP",
          "cycle commit source=modifier selected="
            + "\(cycle.selected.bundleId)#\(cycle.selected.windowID)",
        )
        return finishWindowCycle(cycle, commit: true, state: &state)

      case .windowCycleHUDInteraction(.move(let direction)):
        guard
          let current = state.windowCycleSession,
          var next = windowCycle(
            from: current.selected,
            direction: direction,
            holdModifiers: current.holdModifiers,
            focusedWindow: current.focusedWindow,
            state: state,
          )
        else { return .none }
        next.isHUDVisible = true
        state.windowCycleSession = next
        return showWindowCycleHUD(next, autoDismissAfterMs: nil, state: state)

      case .windowCycleHUDInteraction(.select(let selected)):
        guard
          var cycle = state.windowCycleSession,
          cycle.windows.contains(selected),
          cycle.selected != selected
        else { return .none }
        cycle.selected = selected
        cycle.workspaceId = state.workspaceOwning(selected) ?? cycle.workspaceId
        cycle.isHUDVisible = true
        state.windowCycleSession = cycle
        debugLog.log(
          "BSP",
          "cycle select source=pointer selected=\(selected.bundleId)#\(selected.windowID)",
        )
        return showWindowCycleHUD(cycle, autoDismissAfterMs: nil, state: state)

      case .windowCycleHUDInteraction(.commitSelected):
        guard let cycle = state.windowCycleSession else { return .none }
        debugLog.log(
          "BSP",
          "cycle commit source=keyboard selected="
            + "\(cycle.selected.bundleId)#\(cycle.selected.windowID)",
        )
        return finishWindowCycle(cycle, commit: true, state: &state)

      case .windowCycleHUDInteraction(.commit(let selected)):
        guard
          var cycle = state.windowCycleSession,
          cycle.windows.contains(selected)
        else { return .none }
        cycle.selected = selected
        // A pointer click can jump directly across a host/Borrow boundary.
        // Commit/warp must then use the clicked window's tree, not whichever
        // block owned the keyboard selection before the click.
        cycle.workspaceId = state.workspaceOwning(selected) ?? cycle.workspaceId
        debugLog.log(
          "BSP",
          "cycle commit source=pointer selected=\(selected.bundleId)#\(selected.windowID)",
        )
        return finishWindowCycle(cycle, commit: true, state: &state)

      case .windowCycleHUDInteraction(.cancel):
        guard let cycle = state.windowCycleSession else { return .none }
        return finishWindowCycle(cycle, commit: false, state: &state)

      case .bspFocus(let direction):
        return resolveFocusedWindowKey { key in
          .bspFocusResolved(windowKey: key, direction: direction)
        }

      case .bspFocusResolved(let key, let direction):
        guard
          let workspaceId = state.workspaceOwning(key) ?? state.primaryActiveWorkspaceID,
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
        guard
          let target = tree.directionalNeighbor(
            of: key,
            direction: direction,
            in: workArea,
            gap: gap,
            focusOrder: tree.windows,
          )
        else {
          if
            let cross = crossBlockFocus(
              from: key,
              currentId: workspaceId,
              currentTree: tree,
              currentRect: workArea,
              direction: direction,
              state: state,
            )
          {
            debugLog.log("BSP", "focus \(direction) → cross into \(cross.target.bundleId)")
            let warp = settings.focus.mouseFollowsFocus
            return .run { [mouse = mouse, focus = focusManager] _ in
              await focus.focusWindow(cross.target)
              if warp {
                let frames = await MainActor.run {
                  Self.computeFrames(
                    tree: cross.tree,
                    settings: settings,
                    targetDisplay: cross.display,
                    fullscreenZoomed: cross.zoomed,
                    targetRect: cross.rect,
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
            "focus \(direction) from \(key.bundleId)#\(key.windowID): no neighbor",
          )
          return .none
        }
        debugLog.log(
          "BSP",
          "focus \(direction) \(key.bundleId)#\(key.windowID) "
            + "→ \(target.bundleId)#\(target.windowID)",
        )
        let warpMouse = settings.focus.mouseFollowsFocus
        let zoomed = state.fullscreenZoomed[workspaceId] ?? []
        return .run { [mouse = mouse, focus = focusManager] _ in
          await focus.focusWindow(target)
          if warpMouse {
            let frames = await MainActor.run {
              Self.computeFrames(
                tree: tree,
                settings: settings,
                targetDisplay: display,
                fullscreenZoomed: zoomed,
                targetRect: workArea,
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
        guard
          let workspace = state.config.activeProfile?.workspaces[id: workspaceId],
          let tree = state.tilingTrees[workspaceId]
        else { return .none }
        let newTree = tree.applying(op)
        guard newTree != tree else { return .none }
        state.tilingTrees[workspaceId] = newTree
        let zoomed = state.fullscreenZoomed[workspaceId] ?? []
        return .merge(
          flushLayout(workspaceId: workspaceId, state: &state),
          persist(
            newTree,
            fullscreenZoomed: zoomed,
            unresolvedFullscreenZoomSlots:
            state.unresolvedFullscreenZoomSlots[workspaceId] ?? [],
            for: workspace,
          ),
        )

      case .invalidateResidentLayout(let workspaceId):
        // The inactive workspace's saved snapshot was edited in the GUI. Its
        // resident session tree/zoom would otherwise win at the next activation
        // (activation only loads the snapshot when there's no session tree), so
        // drop them — activation then rebuilds from the edited snapshot.
        // A borrowed workspace is visible even though it is not a value in the
        // display→host map. Invalidating its resident tree would erase a live
        // composition block until the next activation.
        guard !state.visibleWorkspaceIDs.contains(workspaceId) else { return .none }
        state.tilingTrees[workspaceId] = nil
        state.fullscreenZoomed[workspaceId] = nil
        state.unresolvedFullscreenZoomSlots[workspaceId] = nil
        state.insertionPoint[workspaceId] = nil
        return .none

      case .persistedFullscreenZoomRestored(
        let workspaceId,
        let keys,
        let unresolvedSlots,
      ):
        state.fullscreenZoomed[workspaceId] = keys.isEmpty ? nil : keys
        state.unresolvedFullscreenZoomSlots[workspaceId] =
          unresolvedSlots.isEmpty ? nil : unresolvedSlots
        return .none

      case .activationFocusSnapshotResolved(let key):
        _ = state.recordFocusedWindow(
          key,
          requireVisibleTreeMembership: true,
          // This is the outgoing window captured before activation. Its AX
          // result can arrive after `performActivate` has already moved focus
          // to another monitor, so repair only MRU/insertion state here.
          updateFocusedDisplay: false,
        )
        return .none

      case .tilingTreeUpdated(let workspaceId, let tree):
        let removed = Set(state.tilingTrees[workspaceId]?.windows ?? [])
          .subtracting(tree.map { Set($0.windows) } ?? [])
        state.removeFromWindowMRU(removed, workspaceId: workspaceId)
        state.removeFromPresentationMonitoring(removed)
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

      case .borrowedTilingTreeHydrated(
        let display,
        let workspaceId,
        let generation,
        let previousTree,
        let tree,
      ):
        guard
          state.borrowGenerationByDisplay[display] == generation,
          state.compositionsByDisplay[display]?.borrowed.contains(where: {
            $0.workspace == workspaceId
          }) == true,
          state.tilingTrees[workspaceId] == previousTree
        else {
          debugLog.log(
            "Borrow",
            "skip stale hydration \(workspaceId): composition or tree advanced",
          )
          return .none
        }
        let removed = Set(previousTree?.windows ?? [])
          .subtracting(tree.map { Set($0.windows) } ?? [])
        state.removeFromWindowMRU(removed, workspaceId: workspaceId)
        state.removeFromPresentationMonitoring(removed)
        state.tilingTrees[workspaceId] = tree
        state.insertionPoint[workspaceId] = tree?.windows.first
        return .none

      case .presentationLayoutApplied(let keys, let preservesPointer):
        let monitored = state.armPresentationMonitoring(
          keys,
          preservesPointer: preservesPointer,
        )
        // During activation the target display mapping is not committed yet.
        // Keep the arm and verify immediately once `activationCompleted`
        // publishes that mapping.
        guard !state.isActivating else { return .none }
        return requestPresentationVerification(monitored, state: &state)

      case .layoutWriteFinished(let generation, let verificationKeys):
        state.activeLayoutWriteGenerations.remove(generation)
        state.dirtyPresentationSnapshotWindows.formUnion(verificationKeys)
        guard
          state.activeLayoutWriteGenerations.isEmpty,
          !state.dirtyPresentationSnapshotWindows.isEmpty
        else { return .none }
        let pending = state.dirtyPresentationSnapshotWindows
        state.dirtyPresentationSnapshotWindows.removeAll()
        return requestPresentationVerification(pending, state: &state)

      case .presentationObservationReady(let bundleIds):
        let keys = state.presentationConvergenceWindows.filter {
          bundleIds.contains($0.bundleId)
        }
        return requestPresentationVerification(Set(keys), state: &state)

      case .presentationFramesResolved(
        let keys,
        let currentFrames,
        let capturedLayoutGeneration,
      ):
        state.isPresentationSnapshotInFlight = false
        guard
          !state.isActivating,
          !state.isTilingPaused,
          !state.isInFullscreenSpace,
          case .idle = state.drag
        else {
          state.dirtyPresentationSnapshotWindows.formUnion(keys)
          return .none
        }
        guard
          capturedLayoutGeneration == state.layoutWriteGeneration,
          state.activeLayoutWriteGenerations.isEmpty
        else {
          // A newer frame writer started after this WindowServer read. Its
          // completion owns the next verification; this stale snapshot must
          // never launch a writer that cancels it.
          state.dirtyPresentationSnapshotWindows.formUnion(keys)
          guard state.activeLayoutWriteGenerations.isEmpty else { return .none }
          let pending = state.dirtyPresentationSnapshotWindows
          state.dirtyPresentationSnapshotWindows.removeAll()
          return requestPresentationVerification(pending, state: &state)
        }
        let trailingKeys = state.dirtyPresentationSnapshotWindows
        state.dirtyPresentationSnapshotWindows.removeAll()
        let repair = repairPresentationDrift(
          keys,
          currentFrames: currentFrames,
          state: &state,
        )
        let trailing = requestPresentationVerification(
          trailingKeys,
          state: &state,
        )
        return .merge(
          repair,
          trailing,
        )

      case .activationCompleted(let id, let display):
        state.isActivating = false
        state.activatingWorkspaceID = nil
        let reflowDisplayGeometry = state.pendingDisplayGeometryReflow
        state.pendingDisplayGeometryReflow = false
        let pendingWindowSyncBundleIds = state.pendingWindowSyncBundleIds
        state.pendingWindowSyncBundleIds.removeAll()
        let pendingWindowServerPrune = state.pendingWindowServerPrune
        state.pendingWindowServerPrune = false
        var persistWorkspaceSession = Effect<Action>.none
        if let display, let previous = state.activeWorkspacesByDisplay[display], previous != id {
          state.previousWorkspacesByDisplay[display] = previous
        }
        var emptiedByMove = [DisplayName]()
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
          let history = state.displayWorkspaceHistory
          let workspaceMRU = state.workspaceMRU
          persistWorkspaceSession = .run { [profileSessionStore] _ in
            await profileSessionStore.saveWorkspaceState(history, workspaceMRU)
          }
        }
        // A display a dynamic workspace just vacated gets refilled with what the
        // user last had on it — same rules as a reconnect. Skipped mid-cascade
        // (a reconnect plan already schedules its own refills).
        if
          state.pendingDisplayRestores.isEmpty, !emptiedByMove.isEmpty,
          let profile = state.config.activeProfile
        {
          var byId = [Workspace.ID: Workspace]()
          for w in profile.workspaces.elements where w.kind != .scratchpad { byId[w.id] = w }
          let fills = emptiedByMove
            .filter { state.connectedDisplays.contains($0) }
            .compactMap { vacated -> DisplayAssignment? in
              Self.chooseWorkspaceForDisplay(
                vacated,
                reconnect: false,
                byId: byId,
                workspaces: profile.workspaces.elements,
                assigned: state.activeWorkspacesByDisplay,
                history: state.displayWorkspaceHistory,
                connected: state.connectedDisplays,
              ).map { DisplayAssignment(display: vacated, workspace: $0) }
            }
          // The refill is otherwise invisible in the log, which made an empty
          // vacated display indistinguishable from one that was never vacated.
          for vacated in emptiedByMove {
            let fill = fills.first { $0.display.matches(vacated) }?.workspace
            debugLog.log(
              "Display",
              "vacated \(vacated.name) → "
                + (fill.flatMap { profile.workspaces[id: $0]?.name } ?? "nothing eligible"),
            )
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
        var observedBundleIds = OrderedSet(treeIds ?? registeredIds)
        observedBundleIds.append(contentsOf: floatingIds)
        observedBundleIds.append(contentsOf: unmanagedIds)
        let observeIds = Array(observedBundleIds)
        debugLog.log(
          "Activate",
          "completed workspaceId=\(id) "
            + "treeWindows=\(state.tilingTrees[id]?.windows.map { $0.windowID } ?? []) "
            + "observe=\(observeIds)",
        )
        let activatedKeys = Set(state.tilingTrees[id]?.windows ?? [])
        return .merge(
          .cancel(id: CancelID.activationWatchdog),
          persistWorkspaceSession,
          .run { [observer = windowObserver] _ in await observer.observe(observeIds) },
          // The unpaused path already pushed markers from the activation
          // effect's own floating discovery; only the paused path (which
          // skips that block) still needs a refresh here.
          state.isTilingPaused ? refreshMarkers(state: state) : .none,
          // Reconcile only notifications that actually arrived while the
          // activation gate was closed. The observer is armed at activation
          // start, so a blanket delayed AX sweep is no longer needed.
          state.isTilingPaused
            ? .none
            : .merge(pendingWindowSyncBundleIds.map { requestWindowSync($0) }),
          pendingWindowServerPrune ? .send(.pruneOffscreenWindows) : .none,
          reflowDisplayGeometry ? .send(.displayGeometryChanged) : .none,
          activatedKeys.isEmpty
            ? .none
            : .send(
              .presentationLayoutApplied(
                keys: activatedKeys,
                preservesPointer: false,
              )
            ),
        )

      case .activationTailFinished:
        // Drain the display-restore queue: the activation effect is fully
        // done, so the next display's restore can take the slot without
        // cancelling anyone's post-layout work.
        guard !state.pendingDisplayRestores.isEmpty else { return .none }
        return .send(.processDisplayRestores)

      case .activationTimedOut:
        guard state.isActivating else { return .none }
        state.isActivating = false
        state.activatingWorkspaceID = nil
        let reflowDisplayGeometry = state.pendingDisplayGeometryReflow
        state.pendingDisplayGeometryReflow = false
        let pendingWindowSyncBundleIds = state.pendingWindowSyncBundleIds
        state.pendingWindowSyncBundleIds.removeAll()
        let pendingWindowServerPrune = state.pendingWindowServerPrune
        state.pendingWindowServerPrune = false
        debugLog.log(
          "Activate",
          "watchdog: activation did not complete in 10 s — releasing the gate",
        )
        return .merge(
          .cancel(id: CancelID.activation),
          reflowDisplayGeometry ? .send(.displayGeometryChanged) : .none,
          .merge(pendingWindowSyncBundleIds.map { requestWindowSync($0) }),
          pendingWindowServerPrune ? .send(.pruneOffscreenWindows) : .none,
          // The cancelled effect will never report its tail, so drain the
          // restore queue here or a wedged activation strands it for good.
          state.pendingDisplayRestores.isEmpty ? .none : .send(.processDisplayRestores),
        )
      }
    }
  }

  // MARK: Internal

  struct PostLayoutFocus: Sendable {
    var windowKey: WindowKey
    var workspaceId: Workspace.ID
    var shouldFocus: Bool
  }

  struct BorrowPhase: Sendable {
    var display: DisplayName
    var workspaceId: Workspace.ID
    var generation: UInt64
    var composition: Composition
  }

  /// Cancellation identifiers for latest-wins effects and bounded safety work.
  enum CancelID: Hashable {
    /// One visual surface has one frame writer. Normal workspace and borrow
    /// composition layouts on the same display share this id, so crossing the
    /// composition boundary also cancels the stale writer.
    case layout(DisplayName?)
    /// Focus/MFF for a freshly borrowed block is part of the same generation-
    /// validated transaction, but has its own cancellation slot after layout.
    case borrowFocus(DisplayName?)
    /// Reveal/discovery for one display's borrowed block. A dismiss or a
    /// replacement Borrow must stop its old show/hide transaction as well as
    /// rejecting its eventual reducer actions.
    case borrowRender(DisplayName?)
    /// Window-move notifications arrive continuously during a drag. Only the
    /// latest preview matters; older panel updates must not queue behind it.
    case dragPreview
    /// Floating discovery/overlay replacement is authoritative and must not be
    /// cancelled by marker-only work.
    case floatingPresentation
    /// Latest floating-window AX discovery. Kept separate from the overlay
    /// commit so sending its resolved action cannot cancel its own parent task.
    case floatingDiscovery
    /// Marker targets are independently latest-wins.
    case markerRefresh
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
    /// The delayed HUD reveal and modifier polling have distinct lifetimes:
    /// a quick tap cancels the reveal, while the polling task owns the session.
    case windowCycleHUDDelay
    case windowCycleModifier
    /// Focus can move again while a cursor warp is waiting for the main actor.
    /// Only the newest focused window in a workspace may move the cursor.
    case warp(Workspace.ID)
    /// Repeated close/sync signals for one empty tree share one live AX
    /// presence check.
    case emptyWorkspacePresence(Workspace.ID)
  }

  @Dependency(\.workspaceManager) var workspaceManager
  @Dependency(\.windowTiler) var windowTiler
  @Dependency(\.windowObserver) var windowObserver
  @Dependency(\.appLaunch) var appLaunch
  @Dependency(\.displays) var displays
  @Dependency(\.layoutStore) var layoutStore
  @Dependency(\.profileSessionStore) var profileSessionStore
  @Dependency(\.workspaceHUD) var workspaceHUD
  @Dependency(\.mouse) var mouse
  @Dependency(\.marker) var marker
  @Dependency(\.dragPreview) var dragPreview
  @Dependency(\.floatingOverlay) var floatingOverlay
  @Dependency(\.screenRecording) var screenRecording
  @Dependency(\.debugLog) var debugLog
  @Dependency(\.windowSnapshot) var windowSnapshot
  @Dependency(\.focusManager) var focusManager
  @Dependency(\.focusEventOrigin) var focusEventOrigin
  @Dependency(\.continuousClock) var clock
  @Dependency(\.modifierKeys) var modifierKeys
  @Dependency(\.borrowChord) var borrowChord
  @Dependency(\.sls) var sls

  /// The named display's work area inset by the outer gap — the rect
  /// every tiling computation runs in.
  func tilingWorkArea(for display: DisplayName?, settings: AppSettings) -> CGRect {
    displays.workArea(display).insetBy(
      dx: CGFloat(settings.layout.gapOuter),
      dy: CGFloat(settings.layout.gapOuter),
    )
  }

  /// Flush `tree`'s layout to the tiler: compute frames on the main actor,
  /// then apply. Every layout flush funnels through here so the coalescing
  /// policy can't drift per call site. Every writer for a display uses the
  /// same cancellation domain, so a stale single-tree apply cannot outlive a
  /// newer composition apply (or the reverse) and overwrite its frames.
  func applyLayout(
    tree: BSPNode<WindowKey>,
    workspaceId _: Workspace.ID,
    settings: AppSettings,
    display: DisplayName?,
    fullscreenZoomed: Set<WindowKey>,
    forceAllFrames: Bool = false,
    followUp: PostLayoutFocus? = nil,
    monitorsPresentationChanges: Bool = false,
    presentationRepairKeys: Set<WindowKey> = [],
    state: inout State,
  ) -> Effect<Action> {
    let monitoredKeys = monitorsPresentationChanges
      ? state.armPresentationMonitoring(
        Set(tree.windows),
        preservesPointer: false,
      )
      : []
    state.layoutWriteGeneration &+= 1
    let layoutGeneration = state.layoutWriteGeneration
    state.activeLayoutWriteGenerations.insert(layoutGeneration)
    let writer = Effect<Action>.run { [tiler = windowTiler] send in
      let frames = await MainActor.run {
        Self.computeFrames(
          tree: tree,
          settings: settings,
          targetDisplay: display,
          fullscreenZoomed: fullscreenZoomed,
        )
      }
      guard !Task.isCancelled, !frames.isEmpty else { return }
      await tiler.apply(
        FrameApplication(windowFrames: frames, forceAllFrames: forceAllFrames)
      )
      guard !Task.isCancelled else { return }
      if let followUp {
        await send(
          .settleFocusAfterLayout(
            windowKey: followUp.windowKey,
            workspaceId: followUp.workspaceId,
            shouldFocus: followUp.shouldFocus,
          )
        )
      }
    }
    return .concatenate(
      writer.cancellable(
        id: CancelID.layout(display),
        cancelInFlight: true,
      ),
      .send(
        .layoutWriteFinished(
          generation: layoutGeneration,
          verificationKeys: presentationRepairKeys.union(monitoredKeys),
        )
      ),
    )
  }

  /// Composition-aware flush for a workspace whose tree was just mutated.
  /// When the workspace is a block in an active composition, the whole
  /// composition is re-laid (both blocks into their sub-rects) so a
  /// single-tree apply can't clobber the sibling block; otherwise it tiles
  /// into its own work area. The mutated tree must already be written to
  /// `state.tilingTrees[workspaceId]`.
  func flushLayout(
    workspaceId: Workspace.ID,
    state: inout State,
    forceAllFrames: Bool = false,
    followUp: PostLayoutFocus? = nil,
    monitorsPresentationChanges: Bool = false,
    presentationRepairKeys: Set<WindowKey> = [],
  ) -> Effect<Action> {
    for (display, comp) in state.compositionsByDisplay
      where comp.host == workspaceId
      || comp.borrowed.contains(where: { $0.workspace == workspaceId })
    {
      return applyComposition(
        display: display,
        forceAllFrames: forceAllFrames,
        followUp: followUp,
        monitorsPresentationChanges: monitorsPresentationChanges,
        presentationRepairKeys: presentationRepairKeys,
        state: &state,
      )
    }
    guard
      state.config.activeProfile?.workspaces[id: workspaceId] != nil,
      let tree = state.tilingTrees[workspaceId]
    else { return .none }
    let settings = state.config.settings
    // Resolve the display the workspace is actually *shown* on — via
    // `activeWorkspacesByDisplay` first (the placement source of truth), not the
    // cursor. A keyboard op / drag on a workspace shown on a non-cursor display
    // must compute frames for THAT monitor. `tilingContext` falls through to the
    // same `displayHint ?? current()` chain when the workspace isn't active.
    let display = tilingContext(for: workspaceId, state: state).display
    let zoomed = state.fullscreenZoomed[workspaceId] ?? []
    return applyLayout(
      tree: tree,
      workspaceId: workspaceId,
      settings: settings,
      display: display,
      fullscreenZoomed: zoomed,
      forceAllFrames: forceAllFrames,
      followUp: followUp,
      monitorsPresentationChanges: monitorsPresentationChanges,
      presentationRepairKeys: presentationRepairKeys,
      state: &state,
    )
  }

  /// Compute each involved tree once, then select the requested keys. The old
  /// per-key helper recalculated the whole BSP frame map for every window,
  /// turning one verification into O(windowCount²) work on the reducer.
  func expectedPresentationFrames(
    for keys: Set<WindowKey>,
    state: State,
  ) -> [WindowKey: CGRect] {
    guard !keys.isEmpty else { return [:] }
    let gap = CGFloat(state.config.settings.layout.gapInner)
    var expected = [WindowKey: CGRect]()
    for workspaceId in state.visibleWorkspaceIDs {
      guard
        let tree = state.tilingTrees[workspaceId],
        !keys.isDisjoint(with: tree.windows)
      else { continue }
      let context = tilingContext(for: workspaceId, state: state)
      let zoomed = (state.fullscreenZoomed[workspaceId] ?? [])
        .intersection(Set(tree.windows))
      var frames: [WindowKey: CGRect]
      if zoomed.isEmpty {
        frames = tree.frames(in: context.rect, gap: gap)
      } else {
        let trimmed = tree.removingAll(zoomed)
        frames = trimmed?.frames(in: context.rect, gap: gap) ?? [:]
        for zoomedKey in zoomed { frames[zoomedKey] = context.rect }
      }
      for key in keys {
        if let frame = frames[key] { expected[key] = frame }
      }
    }
    return expected
  }

  /// Capture WindowServer geometry on a worker. `CGWindowListCopyWindowInfo`
  /// materializes dictionaries for every visible surface and can be expensive
  /// under load; reducer callbacks must stay free to accept the next hotkey.
  func requestPresentationVerification(
    _ keys: Set<WindowKey>,
    state: inout State,
  ) -> Effect<Action> {
    let candidates = keys.intersection(state.presentationConvergenceWindows)
    guard !candidates.isEmpty else { return .none }
    guard
      !state.isActivating,
      !state.isTilingPaused,
      !state.isInFullscreenSpace,
      case .idle = state.drag
    else {
      state.dirtyPresentationSnapshotWindows.formUnion(candidates)
      return .none
    }
    if
      state.isPresentationSnapshotInFlight
      || !state.activeLayoutWriteGenerations.isEmpty
    {
      state.dirtyPresentationSnapshotWindows.formUnion(candidates)
      return .none
    }
    state.dirtyPresentationSnapshotWindows.subtract(candidates)
    state.isPresentationSnapshotInFlight = true
    let layoutGeneration = state.layoutWriteGeneration
    return .run(priority: .high) { [windowSnapshot] send in
      let currentFrames = windowSnapshot.onScreenWindowFrames()
      guard !Task.isCancelled else { return }
      await send(
        .presentationFramesResolved(
          keys: candidates,
          currentFrames: currentFrames,
          layoutGeneration: layoutGeneration,
        )
      )
    }
  }

  /// Verify armed windows from one local WindowServer snapshot and repair each
  /// affected display. A display-scoped repair is verified immediately after
  /// its writer finishes, so multi-stage app restores converge without a
  /// scheduler delay. Three consecutive rejected writes disarm that window,
  /// bounding hard minimum-size constraints without hiding the initial drift.
  func repairPresentationDrift(
    _ keys: Set<WindowKey>,
    currentFrames: [CGWindowID: CGRect],
    state: inout State,
  ) -> Effect<Action> {
    guard
      !keys.isEmpty,
      !state.isActivating,
      !state.isTilingPaused,
      !state.isInFullscreenSpace,
      case .idle = state.drag
    else { return .none }

    let visibleWindows = state.visibleWorkspaceIDs.reduce(into: Set<WindowKey>()) {
      $0.formUnion(state.tilingTrees[$1]?.windows ?? [])
    }
    let noLongerVisible = state.presentationConvergenceWindows
      .subtracting(visibleWindows)
    state.removeFromPresentationMonitoring(noLongerVisible)
    let candidates = keys
      .intersection(state.presentationConvergenceWindows)
    guard !candidates.isEmpty else { return .none }

    let expectedFrames = expectedPresentationFrames(for: candidates, state: state)
    var drifted = Set<WindowKey>()
    var exhausted = Set<WindowKey>()
    for key in candidates {
      guard
        let current = currentFrames[key.windowID],
        let expected = expectedFrames[key]
      else { continue }
      if
        WindowTilerClient.frameWritePlan(
          current: current,
          target: expected,
          tolerance: 1.5,
        ) == .none
      {
        state.presentationRepairAttempts[key] = nil
      } else if
        state.presentationRepairAttempts[key, default: 0]
        >= Self.maximumPresentationRepairAttempts
      {
        exhausted.insert(key)
      } else {
        drifted.insert(key)
      }
    }

    if !exhausted.isEmpty {
      for key in exhausted {
        debugLog.log(
          "Tiler",
          "stop geometry convergence \(key.bundleId)#\(key.windowID) "
            + "after \(Self.maximumPresentationRepairAttempts) rejected writes",
        )
        state.presentationRepairAttempts[key] = nil
      }
      state.removeFromPresentationMonitoring(exhausted)
    }
    guard !drifted.isEmpty else { return .none }

    var rootByWorkspace = Dictionary(
      uniqueKeysWithValues: state.visibleWorkspaceIDs.map { ($0, $0) }
    )
    for composition in state.compositionsByDisplay.values {
      rootByWorkspace[composition.host] = composition.host
      for slot in composition.borrowed {
        rootByWorkspace[slot.workspace] = composition.host
      }
    }
    var ownershipByKey = [
      WindowKey: (owner: Workspace.ID, root: Workspace.ID)
    ]()
    for owner in state.visibleWorkspaceIDs {
      guard let root = rootByWorkspace[owner] else { continue }
      for key in state.tilingTrees[owner]?.windows ?? []
        where state.presentationConvergenceWindows.contains(key)
      {
        ownershipByKey[key] = (owner, root)
      }
    }

    var driftedByRoot = [Workspace.ID: Set<WindowKey>]()
    for key in drifted {
      guard let ownership = ownershipByKey[key] else { continue }
      driftedByRoot[ownership.root, default: []].insert(key)
      state.presentationRepairAttempts[key, default: 0] += 1
    }

    var effects = [Effect<Action>]()
    for (root, rootDrifted) in driftedByRoot {
      let repairKeys = Set(state.presentationConvergenceWindows.filter {
        ownershipByKey[$0]?.root == root
      })
      let focusedRepair: PostLayoutFocus? = state.lastObservedFocusedWindow.flatMap { focused in
        guard
          rootDrifted.contains(focused),
          !state.presentationPreservesPointerWindows.contains(focused),
          let ownership = ownershipByKey[focused]
        else { return nil }
        return
          PostLayoutFocus(
            windowKey: focused,
            workspaceId: ownership.owner,
            shouldFocus: false,
          )
      }
      effects.append(
        flushLayout(
          workspaceId: root,
          state: &state,
          followUp: focusedRepair,
          monitorsPresentationChanges: false,
          presentationRepairKeys: repairKeys,
        )
      )
    }
    return .merge(effects)
  }

  /// Snapshot the tree to disk so the workspace's BSP layout survives a
  /// restart. The tree is bundle-id keyed (`WindowKey`s die at process exit);
  /// fullscreen-zoom is recorded so it survives too. Per-leaf parent-zoom is
  /// carried inside the tree itself. No-op only when the tree is empty.
  func persist(
    _ tree: BSPNode<WindowKey>?,
    fullscreenZoomed: Set<WindowKey>,
    unresolvedFullscreenZoomSlots: Set<SlotID> = [],
    for workspace: Workspace,
  ) -> Effect<Action> {
    guard let tree else { return .none }
    let id = workspace.id
    // Occurrence-aware slots (windowID rank per bundle) so two windows of one
    // app persist their distinct positions; the same map keys the zoom set.
    let slots = slotAssignment(tree.windows)
    let template = tree.mapWindows { slots[$0]! }
    let zoomedSlots = Set(fullscreenZoomed.compactMap { slots[$0] })
      .union(unresolvedFullscreenZoomSlots)
      .sorted { ($0.bundleId, $0.occurrence) < ($1.bundleId, $1.occurrence) }
    let snapshot = LayoutSnapshot(tree: template, fullscreenZoomedSlots: zoomedSlots)
    return .run { [store = layoutStore] _ in await store.save(id, snapshot) }
  }

  // MARK: Private

  private static let maximumPresentationRepairAttempts = 3

  /// User-intent entry actions that may need a cursor-screen fallback before
  /// the first focused-window owner is known. The `*Resolved` continuations
  /// are deliberately absent: the display was resolved at their entry action,
  /// and re-resolving mid-flow could move the target between the two beats.
  private static func refreshesFocusedDisplay(_ action: Action) -> Bool {
    switch action {
    case .activateInitial,
         .activate,
         .activateNext,
         .activatePrevious,
         .activateRecent,
         .focusAdjacentDisplay,
         .moveFocusedAppToAdjacent,
         .membershipEdit,
         .togglePaused,
         .bspFocus,
         .bspSwap,
         .bspResize,
         .bspToggleOrientation,
         .bspToggleZoomFullscreen,
         .bspBalance,
         .appActivated:
      true
    default:
      false
    }
  }

  /// Resolve one logical step without moving focus. Both immediate gesture
  /// cycling and held-modifier keyboard sessions share this ordering/MRU path,
  /// so their app-level and window-level behavior cannot drift.
  private func windowCycle(
    from key: WindowKey,
    direction: CycleDirection,
    holdModifiers: HotKeyModifiers,
    focusedWindow: WindowKey? = nil,
    state: State,
  ) -> State.WindowCycleSession? {
    guard let workspaceId = state.workspaceOwning(key) ?? state.primaryActiveWorkspaceID
    else { return nil }

    // Borrow is one visible task surface, so cycling spans every tiled tree in
    // that display's composition. Keep the host first for deterministic HUD
    // order; the current key still determines the next/previous wrap point.
    let display = state.displayShowing(workspaceId)
    let composition = display.flatMap { state.compositionsByDisplay[$0] }
    let workspaceIds = composition.map {
      [$0.host] + $0.borrowed.map(\.workspace)
    } ?? [workspaceId]
    var allWindows = workspaceIds.flatMap { state.tilingTrees[$0]?.windows ?? [] }

    // Floating/unmanaged join only when uncomposed. A borrowed workspace's
    // non-tiled assignments are intentionally not part of the borrowed block.
    let isComposed = composition != nil
    if !isComposed {
      let floatingBundles = Self.floatingBundleIds(
        state: state,
        workspaceIDs: [workspaceId],
      )
      if !floatingBundles.isEmpty {
        allWindows += windowSnapshot.cachedKeys(floatingBundles, false)
      }
      let unmanagedBundles = Self.unmanagedBundleIds(
        state: state,
        workspaceIDs: [workspaceId],
      )
      if !unmanagedBundles.isEmpty {
        allWindows += windowSnapshot.cachedKeys(unmanagedBundles, false)
      }
    }
    guard !allWindows.isEmpty else { return nil }

    let byWindow = state.config.settings.switching.cycleSameAppWindows
    var ordered = allWindows
    if !byWindow {
      var seenApps = Set<String>()
      ordered = allWindows.filter { seenApps.insert($0.bundleId).inserted }
    }
    guard ordered.count > 1 else { return nil }

    let count = ordered.count
    let step = direction == .next ? 1 : -1
    let index = byWindow
      ? (ordered.firstIndex(of: key) ?? -1)
      : (ordered.firstIndex { $0.bundleId == key.bundleId } ?? -1)
    var target = ordered[((index + step) % count + count) % count]

    // App-level cycle lands on that app's most-recently-focused window rather
    // than whichever representative happened to appear first in the tree.
    if !byWindow {
      let targetOwner = state.workspaceOwning(target) ?? workspaceId
      let mru = state.mruWindows[targetOwner] ?? []
      let live = Set(allWindows)
      if
        let recent = mru.first(where: {
          $0.bundleId == target.bundleId && live.contains($0)
        })
      {
        target = recent
      }
    }
    guard target != key else { return nil }

    debugLog.log(
      "BSP",
      "cycle \(direction) \(key.bundleId)#\(key.windowID) "
        + "→ \(target.bundleId)#\(target.windowID)",
    )
    let targetWorkspaceId = state.workspaceOwning(target) ?? workspaceId
    return State.WindowCycleSession(
      workspaceId: targetWorkspaceId,
      windows: ordered,
      selected: target,
      focusedWindow: focusedWindow ?? key,
      byWindow: byWindow,
      display: display ?? tilingContext(for: targetWorkspaceId, state: state).display,
      holdModifiers: holdModifiers,
      isHUDVisible: false,
    )
  }

  private func commitWindowCycle(
    _ cycle: State.WindowCycleSession,
    state: State,
  ) -> Effect<Action> {
    let settings = state.config.settings
    let target = cycle.selected
    let shouldWarp = settings.focus.mouseFollowsFocus
    let tree = state.tilingTrees[cycle.workspaceId]
    let zoomed = state.fullscreenZoomed[cycle.workspaceId] ?? []
    let targetRect = tilingContext(for: cycle.workspaceId, state: state).rect
    return .run { [mouse, focusManager, windowSnapshot] _ in
      await focusManager.focusWindow(target)
      if shouldWarp {
        let tiledFrame = await MainActor.run {
          tree.flatMap {
            Self.computeFrames(
              tree: $0,
              settings: settings,
              targetDisplay: cycle.display,
              fullscreenZoomed: zoomed,
              targetRect: targetRect,
            )[target]
          }
        }
        // Floating, Shared floating, and Ignore-mode windows intentionally
        // live outside the BSP tree. Once focus has handed back the real
        // window, read its current AX frame so MFF follows cycling there too.
        let targetFrame: CGRect? =
          if let tiledFrame {
            tiledFrame
          } else {
            await windowSnapshot.windowFrameOffMain(target)
          }
        if let rect = targetFrame {
          mouse.warp(CGPoint(x: rect.midX, y: rect.midY))
        }
      }
    }
  }

  private func finishWindowCycle(
    _ cycle: State.WindowCycleSession,
    commit: Bool,
    state: inout State,
  ) -> Effect<Action> {
    state.windowCycleSession = nil
    var effects: [Effect<Action>] = [
      .cancel(id: CancelID.windowCycleHUDDelay),
      .cancel(id: CancelID.windowCycleModifier),
    ]
    if commit {
      effects.append(commitWindowCycle(cycle, state: state))
    }
    if cycle.isHUDVisible {
      effects.append(
        .run { [workspaceHUD, display = cycle.display] _ in
          await workspaceHUD.dismissWindowSwitcher(display)
        }
      )
    }
    return .merge(effects)
  }

  private func showWindowCycleHUD(
    _ cycle: State.WindowCycleSession,
    autoDismissAfterMs: Int?,
    state: State,
  ) -> Effect<Action> {
    let indicators = windowSwitcherIndicators(cycle, state: state)
    return .run { [workspaceHUD] _ in
      await workspaceHUD.showWindowSwitcher(
        cycle.windows,
        cycle.selected,
        cycle.byWindow,
        indicators,
        autoDismissAfterMs,
        cycle.display,
      )
    }
  }

  private func windowSwitcherIndicators(
    _ cycle: State.WindowCycleSession,
    state: State,
  ) -> [WindowKey: WindowSwitcherIndicators] {
    let composition = cycle.display.flatMap { state.compositionsByDisplay[$0] }
    let workspaceIds = Set(
      composition.map { [$0.host] + $0.borrowed.map(\.workspace) }
        ?? [cycle.workspaceId]
    )
    let floatingBundleIds = Set(Self.floatingBundleIds(
      state: state,
      workspaceIDs: workspaceIds,
    ))
    let sharedBundleIds = Set(state.config.sharedApps.map(\.bundleIdentifier))
    let borrowedWorkspaceIds = Set(composition?.borrowed.map(\.workspace) ?? [])
    let fullscreenKeys = workspaceIds.reduce(into: Set<WindowKey>()) {
      $0.formUnion(state.fullscreenZoomed[$1] ?? [])
    }
    let fullscreenBundleIds = Set(fullscreenKeys.map(\.bundleId))
    let borrowedBundleIds = borrowedWorkspaceIds.reduce(into: Set<String>()) {
      $0.formUnion(state.tilingTrees[$1]?.windows.map(\.bundleId) ?? [])
    }
    var ownerByWindow = [WindowKey: Workspace.ID]()
    for workspaceId in workspaceIds {
      for key in state.tilingTrees[workspaceId]?.windows ?? [] {
        ownerByWindow[key] = workspaceId
      }
    }

    return Dictionary(uniqueKeysWithValues: cycle.windows.map { key in
      let isBorrowed = cycle.byWindow
        ? ownerByWindow[key].map(borrowedWorkspaceIds.contains) == true
        : borrowedBundleIds.contains(key.bundleId)
      let isFullscreen = cycle.byWindow
        ? fullscreenKeys.contains(key)
        : fullscreenBundleIds.contains(key.bundleId)
      return (
        key,
        WindowSwitcherIndicators(
          isFloating: floatingBundleIds.contains(key.bundleId),
          isShared: sharedBundleIds.contains(key.bundleId),
          isBorrowed: isBorrowed,
          isFocused: cycle.byWindow
            ? key == cycle.focusedWindow
            : key.bundleId == cycle.focusedWindow.bundleId,
          isFullscreen: isFullscreen,
        ),
      )
    })
  }

  private func resolveFocusedWindowKey(
    _ continuation: @escaping @Sendable (WindowKey) -> Action
  ) -> Effect<Action> {
    .run { [snapshot = windowSnapshot, debugLog] send in
      let key = await snapshot.focusedWindowKeyOffMain()
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

  private func applyBSPOp(
    windowKey: WindowKey,
    op: BSPOp,
    state: inout State,
  ) -> Effect<Action> {
    // Resolve to the block that owns the focused window — the borrowed
    // workspace when composed, else the single active one. Every mutation
    // runs on this one tree, so directional ops can't cross the boundary.
    guard
      let workspaceId = state.workspaceOwning(windowKey) ?? state.primaryActiveWorkspaceID,
      let workspace = state.config.activeProfile?
        .workspaces[id: workspaceId],
      var tree = state.tilingTrees[workspaceId]
    else {
      debugLog.log(
        "BSP",
        "\(String(describing: op)) \(windowKey.bundleId)#\(windowKey.windowID): "
          + "no active workspace/tree",
      )
      return .none
    }
    debugLog.log(
      "BSP",
      "\(String(describing: op)) \(windowKey.bundleId)#\(windowKey.windowID)",
    )

    let settings = state.config.settings
    // The block's geometry: a composition sub-rect when composed, else the
    // workspace's full work area. (Display is re-derived in `flushLayout`.)
    let (_, workArea) = tilingContext(for: workspaceId, state: state)
    let gap = CGFloat(settings.layout.gapInner)
    // Ops with no obvious visual cue of their own attach a HUD here.
    var hud = Effect<Action>.none
    // Ops that relocate the focused window itself (swap/warp) should carry the
    // cursor with it under mouse-follows-focus — the directional *focus* paths
    // already warp, but the swap path moved the window and left the cursor
    // behind on the now-other tile.
    var warpFocused = false

    switch op {
    case .swap(let direction):
      let updated = tree.applyingDirectionalSwap(
        window: windowKey,
        direction: direction,
        in: workArea,
        gap: gap,
        focusOrder: tree.windows,
      )
      guard updated != tree else { return .none }
      tree = updated
      warpFocused = true

    case .resize(let direction, let delta):
      // Grow/shrink the focused window along the axis implied by the
      // direction. `resizing` walks to the nearest ancestor whose split
      // matches that axis and flips the sign by side, so a positive delta
      // always grows the focused window — including when it sits on the
      // east/south edge. (The previous fence-based path returned nil at the
      // edge, which made grow/shrink a no-op for edge windows.)
      tree = tree.resizing(window: windowKey, direction: direction, delta: delta)

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
      // Explicit user intent supersedes any cold-start restore still waiting
      // for an absent window occurrence.
      state.unresolvedFullscreenZoomSlots[workspaceId] = nil
      hud = hudEffect(
        state,
        \.fullscreen,
        zoomingIn ? "Fullscreen" : "Exit Fullscreen",
        zoomingIn
          ? "arrow.up.left.and.arrow.down.right"
          : "arrow.down.right.and.arrow.up.left",
      )

    case .balance:
      tree = tree.balancedForCommand(
        autoBalance: settings.layout.autoBalance,
        in: workArea,
        gap: gap,
        splitAxis: settings.layout.splitType.bspSplitAxis(),
      )
      hud = hudEffect(state, \.layout, "Layout Balanced", "equal.circle")
    }

    state.tilingTrees[workspaceId] = tree
    let zoomed = state.fullscreenZoomed[workspaceId] ?? []
    let followUp = warpFocused
      ? PostLayoutFocus(
        windowKey: windowKey,
        workspaceId: workspaceId,
        shouldFocus: false,
      )
      : nil

    return .merge(
      // A rapid sequence of tree edits can cancel an older same-app AX batch
      // only after that batch has already written one or more windows. Force
      // the newest complete frame set so it cannot inherit a mixed geometry,
      // and trigger MFF only after those writes finish.
      flushLayout(
        workspaceId: workspaceId,
        state: &state,
        forceAllFrames: true,
        followUp: followUp,
      ),
      persist(
        tree,
        fullscreenZoomed: zoomed,
        unresolvedFullscreenZoomSlots:
        state.unresolvedFullscreenZoomSlots[workspaceId] ?? [],
        for: workspace,
      ),
      refreshMarkers(state: state),
      hud,
    )
  }

}
