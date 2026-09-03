// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import OrderedCollections

// MARK: - DisplayAssignment

/// A workspace to (re)activate on a specific display — the unit of a
/// display-reconnect restore plan (and its pending queue).
public struct DisplayAssignment: Equatable, Sendable {

  // MARK: Lifecycle

  public init(display: DisplayName, workspace: Workspace.ID) {
    self.display = display
    self.workspace = workspace
    presentation = nil
  }

  // MARK: Public

  public var display: DisplayName
  public var workspace: Workspace.ID

  // MARK: Internal

  var presentation: DisplayRestorePresentation?

}

// MARK: - DisplayRestorePresentation

enum DisplayRestorePresentation: Equatable, Sendable {
  case workspaceChain(WorkspaceChainHUDContext)
  case workspaceCleanup(WorkspaceChainCleanupTransaction)
}

// MARK: - WorkspaceChainPlanningFailure

/// Structural or transient runtime state that prevents even the selected
/// workspace from anchoring a workspace-chain plan. Display scarcity and pin
/// collisions are not failures: the chain's stored order decides which peers
/// fit on the currently connected displays.
enum WorkspaceChainPlanningFailure: Error, Equatable, Sendable {
  case duplicateWorkspace(Workspace.ID)
  case invalidWorkspace(Workspace.ID)
  case tooFewWorkspaces
  case triggerDisplayUnavailable(DisplayName)
  case triggerNotInChain(Workspace.ID)

  // MARK: Internal

  var description: String {
    switch self {
    case .duplicateWorkspace(let id):
      "workspace appears more than once: \(id)"

    case .invalidWorkspace(let id):
      "workspace is missing or not independently activatable: \(id)"

    case .tooFewWorkspaces:
      "a chain needs at least two workspaces"

    case .triggerDisplayUnavailable(let display):
      "trigger display is not connected: \(display.name)"

    case .triggerNotInChain(let id):
      "trigger workspace is not in the chain: \(id)"
    }
  }
}

// MARK: - WorkspaceChainPlan

struct WorkspaceChainPlan: Equatable, Sendable {
  let assignments: [DisplayAssignment]
  /// Chain members selected by the priority pass, including peers that are
  /// already on their desired display and therefore need no activation entry.
  let selectedWorkspaceIDs: Set<Workspace.ID>
}

// MARK: - WorkspaceChainHUDRole

enum WorkspaceChainHUDRole: Equatable, Sendable {
  case chainMember
  case nonChain

  var subtitleSymbolIconName: String? {
    switch self {
    case .chainMember: "link"
    case .nonChain: nil
    }
  }
}

// MARK: - WorkspaceChainHUDContext

/// One direct chain switch can update several displays sequentially. Retaining
/// the complete destination set lets every changed display present its own HUD
/// without the final cross-monitor focus note overwriting that feedback.
struct WorkspaceChainHUDContext: Equatable, Sendable {
  let name: String
  /// Whether this destination is an actual selected member or an unrelated
  /// workspace supplied by the ordinary empty-display fallback.
  let role: WorkspaceChainHUDRole
  /// A focused profile switch can also trigger a workspace chain. Retaining
  /// both presentations in one display-scoped context prevents two HUDs (and
  /// two hook events) from competing on the same screen.
  let profileSwitch: WorkspaceChainProfileSwitchHUD?
  /// Every destination or newly-vacated display that owns more specific chain
  /// feedback. A generic focus-moved HUD must not overwrite those panels.
  let coveredDisplays: [DisplayName]
  /// The user-selected member owns final focus after every companion restore.
  /// Carry the complete transfer so the display being left can fold it into
  /// its own result HUD instead of losing either result to a later overwrite.
  let focusTransfer: WorkspaceChainFocusTransfer?
  /// Borrowed workspaces that this assignment removes from its destination.
  /// Captured before the restore queue starts so an earlier assignment cannot
  /// consume the composition and erase this display's result text.
  let destinationReturnedBorrowNames: [String]
  /// Composition changes on displays that keep their current host and therefore
  /// have no destination/vacated assignment of their own.
  let sourceCompositionHUDs: [WorkspaceChainSourceCompositionHUD]
  /// Facts that become true only after a priority cleanup physically returns
  /// the source display. They are emitted by the display-scoped commit, never
  /// by an earlier assignment.
  let deferredCleanupHUDs: [WorkspaceChainSourceCompositionHUD]
  /// Source displays left empty by moving this assignment's workspace away.
  /// Sources filled by another assignment are covered by that result instead.
  let vacatedHUDs: [WorkspaceChainVacatedHUD]
  /// Priority cleanup is committed only after the final trigger has established
  /// focus and its visibility return succeeds. Cancellation before then leaves
  /// the original state intact for the next switch to recalculate.
  var cleanupTransaction: WorkspaceChainCleanupTransaction?
}

// MARK: - WorkspaceChainProfileSwitchHUD

struct WorkspaceChainProfileSwitchHUD: Equatable, Sendable {
  let name: String
  let symbolIconName: String?
}

// MARK: - WorkspaceChainSourceCompositionHUD

struct WorkspaceChainSourceCompositionHUD: Equatable, Sendable {
  let display: DisplayName
  let role: WorkspaceChainHUDRole
  let hostName: String
  let hostSymbolIconName: String?
  let returnedBorrowNames: [String]
  let prioritySkippedWorkspaceName: String?
  /// When the composition host itself moved elsewhere, the source panel is a
  /// vacated-display result rather than a host-local return.
  let movedWorkspaceDestination: DisplayName?
}

// MARK: - WorkspaceChainVacatedHUD

struct WorkspaceChainVacatedHUD: Equatable, Sendable {
  let display: DisplayName
  let returnedBorrowNames: [String]
}

// MARK: - WorkspaceChainVisibilityCleanup

public struct WorkspaceChainVisibilityCleanup: Equatable, Sendable {
  let display: DisplayName
  let bundleIDs: Set<String>
}

// MARK: - WorkspaceChainCleanupReply

/// A one-shot acknowledgement that lets the activation effect retain
/// ownership of its tail while reducer actions validate and commit one
/// display-scoped cleanup step.
public struct WorkspaceChainCleanupReply: Equatable, Sendable {

  // MARK: Lifecycle

  init(
    id: UUID = UUID(),
    complete: @escaping @Sendable (Bool) -> Void,
  ) {
    self.id = id
    completion = Completion(complete)
  }

  // MARK: Public

  public static func ==(lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id
  }

  // MARK: Internal

  let id: UUID

  var wasCommitAccepted: Bool {
    completion.wasCommitAccepted
  }

  func acceptCommit() {
    completion.acceptCommit()
  }

  func complete(_ result: Bool) {
    completion.call(result)
  }

  // MARK: Private

  private final class Completion: @unchecked Sendable {

    // MARK: Lifecycle

    init(_ body: @escaping @Sendable (Bool) -> Void) {
      self.body = body
    }

    // MARK: Internal

    var wasCommitAccepted: Bool {
      lock.lock()
      defer { lock.unlock() }
      return isCommitAccepted
    }

    func acceptCommit() {
      lock.lock()
      isCommitAccepted = true
      lock.unlock()
    }

    func call(_ result: Bool) {
      lock.lock()
      guard !isCompleted else {
        lock.unlock()
        return
      }
      isCompleted = true
      lock.unlock()
      body(result)
    }

    // MARK: Private

    private let body: @Sendable (Bool) -> Void
    private var isCompleted = false
    private var isCommitAccepted = false
    private let lock = NSLock()

  }

  private let completion: Completion

}

// MARK: - WorkspaceChainCleanupTransaction

public struct WorkspaceChainCleanupTransaction: Equatable, Sendable {
  let skippedWorkspaceIDs: Set<Workspace.ID>
  let retainedWorkspaceIDs: Set<Workspace.ID>
  let placements: [WorkspaceChainPlacement]
  let sourcePlacements: [WorkspaceChainPlacement]
  let sourceSnapshots: [WorkspaceChainCleanupSourceSnapshot]
  let requiresFocusSuccessor: Bool
  let cleanupHUDRequests: [ActionHUDRequest]
}

// MARK: - WorkspaceChainPlacement

struct WorkspaceChainPlacement: Equatable, Sendable {
  let display: DisplayName
  let workspace: Workspace.ID
}

// MARK: - WorkspaceChainCleanupSourceSnapshot

struct WorkspaceChainCleanupSourceSnapshot: Equatable, Sendable {
  let display: DisplayName
  let activeWorkspace: Workspace.ID?
  let composition: Composition?
  let borrowGeneration: UInt64
}

// MARK: - WorkspaceChainFocusTransfer

struct WorkspaceChainFocusTransfer: Equatable, Sendable {
  let from: DisplayName
  let to: DisplayName
  let workspaceName: String
}

extension WorkspaceActivationFeature {

  // MARK: Internal

  /// Map persisted fullscreen-zoom slots back onto live windows via the same
  /// windowID-rank assignment `hydrate` uses (`slotToKey` over `keys`), so a
  /// specific same-app window resolves to the exact slot it was zoomed in — not
  /// just "some window of that app". Slots whose window isn't in the laid-out
  /// tree are dropped, so the layout degrades gracefully when an app has fewer
  /// windows than at save time.
  static func resolveFullscreenZoom(
    slots: [SlotID],
    keys: [WindowKey],
    among windows: [WindowKey],
  ) -> Set<WindowKey> {
    let keyForSlot = slotToKey(keys)
    let present = Set(windows)
    return Set(slots.compactMap { keyForSlot[$0] }.filter { present.contains($0) })
  }

  /// Pick the workspace to put on `display`, or nil to leave it be. Pure.
  ///
  /// - `reconnect` (a monitor just plugged in):
  ///     1. the last workspace shown here, if it's pinned here, or it's dynamic
  ///        and not currently in use on another display;
  ///     2. else the first workspace statically pinned to this display;
  ///     3. else a dynamic workspace (or one whose pinned display is absent)
  ///        not in use on another display — the most recently used one
  ///        (`workspaceMRU`), falling back to the first.
  /// - vacated (a dynamic workspace just left this display): walk the display's
  ///   MRU history newest→oldest and take the first workspace that belongs here
  ///   (dynamic, or pinned to this display) and isn't already in use elsewhere —
  ///   so the monitor falls back to what the user last had on it.
  static func chooseWorkspaceForDisplay(
    _ display: DisplayName,
    reconnect: Bool,
    byId: [Workspace.ID: Workspace],
    workspaces: [Workspace],
    assigned: [DisplayName: Workspace.ID],
    history: [DisplayName: [Workspace.ID]],
    workspaceMRU: [Workspace.ID] = [],
    connected: Set<DisplayName> = [],
  ) -> Workspace.ID? {
    func pinned(_ id: Workspace.ID) -> Bool {
      byId[id]?.displayHint?.matches(display) ?? false
    }
    func isDynamic(_ id: Workspace.ID) -> Bool {
      byId[id]?.isDynamic ?? false
    }
    /// A workspace pinned to a display that isn't currently connected has no home
    /// to return to — treat it like a free dynamic so it stays where the user
    /// last put it, rather than being evicted for the display's first pinned one.
    func homelessPin(_ id: Workspace.ID) -> Bool {
      guard let hint = byId[id]?.displayHint else { return false }
      return !connected.contains { hint.matches($0) }
    }
    func elsewhere(_ id: Workspace.ID) -> Bool {
      assigned.contains { $0.key != display && $0.value == id }
    }
    if reconnect {
      // 1. last shown here — pinned here, or a free / homeless-pinned dynamic.
      if
        let last = (history[display] ?? []).first(where: { byId[$0] != nil }),
        pinned(last) || ((isDynamic(last) || homelessPin(last)) && !elsewhere(last))
      {
        return last
      }
      // 2. first pinned to this display.
      if
        let firstPinned = workspaces.first(where: {
          $0.kind != .scratchpad && ($0.displayHint?.matches(display) ?? false)
        })
      {
        return firstPinned.id
      }
      // 3. a free dynamic: most-recently-used, else the first.
      if
        let recentDynamic = workspaceMRU.first(where: {
          byId[$0] != nil
            && (isDynamic($0) || homelessPin($0))
            && !elsewhere($0)
        })
      {
        return recentDynamic
      }
      return workspaces.first {
        $0.kind != .scratchpad
          && ($0.isDynamic || homelessPin($0.id))
          && !elsewhere($0.id)
      }?.id
    }
    // Deliberately stricter than the reconnect branch: only a workspace
    // pinned to *this* display, or a dynamic one nobody else is using, may
    // take over. A homeless pin (pinned to a disconnected display) is not
    // dragged here — it belongs somewhere else and summoning it would open
    // its apps on a monitor the user never assigned it to. When nothing
    // qualifies the display is left empty, which is the intended outcome.
    return (history[display] ?? []).first {
      byId[$0] != nil && !elsewhere($0) && (isDynamic($0) || pinned($0))
    }
  }

  static func planDisplayRestore(
    connected: [DisplayName],
    newlyConnected: Set<DisplayName>,
    workspaces: [Workspace],
    active: [DisplayName: Workspace.ID],
    history: [DisplayName: [Workspace.ID]],
    workspaceMRU: [Workspace.ID] = [],
  ) -> [DisplayAssignment] {
    var byId = [Workspace.ID: Workspace]()
    for w in workspaces where w.kind != .scratchpad { byId[w.id] = w }

    // Live simulation of which workspace sits on each display as the plan grows.
    var assigned = active
    var visited = Set<DisplayName>()

    func displayShowing(_ id: Workspace.ID) -> DisplayName? {
      assigned.first { $0.value == id }?.key
    }
    func pinned(_ id: Workspace.ID, to display: DisplayName) -> Bool {
      byId[id]?.displayHint?.matches(display) ?? false
    }

    func fill(_ display: DisplayName, reconnect: Bool) {
      guard visited.insert(display).inserted else { return }
      guard
        let target = chooseWorkspaceForDisplay(
          display,
          reconnect: reconnect,
          byId: byId,
          workspaces: workspaces,
          assigned: assigned,
          history: history,
          workspaceMRU: workspaceMRU,
          connected: Set(connected),
        ), byId[target] != nil
      else { return }
      if let other = displayShowing(target), other != display {
        // Already up on another display — only pull it over if it's pinned here.
        guard pinned(target, to: display) else { return }
        assigned[other] = nil
        assigned[display] = target
        fill(other, reconnect: false)
      } else {
        assigned[display] = target
      }
    }

    for display in connected where newlyConnected.contains(display) {
      fill(display, reconnect: true)
    }
    // Re-assert every connected display's (possibly reclaimed/filled) workspace.
    return connected.compactMap { display in
      assigned[display].map { DisplayAssignment(display: display, workspace: $0) }
    }
  }

  /// Resolve active placement without letting a stale name-only alias override
  /// an exact live display key. A name fallback is safe only when that name does
  /// not describe multiple connected UUID displays.
  static func activeWorkspace(
    on display: DisplayName,
    connected: [DisplayName],
    active: [DisplayName: Workspace.ID],
  ) -> Workspace.ID? {
    if let exact = active[display] { return exact }
    let connectedUUIDsWithSameName = Set(connected.compactMap { candidate in
      candidate.name == display.name ? candidate.uuid : nil
    })
    guard connectedUUIDsWithSameName.count <= 1 else { return nil }
    return active.first { key, _ in key.matches(display) }?.value
  }

  /// Build one symmetric workspace-chain switch for the displays available now.
  /// The user-selected trigger is mandatory and claims its ordinary target.
  /// Remaining members are considered strictly in stored order: a pinned member
  /// claims its configured target only while that display is connected and free.
  /// An ordinarily dynamic member, or a pinned member explicitly made dynamic
  /// for this chain, claims the pointer-preferred display when free and otherwise
  /// the first remaining connected display. Members that do not fit are skipped
  /// without preventing lower-priority members from being considered.
  ///
  /// Displays vacated by chain members reuse the ordinary reconnect fallback.
  /// The trigger is returned last so it owns final keyboard focus after every
  /// companion restore settles.
  static func planWorkspaceChain(
    _ chain: WorkspaceChain,
    triggeredBy trigger: DisplayAssignment,
    dynamicPreferredDisplay: DisplayName?,
    connected: [DisplayName],
    primaryDisplay: DisplayName?,
    workspaces: [Workspace],
    active: [DisplayName: Workspace.ID],
    history: [DisplayName: [Workspace.ID]],
    workspaceMRU: [Workspace.ID] = [],
  ) -> Result<WorkspaceChainPlan, WorkspaceChainPlanningFailure> {
    let normalWorkspaces = workspaces.filter { $0.kind != .scratchpad }
    var byID = [Workspace.ID: Workspace]()
    for workspace in normalWorkspaces { byID[workspace.id] = workspace }

    guard chain.workspaceIDs.count >= 2 else { return .failure(.tooFewWorkspaces) }
    guard chain.workspaceIDs.contains(trigger.workspace) else {
      return .failure(.triggerNotInChain(trigger.workspace))
    }

    var seenWorkspaceIDs = Set<Workspace.ID>()
    for workspaceID in chain.workspaceIDs {
      guard seenWorkspaceIDs.insert(workspaceID).inserted else {
        return .failure(.duplicateWorkspace(workspaceID))
      }
      guard byID[workspaceID] != nil else {
        return .failure(.invalidWorkspace(workspaceID))
      }
    }

    /// Mirror `DisplayClient.connected`: stable UUID first, then the display
    /// name fallback used by hand-edited and pre-UUID configs.
    func connectedDisplay(for reference: DisplayName) -> DisplayName? {
      if let uuid = reference.uuid {
        return connected.first { $0.uuid == uuid }
      }
      return connected.first { $0.name == reference.name }
    }

    guard let triggerWorkspace = byID[trigger.workspace] else {
      return .failure(.invalidWorkspace(trigger.workspace))
    }
    let resolvedPrimary = primaryDisplay.flatMap(connectedDisplay(for:)) ?? connected.first
    let triggerDisplay: DisplayName? =
      if let hint = triggerWorkspace.displayHint {
        connectedDisplay(for: hint) ?? resolvedPrimary
      } else {
        connectedDisplay(for: trigger.display)
          ?? dynamicPreferredDisplay.flatMap(connectedDisplay(for:))
      }
    guard let triggerDisplay else {
      return .failure(.triggerDisplayUnavailable(trigger.display))
    }

    var displayByWorkspace = [trigger.workspace: triggerDisplay]
    var availableDisplays = connected.filter { !$0.matches(triggerDisplay) }
    let preferredDynamicDisplay = dynamicPreferredDisplay.flatMap(connectedDisplay(for:))

    for workspaceID in chain.workspaceIDs where workspaceID != trigger.workspace {
      guard let workspace = byID[workspaceID], !availableDisplays.isEmpty else { continue }

      if chain.isDynamicInChain(workspace) {
        let index = preferredDynamicDisplay.flatMap { preferred in
          availableDisplays.firstIndex(where: { $0.matches(preferred) })
        } ?? availableDisplays.startIndex
        displayByWorkspace[workspaceID] = availableDisplays.remove(at: index)
      } else if let hint = workspace.displayHint {
        guard
          let target = connectedDisplay(for: hint),
          let index = availableDisplays.firstIndex(where: { $0.matches(target) })
        else { continue }
        displayByWorkspace[workspaceID] = availableDisplays.remove(at: index)
      }
    }

    let explicit = chain.workspaceIDs.compactMap { workspaceID in
      displayByWorkspace[workspaceID].map {
        DisplayAssignment(display: $0, workspace: workspaceID)
      }
    }
    // Canonicalize live state onto the connected display identities while
    // retaining the one-workspace/one-display invariant even if stale state
    // momentarily contains a duplicate.
    var assigned = [DisplayName: Workspace.ID]()
    var alreadyAssigned = Set<Workspace.ID>()
    for display in connected {
      guard
        let workspace = activeWorkspace(
          on: display,
          connected: connected,
          active: active,
        ),
        byID[workspace] != nil,
        alreadyAssigned.insert(workspace).inserted
      else { continue }
      assigned[display] = workspace
    }

    let chainWorkspaceIDs = Set(chain.workspaceIDs)
    for display in connected
      where assigned[display].map(chainWorkspaceIDs.contains) == true
    {
      assigned[display] = nil
    }
    for assignment in explicit {
      assigned[assignment.display] = assignment.workspace
    }

    let emptyDisplays = Set(connected.filter { assigned[$0] == nil })
    let finalAssignments = planDisplayRestore(
      connected: connected,
      newlyConnected: emptyDisplays,
      // Even members skipped by this priority pass must not survive on an old
      // display or be selected again by fallback. Only the chosen subset is
      // allowed to remain visible after this switch.
      workspaces: normalWorkspaces.filter { !chainWorkspaceIDs.contains($0.id) },
      active: assigned,
      history: history,
      workspaceMRU: workspaceMRU,
    )

    // Restoring a display that already has its desired workspace would
    // needlessly tear down Borrow and re-tile it. Only the trigger is kept even
    // when unchanged; the reducer turns that final entry into a focus transfer.
    var changes = finalAssignments.filter { assignment in
      guard assignment.workspace != trigger.workspace else { return false }
      return activeWorkspace(
        on: assignment.display,
        connected: connected,
        active: active,
      ) != assignment.workspace
    }
    guard
      let finalTrigger = finalAssignments.first(where: {
        $0.workspace == trigger.workspace
      })
    else { return .failure(.invalidWorkspace(trigger.workspace)) }
    changes.append(finalTrigger)
    return .success(WorkspaceChainPlan(
      assignments: changes,
      selectedWorkspaceIDs: Set(explicit.map(\.workspace)),
    ))
  }

  /// Lay the tree out, trimming fullscreen-zoomed windows so the rest
  /// of the tree shapes around as if they weren't present. Parent-zoom
  /// is handled inside `tree.frames(...)` directly.
  @MainActor
  static func computeFrames(
    tree: BSPNode<WindowKey>?,
    settings: AppSettings,
    targetDisplay: DisplayName?,
    fullscreenZoomed: Set<WindowKey> = [],
    targetRect: CGRect? = nil,
  ) -> [WindowKey: CGRect] {
    guard let tree else { return [:] }
    // `targetRect` (a composition sub-rect) is already inset; only the
    // full-display path applies the outer gap.
    let workArea = targetRect ?? ScreenGeometry.workArea(for: targetDisplay).insetBy(
      dx: CGFloat(settings.layout.gapOuter),
      dy: CGFloat(settings.layout.gapOuter),
    )
    let gap = CGFloat(settings.layout.gapInner)
    let activeZoom = fullscreenZoomed.intersection(Set(tree.windows))
    if !activeZoom.isEmpty {
      let trimmed = tree.removingAll(activeZoom)
      var frames = trimmed?.frames(in: workArea, gap: gap) ?? [:]
      for key in activeZoom { frames[key] = workArea }
      return frames
    }
    return tree.frames(in: workArea, gap: gap)
  }

  /// Split a work area into (host, borrowed) sub-rects for a borrow docked
  /// to `edge`; the borrowed block sits on that edge with `fraction` share.
  static func subRects(
    workArea: CGRect,
    edge: BorrowEdge,
    fraction: CGFloat,
    gap: CGFloat,
  ) -> (host: CGRect, borrowed: CGRect) {
    let axis: BSPNode<WindowKey>.SplitAxis =
      (edge == .left || edge == .right) ? .vertical : .horizontal
    switch edge {
    case .left,
         .top:
      let (b, h) = axis.subdivide(workArea, ratio: fraction, gap: gap)
      return (host: h, borrowed: b)

    case .right,
         .bottom:
      let (h, b) = axis.subdivide(workArea, ratio: 1 - fraction, gap: gap)
      return (host: h, borrowed: b)
    }
  }

  /// SF Symbol for a borrow docked to `edge` — a filled half-rectangle on the
  /// side the borrowed block sits.
  static func borrowEdgeIcon(_ edge: BorrowEdge) -> String {
    switch edge {
    case .left: "rectangle.lefthalf.inset.filled"
    case .right: "rectangle.righthalf.inset.filled"
    case .top: "rectangle.tophalf.inset.filled"
    case .bottom: "rectangle.bottomhalf.inset.filled"
    }
  }

  /// Keep the caller's effect alive until every physical return, state commit,
  /// layout and deferred HUD has completed. Each step is acknowledged by the
  /// reducer so a canceled or stale transaction cannot enqueue later displays.
  static func runWorkspaceChainCleanup(
    transaction: WorkspaceChainCleanupTransaction,
    cleanups: [WorkspaceChainVisibilityCleanup],
    send: Send<Action>,
  ) async -> Bool {
    for cleanup in orderedWorkspaceChainCleanups(cleanups) {
      guard !Task.isCancelled else { return false }
      let channel = AsyncStream<Bool>.makeStream(
        bufferingPolicy: .bufferingNewest(1)
      )
      let reply = WorkspaceChainCleanupReply { result in
        channel.continuation.yield(result)
        channel.continuation.finish()
      }
      await send(.processWorkspaceChainCleanupStep(
        transaction,
        cleanup: cleanup,
        reply: reply,
      ))
      var iterator = channel.stream.makeAsyncIterator()
      guard await iterator.next() == true else { return false }
    }
    return true
  }

  /// Coalesce only exact display identities and guarantee one transaction step
  /// per physical display. A legacy name-only alias is deliberately not merged
  /// with UUID identities because two identical-model monitors can both match
  /// that non-transitive alias. Physical hides run before state-only commits.
  static func orderedWorkspaceChainCleanups(
    _ cleanups: [WorkspaceChainVisibilityCleanup]
  ) -> [WorkspaceChainVisibilityCleanup] {
    var coalesced = [WorkspaceChainVisibilityCleanup]()
    for cleanup in cleanups.sorted(by: {
      ($0.display.name, $0.display.uuid ?? "")
        < ($1.display.name, $1.display.uuid ?? "")
    }) {
      if
        let index = coalesced.firstIndex(where: {
          $0.display == cleanup.display
        })
      {
        coalesced[index] = WorkspaceChainVisibilityCleanup(
          display: coalesced[index].display,
          bundleIDs: coalesced[index].bundleIDs.union(cleanup.bundleIDs),
        )
      } else {
        coalesced.append(cleanup)
      }
    }
    return coalesced.sorted { lhs, rhs in
      if lhs.bundleIDs.isEmpty != rhs.bundleIDs.isEmpty {
        return !lhs.bundleIDs.isEmpty
      }
      return (lhs.display.name, lhs.display.uuid ?? "")
        < (rhs.display.name, rhs.display.uuid ?? "")
    }
  }

  /// Attach display-specific HUD provenance only when this direct chain plan
  /// changes workspace placement. Every changed destination presents the
  /// workspace that landed there; a source left empty presents where its
  /// workspace moved. The selected final assignment is annotated too, so its
  /// ordinary focus feedback identifies the same transaction.
  func workspaceChainHUDAssignments(
    chain: WorkspaceChain,
    assignments: [DisplayAssignment],
    selectedWorkspaceIDs: Set<Workspace.ID>,
    skippedWorkspaceIDs: Set<Workspace.ID> = [],
    cleanupWorkspaceIDs: Set<Workspace.ID>? = nil,
    profileSwitch: WorkspaceChainProfileSwitchHUD? = nil,
    focusSourceDisplay: DisplayName? = nil,
    connected: [DisplayName],
    state: State,
  ) -> [DisplayAssignment] {
    let cleanupWorkspaceIDs = cleanupWorkspaceIDs ?? skippedWorkspaceIDs
    let changesDisplayState = assignments.contains { assignment in
      Self.activeWorkspace(
        on: assignment.display,
        connected: connected,
        active: state.activeWorkspacesByDisplay,
      ) != assignment.workspace
    }
    let hasSkippedVisibleMember = state.activeWorkspacesByDisplay.values.contains {
      cleanupWorkspaceIDs.contains($0)
    } || state.compositionsByDisplay.values.contains { composition in
      cleanupWorkspaceIDs.contains(composition.host)
        || composition.borrowed.contains { cleanupWorkspaceIDs.contains($0.workspace) }
    }
    let capturedFocusSource = focusSourceDisplay ?? state.focusedDisplay
    let changesFocusDisplay = capturedFocusSource.flatMap { sourceDisplay in
      assignments.last.map { !sourceDisplay.matches($0.display) }
    } ?? false
    let hasCapturedFocusSource = focusSourceDisplay != nil
    guard
      changesDisplayState
      || hasSkippedVisibleMember
      || changesFocusDisplay
      || hasCapturedFocusSource
    else {
      return assignments
    }
    let trimmedName = chain.name?.trimmingCharacters(in: .whitespacesAndNewlines)
    let name =
      if let trimmedName, !trimmedName.isEmpty {
        trimmedName
      } else {
        String(localized: "Workspace Chain")
      }
    let destinationDisplays = assignments.map(\.display)
    var vacatedDisplaysByWorkspace = [Workspace.ID: [DisplayName]]()
    for (sourceDisplay, activeWorkspaceID) in state.activeWorkspacesByDisplay {
      guard
        connected.contains(where: { $0.matches(sourceDisplay) }),
        let destination = assignments.first(where: {
          $0.workspace == activeWorkspaceID
        })?.display,
        !destination.matches(sourceDisplay),
        !destinationDisplays.contains(where: { $0.matches(sourceDisplay) })
      else { continue }
      vacatedDisplaysByWorkspace[activeWorkspaceID, default: []].append(sourceDisplay)
    }

    // Snapshot every composition the chain will dismantle before the serial
    // restore queue mutates state. The assignment that ultimately owns the
    // source display carries its return facts; if the host stays put, the first
    // member moving away owns a separate source-display HUD instead.
    var returnedBorrowNamesByAssignment = [Int: [String]]()
    var sourceCompositionHUDsByAssignment = [Int: [WorkspaceChainSourceCompositionHUD]]()
    var deferredCleanupHUDs = [WorkspaceChainSourceCompositionHUD]()
    // A host moving off its source display leaves a borrowed block there until
    // the display-scoped return commits. Do not emit the usual vacated-display
    // result early: it would describe a return that a cancellation can still
    // prevent.
    var deferredVacatedDisplays = [DisplayName]()
    var coveredDisplays = destinationDisplays
    for display in vacatedDisplaysByWorkspace.values.joined() where !coveredDisplays.contains(
      where: { $0.matches(display) }
    ) {
      coveredDisplays.append(display)
    }
    if state.config.activeProfile != nil {
      /// Profile activation changes `activeProfile` before this presentation is
      /// planned, while the live composition still contains workspace IDs from
      /// the outgoing profile. Resolve names across the complete config so its
      /// return facts are not silently dropped.
      func workspaceForID(_ id: Workspace.ID) -> Workspace? {
        state.config.profiles.lazy.compactMap { $0.workspaces[id: id] }.first
      }

      func appendReturnedBorrowNames(_ names: [String], to assignmentIndex: Int) {
        var existing = returnedBorrowNamesByAssignment[assignmentIndex] ?? []
        for name in names where !existing.contains(name) { existing.append(name) }
        returnedBorrowNamesByAssignment[assignmentIndex] = existing
      }

      func appendSourceHUD(
        display: DisplayName,
        role: WorkspaceChainHUDRole,
        workspace: Workspace,
        returnedBorrowNames: [String],
        prioritySkippedWorkspaceName: String? = nil,
        to assignmentIndex: Int,
      ) {
        var existing = sourceCompositionHUDsByAssignment[assignmentIndex] ?? []
        if let index = existing.firstIndex(where: { $0.display.matches(display) }) {
          let mergedNames = Array(OrderedSet(
            existing[index].returnedBorrowNames + returnedBorrowNames
          ))
          existing[index] = WorkspaceChainSourceCompositionHUD(
            display: display,
            role: existing[index].role == .chainMember || role == .chainMember
              ? .chainMember
              : .nonChain,
            hostName: existing[index].hostName,
            hostSymbolIconName: existing[index].hostSymbolIconName,
            returnedBorrowNames: mergedNames,
            prioritySkippedWorkspaceName: existing[index].prioritySkippedWorkspaceName
              ?? prioritySkippedWorkspaceName,
            movedWorkspaceDestination: existing[index].movedWorkspaceDestination,
          )
        } else {
          existing.append(WorkspaceChainSourceCompositionHUD(
            display: display,
            role: role,
            hostName: workspace.name,
            hostSymbolIconName: workspace.symbolIconName,
            returnedBorrowNames: returnedBorrowNames,
            prioritySkippedWorkspaceName: prioritySkippedWorkspaceName,
            movedWorkspaceDestination: nil,
          ))
        }
        sourceCompositionHUDsByAssignment[assignmentIndex] = existing
        if !coveredDisplays.contains(where: { $0.matches(display) }) {
          coveredDisplays.append(display)
        }
      }

      func appendDeferredCleanupHUD(
        display: DisplayName,
        role: WorkspaceChainHUDRole,
        workspace: Workspace,
        returnedBorrowNames: [String],
        prioritySkippedWorkspaceName: String? = nil,
        movedWorkspaceDestination: DisplayName? = nil,
      ) {
        if
          let index = deferredCleanupHUDs.firstIndex(where: {
            $0.display.matches(display)
          })
        {
          let mergedNames = Array(OrderedSet(
            deferredCleanupHUDs[index].returnedBorrowNames + returnedBorrowNames
          ))
          deferredCleanupHUDs[index] = WorkspaceChainSourceCompositionHUD(
            display: display,
            role: deferredCleanupHUDs[index].role == .chainMember || role == .chainMember
              ? .chainMember
              : .nonChain,
            hostName: deferredCleanupHUDs[index].hostName,
            hostSymbolIconName: deferredCleanupHUDs[index].hostSymbolIconName,
            returnedBorrowNames: mergedNames,
            prioritySkippedWorkspaceName:
            deferredCleanupHUDs[index].prioritySkippedWorkspaceName
              ?? prioritySkippedWorkspaceName,
            movedWorkspaceDestination:
            deferredCleanupHUDs[index].movedWorkspaceDestination
              ?? movedWorkspaceDestination,
          )
        } else {
          deferredCleanupHUDs.append(WorkspaceChainSourceCompositionHUD(
            display: display,
            role: role,
            hostName: workspace.name,
            hostSymbolIconName: workspace.symbolIconName,
            returnedBorrowNames: returnedBorrowNames,
            prioritySkippedWorkspaceName: prioritySkippedWorkspaceName,
            movedWorkspaceDestination: movedWorkspaceDestination,
          ))
        }
        if !coveredDisplays.contains(where: { $0.matches(display) }) {
          coveredDisplays.append(display)
        }
      }

      let compositions = state.compositionsByDisplay.sorted {
        ($0.key.name, $0.key.uuid ?? "") < ($1.key.name, $1.key.uuid ?? "")
      }
      for (sourceDisplay, composition) in compositions {
        guard connected.contains(where: { $0.matches(sourceDisplay) }) else { continue }
        let destinationIndex = assignments.firstIndex {
          $0.display.matches(sourceDisplay)
        }
        let movingMemberIndices = assignments.indices.filter { index in
          let assignment = assignments[index]
          guard !assignment.display.matches(sourceDisplay) else { return false }
          return assignment.workspace == composition.host
            || composition.borrowed.contains(where: {
              $0.workspace == assignment.workspace
            })
        }
        let destinationReplacesHost = destinationIndex.map {
          assignments[$0].workspace != composition.host
        } ?? false

        // Capacity/pin priority can deliberately omit a member that is still
        // visible inside an otherwise unchanged composition. That return is a
        // real part of this switch even though the omitted member has no
        // destination assignment of its own.
        let skippedBorrowNames = composition.borrowed.compactMap { slot in
          cleanupWorkspaceIDs.contains(slot.workspace)
            ? workspaceForID(slot.workspace)?.name
            : nil
        }
        let removesSkippedChainBorrow = composition.borrowed.contains {
          skippedWorkspaceIDs.contains($0.workspace)
        }
        if
          !destinationReplacesHost,
          movingMemberIndices.isEmpty,
          !skippedBorrowNames.isEmpty
        {
          if let host = workspaceForID(composition.host) {
            appendDeferredCleanupHUD(
              display: sourceDisplay,
              role: removesSkippedChainBorrow ? .chainMember : .nonChain,
              workspace: host,
              returnedBorrowNames: skippedBorrowNames,
            )
          }
        }
        if
          cleanupWorkspaceIDs.contains(composition.host),
          destinationIndex == nil,
          let host = workspaceForID(composition.host)
        {
          let returnedNames = composition.borrowed.compactMap {
            workspaceForID($0.workspace)?.name
          }
          appendDeferredCleanupHUD(
            display: sourceDisplay,
            role: skippedWorkspaceIDs.contains(composition.host)
              ? .chainMember
              : .nonChain,
            workspace: host,
            returnedBorrowNames: returnedNames,
            prioritySkippedWorkspaceName: skippedWorkspaceIDs.contains(composition.host)
              ? host.name
              : nil,
          )
        }
        guard destinationReplacesHost || !movingMemberIndices.isEmpty else { continue }

        // Promoting a borrowed member on this same display is not a return for
        // that member. Every other borrowed block disappears with the source
        // composition and must remain visible in HUD metadata.
        let promotedWorkspaceID = destinationIndex.flatMap { index -> Workspace.ID? in
          let workspaceID = assignments[index].workspace
          return composition.borrowed.contains(where: { $0.workspace == workspaceID })
            ? workspaceID
            : nil
        }
        let returnedBorrowNames = composition.borrowed.compactMap { slot -> String? in
          guard slot.workspace != promotedWorkspaceID else { return nil }
          return workspaceForID(slot.workspace)?.name
        }
        guard !returnedBorrowNames.isEmpty else { continue }

        if let destinationIndex {
          appendReturnedBorrowNames(returnedBorrowNames, to: destinationIndex)
        } else if
          movingMemberIndices.contains(where: {
            assignments[$0].workspace == composition.host
          }),
          vacatedDisplaysByWorkspace[composition.host]?.contains(where: {
            $0.matches(sourceDisplay)
          }) == true,
          let host = workspaceForID(composition.host)
        {
          appendDeferredCleanupHUD(
            display: sourceDisplay,
            role: assignments.first(where: {
              $0.workspace == composition.host
            }).map {
              selectedWorkspaceIDs.contains($0.workspace)
                ? .chainMember
                : .nonChain
            } ?? .nonChain,
            workspace: host,
            returnedBorrowNames: returnedBorrowNames,
            movedWorkspaceDestination: assignments.first(where: {
              $0.workspace == composition.host
            })?.display,
          )
          if !deferredVacatedDisplays.contains(where: { $0.matches(sourceDisplay) }) {
            deferredVacatedDisplays.append(sourceDisplay)
          }
        } else if
          let ownerIndex = movingMemberIndices.first,
          let host = workspaceForID(composition.host)
        {
          appendSourceHUD(
            display: sourceDisplay,
            role: selectedWorkspaceIDs.contains(assignments[ownerIndex].workspace)
              ? .chainMember
              : .nonChain,
            workspace: host,
            returnedBorrowNames: returnedBorrowNames,
            to: ownerIndex,
          )
        }
      }

      // A skipped standalone host on a display with no replacement has no
      // destination assignment from which to announce its removal. Attach that
      // source-display result to the first queued assignment.
      for (sourceDisplay, workspaceID) in state.activeWorkspacesByDisplay
        where cleanupWorkspaceIDs.contains(workspaceID)
      {
        guard
          connected.contains(where: { $0.matches(sourceDisplay) }),
          !destinationDisplays.contains(where: { $0.matches(sourceDisplay) }),
          let workspace = workspaceForID(workspaceID)
        else { continue }
        appendDeferredCleanupHUD(
          display: sourceDisplay,
          role: skippedWorkspaceIDs.contains(workspaceID)
            ? .chainMember
            : .nonChain,
          workspace: workspace,
          returnedBorrowNames: [],
          prioritySkippedWorkspaceName: skippedWorkspaceIDs.contains(workspaceID)
            ? workspace.name
            : nil,
        )
      }
    }
    let focusTransfer: WorkspaceChainFocusTransfer? = {
      guard
        let sourceDisplay = capturedFocusSource,
        let destination = assignments.last,
        !sourceDisplay.matches(destination.display),
        let destinationWorkspace = state.config.activeProfile?
          .workspaces[id: destination.workspace]
      else { return nil }
      return WorkspaceChainFocusTransfer(
        from: sourceDisplay,
        to: destination.display,
        workspaceName: destinationWorkspace.name,
      )
    }()
    return assignments.enumerated().map { index, assignment in
      var assignment = assignment
      assignment.presentation = .workspaceChain(WorkspaceChainHUDContext(
        name: name,
        role: selectedWorkspaceIDs.contains(assignment.workspace)
          ? .chainMember
          : .nonChain,
        profileSwitch: profileSwitch,
        coveredDisplays: coveredDisplays,
        focusTransfer: focusTransfer,
        destinationReturnedBorrowNames: returnedBorrowNamesByAssignment[index] ?? [],
        sourceCompositionHUDs: sourceCompositionHUDsByAssignment[index] ?? [],
        deferredCleanupHUDs: index == assignments.indices.last
          ? deferredCleanupHUDs
          : [],
        vacatedHUDs: (vacatedDisplaysByWorkspace[assignment.workspace] ?? []).compactMap { display in
          guard !deferredVacatedDisplays.contains(where: { $0.matches(display) }) else {
            return nil
          }
          return WorkspaceChainVacatedHUD(
            display: display,
            returnedBorrowNames: [],
          )
        },
        cleanupTransaction: nil,
      ))
      return assignment
    }
  }

  /// Resolve the display-scoped process hides for a priority cleanup without
  /// mutating reducer state. The final trigger establishes focus first; only a
  /// completed hide is allowed to commit the corresponding state transition.
  func workspaceChainVisibilityCleanups(
    _ transaction: WorkspaceChainCleanupTransaction,
    state: State,
  ) -> [WorkspaceChainVisibilityCleanup] {
    guard let profile = state.config.activeProfile else { return [] }
    let assignedWorkspaceIDs = Set(transaction.placements.map(\.workspace))
    let sharedBundleIDs = Set(state.config.sharedApps.map(\.bundleIdentifier))
    var bundleIDsByDisplay = [DisplayName: Set<String>]()

    func destination(on display: DisplayName) -> WorkspaceChainPlacement? {
      transaction.placements.first { $0.display.matches(display) }
    }

    /// A composition host that is being placed on a different display leaves
    /// its borrowed block behind. That block is not an ordinary "skipped"
    /// member, but it still has to be physically returned before the source
    /// composition can be removed from reducer state.
    func hostMovesAway(_ composition: Composition, from display: DisplayName) -> Bool {
      transaction.placements.contains {
        $0.workspace == composition.host && !$0.display.matches(display)
      }
    }

    func addBundles(for workspaceID: Workspace.ID, on display: DisplayName) {
      guard !assignedWorkspaceIDs.contains(workspaceID) else { return }
      let registered = state.config.profiles.lazy.compactMap {
        $0.workspaces[id: workspaceID]
      }.first?.apps.map(\.bundleIdentifier) ?? []
      let resident = state.tilingTrees[workspaceID]?.windows
        .map(\.bundleId)
        .filter(state.managedBundleIds.contains) ?? []
      bundleIDsByDisplay[display, default: []].formUnion(registered + resident)
    }

    for (display, composition) in state.compositionsByDisplay {
      let target = destination(on: display)
      if hostMovesAway(composition, from: display) {
        // The host itself is becoming visible on its destination. Only return
        // the borrowed block from this source display.
        for slot in composition.borrowed {
          let registered = state.config.profiles.lazy.compactMap {
            $0.workspaces[id: slot.workspace]
          }.first?.apps.map(\.bundleIdentifier) ?? []
          let resident = state.tilingTrees[slot.workspace]?.windows
            .map(\.bundleId)
            .filter(state.managedBundleIds.contains) ?? []
          bundleIDsByDisplay[display, default: []].formUnion(registered + resident)
        }
        continue
      }
      if transaction.skippedWorkspaceIDs.contains(composition.host) {
        guard target == nil else { continue }
        addBundles(for: composition.host, on: display)
        for slot in composition.borrowed {
          addBundles(for: slot.workspace, on: display)
        }
        continue
      }
      guard target?.workspace == composition.host || target == nil else { continue }
      for slot in composition.borrowed
        where transaction.skippedWorkspaceIDs.contains(slot.workspace)
      {
        addBundles(for: slot.workspace, on: display)
      }
    }
    for (display, workspaceID) in state.activeWorkspacesByDisplay
      where transaction.skippedWorkspaceIDs.contains(workspaceID)
      && destination(on: display) == nil
    {
      addBundles(for: workspaceID, on: display)
    }
    for source in transaction.sourcePlacements
      where transaction.skippedWorkspaceIDs.contains(source.workspace)
      && destination(on: source.display) == nil
    {
      addBundles(for: source.workspace, on: source.display)
    }

    // Protect the complete prospective visible set, not only emitted changes:
    // unchanged selected peers and unrelated active/composed workspaces can
    // share an app process with a skipped member.
    var protectedWorkspaceIDs = transaction.retainedWorkspaceIDs
      .union(assignedWorkspaceIDs)
    for (display, workspaceID) in state.activeWorkspacesByDisplay
      where !transaction.skippedWorkspaceIDs.contains(workspaceID)
      && (destination(on: display) == nil
        || destination(on: display)?.workspace == workspaceID)
    {
      protectedWorkspaceIDs.insert(workspaceID)
    }
    for (display, composition) in state.compositionsByDisplay {
      guard !transaction.skippedWorkspaceIDs.contains(composition.host) else { continue }
      let target = destination(on: display)
      // Its host is protected through the destination placement. The borrowed
      // block is deliberately *not* protected: it is the source-only content
      // this cleanup returns after the host moved away.
      if hostMovesAway(composition, from: display) {
        continue
      }
      guard target?.workspace == composition.host || target == nil else { continue }
      protectedWorkspaceIDs.insert(composition.host)
      protectedWorkspaceIDs.formUnion(composition.borrowed.compactMap { slot in
        transaction.skippedWorkspaceIDs.contains(slot.workspace) ? nil : slot.workspace
      })
    }
    var protectedBundleIDs = sharedBundleIDs
    for workspaceID in protectedWorkspaceIDs {
      protectedBundleIDs.formUnion(
        profile.workspaces[id: workspaceID]?.apps.map(\.bundleIdentifier) ?? []
      )
      protectedBundleIDs.formUnion(
        state.tilingTrees[workspaceID]?.windows.map(\.bundleId) ?? []
      )
    }
    return bundleIDsByDisplay.map { display, bundleIDs in
      let filtered = bundleIDs.subtracting(protectedBundleIDs)
      return WorkspaceChainVisibilityCleanup(display: display, bundleIDs: filtered)
    }.sorted {
      ($0.display.name, $0.display.uuid ?? "")
        < ($1.display.name, $1.display.uuid ?? "")
    }
  }

  /// Preserve cleanup provenance across a superseded profile cascade. Runtime
  /// placement may still contain workspaces from the outgoing profile until a
  /// successful post-focus cleanup commits; merge those sources into the next
  /// direct or chained activation instead of dropping them with the old queue.
  func makeWorkspaceCleanupTransaction(
    prioritySkippedWorkspaceIDs: Set<Workspace.ID> = [],
    retainedWorkspaceIDs: Set<Workspace.ID>,
    assignments: [DisplayAssignment],
    cleanupHUDRequests: [ActionHUDRequest] = [],
    state: State,
  ) -> WorkspaceChainCleanupTransaction? {
    guard let profile = state.config.activeProfile else { return nil }
    let activeProfileWorkspaceIDs = Set(profile.workspaces.ids)
    var visibleWorkspaceIDs = Set(state.activeWorkspacesByDisplay.values)
    for composition in state.compositionsByDisplay.values {
      visibleWorkspaceIDs.insert(composition.host)
      visibleWorkspaceIDs.formUnion(composition.borrowed.map(\.workspace))
    }
    let outgoingProfileWorkspaceIDs = visibleWorkspaceIDs
      .subtracting(activeProfileWorkspaceIDs)
    let skippedWorkspaceIDs = prioritySkippedWorkspaceIDs
      .union(outgoingProfileWorkspaceIDs)
    let placements = assignments.map {
      WorkspaceChainPlacement(display: $0.display, workspace: $0.workspace)
    }
    func destination(on display: DisplayName) -> WorkspaceChainPlacement? {
      placements.first { $0.display.matches(display) }
    }
    let hasMovingCompositionHost = state.compositionsByDisplay.contains { display, composition in
      placements.contains {
        $0.workspace == composition.host && !$0.display.matches(display)
      }
    }
    guard !skippedWorkspaceIDs.isEmpty || hasMovingCompositionHost else { return nil }
    let hasUnfilledSkippedHost = state.activeWorkspacesByDisplay.contains {
      display, workspaceID in
      skippedWorkspaceIDs.contains(workspaceID) && destination(on: display) == nil
    }
    let hasExplicitCompositionCleanup = state.compositionsByDisplay.contains {
      display, composition in
      let target = destination(on: display)
      if
        placements.contains(where: {
          $0.workspace == composition.host && !$0.display.matches(display)
        })
      {
        return true
      }
      if skippedWorkspaceIDs.contains(composition.host) {
        return target == nil
      }
      return (target?.workspace == composition.host || target == nil)
        && composition.borrowed.contains {
          skippedWorkspaceIDs.contains($0.workspace)
        }
    }
    var cleanupDisplays = [DisplayName]()
    func appendCleanupDisplay(_ display: DisplayName) {
      guard !cleanupDisplays.contains(where: { $0.matches(display) }) else { return }
      cleanupDisplays.append(display)
    }
    for (display, workspaceID) in state.activeWorkspacesByDisplay
      where skippedWorkspaceIDs.contains(workspaceID) && destination(on: display) == nil
    {
      appendCleanupDisplay(display)
    }
    for (display, composition) in state.compositionsByDisplay {
      let target = destination(on: display)
      if
        placements.contains(where: {
          $0.workspace == composition.host && !$0.display.matches(display)
        })
      {
        appendCleanupDisplay(display)
      } else if skippedWorkspaceIDs.contains(composition.host), target == nil {
        appendCleanupDisplay(display)
      } else if
        target?.workspace == composition.host || target == nil,
        composition.borrowed.contains(where: {
          skippedWorkspaceIDs.contains($0.workspace)
        })
      {
        appendCleanupDisplay(display)
      }
    }
    let sourceSnapshots = cleanupDisplays.map { display in
      let composition = state.compositionsByDisplay[display]
        ?? state.compositionsByDisplay.first(where: { $0.key.matches(display) })?.value
      let generation = state.borrowGenerationByDisplay[display]
        ?? state.borrowGenerationByDisplay.first(where: {
          $0.key.matches(display)
        })?.value
        ?? 0
      let currentActiveWorkspace = Self.activeWorkspace(
        on: display,
        connected: Array(state.connectedDisplays),
        active: state.activeWorkspacesByDisplay,
      )
      // `recordCompletedActivation` enforces one workspace per display before
      // the deferred cleanup starts. A host moving to another destination is
      // therefore absent from its source active map by then, while its source
      // composition/generation intentionally remain unchanged until commit.
      let expectedActiveWorkspace = currentActiveWorkspace.flatMap { workspaceID in
        placements.contains(where: {
          $0.workspace == workspaceID && !$0.display.matches(display)
        }) ? nil : workspaceID
      }
      return WorkspaceChainCleanupSourceSnapshot(
        display: display,
        activeWorkspace: expectedActiveWorkspace,
        composition: composition,
        borrowGeneration: generation,
      )
    }
    return WorkspaceChainCleanupTransaction(
      skippedWorkspaceIDs: skippedWorkspaceIDs,
      // Callers provide the selected/incoming workspaces explicitly. Unaffected
      // visible workspaces are protected by the prospective active/composition
      // scan in `workspaceChainVisibilityCleanups`; unioning every visible ID
      // here also protected unrelated borrows under a skipped host even though
      // committing that host removes the whole composition.
      retainedWorkspaceIDs: retainedWorkspaceIDs.subtracting(skippedWorkspaceIDs),
      placements: placements,
      sourcePlacements: state.activeWorkspacesByDisplay.compactMap {
        display, activeWorkspaceID in
        skippedWorkspaceIDs.contains(activeWorkspaceID)
          ? WorkspaceChainPlacement(display: display, workspace: activeWorkspaceID)
          : nil
      },
      sourceSnapshots: sourceSnapshots,
      requiresFocusSuccessor: hasUnfilledSkippedHost || hasExplicitCompositionCleanup,
      cleanupHUDRequests: cleanupHUDRequests,
    )
  }

  /// Commit a cleanup whose visibility return completed after focus moved to
  /// the trigger. If that effect was cancelled, this action is never delivered
  /// and the intact state is available to the next switch.
  func commitWorkspaceChainCleanup(
    _ transaction: WorkspaceChainCleanupTransaction,
    displays cleanupDisplays: Set<DisplayName>,
    state: inout State,
  ) -> Effect<Action> {
    guard !cleanupDisplays.isEmpty else { return .none }
    guard
      isWorkspaceChainCleanupCurrent(
        transaction,
        displays: cleanupDisplays,
        state: state,
      )
    else {
      debugLog.log("WorkspaceChain", "skip stale priority cleanup transaction")
      return .none
    }
    debugLog.log(
      "WorkspaceChain",
      "commit priority cleanup displays=\(cleanupDisplays.map(\.name).sorted()) "
        + "skipped=\(transaction.skippedWorkspaceIDs)",
    )
    var compositionLayoutDisplays = Set<DisplayName>()
    var fullLayoutWorkspaceIDs = Set<Workspace.ID>()
    var changedComposition = false

    func destination(on display: DisplayName) -> WorkspaceChainPlacement? {
      transaction.placements.first { $0.display.matches(display) }
    }

    func hostMovesAway(_ composition: Composition, from display: DisplayName) -> Bool {
      transaction.placements.contains {
        $0.workspace == composition.host && !$0.display.matches(display)
      }
    }

    for (display, original) in Array(state.compositionsByDisplay)
      where cleanupDisplays.contains(where: { $0.matches(display) })
    {
      let target = destination(on: display)
      if
        transaction.skippedWorkspaceIDs.contains(original.host)
        || hostMovesAway(original, from: display)
      {
        state.borrowGenerationByDisplay[display, default: 0] &+= 1
        state.pendingBorrowCompletionByDisplay[display] = nil
        for slot in original.borrowed {
          state.pendingCenterWarps[slot.workspace] = nil
        }
        state.compositionsByDisplay[display] = nil
        changedComposition = true
        continue
      }

      let removedSlots = original.borrowed.filter {
        transaction.skippedWorkspaceIDs.contains($0.workspace)
      }
      guard
        !removedSlots.isEmpty,
        target?.workspace == original.host || target == nil
      else { continue }
      state.borrowGenerationByDisplay[display, default: 0] &+= 1
      state.pendingBorrowCompletionByDisplay[display] = nil
      var updated = original
      updated.borrowed.removeAll {
        transaction.skippedWorkspaceIDs.contains($0.workspace)
      }
      for slot in removedSlots {
        state.pendingCenterWarps[slot.workspace] = nil
      }
      state.compositionsByDisplay[display] = updated.borrowed.isEmpty ? nil : updated
      if updated.borrowed.isEmpty {
        fullLayoutWorkspaceIDs.insert(original.host)
      } else {
        compositionLayoutDisplays.insert(display)
      }
      changedComposition = true
    }

    let skippedActiveKeys = state.activeWorkspacesByDisplay.keys.filter { display in
      cleanupDisplays.contains(where: { $0.matches(display) })
        && state.activeWorkspacesByDisplay[display].map(
          transaction.skippedWorkspaceIDs.contains
        ) == true && destination(on: display) == nil
    }
    for display in skippedActiveKeys {
      state.activeWorkspacesByDisplay.removeValue(forKey: display)
    }

    var layouts = [Effect<Action>]()
    for display in compositionLayoutDisplays {
      layouts.append(applyComposition(display: display, state: &state))
    }
    for workspaceID in fullLayoutWorkspaceIDs {
      layouts.append(flushLayout(workspaceId: workspaceID, state: &state))
    }
    if changedComposition {
      layouts.append(refreshMarkers(state: state))
    }
    let cleanupHUDRequests = transaction.cleanupHUDRequests.filter { request in
      guard let display = request.display else { return false }
      return cleanupDisplays.contains { $0.matches(display) }
    }
    if !cleanupHUDRequests.isEmpty {
      layouts.append(.run { [workspaceHUD, cleanupHUDRequests] _ in
        for request in cleanupHUDRequests {
          guard !Task.isCancelled else { return }
          await workspaceHUD.showAction(request)
        }
      })
    }
    return .merge(layouts)
  }

  func isWorkspaceChainCleanupCurrent(
    _ transaction: WorkspaceChainCleanupTransaction,
    displays cleanupDisplays: Set<DisplayName>? = nil,
    state: State,
  ) -> Bool {
    let connected = state.connectedDisplays.isEmpty
      ? transaction.placements.map(\.display)
      : Array(state.connectedDisplays)
    guard
      transaction.placements.allSatisfy({ placement in
        Self.activeWorkspace(
          on: placement.display,
          connected: connected,
          active: state.activeWorkspacesByDisplay,
        ) == placement.workspace
      })
    else { return false }
    let snapshots = transaction.sourceSnapshots.filter { snapshot in
      cleanupDisplays?.contains(where: { $0.matches(snapshot.display) }) ?? true
    }
    if let cleanupDisplays {
      guard
        cleanupDisplays.allSatisfy({ display in
          snapshots.contains { $0.display.matches(display) }
        })
      else { return false }
    }
    return snapshots.allSatisfy { snapshot in
      let activeWorkspace = Self.activeWorkspace(
        on: snapshot.display,
        connected: connected,
        active: state.activeWorkspacesByDisplay,
      )
      let composition = state.compositionsByDisplay[snapshot.display]
        ?? state.compositionsByDisplay.first(where: {
          $0.key.matches(snapshot.display)
        })?.value
      let generation = state.borrowGenerationByDisplay[snapshot.display]
        ?? state.borrowGenerationByDisplay.first(where: {
          $0.key.matches(snapshot.display)
        })?.value
        ?? 0
      return activeWorkspace == snapshot.activeWorkspace
        && composition == snapshot.composition
        && generation == snapshot.borrowGeneration
    }
  }

  /// A chain-owned display already has authoritative feedback about the
  /// workspace that landed there. Add the focus transfer as another fact in
  /// that same HUD instead of presenting a second, generic HUD that would
  /// replace the workspace/chain/borrow-return result on the screen.
  func workspaceChainFocusTransferSubtitle(
    on display: DisplayName,
    context: WorkspaceChainHUDContext?,
  ) -> String? {
    guard
      let transfer = context?.focusTransfer,
      transfer.from.matches(display)
    else { return nil }
    let title = String(localized: "Focus moved")
    let destination = String(
      localized: "\(transfer.workspaceName) is on \(transfer.to.name)"
    )
    return "\(title): \(destination)"
  }

  func returnedBorrowSubtitles(_ names: [String]) -> [String] {
    names.map { String(localized: "Returned \($0)") }
  }

  func workspaceChainCleanupEffect(
    transaction: WorkspaceChainCleanupTransaction?,
    cleanups: [WorkspaceChainVisibilityCleanup],
  ) -> Effect<Action> {
    guard let transaction else { return .none }
    let orderedCleanups = Self.orderedWorkspaceChainCleanups(cleanups)
    guard !orderedCleanups.isEmpty else { return .none }
    return .run { send in
      _ = await Self.runWorkspaceChainCleanup(
        transaction: transaction,
        cleanups: orderedCleanups,
        send: send,
      )
    }
    .cancellable(id: CancelID.workspaceChainCleanup, cancelInFlight: true)
  }

  /// A borrowed chain member can leave a composition while that display keeps
  /// its host workspace. Since no display assignment is emitted for the host,
  /// publish the source result alongside the member's destination assignment.
  func workspaceChainSourceCompositionHUDRequests(
    context: WorkspaceChainHUDContext?,
    state: State,
  ) -> [ActionHUDRequest] {
    guard let context else { return [] }
    return workspaceChainSourceHUDRequests(
      context.sourceCompositionHUDs,
      context: context,
      state: state,
    )
  }

  func workspaceChainDeferredCleanupHUDRequests(
    context: WorkspaceChainHUDContext,
    state: State,
  ) -> [ActionHUDRequest] {
    workspaceChainSourceHUDRequests(
      context.deferredCleanupHUDs,
      context: context,
      state: state,
    )
  }

  /// If a chained move leaves a source display empty, that screen has no
  /// destination assignment from which to present feedback. Announce the move
  /// alongside the destination activation instead.
  func workspaceChainVacatedHUDRequests(
    workspace: Workspace,
    targetDisplay: DisplayName?,
    context: WorkspaceChainHUDContext?,
    state: State,
  ) -> [ActionHUDRequest] {
    guard
      let context,
      let targetDisplay,
      !context.vacatedHUDs.isEmpty
    else { return [] }
    let showsWorkspaceSwitch = state.config.settings.hud.shows(\.workspaceSwitch)
    let showsBorrow = state.config.settings.hud.shows(\.borrow)
    let showsProfileSwitch = context.profileSwitch != nil
      && state.config.settings.hud.shows(\.profileSwitch)
    let visibleProfileSwitch = showsProfileSwitch ? context.profileSwitch : nil
    let durationMs = state.config.settings.hud.durationMs
    let position = state.config.settings.hud.position
    let size = state.config.settings.hud.size
    return context.vacatedHUDs.compactMap { vacatedHUD in
      let hasChainIdentity = context.role == .chainMember
      let returned = showsBorrow
        ? returnedBorrowSubtitles(vacatedHUD.returnedBorrowNames)
        : []
      guard showsProfileSwitch || showsWorkspaceSwitch || !returned.isEmpty else { return nil }
      let movedWorkspace = String(localized: "\(workspace.name) is on \(targetDisplay.name)")
      var resultFacts = showsWorkspaceSwitch && hasChainIdentity ? [context.name] : []
      if showsProfileSwitch || showsWorkspaceSwitch {
        resultFacts.append(movedWorkspace)
      }
      resultFacts.append(contentsOf: returned)
      let resultLine = resultFacts.joined(separator: " · ")
      let subtitle = [
        resultLine,
        showsWorkspaceSwitch
          ? workspaceChainFocusTransferSubtitle(on: vacatedHUD.display, context: context)
          : nil,
      ]
      .compactMap { $0 }
      .joined(separator: "\n")
      return ActionHUDRequest(
        name: visibleProfileSwitch?.name ?? (
          showsWorkspaceSwitch ? String(localized: "Workspace moved") : workspace.name
        ),
        symbolIconName: visibleProfileSwitch?.symbolIconName ?? (
          showsWorkspaceSwitch ? "arrow.right.to.line" : workspace.symbolIconName
        ),
        subtitle: subtitle,
        subtitleSymbolIconName: hasChainIdentity
          ? context.role.subtitleSymbolIconName
          : nil,
        subtitleExtendsDuration: !returned.isEmpty,
        durationMs: durationMs,
        position: position,
        size: size,
        display: vacatedHUD.display,
      )
    }
  }

  /// On the display being left, identify both where focus went and which
  /// workspace now owns it. The destination display shows the regular
  /// workspace-switch HUD separately.
  func focusMovedHUDEffect(
    workspace: Workspace,
    from oldDisplay: DisplayName?,
    to targetDisplay: DisplayName?,
    subtitleSymbolIconName: String? = nil,
    state: State,
  ) -> Effect<Action> {
    guard
      let request = focusMovedHUDRequest(
        workspace: workspace,
        from: oldDisplay,
        to: targetDisplay,
        subtitleSymbolIconName: subtitleSymbolIconName,
        state: state,
      )
    else { return .none }
    return .run { [workspaceHUD] _ in
      await workspaceHUD.showAction(request)
    }
  }

  func focusMovedHUDRequest(
    workspace: Workspace,
    from oldDisplay: DisplayName?,
    to targetDisplay: DisplayName?,
    subtitleSymbolIconName: String? = nil,
    state: State,
  ) -> ActionHUDRequest? {
    guard
      state.config.settings.hud.shows(\.workspaceSwitch),
      let oldDisplay,
      let targetDisplay,
      !oldDisplay.matches(targetDisplay)
    else { return nil }
    let durationMs = state.config.settings.hud.durationMs
    let position = state.config.settings.hud.position
    let size = state.config.settings.hud.size
    let subtitle = String(localized: "\(workspace.name) is on \(targetDisplay.name)")
    return ActionHUDRequest(
      name: String(localized: "Focus moved"),
      symbolIconName: "arrow.right.to.line",
      subtitle: subtitle,
      subtitleSymbolIconName: subtitleSymbolIconName,
      subtitleExtendsDuration: subtitleSymbolIconName == nil,
      durationMs: durationMs,
      position: position,
      size: size,
      display: oldDisplay,
    )
  }

  /// A chain snapshots its interaction display before serial restores begin.
  /// Mutable focus state observed during those restores must never invent a
  /// second origin. Covered source displays fold this fact into their own HUD.
  func uncoveredWorkspaceChainFocusMovedHUDRequest(
    workspace: Workspace,
    context: WorkspaceChainHUDContext,
    state: State,
  ) -> ActionHUDRequest? {
    guard
      let transfer = context.focusTransfer,
      !context.coveredDisplays.contains(where: { $0.matches(transfer.from) })
    else { return nil }
    return focusMovedHUDRequest(
      workspace: workspace,
      from: transfer.from,
      to: transfer.to,
      subtitleSymbolIconName: context.role.subtitleSymbolIconName,
      state: state,
    )
  }

  /// Where a deliberate (focus-taking) activation puts `workspace`: its pinned
  /// display resolved to a connected screen, else — for a dynamic workspace —
  /// the display under the pointer. `performActivate` and the already-visible
  /// focus-transfer shortcut must agree on this; when they drift, a dynamic
  /// workspace looks pinned to whichever monitor it happens to sit on.
  func deliberateActivationDisplay(
    for workspace: Workspace,
    interactionDisplay: DisplayName? = nil,
    state: State,
  ) -> DisplayName? {
    guard let hint = workspace.displayHint else {
      return interactionDisplay ?? self.interactionDisplay(state: state)
    }
    return displays.connected(hint) ?? displays.primary() ?? hint
  }

  /// Shared deliberate-switch planner for hotkeys/UI, app focus, and CLI
  /// completion tracking. Every reducer entry point must cancel the prior
  /// workspace-chain cleanup *before* running this effect; keeping that cancel
  /// inside a merge lets an old physical return race a newer activation.
  func deliberateActivation(
    workspaceId: Workspace.ID,
    setFocus: Bool,
    targetDisplayOverride: DisplayName? = nil,
    interactionDisplayOverride: DisplayName? = nil,
    followsCursor: Bool = false,
    continuesCLIActivation: Bool = false,
    state: inout State,
  ) -> Effect<Action> {
    // A deliberate switch supersedes any in-flight reconnect restore cascade.
    // The user's action wins over the display-restore queue.
    state.pendingDisplayRestores = []
    state.focusWorkspaceOnRestore = nil
    state.finalRestoreTakesFocus = true
    state.finalRestoreFollowsCursor = false
    state.suppressFocusedRestoreHUD = false
    let commandInteractionDisplay = interactionDisplayOverride
      ?? interactionDisplay(state: state)

    // A workspace chain is a symmetric set of workspace identities. Its
    // destinations come from each workspace's ordinary pinned/dynamic target
    // at activation time; internal restores enter through `restoreDisplay` and
    // therefore cannot recursively expand another chain. The selected member
    // remains last and owns final focus.
    if
      setFocus || followsCursor,
      let profile = state.config.activeProfile,
      let workspace = profile.workspaces[id: workspaceId]
    {
      let connected = displays.all()
      let resolvedDisplay: DisplayName? =
        if let targetDisplayOverride {
          targetDisplayOverride
        } else if workspace.isDynamic {
          if !setFocus {
            state.displayShowing(workspaceId) ?? commandInteractionDisplay
          } else {
            commandInteractionDisplay
          }
        } else {
          deliberateActivationDisplay(
            for: workspace,
            interactionDisplay: commandInteractionDisplay,
            state: state,
          )
        }
      if
        let resolvedDisplay,
        let actualDisplay = connected.first(where: { $0.matches(resolvedDisplay) }),
        let chain = profile.validWorkspaceChain(containing: workspaceId)
      {
        let trigger = DisplayAssignment(display: actualDisplay, workspace: workspaceId)
        let result = Self.planWorkspaceChain(
          chain,
          triggeredBy: trigger,
          // App-focus keeps a dynamic trigger on the display that already owns
          // its focused window. A pinned trigger still lets its first dynamic
          // companion follow the pointer/focus interaction display.
          dynamicPreferredDisplay: targetDisplayOverride ?? (
            workspace.isDynamic ? resolvedDisplay : commandInteractionDisplay
          ),
          connected: connected,
          primaryDisplay: displays.primary(),
          workspaces: profile.workspaces.elements,
          active: state.activeWorkspacesByDisplay,
          history: state.displayWorkspaceHistory,
          workspaceMRU: state.workspaceMRU,
        )
        switch result {
        case .success(let chainPlan):
          let skippedWorkspaceIDs = Set(chain.workspaceIDs)
            .subtracting(chainPlan.selectedWorkspaceIDs)
          var plan = workspaceChainHUDAssignments(
            chain: chain,
            assignments: chainPlan.assignments,
            selectedWorkspaceIDs: chainPlan.selectedWorkspaceIDs,
            skippedWorkspaceIDs: skippedWorkspaceIDs,
            focusSourceDisplay: commandInteractionDisplay,
            connected: connected,
            state: state,
          )
          let cleanupHUDRequests: [ActionHUDRequest] =
            if
              let finalIndex = plan.indices.last,
              case .workspaceChain(let context)? = plan[finalIndex].presentation
            {
              workspaceChainDeferredCleanupHUDRequests(context: context, state: state)
            } else {
              []
            }
          if
            let transaction = makeWorkspaceCleanupTransaction(
              prioritySkippedWorkspaceIDs: skippedWorkspaceIDs,
              retainedWorkspaceIDs: chainPlan.selectedWorkspaceIDs,
              assignments: chainPlan.assignments,
              cleanupHUDRequests: cleanupHUDRequests,
              state: state,
            ),
            let finalIndex = plan.indices.last
          {
            if case .workspaceChain(var context)? = plan[finalIndex].presentation {
              context.cleanupTransaction = transaction
              plan[finalIndex].presentation = .workspaceChain(context)
            } else {
              plan[finalIndex].presentation = .workspaceCleanup(transaction)
            }
          }
          let superseded = continuesCLIActivation
            ? Effect<Action>.none
            : supersedePendingCLIActivation(state: &state)
          state.pendingDisplayRestores = plan
          state.focusWorkspaceOnRestore = workspaceId
          state.finalRestoreTakesFocus = setFocus
          state.finalRestoreFollowsCursor = followsCursor
          debugLog.log(
            "WorkspaceChain",
            "trigger workspace=\(workspace.name) display=\(actualDisplay.name) "
              + "plan=\(plan.map { "\($0.display.name)→\($0.workspace)" })",
          )
          return .merge(superseded, .send(.processDisplayRestores))

        case .failure(let failure):
          // Structurally malformed or transiently stale chain state cannot
          // prevent the selected workspace's standalone activation.
          debugLog.log(
            "WorkspaceChain",
            "reject chain=\(chain.id) trigger=\(workspace.name): \(failure.description)",
          )
        }
      }
    }
    // An already-active host that activation would leave exactly where it is
    // is a display focus transfer. Re-activation would tear down its Borrow.
    if
      state.activeActivationGeneration == nil,
      setFocus,
      let display = state.activeWorkspacesByDisplay.first(where: {
        $0.value == workspaceId
      })?.key,
      let workspace = state.config.activeProfile?.workspaces[id: workspaceId],
      targetDisplayOverride?.matches(display)
      ?? deliberateActivationDisplay(
        for: workspace,
        interactionDisplay: commandInteractionDisplay,
        state: state,
      )?.matches(display)
      ?? true,
      // With no focus target, a transfer would silently swallow the switch;
      // run a real activation so the workspace is raised again.
      visibleFocusTarget(workspaceId, state: state) != nil
    {
      let cleanup = makeWorkspaceCleanupTransaction(
        retainedWorkspaceIDs: [workspaceId],
        assignments: [DisplayAssignment(display: display, workspace: workspaceId)],
        state: state,
      )
      let superseded = continuesCLIActivation
        ? Effect<Action>.none
        : supersedePendingCLIActivation(state: &state)
      return .merge(
        superseded,
        focusVisibleWorkspace(
          workspaceId: workspaceId,
          display: display,
          workspaceChainCleanup: cleanup,
          state: &state,
        ),
      )
    }
    let dynamicDisplayOverride: DisplayName? =
      if
        targetDisplayOverride == nil,
        state.config.activeProfile?.workspaces[id: workspaceId]?.isDynamic == true
      {
        if !setFocus, followsCursor {
          state.displayShowing(workspaceId) ?? commandInteractionDisplay
        } else if setFocus || interactionDisplayOverride != nil {
          commandInteractionDisplay
        } else {
          nil
        }
      } else {
        nil
      }
    let activationDisplayOverride = targetDisplayOverride ?? dynamicDisplayOverride
    let cleanupDisplay = activationDisplayOverride ?? state.config.activeProfile?
      .workspaces[id: workspaceId]
      .flatMap {
        deliberateActivationDisplay(
          for: $0,
          interactionDisplay: commandInteractionDisplay,
          state: state,
        )
      }
    let cleanup = cleanupDisplay.flatMap { display in
      makeWorkspaceCleanupTransaction(
        retainedWorkspaceIDs: [workspaceId],
        assignments: [DisplayAssignment(display: display, workspace: workspaceId)],
        state: state,
      )
    }
    return performActivate(
      workspaceId: workspaceId,
      setFocus: setFocus,
      displayOverride: activationDisplayOverride,
      workspaceChainCleanup: cleanup,
      continuesCLIActivation: continuesCLIActivation,
      followsCursor: followsCursor,
      state: &state,
    )
  }

  func performActivate(
    workspaceId: Workspace.ID,
    setFocus: Bool,
    displayOverride: DisplayName? = nil,
    suppressSwitchHUD: Bool = false,
    workspaceChainHUD: WorkspaceChainHUDContext? = nil,
    workspaceChainCleanup: WorkspaceChainCleanupTransaction? = nil,
    /// Planned profile restores and the originating workspace CLI command keep
    /// ownership of the pending CLI request. Every other activation supersedes
    /// that request instead of silently rebinding it to unrelated work.
    continuesCLIActivation: Bool = false,
    // The cursor follows focus even though this activation does not set it.
    // `setFocus` answers "does Tatami pick the focused window", which is not
    // the same question as "did focus move" — an app the user activated from
    // the Dock or Spotlight already owns focus, and the cursor still has to
    // follow it or a multi-window workspace gives no clue which window won.
    followsCursor: Bool = false,
    state: inout State,
  ) -> Effect<Action> {
    guard
      let profile = state.config.activeProfile,
      let workspace = profile.workspaces[id: workspaceId]
    else { return .none }
    // (Switching to a borrowed workspace fully activates it — the composition
    // is dropped as the display re-tiles. Moving focus *into* a borrowed block
    // without switching is the directional-focus path, not activation.)
    let superseded = continuesCLIActivation
      ? Effect<Action>.none
      : supersedePendingCLIActivation(state: &state)

    // A scratchpad is borrow-only: there's no "switch to" it. Redirect a
    // standalone activate into a borrow on the pointer display's host
    // (re-docks if it's already borrowed there).
    if workspace.kind == .scratchpad {
      debugLog.log("Activate", "scratchpad \(workspace.name) → borrow")
      let resolved = workspace.borrowEdge ?? state.config.settings.switching.borrowDefaultEdge
      if let resolved {
        // A configured default edge → dock straight there.
        return .merge(
          superseded,
          performBorrow(
            targetId: workspaceId,
            edge: resolved,
            displayOverride: displayOverride,
            state: &state,
          ),
        )
      }
      if setFocus {
        // "Ask" via a deliberate shortcut (switch/borrow): open the direction
        // picker with nothing placed yet, like the borrow shortcut.
        return .merge(
          superseded,
          .send(.beginBorrowDirection(
            workspaceId: workspaceId,
            interactionDisplay: displayOverride,
          )),
        )
      }
      // "Ask" via focusing the app: dock provisionally at the fallback edge so
      // the window never floats unplaced, then open the picker to re-steer it.
      return .merge(
        superseded,
        performBorrow(
          targetId: workspaceId,
          edge: .right,
          displayOverride: displayOverride,
          state: &state,
        ),
        .send(.beginBorrowDirection(
          workspaceId: workspaceId,
          interactionDisplay: displayOverride,
        )),
      )
    }
    // AX callbacks continuously maintain the latest focused key. Never perform
    // a synchronous focus IPC read in the hotkey reducer: one unresponsive app
    // would stall every subsequent menu and hotkey event on the main thread.
    let outgoingWorkspaceId = state.isActivating
      ? state.activatingWorkspaceID
      : state.activeWorkspace(on: state.focusedDisplay)
        ?? state.primaryActiveWorkspaceID
    var recordedOutgoingFocus = false
    if
      setFocus,
      let focused = state.lastObservedFocusedWindow,
      let outgoing = state.recordFocusedWindow(
        focused,
        preferredWorkspaceId: outgoingWorkspaceId,
        requireVisibleTreeMembership: true,
      )
    {
      debugLog.log(
        "FocusSnapshot",
        "before activation workspaceId=\(outgoing) "
          + "key=\(focused.bundleId)#\(focused.windowID)",
      )
      recordedOutgoingFocus = true
    }
    // Only fall back to a live AX lookup when the observer stream did not
    // already give us a valid outgoing key. Waiting on the same Electron app
    // before show/hide added its full timeout to the visible switch path under
    // CPU pressure even though MRU and insertion state were already current.
    let outgoingFrontmostApp = setFocus && !recordedOutgoingFocus
      ? windowSnapshot.frontmostApp()
      : nil
    // Latest-wins: a switch arriving mid-activation supersedes the
    // in-flight one (the effect below is `cancellable(cancelInFlight:)`)
    // instead of being dropped — dropping read as "the hotkey got
    // swallowed" whenever an activation was slow (an app still
    // launching, AX waits under load). The superseded effect stops at
    // its next cancellation check; this activation's own show/hide and
    // tile pass overwrite whatever partial state it left.
    if state.isActivating {
      debugLog.log("Activate", "supersede in-flight activation → workspaceId=\(workspaceId)")
    }
    state.isActivating = true
    state.activatingWorkspaceID = workspaceId
    state.activationGeneration &+= 1
    let activationGeneration = state.activationGeneration
    state.activeActivationGeneration = activationGeneration
    if continuesCLIActivation, let request = state.pendingCLIActivation {
      state.pendingCLIActivationBinding = CLIActivationBinding(
        requestID: request.id,
        activationGeneration: activationGeneration,
      )
    }
    let isPaused = state.isTilingPaused
    debugLog.log(
      "Activate",
      "start workspace=\(workspace.name) setFocus=\(setFocus) "
        + "paused=\(isPaused) registeredApps=\(workspace.apps.map(\.bundleIdentifier))",
    )

    // Resolve the pinned display to where it actually tiles: the connected
    // screen (UUID → name match), else the primary display as fallback.
    // Learn the UUID for a name-only hint so future matching is UUID-stable.
    let targetDisplay: DisplayName?
    if let displayOverride {
      targetDisplay = displayOverride
      if
        let hint = workspace.displayHint,
        hint.matches(displayOverride),
        hint.uuid != displayOverride.uuid
      {
        state.$config.withLock { config in
          config.mutateWorkspace(workspaceId) { $0.displayHint = displayOverride }
        }
      }
    } else if workspace.displayHint == nil, !setFocus {
      // A background reflow keeps the workspace on its actual display (or the
      // keyboard-focused one before it has an owner) so a config/layout sync
      // cannot move it merely because the pointer happens to be on another
      // monitor. An app-focus activation is user-originated (`followsCursor`),
      // so an inactive dynamic workspace follows the current pointer before a
      // stale focused-display cache. A visible dynamic always keeps its actual
      // owner in both cases.
      targetDisplay = state.displayShowing(workspaceId) ?? (
        followsCursor
          ? interactionDisplay(state: state)
          : state.focusedDisplay ?? displays.current()
      )
    } else {
      if
        let hint = workspace.displayHint,
        let connected = displays.connected(hint),
        hint.uuid != connected.uuid
      {
        state.$config.withLock { config in
          config.mutateWorkspace(workspaceId) { $0.displayHint = connected }
        }
      }
      targetDisplay = deliberateActivationDisplay(for: workspace, state: state)
    }
    state.activatingDisplay = targetDisplay
    // The switch HUD shows on the display focus lands on; on a cross-monitor
    // switch a second HUD on the monitor being left says where focus went, so
    // it doesn't look like the workspace just vanished.
    let oldDisplay = state.focusedDisplay
    if setFocus, let targetDisplay {
      state.focusedDisplay = targetDisplay
    }
    // Re-tiling this display to `workspace` dismisses any live composition on
    // it — a borrow is transient and vanishes when its host re-tiles. Capture
    // the dropped borrow's name so the switch HUD can announce it; skip the
    // case where we're switching *into* the borrowed workspace (a promotion,
    // not a return).
    // Restoring the *host* of a live composition (a borrow release), as opposed
    // to switching away to a third workspace. The host never left the screen, so
    // its tree's transient (unregistered) members must survive the re-tile, and
    // the hide pass stays borrow-scoped to the managed universe so an
    // unregistered floating app summoned alongside the borrow is left alone.
    // Every other activation — a fresh switch, *and* switching to a third
    // workspace while a borrow is still up — passes an empty set → legacy full
    // hide, so nothing unmanaged lingers on the new workspace. (The earlier
    // `compositionsByDisplay[display] != nil` gate leaked the managed-only scope
    // onto third-workspace switches, stranding the unregistered app on screen.)
    let targetCompositionDisplay = targetDisplay.flatMap { target in
      state.compositionsByDisplay.keys.first { $0.matches(target) }
    }
    let restoringHost = targetCompositionDisplay
      .flatMap { state.compositionsByDisplay[$0]?.host } == workspaceId
    var dismissedBorrowName: String?
    var clearedComposition = false
    if
      let compositionDisplay = targetCompositionDisplay,
      let comp = state.compositionsByDisplay[compositionDisplay]
    {
      if let slot = comp.borrowed.first, slot.workspace != workspaceId {
        dismissedBorrowName = profile.workspaces[id: slot.workspace]?.name
      }
      state.borrowGenerationByDisplay[compositionDisplay, default: 0] &+= 1
      state.pendingBorrowCompletionByDisplay[compositionDisplay] = nil
      for slot in comp.borrowed {
        state.pendingCenterWarps[slot.workspace] = nil
      }
      state.compositionsByDisplay[compositionDisplay] = nil
      clearedComposition = true
    }
    var displacedCompositionHosts = [Workspace.ID]()
    // A host moving to another display leaves its borrowed block on the source
    // display. Do not erase that composition here: the cleanup transaction
    // returns those windows *after* target focus has settled, then commits the
    // source removal only when the display-scoped return succeeded. This keeps
    // state paired with the visible block if a newer switch cancels the move.
    for (sourceDisplay, composition) in Array(state.compositionsByDisplay)
      where composition.host == workspaceId
      || composition.borrowed.contains(where: { $0.workspace == workspaceId })
    {
      guard targetDisplay?.matches(sourceDisplay) != true else { continue }
      // Promotion of a borrowed member still collapses its old host right
      // away; the host remains on this display and gets a local reflow. The
      // moving-host case above is different: it leaves the whole source
      // composition stranded and is committed by the cleanup transaction.
      guard composition.host != workspaceId else { continue }
      state.borrowGenerationByDisplay[sourceDisplay, default: 0] &+= 1
      state.pendingBorrowCompletionByDisplay[sourceDisplay] = nil
      for slot in composition.borrowed {
        state.pendingCenterWarps[slot.workspace] = nil
      }
      state.compositionsByDisplay[sourceDisplay] = nil
      clearedComposition = true
      displacedCompositionHosts.append(composition.host)
    }
    // "Most recently used" (no pinned focus app): restore the exact window the
    // user last had focused in this workspace. On a plain switch the target must
    // be a window that survives the switch's hide pass — a registered or shared
    // member. An unregistered app folded into the tree this session (a transient)
    // is hidden by the switch, so restoring it as the focus target would have the
    // manager *resurrect* it (unhide + raise + activate) and the post-switch sync
    // re-fold it into the tree — making it stick on every return (the symptom:
    // "an unregistered app lingers across workspaces"). The design contract is
    // that transients drop out on the next activation; MRU restoration must not
    // defeat it. Only a borrow return (`restoringHost`) keeps transients on
    // screen (managed-scoped hide), so the last-used transient is restorable
    // there — that's the borrow-return focus the manager honors.
    let mruCandidates = workspace.appToFocusBundleId == nil
      ? (state.mruWindows[workspaceId] ?? [])
      : []
    let isWorkspaceMember: (WindowKey) -> Bool = { key in
      workspace.apps.contains { $0.bundleIdentifier == key.bundleId }
        || state.config.sharedApps.contains { $0.bundleIdentifier == key.bundleId }
    }
    let mruWindow = restoringHost
      ? mruCandidates.first
      : mruCandidates.first(where: isWorkspaceMember)
    let expectedFocusBundleId = workspace.appToFocusBundleId
      ?? mruWindow?.bundleId
      ?? workspace.apps.last?.bundleIdentifier
    debugLog.log(
      "FocusTarget",
      "ws=\(workspace.name) pin=\(workspace.appToFocusBundleId ?? "nil(MRU)") "
        + "mru=\(state.mruWindows[workspaceId]?.map { "\($0.bundleId)#\($0.windowID)" } ?? []) "
        + "pick=\(mruWindow.map { "\($0.bundleId)#\($0.windowID)" } ?? "nil")",
    )
    let request = ActivationRequest(
      workspace: workspace,
      sharedApps: state.config.sharedApps,
      targetDisplay: targetDisplay,
      setFocus: setFocus,
      mouseHidesOnFocus: setFocus && state.config.settings.focus.mouseHidesOnFocus,
      windowKeyToFocus: mruWindow,
      managedBundleIds: restoringHost ? state.managedBundleIds : [],
    )
    let warpMouse = (setFocus || followsCursor)
      && state.config.settings.focus.mouseFollowsFocus
    // When focus arrived on its own, the window the system actually raised is
    // the truth — the workspace's MRU pick can name a different window of the
    // same app, and warping there would point at the wrong tile.
    let prefersLiveFocusTarget = followsCursor && !setFocus
    // Show the HUD on a normal switch, or whenever this switch returned a
    // borrow (so the dismissal is always announced — even mid-move).
    // A profile switch shows its own HUD (profile name + activated workspace),
    // so the per-workspace switch HUD is suppressed here to avoid clobbering it.
    let showsWorkspaceSwitchHUD = state.config.settings.hud.shows(\.workspaceSwitch)
    let showsBorrowHUD = state.config.settings.hud.shows(\.borrow)
    let showsProfileSwitchHUD = workspaceChainHUD?.profileSwitch != nil
      && state.config.settings.hud.shows(\.profileSwitch)
    let returnedBorrowNames = Array(OrderedSet(
      (workspaceChainHUD?.destinationReturnedBorrowNames ?? [])
        + (dismissedBorrowName.map { [$0] } ?? [])
    ))
    let deferredCleanupOwnsTargetHUD = workspaceChainCleanup != nil
      && targetDisplay.map { target in
        workspaceChainHUD?.deferredCleanupHUDs.contains {
          $0.display.matches(target)
        } == true
      } == true
    let showHUD = !suppressSwitchHUD && !deferredCleanupOwnsTargetHUD && (
      showsProfileSwitchHUD
        || ((setFocus || workspaceChainHUD != nil) && showsWorkspaceSwitchHUD)
        || ((setFocus || workspaceChainHUD != nil)
          && !returnedBorrowNames.isEmpty
          && showsBorrowHUD)
    )

    let settings = state.config.settings
    let workspaceChainVisibilityCleanups = workspaceChainCleanup.map {
      self.workspaceChainVisibilityCleanups($0, state: state)
    } ?? []
    // Tile target: this workspace's tiled apps + shared tiled apps. Floating
    // apps (per-workspace or shared) are shown by the manager but kept out of
    // the tree.
    // An app registered to the workspace AND shared appears in both lists —
    // dedupe, or its windows get discovered twice and tile twice.
    // Restoring the host after a borrow keeps its tree's transient members
    // (apps folded in this session but registered nowhere) — discover them too,
    // or `mergeTree` would drop them as stale and they'd fall out of the tiling.
    // A fresh switch passes none, so transients drop as designed.
    let transientBundles = restoringHost
      ? (state.tilingTrees[workspace.id]?.windows.map(\.bundleId) ?? [])
      : []
    let bundleIds = Array(OrderedSet(
      workspace.apps.filter { $0.layout == .tiled }.map(\.bundleIdentifier)
        + state.config.sharedApps.filter { $0.layout == .tiled }.map(\.bundleIdentifier)
        + transientBundles
    ))
    // Floating apps (per-workspace + shared) are raised above the tiles after
    // the tile pass. Unmanaged apps are neither tiled nor floated — left out
    // of both sets; the manager still shows/hides them as members.
    let floatingBundleIds = Array(OrderedSet(
      workspace.apps.filter { $0.layout == .floating }.map(\.bundleIdentifier)
        + state.config.sharedApps.filter { $0.layout == .floating }.map(\.bundleIdentifier)
    ))
    // Floating overlays and markers are process-global presentation surfaces.
    // Replacing one display must retain the other displays' visible members;
    // using only the target workspace here tore their mirrors/markers down.
    var presentationWorkspaceIDs = state.visibleWorkspaceIDs
    if
      let targetDisplay,
      let outgoing = state.activeWorkspace(on: targetDisplay)
    {
      presentationWorkspaceIDs.remove(outgoing)
    }
    presentationWorkspaceIDs.insert(workspace.id)
    let presentationFloatingBundleIds = Self.floatingBundleIds(
      state: state,
      workspaceIDs: presentationWorkspaceIDs,
    )
    let activationObservedBundleIds = Array(OrderedSet(
      bundleIds
        + presentationFloatingBundleIds
        + Self.unmanagedBundleIds(
          state: state,
          workspaceIDs: presentationWorkspaceIDs,
        )
    ))
    let sessionTree = state.tilingTrees[workspace.id]
    let sharedTiledBundleIds = Set(
      state.config.sharedApps.filter { $0.layout == .tiled }.map(\.bundleIdentifier)
    )
    let partitionsSharedWindows = state.connectedDisplays.count > 1
      || state.activeWorkspacesByDisplay.count > 1
    var protectedWindowKeys = Set<WindowKey>()
    if let targetDisplay {
      for otherId in state.visibleWorkspaceIDs where otherId != workspace.id {
        guard
          let otherDisplay = state.displayShowing(otherId),
          !otherDisplay.matches(targetDisplay)
        else { continue }
        protectedWindowKeys.formUnion(state.tilingTrees[otherId]?.windows ?? [])
      }
    }
    let existingTargetKeys = Set(sessionTree?.windows ?? [])
    let zoomed = state.fullscreenZoomed[workspace.id] ?? []
    let insertionPoint = state.insertionPoint[workspace.id]
    // A composition marker is an always-visible symbol badge. Clear it as soon
    // as activation drops the composition; waiting for the post-layout
    // floating-window pass leaves the old, 2× Borrow badge masquerading as an
    // oversized fullscreen dot on the promoted workspace.
    let clearedCompositionMarkers = clearedComposition
      ? refreshMarkers(state: state)
      : Effect<Action>.none

    let visibleProfileSwitch = showsProfileSwitchHUD
      ? workspaceChainHUD?.profileSwitch
      : nil
    let hudName = visibleProfileSwitch?.name ?? workspace.name
    let hudIcon = visibleProfileSwitch?.symbolIconName ?? workspace.symbolIconName
    let returnedBorrowFacts = showsBorrowHUD
      ? returnedBorrowSubtitles(returnedBorrowNames)
      : []
    let focusTransferSubtitle = showsWorkspaceSwitchHUD
      ? targetDisplay.flatMap {
        workspaceChainFocusTransferSubtitle(on: $0, context: workspaceChainHUD)
      }
      : nil
    let hasWorkspaceChainIdentity = workspaceChainHUD?.role == .chainMember
    let visibleWorkspaceChainName = showsWorkspaceSwitchHUD && hasWorkspaceChainIdentity
      ? workspaceChainHUD?.name
      : nil
    let hudResultLine = (
      (visibleProfileSwitch == nil ? [] : [workspace.name])
        + [visibleWorkspaceChainName].compactMap { $0 }
        + returnedBorrowFacts
    ).joined(separator: " · ")
    let hudSubtitle = [
      hudResultLine.isEmpty ? nil : hudResultLine,
      focusTransferSubtitle,
    ]
    .compactMap { $0 }
    .joined(separator: "\n")
    let effectiveHUDSubtitle = hudSubtitle.isEmpty ? nil : hudSubtitle
    let hudSubtitleIcon = hasWorkspaceChainIdentity
      ? workspaceChainHUD?.role.subtitleSymbolIconName
      : nil
    // The switch HUD shows on the display focus landed on (the target). On a
    // same-monitor switch with no resolved target it falls back to the cursor.
    let hudDisplay = targetDisplay
    let hudDurationMs = state.config.settings.hud.durationMs
    let hudPosition = state.config.settings.hud.position
    let hudSize = state.config.settings.hud.size

    var auxiliaryHUDRequests = workspaceChainVacatedHUDRequests(
      workspace: workspace,
      targetDisplay: targetDisplay,
      context: workspaceChainHUD,
      state: state,
    )
    auxiliaryHUDRequests.append(contentsOf: workspaceChainSourceCompositionHUDRequests(
      context: workspaceChainHUD,
      state: state,
    ))

    // On a cross-monitor switch, a second HUD on the monitor being left names
    // where focus went. Separate panel (the controller tracks one per screen),
    // shown alongside the switch HUD on the new monitor.
    let focusMovedHUDRequest = workspaceChainHUD.map {
      uncoveredWorkspaceChainFocusMovedHUDRequest(
        workspace: workspace,
        context: $0,
        state: state,
      )
    } ?? self.focusMovedHUDRequest(
      workspace: workspace,
      from: oldDisplay,
      to: targetDisplay,
      state: state,
    )
    if
      setFocus || (followsCursor && workspaceChainHUD != nil),
      !suppressSwitchHUD,
      let focusMovedHUDRequest
    {
      auxiliaryHUDRequests.append(focusMovedHUDRequest)
    }
    var displacedCompositionEffects = [Effect<Action>]()
    for workspaceId in displacedCompositionHosts {
      displacedCompositionEffects.append(
        flushLayout(workspaceId: workspaceId, state: &state)
      )
    }
    let displacedCompositionReflow = Effect<Action>.merge(
      displacedCompositionEffects
    )

    // Floating windows need Screen Recording for their mirrors. Don't fail
    // silently ("floating just doesn't stay on top"): surface the system
    // prompt and a HUD pointing at the Settings row, once per session.
    var screenRecordingAccess = Effect<Action>.none
    var screenRecordingWarningHUDRequest: ActionHUDRequest? = nil
    if
      !floatingBundleIds.isEmpty,
      !screenRecording.isGranted(),
      !state.didWarnMissingScreenRecording
    {
      state.didWarnMissingScreenRecording = true
      screenRecordingAccess = .run { [screenRecording] _ in
        await screenRecording.requestAccess()
      }
      if state.config.settings.hud.shows(\.floating) {
        screenRecordingWarningHUDRequest = ActionHUDRequest(
          name: String(localized: "Screen Recording Needed"),
          symbolIconName: "exclamationmark.triangle.fill",
          subtitle: String(
            localized: "Floating windows can't stay above the tiles without it — grant in Settings → General → Permissions, then relaunch"
          ),
          durationMs: hudDurationMs,
          position: hudPosition,
          size: hudSize,
          display: targetDisplay,
        )
      }
    }

    // Watchdog: `isActivating` is only ever cleared by
    // `activationCompleted` — if the activation effect wedges past every
    // AX timeout (or dies without reporting), the latch would refuse all
    // future activations and syncs for the rest of the session. Cancelled
    // by `activationCompleted` on the normal path.
    let watchdog = Effect<Action>.run { [clock] send in
      try await clock.sleep(for: .seconds(10))
      await send(.activationTimedOut(generation: activationGeneration))
    }
    .cancellable(id: CancelID.activationWatchdog, cancelInFlight: true)

    // High/user-initiated priority: the whole effect is the visible response to a
    // hotkey press. Under system load the default priority leaves our
    // main-actor hops queued behind everything else — exactly when the
    // switch already crawls on slow AX replies.
    return .merge(
      superseded,
      .concatenate(
        // Every frame writer targeting this display shares one cancellation
        // domain. An activation is the authoritative writer, so retire an
        // in-flight tree/composition flush before its show/hide + tile pass.
        .cancel(id: CancelID.layout(targetDisplay)),
        .cancel(id: CancelID.borrowFocus(targetDisplay)),
        .cancel(id: CancelID.borrowRender(targetDisplay)),
        .cancel(id: CancelID.activationHUD),
        .merge(
          screenRecordingAccess,
          watchdog,
          displacedCompositionReflow,
          clearedCompositionMarkers,
          // Arm tiled, floating, and unmanaged apps concurrently with activation.
          // A first-time installation emits one observation-ready reconcile, so
          // a state change racing this setup cannot fall through the cache gap.
          .run { [observer = windowObserver, activationObservedBundleIds] send in
            await observer.observe(activationObservedBundleIds)
            await send(
              .presentationObservationReady(
                bundleIds: Set(activationObservedBundleIds)
              )
            )
          },
          .run(priority: .high) { [
            mgr = workspaceManager,
            tiler = windowTiler,
            store = layoutStore,
            hud = workspaceHUD,
            mouse = mouse,
            overlay = floatingOverlay,
            snapshot = windowSnapshot,
            displays = displays,
            debugLog = debugLog,
            focus = focusManager,
            auxiliaryHUDRequests,
            screenRecordingWarningHUDRequest,
          ] send in
            async let outgoingFocus: WindowKey? = {
              guard let outgoingFrontmostApp else { return nil as WindowKey? }
              return await snapshot.focusedWindowKeyOffMain(outgoingFrontmostApp)
            }()
            // Wall-clock per phase. AX round trips block on *other* apps' run
            // loops, so when a switch crawls under load this names the phase
            // (and thus the app set) that ate the time.
            let timer = ContinuousClock()
            var phaseStart = timer.now
            var phases = [(String, Duration)]()
            var coreCompletionSent = false
            func mark(_ name: String) {
              let now = timer.now
              phases.append((name, now - phaseStart))
              phaseStart = now
            }
            guard !Task.isCancelled else { return }
            if showHUD, screenRecordingWarningHUDRequest == nil {
              await hud.showAction(
                ActionHUDRequest(
                  name: hudName,
                  symbolIconName: hudIcon,
                  subtitle: effectiveHUDSubtitle,
                  subtitleSymbolIconName: hudSubtitleIcon,
                  subtitleExtendsDuration: !returnedBorrowFacts.isEmpty,
                  durationMs: hudDurationMs,
                  position: hudPosition,
                  size: hudSize,
                  display: hudDisplay,
                )
              )
            }
            for request in auxiliaryHUDRequests {
              guard !Task.isCancelled else { return }
              await hud.showAction(request)
            }
            if let screenRecordingWarningHUDRequest {
              guard !Task.isCancelled else { return }
              await hud.showAction(screenRecordingWarningHUDRequest)
            }
            guard !Task.isCancelled else { return }
            // Tear down the outgoing workspace's mirrors in the same beat as the
            // hide pass. Leaving them to the post-tile `setFloating` made the
            // floating windows visibly outlive the windows they mirror.
            await overlay.retainOnly(Set(presentationFloatingBundleIds))
            guard !Task.isCancelled else { return }
            // Resolve the outgoing window before show/hide can focus a different
            // window in the same process. Merely starting this child task first
            // does not order its AX read ahead of `mgr.activate`.
            let outgoingFocusedWindow = await outgoingFocus
            guard !Task.isCancelled else { return }
            await mgr.activate(request)
            guard !Task.isCancelled else { return }
            if let outgoingWorkspaceId, let outgoingFocusedWindow {
              await send(.activationFocusSnapshotResolved(
                workspaceId: outgoingWorkspaceId,
                key: outgoingFocusedWindow,
              ))
            }
            mark("showHide")
            // Superseded by a newer switch: stop before the tile pass. `send`
            // on a cancelled effect is already a no-op, but the AX work below
            // is not. Without these checks a superseded activation would keep
            // writing the *old* workspace's frames interleaved with the new
            // activation's main-actor hops.
            guard !Task.isCancelled else { return }
            if !isPaused {
              // Layouts always persist now. Restore the saved template whenever
              // there's no in-memory tree yet (fresh launch / first activation).
              let persistedSnapshot: LayoutSnapshot? =
                sessionTree == nil ? await store.load(workspaceId) : nil
              guard !Task.isCancelled else { return }
              // Cache-first discovery: a warm `WindowKeyCache` entry costs zero
              // AX round trips. AX scans block on each target app's run loop
              // (measured 50 ms–1.2 s per switch), which is what made switching
              // crawl under system load. Each process has its own serialized AX
              // lane, so independent apps can resolve concurrently without one
              // slow app adding its timeout to every following bundle. Preserve
              // configured order when flattening so fresh-tree placement stays
              // deterministic.
              let discovered = await withTaskGroup(
                of: (Int, [WindowKey]).self,
                returning: [WindowKey].self,
              ) { group in
                for (index, bundleId) in bundleIds.enumerated() {
                  group.addTask {
                    (index, await snapshot.stableCachedKeysOffMain([bundleId], true))
                  }
                }
                var results = [(Int, [WindowKey])]()
                for await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }.flatMap(\.1)
              }
              guard !Task.isCancelled else { return }
              let onScreenFrames = snapshot.onScreenWindowFrames()
              let keys = await MainActor.run {
                Self.scopedWindowKeys(
                  discovered,
                  sharedTiledBundleIds: sharedTiledBundleIds,
                  existingTargetKeys: existingTargetKeys,
                  protectedKeys: protectedWindowKeys,
                  partitionSharedWindows: partitionsSharedWindows,
                  targetWorkArea: displays.workArea(targetDisplay),
                  windowFrame: { onScreenFrames[$0.windowID] },
                )
              }
              mark("discover")
              let (tree, frames, restoredZoom, unresolvedZoomSlots) = await MainActor.run {
                () -> (
                  BSPNode<WindowKey>?,
                  [WindowKey: CGRect],
                  Set<WindowKey>,
                  Set<SlotID>
                ) in
                let workArea = displays.workArea(targetDisplay).insetBy(
                  dx: CGFloat(settings.layout.gapOuter),
                  dy: CGFloat(settings.layout.gapOuter),
                )
                var base = sessionTree
                var persistedZoomSlots = [SlotID]()
                if let snapshot = persistedSnapshot {
                  base = BSPNode.hydrate(template: snapshot.tree, keys: keys)
                  persistedZoomSlots = snapshot.fullscreenZoomedSlots
                }
                let restoredLayout = base != nil
                let merged = Self.mergeTree(
                  existing: base,
                  target: keys,
                  focused: { outgoingFocusedWindow },
                  insertionPoint: insertionPoint,
                  workArea: workArea,
                  settings: settings,
                )
                let axis = settings.layout.autoBalance
                // No resident tree and no persisted template (or a template with
                // zero matching windows) means the old shape is genuinely gone.
                // Initialize from the same contract as explicit Balance:
                // Auto-balance axes when enabled, canonical BSP when Off.
                let tree =
                  if restoredLayout {
                    axis == .none ? merged : merged?.balanced(axis: axis)
                  } else {
                    merged?.balancedForCommand(
                      autoBalance: axis,
                      in: workArea,
                      gap: CGFloat(settings.layout.gapInner),
                      splitAxis: settings.layout.splitType.bspSplitAxis(),
                    )
                  }
                let resolvedZoom: Set<WindowKey> = {
                  if !zoomed.isEmpty { return zoomed }
                  guard let tree else { return [] }
                  return Self.resolveFullscreenZoom(
                    slots: persistedZoomSlots,
                    keys: keys,
                    among: tree.windows,
                  )
                }()
                let frames = Self.computeFrames(
                  tree: tree,
                  settings: settings,
                  targetDisplay: targetDisplay,
                  fullscreenZoomed: resolvedZoom,
                )
                let assignments = slotAssignment(keys)
                let resolvedSlots = Set(resolvedZoom.compactMap { assignments[$0] })
                let unresolvedZoomSlots =
                  Set(persistedZoomSlots).subtracting(resolvedSlots)
                return (tree, frames, resolvedZoom, unresolvedZoomSlots)
              }
              mark("layout")
              // Cancellation can arrive while the main actor computes a large tree.
              // Do not publish or persist a superseded workspace's layout snapshot.
              guard !Task.isCancelled else { return }
              await send(.tilingTreeUpdated(workspaceId: workspaceId, tree: tree))
              if persistedSnapshot != nil, zoomed.isEmpty {
                await send(.persistedFullscreenZoomRestored(
                  workspaceId: workspaceId,
                  keys: restoredZoom,
                  unresolvedSlots: unresolvedZoomSlots,
                ))
              }
              guard !Task.isCancelled else { return }
              if let tree {
                let slots = slotAssignment(tree.windows)
                await store.save(
                  workspaceId,
                  LayoutSnapshot(
                    tree: tree.mapWindows { slots[$0]! },
                    fullscreenZoomedSlots: Set(
                      restoredZoom.compactMap { slots[$0] }
                    )
                    .union(unresolvedZoomSlots)
                    .sorted { ($0.bundleId, $0.occurrence) < ($1.bundleId, $1.occurrence) },
                  ),
                )
              }
              guard !Task.isCancelled else { return }
              if !frames.isEmpty {
                await tiler.apply(FrameApplication(windowFrames: frames))
              }
              mark("apply")
              guard !Task.isCancelled else { return }
              if !frames.isEmpty {
                await send(
                  .presentationLayoutApplied(
                    keys: Set(frames.keys),
                    preservesPointer: false,
                  )
                )
              }
              // Show/hide + the first authoritative tile pass is the visible
              // switch. Publish it now; floating overlays, markers, focus
              // validation, and pointer warp are cancellable best-effort
              // post-layout work and must not hold the activation gate.
              coreCompletionSent = true
              await send(.activationCompleted(
                workspaceId: workspaceId,
                display: targetDisplay,
                generation: activationGeneration,
              ))
              guard !Task.isCancelled else { return }
              // Mirror floating windows onto always-on-top panels (the Topit /
              // Floaty technique): a foreign window's level can't be raised without
              // SIP, so instead of trying we paint a live mirror above the tiles.
              // Passing the resolved set (possibly empty) also tears down mirrors
              // for apps that were just un-floated or belong to another workspace.
              // Same cache-first, per-bundle worker discovery as the tile pass
              // above.
              var floatingDiscovered = Set<WindowKey>()
              for bundleId in presentationFloatingBundleIds {
                guard !Task.isCancelled else { return }
                floatingDiscovered.formUnion(
                  await snapshot.cachedKeysOffMain([bundleId], false)
                )
              }
              let floatingKeys = floatingDiscovered
              mark("float")
              guard !Task.isCancelled else { return }
              await overlay.setFloating(floatingKeys)
              guard !Task.isCancelled else { return }
              // Markers ride the same discovery, but reducer state owns their
              // categories. Re-derive after `activationCompleted` publishes the
              // target workspace and cancel any composition-era marker refresh.
              await send(.activationMarkerKeysResolved(Array(floatingKeys)))
              guard !Task.isCancelled else { return }
              if warpMouse {
                var fallbackFrames = [WindowKey: CGRect]()
                let liveWindowServerFrames = snapshot.onScreenWindowFrames()
                if let mruWindow, frames[mruWindow] == nil {
                  if let frame = liveWindowServerFrames[mruWindow.windowID] {
                    fallbackFrames[mruWindow] = frame
                  } else if let frame = await snapshot.windowFrameOffMain(mruWindow) {
                    fallbackFrames[mruWindow] = frame
                  }
                }
                guard !Task.isCancelled else { return }
                // Read focus after the potentially blocking MRU geometry lookup,
                // so a user focus change during that IPC cannot leave a stale
                // "still focused" proof for the eventual pointer warp.
                var liveFocused = await snapshot.focusedWindowKeyOffMain()
                guard !Task.isCancelled else { return }
                if
                  let candidateFocus = liveFocused,
                  frames[candidateFocus] == nil,
                  fallbackFrames[candidateFocus] == nil
                {
                  if let frame = liveWindowServerFrames[candidateFocus.windowID] {
                    fallbackFrames[candidateFocus] = frame
                  } else {
                    let frame = await snapshot.windowFrameOffMain(candidateFocus)
                    guard !Task.isCancelled else { return }
                    // Geometry is another suspension point. Validate focus again
                    // and accept that frame only if the same window still owns it.
                    let verifiedFocused = await snapshot.focusedWindowKeyOffMain()
                    guard !Task.isCancelled else { return }
                    if verifiedFocused == candidateFocus, let frame {
                      fallbackFrames[candidateFocus] = frame
                    }
                    liveFocused = verifiedFocused
                  }
                }
                guard !Task.isCancelled else { return }
                let warp: (key: WindowKey, rect: CGRect, live: WindowKey?)? = {
                  // Warp to the window this activation deliberately focused (the MRU
                  // target), not a live `focusedWindowKey()` read. That read races
                  // the async app activation and can return a *different* frontmost
                  // window (e.g. Siri keeping front while ChatGPT is the target),
                  // sending the cursor to the wrong tile, where focus-follows-mouse
                  // then grabs focus to it. Fall back to the live read only when this
                  // workspace has no MRU target (a pinned-app or empty workspace).
                  let live = liveFocused
                  // Unless focus arrived on its own: then the raised window is
                  // the answer and the MRU pick is a guess about it.
                  if
                    prefersLiveFocusTarget,
                    let live,
                    live.bundleId == expectedFocusBundleId,
                    let rect = frames[live] ?? fallbackFrames[live]
                  {
                    return (live, rect, live)
                  }
                  if
                    let mruWindow,
                    let rect = frames[mruWindow] ?? fallbackFrames[mruWindow]
                  {
                    return (mruWindow, rect, live)
                  }
                  // A stale MRU id is allowed to fall back to the app's live main
                  // window (the focus manager does the same). Gate by the expected
                  // bundle so a lagging frontmost read can never warp into the
                  // outgoing workspace. AX geometry also lets MFF follow an owned
                  // floating/unmanaged restore target, which has no tiled frame.
                  guard
                    let live,
                    live.bundleId == expectedFocusBundleId,
                    let rect = frames[live] ?? fallbackFrames[live]
                  else { return nil }
                  return (live, rect, live)
                }()
                guard !Task.isCancelled else { return }
                if let warp {
                  let center = CGPoint(x: warp.rect.midX, y: warp.rect.midY)
                  debugLog.log(
                    "Warp",
                    "activate target=\(warp.key.bundleId)#\(warp.key.windowID) "
                      + "live=\(warp.live.map { "\($0.bundleId)#\($0.windowID)" } ?? "nil") "
                      + "→ (\(Int(center.x)),\(Int(center.y)))",
                  )
                  // The deliberate activation focus can be stolen mid-switch. An app
                  // like Siri grabs frontmost as it unhides, leaving the keyboard
                  // focus on the wrong tile while the cursor warps to the intended
                  // one, so directional focus then anchors on the wrong window. When
                  // the live frontmost differs from the window we're warping to,
                  // re-assert the intended focus now that the layout has settled.
                  if warp.live != warp.key {
                    await focus.focusWindow(warp.key)
                  }
                  guard !Task.isCancelled else { return }
                  mouse.warp(center)
                }
              }
            }
            debugLog.log(
              "Activate",
              "phases " + phases.map { "\($0.0)=\(ms($0.1))ms" }.joined(separator: " "),
            )
            if !coreCompletionSent {
              await send(.activationCompleted(
                workspaceId: workspaceId,
                display: targetDisplay,
                generation: activationGeneration,
              ))
            }
            // Priority-skipped members on otherwise-unfilled displays are
            // hidden only after the selected trigger has established focus.
            // Hiding the old frontmost app earlier can make macOS reactivate it
            // and bounce follow-app-focus back into the discarded workspace.
            if let workspaceChainCleanup {
              guard !Task.isCancelled else { return }
              _ = await Self.runWorkspaceChainCleanup(
                transaction: workspaceChainCleanup,
                cleanups: workspaceChainVisibilityCleanups,
                send: send,
              )
            }
            // The tail survived to the end. Only now is it safe for a queued
            // display restore to start its own activation, which would cancel
            // this effect. A cancelled tail never gets here, but cancellation
            // only happens when another activation is already taking over.
            guard !Task.isCancelled else { return }
            await send(.activationTailFinished(generation: activationGeneration))
          }
          .cancellable(id: CancelID.activation, cancelInFlight: true),
        ),
      ),
    )
  }

  func supersedePendingCLIActivation(state: inout State) -> Effect<Action> {
    guard let request = state.pendingCLIActivation else { return .none }
    state.pendingCLIActivation = nil
    state.pendingCLIActivationBinding = nil
    return .run { _ in
      request.complete("Activation was superseded by a newer user action")
    }
  }

  func cycle(
    by direction: Int,
    display: DisplayName?,
    state: inout State,
  ) -> Effect<Action> {
    let inFlightAnchor = state.config.settings.switching.cycleAcrossDisplays
      ? state.activatingWorkspaceID
      : state.activatingWorkspace(on: display)
    let anchor = inFlightAnchor
      ?? state.activeWorkspace(on: display)
      ?? state.primaryActiveWorkspaceID
    let workspaces = state.config.activeProfile?.workspaces
    let name = { (id: Workspace.ID?) -> String in
      id.flatMap { workspaces?[id: $0]?.name } ?? "nil"
    }
    guard let id = adjacentWorkspaceId(by: direction, state: state, display: display) else {
      debugLog.log(
        "Activate",
        "cycle \(direction > 0 ? "next" : "previous") from=\(name(anchor)): no eligible target",
      )
      return .none
    }
    debugLog.log(
      "Activate",
      "cycle \(direction > 0 ? "next" : "previous") from=\(name(anchor)) → \(name(id))",
    )
    return .send(.activate(
      workspaceId: id,
      setFocus: true,
      interactionDisplay: display,
    ))
  }

  /// The workspace `direction` steps from the active one, honoring the
  /// `loop` / `skipEmpty` switching preferences. Shared by cycling and by
  /// "move focused app to next/previous workspace". Returns `nil` when there
  /// is no eligible target (e.g. at an end with looping off).
  func adjacentWorkspaceId(
    by direction: Int,
    state: State,
    display: DisplayName?,
  ) -> Workspace.ID? {
    // Scratchpads are borrow-only — never a cycle destination.
    guard
      let all = state.config.activeProfile?.workspaces
        .filter({ $0.kind != .scratchpad }),
      !all.isEmpty
    else { return nil }
    let settings = state.config.settings
    // Scope the cycle. `cycleAcrossDisplays` → every workspace. Otherwise stay
    // on the cursor's display: pinned workspaces by their display, dynamic
    // (unpinned) ones by the display they were last activated on (never-active
    // ones are included so they stay reachable).
    let workspaces: IdentifiedArrayOf<Workspace> =
      if
        !settings.switching.cycleAcrossDisplays,
        let focused = display ?? state.focusedDisplay
      {
        all.filter { ws in
          if let hint = ws.displayHint {
            // A pinned workspace belongs to the display it actually tiles on —
            // the connected screen, or the primary as fallback — so one pinned
            // to a *disconnected* display stays reachable on the primary.
            return displays.resolveOrPrimary(hint)?.matches(focused) ?? true
          }
          // Dynamic: the monitor it was last on (or include if never activated).
          if let last = state.lastActiveDisplay[ws.id] { return last.matches(focused) }
          return true
        }
      } else {
        all
      }
    guard !workspaces.isEmpty else { return nil }
    // Anchor at the in-flight activation's target when it belongs to this
    // cycle scope, else the active workspace on the interaction display.
    // `primaryActive` only
    // updates on completion, so without the in-flight anchor every press
    // during a slow switch re-resolved to the same target.
    let inFlightWorkspaceID = settings.switching.cycleAcrossDisplays
      ? state.activatingWorkspaceID
      : state.activatingWorkspace(on: display ?? state.focusedDisplay)
    let currentID = inFlightWorkspaceID.flatMap { id in
      workspaces.contains(where: { $0.id == id }) ? id : nil
    }
      ?? state.activeWorkspace(on: display ?? state.focusedDisplay)
      ?? state.primaryActiveWorkspaceID
    let count = workspaces.count
    let currentIndex = workspaces.firstIndex { $0.id == currentID }
      ?? (direction > 0 ? -1 : count)

    let runningBundleIds: Set<String> = settings.switching.skipEmpty
      ? windowSnapshot.runningBundleIds()
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

  /// The full set of (display → workspace) activations to run when the display
  /// configuration changes. Pure so the rules + reclaim recursion are testable.
  ///
  /// It re-asserts every still-connected display's current workspace (so macOS's
  /// own window shuffle on a config change is overwritten by Tatami's layout),
  /// and fills each `newlyConnected` monitor per `chooseWorkspaceForDisplay`.
  /// When a pinned workspace is reclaimed from another display A, A is refilled
  /// by walking its history (recursively), skipping anything in use elsewhere.
  /// Per-display profile-switch HUDs: on each monitor, the profile name (title)
  /// + the workspace that lands there (subtitle). One HUD per display so a
  /// multi-monitor switch reads correctly on each screen; the per-workspace
  /// switch HUD is suppressed during the switch so these aren't clobbered.
  func profileSwitchHUDs(
    profile: Profile,
    plan: [DisplayAssignment],
    show: Bool,
    durationMs: Int,
    position: HUDPosition,
    size: HUDSize,
  ) -> Effect<Action> {
    guard show else { return .none }
    let name = profile.name
    let symbol = profile.symbolIconName ?? "rectangle.stack.fill"
    let entries = plan.compactMap { assignment in
      profile.workspaces[id: assignment.workspace].map { (assignment.display, $0.name) }
    }
    guard !entries.isEmpty else { return .none }
    return .run { [workspaceHUD] _ in
      for (display, workspaceName) in entries {
        await workspaceHUD.showAction(
          ActionHUDRequest(
            name: name,
            symbolIconName: symbol,
            subtitle: workspaceName,
            durationMs: durationMs,
            position: position,
            size: size,
            display: display,
          )
        )
      }
    }
  }

  /// Flush the display's composition (host + borrowed blocks) in one apply:
  /// each workspace's tree laid into its sub-rect, frames merged, applied
  /// together. No-op when the display has no active composition.
  func applyComposition(
    display: DisplayName?,
    forceAllFrames: Bool = false,
    followUp: PostLayoutFocus? = nil,
    monitorsPresentationChanges: Bool = false,
    presentationRepairKeys: Set<WindowKey> = [],
    borrowPhaseCompletion: BorrowPhase? = nil,
    // Default false: a borrow summon's own layout should still carry the
    // cursor to the borrowed block. Only a pointer-driven flush sets this.
    preservesPointer: Bool = false,
    state: inout State,
  ) -> Effect<Action> {
    let settings = state.config.settings
    guard
      let display,
      let comp = state.compositionsByDisplay[display],
      let slot = comp.borrowed.first,
      let hostTree = state.tilingTrees[comp.host]
    else {
      guard let phase = borrowPhaseCompletion else { return .none }
      return .send(
        .borrowCompositionLayoutCompleted(
          display: phase.display,
          workspaceId: phase.workspaceId,
          generation: phase.generation,
          composition: phase.composition,
        )
      )
    }
    let borrowedTree = state.tilingTrees[slot.workspace]
    let hostZoom = state.fullscreenZoomed[comp.host] ?? []
    let borrowedZoom = state.fullscreenZoomed[slot.workspace] ?? []
    let edge = slot.edge
    let fraction = slot.fraction
    let monitoredKeys = monitorsPresentationChanges
      ? state.armPresentationMonitoring(
        Set(hostTree.windows + (borrowedTree?.windows ?? [])),
        preservesPointer: preservesPointer,
      )
      : []
    state.layoutWriteGeneration &+= 1
    let layoutGeneration = state.layoutWriteGeneration
    state.activeLayoutWriteGenerations.insert(layoutGeneration)
    let writer = Effect<Action>.run { [tiler = windowTiler, displays] send in
      let merged: [WindowKey: CGRect] = await MainActor.run {
        let workArea = displays.workArea(display).insetBy(
          dx: CGFloat(settings.layout.gapOuter),
          dy: CGFloat(settings.layout.gapOuter),
        )
        let gap = CGFloat(settings.layout.gapInner)
        let (hostRect, borrowedRect) = Self.subRects(
          workArea: workArea,
          edge: edge,
          fraction: fraction,
          gap: gap,
        )
        let hf = Self.computeFrames(
          tree: hostTree,
          settings: settings,
          targetDisplay: display,
          fullscreenZoomed: hostZoom,
          targetRect: hostRect,
        )
        let bf = Self.computeFrames(
          tree: borrowedTree,
          settings: settings,
          targetDisplay: display,
          fullscreenZoomed: borrowedZoom,
          targetRect: borrowedRect,
        )
        return hf.merging(bf) { current, _ in current }
      }
      /// A Borrow's focus must not ride this writer's cancellation. Superseding
      /// layout writes are routine. A sync folding the borrowed window into the
      /// tree starts one, and they change where the block lands, not whether it
      /// gets focus. Dropping the notification here left the block summoned but
      /// unfocused, with the cursor still on the host. The reducer re-validates
      /// generation, pending completion and composition identity, so a genuinely
      /// stale one is rejected there rather than silently lost here.
      @Sendable
      func publishBorrowPhase() async {
        guard let phase = borrowPhaseCompletion else { return }
        await send(
          .borrowCompositionLayoutCompleted(
            display: phase.display,
            workspaceId: phase.workspaceId,
            generation: phase.generation,
            composition: phase.composition,
          )
        )
      }
      guard !Task.isCancelled else {
        await publishBorrowPhase()
        return
      }
      guard !merged.isEmpty else {
        await publishBorrowPhase()
        return
      }
      await tiler.apply(
        FrameApplication(windowFrames: merged, forceAllFrames: forceAllFrames)
      )
      await publishBorrowPhase()
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

  /// Re-apply a borrowed block after one of its windows becomes focused.
  /// Notification clicks and app-owned window selectors can make an already
  /// tiled window restore its saved frame after the immediate AX focus event.
  /// Membership is unchanged, so the ordinary sync is intentionally a no-op.
  /// Arm the exact affected windows and let their real geometry notification
  /// drive convergence; the immediate WindowServer verification covers a
  /// restore that landed just before this focus event.
  func monitorBorrowedPresentationAfterFocus(
    bundleId: String,
    preservesPointer: Bool,
    state: State,
  ) -> Effect<Action> {
    let sharedTiled = state.config.sharedApps.contains {
      $0.bundleIdentifier == bundleId && $0.layout == .tiled
    }
    let keys = state.compositionsByDisplay.values.reduce(into: Set<WindowKey>()) {
      keys, composition in
      guard
        let slot = composition.borrowed.first,
        state.tilingTrees[slot.workspace]?.windows.contains(where: {
          $0.bundleId == bundleId
        }) == true
        || sharedTiled
        || state.config.activeProfile?.workspaces[id: slot.workspace]?
        .apps.contains(where: {
          $0.bundleIdentifier == bundleId && $0.layout == .tiled
        }) == true
      else { return }
      keys.formUnion(
        (state.tilingTrees[slot.workspace]?.windows ?? [])
          .filter { sharedTiled || $0.bundleId == bundleId }
      )
    }
    guard !keys.isEmpty else { return .none }
    return .send(
      .presentationLayoutApplied(
        keys: keys,
        preservesPointer: preservesPointer,
      )
    )
  }

  /// Borrow `targetId` into the pointer display's host workspace, docked to
  /// `edge`. Re-borrowing a target already borrowed there dismisses it when
  /// `toggleBorrowOnRepeat` is on, otherwise it re-docks to the new edge. Live:
  /// the borrowed block reuses the target's real tree, so
  /// edits persist to it. Only the borrowed workspace's *tiled* apps take part
  /// — its floating / unmanaged apps are ignored while borrowed.
  func performBorrow(
    targetId: Workspace.ID,
    edge: BorrowEdge,
    displayOverride: DisplayName? = nil,
    state: inout State,
  ) -> Effect<Action> {
    guard
      let profile = state.config.activeProfile,
      let target = profile.workspaces[id: targetId],
      let display = displayOverride ?? interactionDisplay(state: state)
      ?? state.activeWorkspacesByDisplay.keys.first,
      let hostId = state.activeWorkspace(on: display),
      hostId != targetId,
      let hostWs = profile.workspaces[id: hostId]
    else { return .none }
    // Already borrowed here → dismiss by default. Users who want repeated
    // summons to move/refocus the block can turn the toggle behavior off.
    if
      let existingDisplay = state.compositionsByDisplay.keys.first(where: {
        $0.matches(display)
      }),
      let existing = state.compositionsByDisplay[existingDisplay],
      let idx = existing.borrowed.firstIndex(where: { $0.workspace == targetId })
    {
      if state.config.settings.switching.toggleBorrowOnRepeat {
        debugLog.log("Borrow", "repeat summon \(target.name) → dismiss")
        return dismissBorrow(display: existingDisplay, state: &state)
      }
      var comp = existing
      comp.borrowed[idx].edge = edge
      state.compositionsByDisplay[existingDisplay] = comp
      let generation = state.borrowGenerationByDisplay[existingDisplay, default: 0]
      state.pendingBorrowCompletionByDisplay[existingDisplay] = .init(
        workspaceId: targetId,
        generation: generation,
      )
      debugLog.log("Borrow", "re-dock \(target.name) → \(edge)")
      // Keep an in-flight first hydration valid: re-docking changes only the
      // composition edge, and that hydration's eventual flush reads this
      // current composition. Starting neither a replacement discovery nor a
      // new generation used to strand a fast re-dock with an empty block.
      return .send(
        .flushCompositionAndFocus(
          display: existingDisplay,
          workspaceId: targetId,
          generation: generation,
        )
      )
    }
    // One workspace/tree can have one physical display owner. Borrowing a
    // workspace already visible on another monitor would make two layout
    // writers fight over the same WindowKeys. Keep that monitor intact and
    // report the conflict instead of silently duplicating it.
    if
      let sourceDisplay = state.displayShowing(targetId),
      !sourceDisplay.matches(display)
    {
      debugLog.log(
        "Borrow",
        "skip \(target.name): already visible on \(sourceDisplay.name)",
      )
      return hudEffect(
        state,
        \.borrow,
        "Already visible",
        "rectangle.on.rectangle.slash",
        subtitle: "\(target.name) is on \(sourceDisplay.name)",
      )
    }
    let fraction = target.borrowFraction ?? state.config.settings.switching.borrowFraction
    let slot = BorrowedSlot(workspace: targetId, edge: edge, fraction: fraction)
    state.borrowGenerationByDisplay[display, default: 0] &+= 1
    let borrowGeneration = state.borrowGenerationByDisplay[display, default: 0]
    state.pendingBorrowCompletionByDisplay[display] = .init(
      workspaceId: targetId,
      generation: borrowGeneration,
    )
    state.compositionsByDisplay[display] = Composition(host: hostId, borrowed: [slot])
    // Only tiled apps from the borrowed workspace participate; float / unmanaged
    // are ignored while borrowed. A scratchpad forces auto-open on all of them
    // (it only ever shows when borrowed, so its apps should come up then).
    let tiledBorrowed = target.apps.filter { $0.layout == .tiled }
    let tiledBorrowedBundleIds = tiledBorrowed.map(\.bundleIdentifier)
    let borrowedApps: [AppAssignment] = target.kind == .scratchpad
      ? tiledBorrowed.map { var a = $0
        a.autoOpen = true
        return a
      }
      : tiledBorrowed
    let existingBorrowedTree = state.tilingTrees[targetId]
    let request = ActivationRequest(
      workspace: hostWs,
      sharedApps: state.config.sharedApps,
      targetDisplay: display,
      setFocus: false,
      borrowedApps: borrowedApps,
      managedBundleIds: state.managedBundleIds,
      knownWindows: Set(existingBorrowedTree?.windows ?? []),
    )
    let settings = state.config.settings
    let focusedForBorrowMerge = state.lastObservedFocusedWindow
    debugLog.log("Borrow", "borrow \(target.name) → host=\(hostWs.name) edge=\(edge)")
    let hud = hudEffect(
      state,
      \.borrow,
      "Borrowed \(target.name)",
      Self.borrowEdgeIcon(edge),
    )
    let render = Effect<Action>.run {
      [
        mgr = workspaceManager,
        observer = windowObserver,
        snapshot = windowSnapshot,
        displays,
      ] send in
      // Borrowed workspaces are visible without becoming the display's active
      // host, so the normal activation-completion observer setup never sees
      // them. Arm their apps alongside the reveal; a replacement surface that
      // appears after discovery then gets an immediate sync.
      async let observation: Void = observer.observe(tiledBorrowedBundleIds)
      await mgr.activate(request)
      // Independent app processes resolve concurrently; WindowSnapshotClient
      // still serializes every AX operation per PID. This bounds cold Borrow
      // latency by the slowest app instead of summing every app's timeout.
      let discovered = await withTaskGroup(
        of: (Int, [WindowKey]).self,
        returning: [WindowKey].self,
      ) { group in
        for (index, bundleId) in tiledBorrowedBundleIds.enumerated() {
          group.addTask {
            let keys: [WindowKey] =
              switch await snapshot.cachedKeysOnlyOffMain([bundleId], true) {
              case .hit(let cached) where !cached.isEmpty:
                // A non-empty cache hit keeps the repeated-Borrow zero-AX path.
                cached
              case .hit,
                   .miss:
                // A miss and a warm empty result each need exactly one fresh
                // post-unhide scan.
                await snapshot.discoverKeysOffMain([bundleId], true)
              }
            return (index, keys)
          }
        }
        var results = [(Int, [WindowKey])]()
        for await result in group { results.append(result) }
        return results.sorted { $0.0 < $1.0 }.flatMap(\.1)
      }
      guard !Task.isCancelled else { return }
      // Validate identity, not immediate visibility. `unhide()` returns before
      // WindowServer necessarily publishes the reused surface through
      // `.optionOnScreenOnly`; filtering there erased a live cached KakaoTalk
      // window and left the Borrow block empty until another window was opened.
      // Exact WindowServer existence still rejects a retired/reused key.
      let existingKeys = snapshot.existingWindowKeys(discovered)
      let keys = discovered.filter(existingKeys.contains)
      let tree = await MainActor.run { () -> BSPNode<WindowKey>? in
        let workArea = displays.workArea(display).insetBy(
          dx: CGFloat(settings.layout.gapOuter),
          dy: CGFloat(settings.layout.gapOuter),
        )
        return Self.mergeTree(
          existing: existingBorrowedTree,
          target: keys,
          focused: { focusedForBorrowMerge },
          insertionPoint: nil,
          workArea: workArea,
          settings: settings,
        )
      }
      await send(
        .borrowedTilingTreeHydrated(
          display: display,
          workspaceId: targetId,
          generation: borrowGeneration,
          previousTree: existingBorrowedTree,
          tree: tree,
        )
      )
      // The borrowed tree is now in state. Apply every host/borrow AX frame
      // first, then land focus + cursor on the completed block. Previously the
      // layout and focus effects raced on the main actor, which made the
      // summon visibly hitch and could wake an overlapping floating mirror.
      await send(
        .flushCompositionAndFocus(
          display: display,
          workspaceId: targetId,
          generation: borrowGeneration,
        )
      )
      // Observer readiness is not part of the visible layout/focus critical
      // path. Its synthetic create event reconciles any surface that raced the
      // snapshot, and this verification catches a frame restore that landed
      // while the AX notifications were being armed.
      _ = await observation
      await send(
        .presentationObservationReady(
          bundleIds: Set(tiledBorrowedBundleIds)
        )
      )
    }
    .cancellable(
      id: CancelID.borrowRender(display),
      cancelInFlight: true,
    )
    return .concatenate(
      .cancel(id: CancelID.borrowFocus(display)),
      .merge(render, hud),
    )
  }

  /// Land focus on a just-summoned borrowed block: the last-used window still
  /// in its tree, else the tree's first window, and — under mouse-follows-focus
  /// — warp the cursor onto it. A deliberate borrow means "work in this now", so
  /// focus + cursor should follow; the borrow itself only *unhides* the apps
  /// (`setFocus: false`) and leaves both on the host. A scratchpad seemed to
  /// land focus only by accident — force-opening its app spawns a fresh window
  /// that the new-window sync warps to — but borrowing an already-running
  /// workspace creates no window, so it never warped. This makes both
  /// consistent. No-op while the borrowed tree is still empty (a cold-launching
  /// app); the new-window sync warps once its window appears, as before.
  func focusBorrowedBlock(
    workspaceId: Workspace.ID,
    completion: BorrowPhase? = nil,
    state: inout State,
  ) -> Effect<Action> {
    guard let tree = state.tilingTrees[workspaceId] else { return .none }
    let target = (state.mruWindows[workspaceId] ?? [])
      .first { tree.windows.contains($0) } ?? tree.windows.first
    guard let target else { return .none }
    debugLog.log("Borrow", "focus borrowed block → \(target.bundleId)#\(target.windowID)")
    // Keep the two main-thread AX operations ordered. Merging focus and warp
    // let app activation win the race after the pointer had already moved,
    // producing a focused Borrow block with the cursor left on its host.
    return settleFocusAfterLayout(
      target,
      workspaceId: workspaceId,
      shouldFocus: true,
      borrowCompletion: completion,
      state: &state,
    )
  }

  /// End the borrow on `display`: drop the composition and re-activate the
  /// host alone, which hides the borrowed apps (no longer in keepVisible) and
  /// re-tiles the host to the full work area. Fire-and-forget.
  /// The recent target shared by switch / assign / borrow. Local mode uses a
  /// strict per-display history; global mode walks workspace MRU across every
  /// display while excluding the workspace on the interaction display.
  func recentWorkspaceId(state: State, display: DisplayName?) -> Workspace.ID? {
    let interactionDisplay = display ?? state.focusedDisplay
    guard let workspaces = state.config.activeProfile?.workspaces else { return nil }
    let isEligible: (Workspace.ID) -> Bool = { id in
      workspaces[id: id]?.kind == .normal
    }
    guard state.config.settings.switching.recentAcrossDisplays else {
      if let interactionDisplay {
        if let previous = state.previousWorkspace(on: interactionDisplay), isEligible(previous) {
          return previous
        }
        let exactHistory = state.displayWorkspaceHistory[interactionDisplay]
        let connectedUUIDsWithSameName = Set(state.connectedDisplays.compactMap { candidate in
          candidate.name == interactionDisplay.name ? candidate.uuid : nil
        })
        let matchingHistory = connectedUUIDsWithSameName.count <= 1
          ? state.displayWorkspaceHistory.first(where: {
            $0.key.matches(interactionDisplay)
          })?.value
          : nil
        let current = state.activeWorkspace(on: interactionDisplay)
        return (exactHistory ?? matchingHistory ?? []).first {
          $0 != current && isEligible($0)
        }
      }
      return state.previousWorkspacesByDisplay.values.first(where: isEligible)
    }
    let current = state.activeWorkspace(on: interactionDisplay)
      ?? state.primaryActiveWorkspaceID
    return state.workspaceMRU.first { $0 != current && isEligible($0) }
  }

  /// The window a visible workspace can hand keyboard focus to right now.
  /// Nil means there is nothing to focus, so a focus transfer would be a
  /// silent no-op and the caller has to run a real activation instead.
  func visibleFocusTarget(_ workspaceId: Workspace.ID, state: State) -> WindowKey? {
    (state.mruWindows[workspaceId] ?? []).first
      ?? state.tilingTrees[workspaceId]?.windows.first
  }

  /// Transfer keyboard focus to a workspace that is already visible without
  /// re-running activation. Activation intentionally tears down the target
  /// display's Borrow composition before re-tiling its host; display focus
  /// navigation must preserve that composition and focus its existing window.
  func focusVisibleWorkspace(
    workspaceId: Workspace.ID,
    display: DisplayName,
    workspaceChainHUD: WorkspaceChainHUDContext? = nil,
    workspaceChainCleanup: WorkspaceChainCleanupTransaction? = nil,
    state: inout State,
  ) -> Effect<Action> {
    guard state.displayShowing(workspaceId)?.matches(display) == true else {
      return .none
    }
    let oldDisplay = state.focusedDisplay
    state.focusedDisplay = display
    guard let target = visibleFocusTarget(workspaceId, state: state) else {
      debugLog.log(
        "Display",
        "focus visible \(workspaceId) on \(display.name): no window",
      )
      return .none
    }
    debugLog.log(
      "Display",
      "focus visible \(workspaceId) on \(display.name) "
        + "→ \(target.bundleId)#\(target.windowID)",
    )
    let focus = settleFocusAfterLayout(
      target,
      workspaceId: workspaceId,
      shouldFocus: true,
      state: &state,
    )
    let visibilityCleanup = workspaceChainCleanupEffect(
      transaction: workspaceChainCleanup,
      cleanups: workspaceChainCleanup.map {
        workspaceChainVisibilityCleanups($0, state: state)
      } ?? [],
    )
    guard let workspace = state.config.activeProfile?.workspaces[id: workspaceId]
    else { return .concatenate(focus, visibilityCleanup) }
    let showsWorkspaceSwitchHUD = state.config.settings.hud.shows(\.workspaceSwitch)
    let showsBorrowHUD = state.config.settings.hud.shows(\.borrow)
    let showsProfileSwitchHUD = workspaceChainHUD?.profileSwitch != nil
      && state.config.settings.hud.shows(\.profileSwitch)
    let returnedBorrowNames = workspaceChainHUD?.destinationReturnedBorrowNames ?? []
    let returnedBorrowFacts = showsBorrowHUD
      ? returnedBorrowSubtitles(returnedBorrowNames)
      : []
    let movedAcrossDisplays = oldDisplay?.matches(display) == false
    let hasWorkspaceChainPresentation = workspaceChainHUD != nil
    let showsWorkspaceResult = showsWorkspaceSwitchHUD
      && (movedAcrossDisplays || hasWorkspaceChainPresentation)
    let showsBorrowResult = showsBorrowHUD && !returnedBorrowFacts.isEmpty
    let deferredCleanupOwnsTargetHUD = workspaceChainCleanup != nil
      && workspaceChainHUD?.deferredCleanupHUDs.contains {
        $0.display.matches(display)
      } == true
    let durationMs = state.config.settings.hud.durationMs
    let position = state.config.settings.hud.position
    let size = state.config.settings.hud.size
    let visibleProfileSwitch = showsProfileSwitchHUD
      ? workspaceChainHUD?.profileSwitch
      : nil
    let hasWorkspaceChainIdentity = workspaceChainHUD?.role == .chainMember
    let visibleWorkspaceChainName = showsWorkspaceSwitchHUD && hasWorkspaceChainIdentity
      ? workspaceChainHUD?.name
      : nil
    let resultLine = (
      (visibleProfileSwitch == nil ? [] : [workspace.name])
        + [visibleWorkspaceChainName].compactMap { $0 }
        + returnedBorrowFacts
    ).joined(separator: " · ")
    let subtitle = resultLine
    var hudRequests = [ActionHUDRequest]()
    if
      !deferredCleanupOwnsTargetHUD,
      showsProfileSwitchHUD || showsWorkspaceResult || showsBorrowResult
    {
      hudRequests.append(ActionHUDRequest(
        name: visibleProfileSwitch?.name ?? workspace.name,
        symbolIconName: visibleProfileSwitch?.symbolIconName ?? workspace.symbolIconName,
        subtitle: subtitle.isEmpty ? nil : subtitle,
        subtitleSymbolIconName: hasWorkspaceChainIdentity
          ? workspaceChainHUD?.role.subtitleSymbolIconName
          : nil,
        subtitleExtendsDuration: !returnedBorrowFacts.isEmpty,
        durationMs: durationMs,
        position: position,
        size: size,
        display: display,
      ))
    }
    hudRequests.append(contentsOf: workspaceChainSourceCompositionHUDRequests(
      context: workspaceChainHUD,
      state: state,
    ))
    let focusMovedHUDRequest = workspaceChainHUD.map {
      uncoveredWorkspaceChainFocusMovedHUDRequest(
        workspace: workspace,
        context: $0,
        state: state,
      )
    } ?? self.focusMovedHUDRequest(
      workspace: workspace,
      from: oldDisplay,
      to: display,
      state: state,
    )
    if let movedHUD = focusMovedHUDRequest {
      hudRequests.append(movedHUD)
    }
    guard !hudRequests.isEmpty else {
      return .concatenate(focus, visibilityCleanup)
    }
    let hud = Effect<Action>.run { [workspaceHUD, hudRequests] _ in
      for request in hudRequests {
        guard !Task.isCancelled else { return }
        await workspaceHUD.showAction(request)
      }
    }
    .cancellable(id: CancelID.activationHUD, cancelInFlight: true)
    return .merge(.concatenate(focus, visibilityCleanup), hud)
  }

  func dismissBorrow(display: DisplayName?, state: inout State) -> Effect<Action> {
    // A hotkey passes nil → resolve the pointer display. Internal collapse
    // actions pass their exact owner so a background monitor stays isolated.
    let requestedDisplay = display ?? interactionDisplay(state: state)
      ?? state.compositionsByDisplay.keys.first
    guard
      let requestedDisplay,
      let display = state.compositionsByDisplay.keys.first(where: {
        $0.matches(requestedDisplay)
      }),
      let comp = state.compositionsByDisplay[display]
    else { return .none }
    debugLog.log("Borrow", "dismiss borrow on \(display.name) → restore host")
    state.borrowGenerationByDisplay[display, default: 0] &+= 1
    state.pendingBorrowCompletionByDisplay[display] = nil
    for slot in comp.borrowed {
      state.pendingCenterWarps[slot.workspace] = nil
    }
    // Re-activate the host on the composition's own display. A plain
    // `.activate` re-resolves a dynamic host from interaction focus/cursor and
    // could pull a background-display composition onto the wrong monitor.
    return performActivate(
      workspaceId: comp.host,
      setFocus: true,
      displayOverride: display,
      state: &state,
    )
  }

  /// Disarm the borrow direction pick: clear the target, remove the tap, and
  /// cancel the auto-timeout.
  func endBorrowCapture(state: inout State) -> Effect<Action> {
    state.borrowCapture = nil
    return .merge(
      .run { [borrowChord] _ in await borrowChord.setArmed(false) },
      .cancel(id: CancelID.borrowChordTimeout),
    )
  }

  /// Auto-cancel the borrow direction pick after a few idle seconds so a
  /// half-finished borrow can't keep the key tap swallowing keystrokes.
  func borrowChordTimeout() -> Effect<Action> {
    .run { [clock] send in
      try await clock.sleep(for: .seconds(5))
      await send(.borrowChordKey(.cancel))
    }
    .cancellable(id: CancelID.borrowChordTimeout, cancelInFlight: true)
  }

  /// HUD hint while a borrow direction pick is armed: which workspace, and
  /// that a direction key places it.
  func borrowChordHint(state: State) -> Effect<Action> {
    guard
      state.config.settings.hud.shows(\.borrow),
      let capture = state.borrowCapture,
      let name = state.config.activeProfile?.workspaces[id: capture.workspaceId]?.name
    else { return .none }
    let durationMs = max(state.config.settings.hud.durationMs, 4000)
    let position = state.config.settings.hud.position
    let size = state.config.settings.hud.size
    return .run { [workspaceHUD] _ in
      await workspaceHUD.showAction(
        ActionHUDRequest(
          name: String(localized: "Borrow \(name)"),
          symbolIconName: "rectangle.split.2x1",
          subtitle: String(localized: "press a direction · h j k l / arrows · esc"),
          durationMs: durationMs,
          position: position,
          size: size,
        )
      )
    }
  }

  /// Directional focus at a block edge crossing into the sibling composition
  /// block (host ↔ borrowed): the nearest window in the sibling toward the
  /// shared boundary, plus the geometry for a mouse warp. Nil when the
  /// direction doesn't point across the boundary or there's no sibling window.
  func crossBlockFocus(
    from key: WindowKey,
    currentId: Workspace.ID,
    currentTree: BSPNode<WindowKey>,
    currentRect: CGRect,
    direction: BSPDirection,
    state: State,
  ) -> (target: WindowKey, display: DisplayName?, tree: BSPNode<WindowKey>, rect: CGRect, zoomed: Set<WindowKey>)? {
    guard
      let display = state.displayShowing(currentId),
      let comp = state.compositionsByDisplay[display],
      let slot = comp.borrowed.first
    else { return nil }
    let dirEdge: BorrowEdge =
      switch direction {
      case .east: .right
      case .west: .left
      case .north: .top
      case .south: .bottom
      }
    // Host crosses toward the borrowed dock; borrowed crosses back (opposite).
    let siblingId: Workspace.ID
    if currentId == comp.host {
      guard dirEdge == slot.edge else { return nil }
      siblingId = slot.workspace
    } else if currentId == slot.workspace {
      guard dirEdge == slot.edge.opposite else { return nil }
      siblingId = comp.host
    } else {
      return nil
    }
    guard let siblingTree = state.tilingTrees[siblingId], !siblingTree.windows.isEmpty
    else { return nil }
    let gap = CGFloat(state.config.settings.layout.gapInner)
    let (_, siblingRect) = tilingContext(for: siblingId, state: state)
    let siblingFrames = siblingTree.frames(in: siblingRect, gap: gap)
    guard !siblingFrames.isEmpty else { return nil }
    let center: CGPoint = currentTree.frames(in: currentRect, gap: gap)[key]
      .map { CGPoint(x: $0.midX, y: $0.midY) }
      ?? CGPoint(x: currentRect.midX, y: currentRect.midY)
    let target = siblingFrames.min {
      hypot($0.value.midX - center.x, $0.value.midY - center.y)
        < hypot($1.value.midX - center.x, $1.value.midY - center.y)
    }?.key
    guard let target else { return nil }
    return (target, display, siblingTree, siblingRect, state.fullscreenZoomed[siblingId] ?? [])
  }

  /// The display + rect a workspace's tree should tile into right now: its
  /// composition sub-rect when it's a host/borrowed block, else its own
  /// display's full work area (pre-feature behavior). The single place every
  /// focus-relative BSP op resolves geometry, so composed and uncomposed
  /// paths can't drift.
  func tilingContext(for workspaceId: Workspace.ID, state: State) -> (display: DisplayName?, rect: CGRect) {
    if
      let display = state.displayShowing(workspaceId),
      let comp = state.compositionsByDisplay[display],
      let slot = comp.borrowed.first
    {
      let workArea = tilingWorkArea(for: display, settings: state.config.settings)
      let gap = CGFloat(state.config.settings.layout.gapInner)
      let (hostRect, borrowedRect) = Self.subRects(
        workArea: workArea,
        edge: slot.edge,
        fraction: slot.fraction,
        gap: gap,
      )
      if workspaceId == comp.host { return (display, hostRect) }
      if workspaceId == slot.workspace { return (display, borrowedRect) }
    }
    // Tile on the display the workspace is *actually* on — not its logical
    // home. A pinned workspace displaced off its (disconnected/other) monitor,
    // or a dynamic one moved across monitors, must lay out for the display it
    // really occupies; resolving to `displayHint`/`displays.current()` sized it
    // to the wrong monitor, leaving a gap / wrong ratio (the intermittent
    // cross-display tiling bug). `activeWorkspacesByDisplay` is the source of
    // truth for placement; fall back to the hint (fresh pinned activation) then
    // the cursor (fresh dynamic activation).
    let display = state.displayShowing(workspaceId)
      ?? state.config.activeProfile?.workspaces[id: workspaceId]?.displayHint
      ?? displays.current()
    return (display, tilingWorkArea(for: display, settings: state.config.settings))
  }

  // MARK: Private

  private func workspaceChainSourceHUDRequests(
    _ sources: [WorkspaceChainSourceCompositionHUD],
    context: WorkspaceChainHUDContext,
    state: State,
  ) -> [ActionHUDRequest] {
    guard !sources.isEmpty else { return [] }
    let showsWorkspaceSwitch = state.config.settings.hud.shows(\.workspaceSwitch)
    let showsBorrow = state.config.settings.hud.shows(\.borrow)
    let showsProfileSwitch = context.profileSwitch != nil
      && state.config.settings.hud.shows(\.profileSwitch)
    let visibleProfileSwitch = showsProfileSwitch ? context.profileSwitch : nil
    guard showsProfileSwitch || showsWorkspaceSwitch || showsBorrow else { return [] }
    let durationMs = state.config.settings.hud.durationMs
    let position = state.config.settings.hud.position
    let size = state.config.settings.hud.size
    return sources.compactMap { source in
      let hasChainIdentity = source.role == .chainMember
      let returned = showsBorrow
        ? returnedBorrowSubtitles(source.returnedBorrowNames)
        : []
      guard showsProfileSwitch || showsWorkspaceSwitch || !returned.isEmpty else { return nil }
      var resultFacts = showsProfileSwitch && source.movedWorkspaceDestination == nil
        ? [source.hostName]
        : []
      if showsWorkspaceSwitch && hasChainIdentity {
        resultFacts.append(context.name)
      }
      if
        showsProfileSwitch || showsWorkspaceSwitch,
        let destination = source.movedWorkspaceDestination
      {
        resultFacts.append(String(localized: "\(source.hostName) is on \(destination.name)"))
      }
      if
        showsWorkspaceSwitch && hasChainIdentity,
        let skipped = source.prioritySkippedWorkspaceName
      {
        resultFacts.append(String(localized: "Skipped by chain priority: \(skipped)"))
      }
      resultFacts.append(contentsOf: returned)
      let resultLine = resultFacts.joined(separator: " · ")
      let focusTransfer = showsWorkspaceSwitch
        ? workspaceChainFocusTransferSubtitle(on: source.display, context: context)
        : nil
      let subtitle = [resultLine.isEmpty ? nil : resultLine, focusTransfer]
        .compactMap { $0 }
        .joined(separator: "\n")
      return ActionHUDRequest(
        name: visibleProfileSwitch?.name ?? (
          source.movedWorkspaceDestination == nil
            ? source.hostName
            : String(localized: "Workspace moved")
        ),
        symbolIconName: visibleProfileSwitch?.symbolIconName ?? (
          source.movedWorkspaceDestination == nil
            ? source.hostSymbolIconName
            : "arrow.right.to.line"
        ),
        subtitle: subtitle.isEmpty ? nil : subtitle,
        subtitleSymbolIconName: hasChainIdentity
          ? source.role.subtitleSymbolIconName
          : nil,
        subtitleExtendsDuration: !returned.isEmpty
          || source.prioritySkippedWorkspaceName != nil,
        durationMs: durationMs,
        position: position,
        size: size,
        display: source.display,
      )
    }
  }

}

/// Whole milliseconds of a `Duration`, for the activation phase log.
private func ms(_ duration: Duration) -> Int64 {
  duration.components.seconds * 1000
    + duration.components.attoseconds / 1_000_000_000_000_000
}

extension SplitTypePreference {
  /// Translate the user-facing preference to the internal split axis
  /// used by `BSPNode.inserting(...)`. `.auto` returns nil so the
  /// aspect-ratio heuristic kicks in.
  func bspSplitAxis() -> BSPNode<WindowKey>.SplitAxis? {
    switch self {
    case .auto: nil
    case .horizontal: .horizontal
    case .vertical: .vertical
    }
  }
}
